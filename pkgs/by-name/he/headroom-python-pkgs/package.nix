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
    hash = "sha256-70DAqvC2Q4V+qTBvx+3c4X6vn7BAfkgB8fxXWEQ6OOA=";
    pname = "onnx";
    version = "1.22.0";
  };
in
python313Packages.overrideScope (
  final: prev:
  let

    onnxCpp = onnx.overrideAttrs (old: {
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
      postPatch = ''
        mkdir -p absl/utility/internal
        cp ${./onnx-if-constexpr.h} absl/utility/internal/if_constexpr.h
        substituteInPlace pyproject.toml --replace-fail "protobuf==4.25.1" "protobuf>=4.25.1"
      '';
      preBuild = ''
        export PATH=${protobuf_29}/bin:$PATH
      ''
      + old.preBuild;
      src = onnxSource;
      version = "1.22.0";
    });
    # Keep Python and C++ protobuf runtimes aligned at 5.29 for AutoGen/ONNX.
    protobuf = prev.protobuf.overridePythonAttrs (_: {
      doCheck = false;
      postInstall = ''
        if [ -f "$out/${prev.python.sitePackages}/google/__init__.py" ]; then
          rm "$out/${prev.python.sitePackages}/google/__init__.py"
        fi
      '';
      propagatedNativeBuildInputs = [
        protobuf_29
        abseil-cpp
      ];
      src = prev.fetchPypi {
        hash = "sha256-2p7mpUJLazD9XkXF6mY671QMqV+a2Z0eiH6BnN+bhyM=";
        pname = "protobuf";
        version = "5.29.6";
      };
      version = "5.29.6";
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
        build-system = buildSystems;
        inherit dependencies pname version;
        pyproject = true;
        src = prev.fetchPypi {
          inherit hash version;
          pname = pypiName;
        };
      };
  in
  {

    agno = sourcePackage {
      dependencies = builtins.attrValues {
        inherit (final)
          docstring-parser
          gitpython
          h11
          httpx
          packaging
          pydantic
          pydantic-settings
          python-dotenv
          python-multipart
          pyyaml
          rich
          typer
          typing-extensions
          ;
      };
      hash = "sha256-yHZ/91KKT4t6qMBUNZLDucw8Lj9aKFJVWhxJNAjfOs8=";
      pname = "agno";
      version = "2.6.6";
    };

    anthropic = prev.anthropic.overridePythonAttrs (old: rec {
      dependencies = (old.dependencies or [ ]) ++ [ final.distro ];
      doCheck = false; # The sdist omits a hashed snapshot fixture required by one test.
      src = prev.fetchPypi {
        hash = "sha256-4Mrmo2iYbVz233Q9+7G5UZ5qnu6cbJQq2BIcCzRBb/4=";
        pname = "anthropic";
        inherit version;
      };
      version = "0.76.0";
    });

    any-llm-sdk = sourcePackage {
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
      hash = "sha256-duBD/KpW/M+zdakIURhp3H2/OT3ZeoLQa7dk2CAXJOg=";
      pname = "any-llm-sdk";
      pypiName = "any_llm_sdk";
      version = "1.12.1";
    };

    autogen-agentchat = sourcePackage {
      buildSystem = prev.hatchling;
      dependencies = [ final.autogen-core ];
      hash = "sha256-jZxxjbUu8kpRiAazoO+Ejw5MGQKHdnXcCr7XOo5ud1U=";
      pname = "autogen-agentchat";
      pypiName = "autogen_agentchat";
      version = "0.7.5";
    };

    autogen-core = sourcePackage {
      buildSystem = prev.hatchling;
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
      hash = "sha256-cMKHE4nx0Kf22473hxelG3zod/9KCKg2t3WNYE3s4gM=";
      pname = "autogen-core";
      pypiName = "autogen_core";
      version = "0.7.5";
    };

    # Headroom's [evals] and [voice-train] extras require datasets >=5.0.1.
    datasets = prev.datasets.overridePythonAttrs (_: rec {
      src = prev.fetchPypi {
        hash = "sha256-ziK7hR79dJTwiq0zuUCAN4RDT253dj0AZ5oNxF/PaGo=";
        pname = "datasets";
        inherit version;
      };
      version = "5.0.1";
    });

    frictionless = prev.frictionless.overridePythonAttrs (_: {
      doCheck = false;
      nativeCheckInputs = [ ];
    });

    # Match uv.lock; LiteLLM's bundled price map is part of runtime semantics.
    litellm = prev.litellm.overridePythonAttrs (old: rec {
      cargoDeps = rustPlatform.fetchCargoVendor {
        cargoRoot = "litellm-rust";
        hash = "sha256-LztGaOej87dfORnPTxgwAgqm2iEopxR8PRVkRngz4iE=";
        pname = "litellm";
        inherit src version;
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
      src = fetchFromGitHub {
        hash = "sha256-rYsMMuk3/DgSJclKrK354m9mJli3Ug2gR16+mIx0LDY=";
        owner = "BerriAI";
        repo = "litellm";
        tag = "v${version}";
      };
      version = "1.101.0";
    });

    lxml-html-clean = prev.lxml-html-clean.overridePythonAttrs (_: rec {
      src = prev.fetchPypi {
        hash = "sha256-4qTH1b7t0XzXtITYSKBXHlS6ojmk+d9VRuOsun+ZBWA=";
        pname = "lxml_html_clean";
        inherit version;
      };
      version = "0.4.5";
    });

    mem0ai = sourcePackage {
      buildSystem = prev.hatchling;
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
      hash = "sha256-yheaYvlF8RAuSQ7PHhT+5y1iXQ8QmnjHxe/LA1Z8/NA=";
      pname = "mem0ai";
      version = "2.0.5";
    };

    # These pure-Python packages use DuckDB only in their optional test backends.
    narwhals = prev.narwhals.overridePythonAttrs (_: {
      doCheck = false;
      nativeCheckInputs = [ ];
    });

    onnx = prev.onnx.overridePythonAttrs (_: {
      buildInputs = [ onnxCpp ];
      # The PyPI sdist has no tests directory; the C++ source derivation runs its test suite.
      doCheck = false;
      postUnpack = ''
        cp -rv "${onnxCpp.dist}" "$sourceRoot/dist"
        chmod +w "$sourceRoot/dist"
      '';
      src = onnxSource;
      version = "1.22.0";
    });

    openresponses-types = sourcePackage {
      buildSystem = prev.hatchling;
      dependencies = [ final.pydantic ];
      hash = "sha256-zVXn+hcjDY7dRuJU7zRmbKbyULfvo3EqEQqsVGx9yNU=";
      pname = "openresponses-types";
      pypiName = "openresponses_types";
      version = "2.4.0";
    };
    inherit protobuf;

    pydantic-settings = prev.pydantic-settings.overridePythonAttrs (_: rec {
      src = prev.fetchPypi {
        hash = "sha256-wZ3WSxkJfx3oAYTwzHsCcqE65uFwy/JAo+J+OB7RSl8=";
        pname = "pydantic_settings";
        inherit version;
      };
      version = "2.14.2";
    });

    strands-agents = sourcePackage {
      buildSystems = [
        prev.hatchling
        prev.hatch-vcs
      ];
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
      hash = "sha256-o3VfzAvv3ZnBtaXYqMmFkEkPC7erZQktz5OX91UTMd4=";
      pname = "strands-agents";
      pypiName = "strands_agents";
      version = "1.24.0";
    };

    torchaudio = prev.torchaudio.overridePythonAttrs (_: {
      doCheck = false; # shortcut: skip OOMing tests; re-enable when the builder has enough memory.
    });

    # Headroom pins <1.0 because tree-sitter-language-pack 1.x changed the
    # tree-sitter API. Build the 0.13 source distribution; nixpkgs 1.x fetches
    # precompiled parser bundles, which this package deliberately avoids.
    tree-sitter-language-pack = prev.buildPythonPackage {

      build-system = builtins.attrValues { inherit (prev) cython setuptools typing-extensions; };
      dependencies = builtins.attrValues {
        inherit (final)
          tree-sitter
          tree-sitter-c-sharp
          tree-sitter-embedded-template
          tree-sitter-yaml
          ;
      };

      meta = {
        description = "Tree-sitter language parsers built from source";
        homepage = "https://github.com/Goldziher/tree-sitter-language-pack";
        license = lib.licenses.mit;
        platforms = lib.platforms.linux;
      };
      nativeCheckInputs = [ prev.pytestCheckHook ];
      pname = "tree-sitter-language-pack";
      preCheck = ''
        # Pytest imports from the source root; make its compiled grammar modules visible there.
        cp build/lib.*/tree_sitter_language_pack/bindings/*.so \
          tree_sitter_language_pack/bindings/
      '';
      pyproject = true;
      pythonImportsCheck = [ "tree_sitter_language_pack" ];
      src = prev.fetchPypi {
        hash = "sha256-AyA0xeJ7H24AcwuefC28ggO0cA0MaB/QGdbe/PYRg+w=";
        pname = "tree_sitter_language_pack";
        version = "0.13.0";
      };
      version = "0.13.0";
    };
  }
)
