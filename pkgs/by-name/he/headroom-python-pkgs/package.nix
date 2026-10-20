# Headroom 0.41 requires newer Python dependencies than nixos-26.05 provides.
# Keep them on nixpkgs-unstable's Python 3.13 set so compiled extensions share
# one interpreter; override only versions that still miss upstream's floors.
{
  abseil-cpp,
  fetchFromGitHub,
  lib,
  onnx,
  protobuf_29,
  python313Packages,
  python3Packages,
  rustPlatform,
}:
let
  # AutoGen requires protobuf 5.29; ONNX 1.23 requires protobuf 6.31+.
  # Keep ONNX on the compatible source release rather than weakening either constraint.
  onnxSource = python313Packages.fetchPypi {
    pname = "onnx";
    version = "1.22.0";
    hash = "sha256-70DAqvC2Q4V+qTBvx+3c4X6vn7BAfkgB8fxXWEQ6OOA=";
  };
in
python313Packages.overrideScope (
  final: prev:
  let
    # Keep Python and C++ protobuf runtimes aligned at 5.29 for AutoGen/ONNX.
    protobuf = prev.protobuf.overridePythonAttrs (_: {
      version = "5.29.6";
      src = prev.fetchPypi {
        pname = "protobuf";
        version = "5.29.6";
        hash = "sha256-2p7mpUJLazD9XkXF6mY671QMqV+a2Z0eiH6BnN+bhyM=";
      };
      propagatedNativeBuildInputs = [
        protobuf_29
        abseil-cpp
      ];
      doCheck = false;
      postInstall = ''
        if [ -f "$out/${prev.python.sitePackages}/google/__init__.py" ]; then
          rm "$out/${prev.python.sitePackages}/google/__init__.py"
        fi
      '';
    });

    onnxCpp = onnx.overrideAttrs (old: {
      version = "1.22.0";
      src = onnxSource;
      buildInputs = [
        abseil-cpp
        protobuf
        protobuf_29
      ];
      cmakeFlags = old.cmakeFlags ++ [ "-DCMAKE_CXX_STANDARD=20" ];
      env = old.env // {
        PYTHONPATH = python3Packages.makePythonPath (
          builtins.attrValues { inherit (python3Packages) protobuf scikit-build-core; }
        );
      };
      preBuild = ''
        export PATH=${protobuf_29}/bin:$PATH
      ''
      + old.preBuild;
      postPatch = ''
        mkdir -p absl/utility/internal
        cp ${./onnx-if-constexpr.h} absl/utility/internal/if_constexpr.h
        substituteInPlace pyproject.toml --replace-fail "protobuf==4.25.1" "protobuf>=4.25.1"
      '';
    });

    # These upstream extras are not packaged in nixpkgs yet; use pinned sdists.
    sourcePackage =
      {
        buildSystem ? prev.setuptools,
        buildSystems ? [ buildSystem ],
        dependencies ? [ ],
        hash,
        pname,
        pypiName ? pname,
        version,
      }:
      prev.buildPythonPackage {
        inherit pname version dependencies;
        pyproject = true;
        src = prev.fetchPypi {
          pname = pypiName;
          inherit version hash;
        };
        build-system = buildSystems;
      };
  in
  {
    inherit protobuf;

    # These pure-Python packages use DuckDB only in their optional test backends.
    narwhals = prev.narwhals.overridePythonAttrs (_: {
      doCheck = false;
      nativeCheckInputs = [ ];
    });

    frictionless = prev.frictionless.overridePythonAttrs (_: {
      doCheck = false;
      nativeCheckInputs = [ ];
    });

    torchaudio = prev.torchaudio.overridePythonAttrs (_: {
      doCheck = false; # shortcut: skip OOMing tests; re-enable when the builder has enough memory.
    });

    onnx = prev.onnx.overridePythonAttrs (_: {
      version = "1.22.0";
      src = onnxSource;
      buildInputs = [ onnxCpp ];
      # The PyPI sdist has no tests directory; the C++ source derivation runs its test suite.
      doCheck = false;
      postUnpack = ''
        cp -rv "${onnxCpp.dist}" "$sourceRoot/dist"
        chmod +w "$sourceRoot/dist"
      '';
    });

    pydantic-settings = prev.pydantic-settings.overridePythonAttrs (_: rec {
      version = "2.14.2";
      src = prev.fetchPypi {
        pname = "pydantic_settings";
        inherit version;
        hash = "sha256-wZ3WSxkJfx3oAYTwzHsCcqE65uFwy/JAo+J+OB7RSl8=";
      };
    });

    lxml-html-clean = prev.lxml-html-clean.overridePythonAttrs (_: rec {
      version = "0.4.5";
      src = prev.fetchPypi {
        pname = "lxml_html_clean";
        inherit version;
        hash = "sha256-4qTH1b7t0XzXtITYSKBXHlS6ojmk+d9VRuOsun+ZBWA=";
      };
    });

    # Headroom's [evals] and [voice-train] extras require datasets >=5.0.1.
    datasets = prev.datasets.overridePythonAttrs (_: rec {
      version = "5.0.1";
      src = prev.fetchPypi {
        pname = "datasets";
        inherit version;
        hash = "sha256-ziK7hR79dJTwiq0zuUCAN4RDT253dj0AZ5oNxF/PaGo=";
      };
    });

    # Match uv.lock; LiteLLM's bundled price map is part of runtime semantics.
    litellm = prev.litellm.overridePythonAttrs (old: rec {
      version = "1.101.0";
      src = fetchFromGitHub {
        owner = "BerriAI";
        repo = "litellm";
        tag = "v${version}";
        hash = "sha256-rYsMMuk3/DgSJclKrK354m9mJli3Ug2gR16+mIx0LDY=";
      };
      cargoDeps = rustPlatform.fetchCargoVendor {
        pname = "litellm";
        inherit version src;
        cargoRoot = "litellm-rust";
        hash = "sha256-LztGaOej87dfORnPTxgwAgqm2iEopxR8PRVkRngz4iE=";
      };
      postPatch = (old.postPatch or "") + ''
        ${prev.python.interpreter} - <<'PY'
        import json
        from pathlib import Path

        prices = Path("litellm/model_prices_and_context_window_backup.json")
        model_cost = json.loads(prices.read_text())
        model_cost["groq/llama-guard-3-8b"] = {
            "input_cost_per_token": 2e-7,
            "output_cost_per_token": 2e-7,
            "litellm_provider": "groq",
            "max_input_tokens": 8192,
            "max_output_tokens": 8192,
            "max_tokens": 8192,
            "mode": "chat",
        }
        prices.write_text(json.dumps(model_cost, indent=4) + "\n")
        PY
      '';
    });

    anthropic = prev.anthropic.overridePythonAttrs (old: rec {
      version = "0.76.0";
      src = prev.fetchPypi {
        pname = "anthropic";
        inherit version;
        hash = "sha256-4Mrmo2iYbVz233Q9+7G5UZ5qnu6cbJQq2BIcCzRBb/4=";
      };
      dependencies = (old.dependencies or [ ]) ++ [ final.distro ];
      doCheck = false; # The sdist omits a hashed snapshot fixture required by one test.
    });

    agno = sourcePackage {
      pname = "agno";
      version = "2.6.6";
      hash = "sha256-yHZ/91KKT4t6qMBUNZLDucw8Lj9aKFJVWhxJNAjfOs8=";
      dependencies = builtins.attrValues {
        inherit (final)
          docstring-parser
          gitpython
          h11
          httpx
          packaging
          pydantic-settings
          pydantic
          python-dotenv
          python-multipart
          pyyaml
          rich
          typer
          typing-extensions
          ;
      };
    };

    openresponses-types = sourcePackage {
      pname = "openresponses-types";
      pypiName = "openresponses_types";
      version = "2.4.0";
      buildSystem = prev.hatchling;
      hash = "sha256-zVXn+hcjDY7dRuJU7zRmbKbyULfvo3EqEQqsVGx9yNU=";
      dependencies = [ final.pydantic ];
    };

    any-llm-sdk = sourcePackage {
      pname = "any-llm-sdk";
      pypiName = "any_llm_sdk";
      version = "1.12.1";
      hash = "sha256-duBD/KpW/M+zdakIURhp3H2/OT3ZeoLQa7dk2CAXJOg=";
      dependencies = builtins.attrValues {
        inherit (final)
          httpx
          openai
          openresponses-types
          pydantic
          rich
          typing-extensions
          ;
      };
    };

    autogen-core = sourcePackage {
      pname = "autogen-core";
      pypiName = "autogen_core";
      version = "0.7.5";
      buildSystem = prev.hatchling;
      hash = "sha256-cMKHE4nx0Kf22473hxelG3zod/9KCKg2t3WNYE3s4gM=";
      dependencies = builtins.attrValues {
        inherit (final)
          jsonref
          opentelemetry-api
          pillow
          protobuf
          pydantic
          typing-extensions
          ;
      };
    };

    autogen-agentchat = sourcePackage {
      pname = "autogen-agentchat";
      pypiName = "autogen_agentchat";
      version = "0.7.5";
      buildSystem = prev.hatchling;
      hash = "sha256-jZxxjbUu8kpRiAazoO+Ejw5MGQKHdnXcCr7XOo5ud1U=";
      dependencies = [ final.autogen-core ];
    };

    mem0ai = sourcePackage {
      pname = "mem0ai";
      version = "2.0.5";
      buildSystem = prev.hatchling;
      hash = "sha256-yheaYvlF8RAuSQ7PHhT+5y1iXQ8QmnjHxe/LA1Z8/NA=";
      dependencies = builtins.attrValues {
        inherit (final)
          httpx
          openai
          posthog
          protobuf
          pydantic
          pytz
          qdrant-client
          sqlalchemy
          ;
      };
    };

    strands-agents = sourcePackage {
      pname = "strands-agents";
      pypiName = "strands_agents";
      version = "1.24.0";
      buildSystems = [
        prev.hatchling
        prev.hatch-vcs
      ];
      hash = "sha256-o3VfzAvv3ZnBtaXYqMmFkEkPC7erZQktz5OX91UTMd4=";
      dependencies = builtins.attrValues {
        inherit (final)
          boto3
          botocore
          docstring-parser
          httpx
          jsonschema
          mcp
          opentelemetry-api
          opentelemetry-instrumentation-threading
          opentelemetry-sdk
          pydantic
          typing-extensions
          watchdog
          ;
      };
    };

    # Headroom pins <1.0 because tree-sitter-language-pack 1.x changed the
    # tree-sitter API. Build the 0.13 source distribution; nixpkgs 1.x fetches
    # precompiled parser bundles, which this package deliberately avoids.
    tree-sitter-language-pack = prev.buildPythonPackage {
      pname = "tree-sitter-language-pack";
      version = "0.13.0";
      pyproject = true;
      src = prev.fetchPypi {
        pname = "tree_sitter_language_pack";
        version = "0.13.0";
        hash = "sha256-AyA0xeJ7H24AcwuefC28ggO0cA0MaB/QGdbe/PYRg+w=";
      };

      build-system = builtins.attrValues { inherit (prev) cython setuptools typing-extensions; };
      dependencies = builtins.attrValues {
        inherit (final)
          tree-sitter
          tree-sitter-c-sharp
          tree-sitter-embedded-template
          tree-sitter-yaml
          ;
      };
      nativeCheckInputs = [ prev.pytestCheckHook ];
      preCheck = ''
        # Pytest imports from the source root; make its compiled grammar modules visible there.
        cp build/lib.*/tree_sitter_language_pack/bindings/*.so \
          tree_sitter_language_pack/bindings/
      '';
      pythonImportsCheck = [ "tree_sitter_language_pack" ];

      meta = {
        description = "Tree-sitter language parsers built from source";
        homepage = "https://github.com/Goldziher/tree-sitter-language-pack";
        license = lib.licenses.mit;
        platforms = lib.platforms.linux;
      };
    };
  }
)
