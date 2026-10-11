# Headroom 0.40 requires newer Python dependencies than nixos-26.05 provides.
# Keep them on nixpkgs-unstable's Python 3.13 set so compiled extensions share
# one interpreter; override only versions that still miss upstream's floors.
{ pkgs, unstable }:
unstable.python313Packages.overrideScope (
  final: prev: {
    pydantic-settings = prev.pydantic-settings.overridePythonAttrs (_: rec {
      version = "2.14.2";
      src = pkgs.fetchFromGitHub {
        owner = "pydantic";
        repo = "pydantic-settings";
        tag = "v${version}";
        hash = "sha256-7h0Jr/0qGJmve6fav9hKR1npDz29zD6Cci8h1TmuK4M=";
      };
    });

    lxml-html-clean = prev.lxml-html-clean.overridePythonAttrs (_: rec {
      version = "0.4.5";
      src = pkgs.fetchFromGitHub {
        owner = "fedora-python";
        repo = "lxml_html_clean";
        tag = version;
        hash = "sha256-R2FRaIgO0n9hNbKY4HYeqO0THXrXYokQekqers/Q1ao=";
      };
    });

    # Headroom's [evals] and [voice-train] extras require datasets >=5.0.1.
    datasets = prev.datasets.overridePythonAttrs (_: rec {
      version = "5.0.1";
      src = pkgs.fetchFromGitHub {
        owner = "huggingface";
        repo = "datasets";
        tag = version;
        hash = "sha256-/OE6lVUniOmCTuLXMYl8n3BIN+6HoZqlgy7Ou+iy1So=";
      };
    });

    # Match uv.lock; LiteLLM's bundled price map is part of runtime semantics.
    litellm = prev.litellm.overridePythonAttrs (_: rec {
      version = "1.101.0";
      src = pkgs.fetchFromGitHub {
        owner = "BerriAI";
        repo = "litellm";
        tag = "v${version}";
        hash = "sha256-rYsMMuk3/DgSJclKrK354m9mJli3Ug2gR16+mIx0LDY=";
      };
      cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
        pname = "litellm";
        inherit version src;
        cargoRoot = "litellm-rust";
        hash = "sha256-LztGaOej87dfORnPTxgwAgqm2iEopxR8PRVkRngz4iE=";
      };
    });

    # Headroom pins <1.0 because tree-sitter-language-pack 1.x changed the
    # tree-sitter API. Build the 0.13 source distribution; nixpkgs 1.x fetches
    # precompiled parser bundles, which this package deliberately avoids.
    tree-sitter-language-pack = prev.buildPythonPackage {
      pname = "tree-sitter-language-pack";
      version = "0.13.0";
      pyproject = true;
      src = pkgs.fetchurl {
        url = "https://files.pythonhosted.org/packages/c1/83/d1bc738d6f253f415ee54a8afb99640f47028871436f53f2af637c392c4f/tree_sitter_language_pack-0.13.0.tar.gz";
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
        license = pkgs.lib.licenses.mit;
        platforms = pkgs.lib.platforms.linux;
      };
    };
  }
)
