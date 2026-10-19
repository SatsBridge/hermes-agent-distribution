{
  description = "Hermes Agent distribution and supporting tools";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    codebase-memory-mcp = {
      url = "github:DeusData/codebase-memory-mcp/v0.11.0";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    flake-compat.url = "github:NixOS/flake-compat";
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
    git-hooks.inputs.flake-compat.follows = "flake-compat";
    nix-github-actions.url = "github:nix-community/nix-github-actions";
    nix-github-actions.inputs.nixpkgs.follows = "nixpkgs";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      codebase-memory-mcp,
      git-hooks,
      nix-github-actions,
      treefmt-nix,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      ghTokenManagerFor =
        system:
        import ./gh-token-manager/nix.nix {
          pkgs = nixpkgs.legacyPackages.${system};
          coveragePkgs = nixpkgs-unstable.legacyPackages.${system};
          gitHooks = git-hooks.lib.${system};
        };
      headroomFor =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system}.extend self.overlays.default;
          treefmt = (treefmt-nix.lib.evalModule pkgs ./headroom-nix/nix/treefmt.nix).config.build.wrapper;
          headroomHookSource = builtins.path {
            path = ./.;
            name = "headroom-hooks";
            filter =
              path: _:
              let
                relative = nixpkgs.lib.removePrefix "${toString ./.}/" (toString path);
                packageDirs = [
                  "pkgs/by-name/he/headroom"
                  "pkgs/by-name/he/headroom-hermes-plugin"
                  "pkgs/by-name/he/headroom-proxy"
                  "pkgs/by-name/he/headroom-py"
                ];
              in
              relative == ""
              || relative == "headroom-nix"
              || nixpkgs.lib.hasPrefix "headroom-nix/" relative
              || relative == "pkgs"
              || relative == "pkgs/by-name"
              || relative == "pkgs/by-name/he"
              || builtins.any (dir: relative == dir || nixpkgs.lib.hasPrefix "${dir}/" relative) packageDirs;
          };
          independentPkgs = import nixpkgs {
            inherit system;
            overlays = [ self.overlays.default ];
          };
          finalOverridePkgs = import nixpkgs {
            inherit system;
            overlays = [
              self.overlays.default
              (_: prev: {
                onnxruntime = prev.hello;
                rtk = prev.hello;
              })
            ];
          };
          overrideSourcePath = pkgs.runCommand "headroom-override-source" { } "mkdir -p $out";
          overrideSource = {
            version = "override-probe";
            src = overrideSourcePath;
            testSrc = overrideSourcePath;
          };
          overrideRustPlatform = {
            buildRustPackage = args: pkgs.runCommand "rust-platform-${args.version}" { } "touch $out";
          };
          overridePythonPackages = independentPkgs.python3Packages // {
            buildPythonPackage = args: pkgs.runCommand "python-package-${args.version}" { } "touch $out";
          };
          overlayRegression =
            assert
              (independentPkgs.headroom-proxy.override {
                headroomSource = overrideSource;
                rustPlatform = overrideRustPlatform;
              }).name == "rust-platform-override-probe";
            assert
              (independentPkgs.headroom-py.override {
                headroomSource = overrideSource;
                python3Packages = overridePythonPackages;
              }).name == "python-package-override-probe";
            assert
              (independentPkgs.headroom.override {
                headroomSource = overrideSource;
              }).name == "python3.13-headroom-override-probe";
            assert
              (independentPkgs.headroom-hermes-plugin.override {
                headroomSource = overrideSource;
              }).name == "headroom-hermes-plugin-override-probe";
            assert
              (independentPkgs.headroom-proxy.override {
                onnxruntime = independentPkgs.hello;
              }).drvPath != independentPkgs.headroom-proxy.drvPath;
            assert
              (independentPkgs.headroom.override {
                rtk = independentPkgs.hello;
              }).drvPath != independentPkgs.headroom.drvPath;
            assert finalOverridePkgs.headroom-proxy.drvPath != independentPkgs.headroom-proxy.drvPath;
            assert finalOverridePkgs.headroom.drvPath != independentPkgs.headroom.drvPath;
            pkgs.runCommand "headroom-overlay-regression" { } "touch $out";
          gitHooks = git-hooks.lib.${system}.run {
            src = headroomHookSource;
            package = pkgs.prek;
            hooks = {
              convco.enable = true;
              treefmt = {
                enable = true;
                package = treefmt;
                settings.fail-on-change = true;
              };
            };
          };
        in
        {
          packages = {
            inherit (pkgs)
              headroom-proxy
              headroom-py
              headroom
              headroom-hermes-plugin
              ;
            default = pkgs.headroom;
          };
          apps = {
            headroom-proxy = {
              type = "app";
              program = nixpkgs.lib.getExe pkgs.headroom-proxy;
            };
            headroom = {
              type = "app";
              program = nixpkgs.lib.getExe pkgs.headroom;
            };
            default = {
              type = "app";
              program = nixpkgs.lib.getExe pkgs.headroom;
            };
          };
          checks = {
            inherit (pkgs)
              headroom-proxy
              headroom-py
              headroom
              headroom-hermes-plugin
              ;
            clippy = pkgs.headroom-proxy.passthru.clippy;
            git-hooks = gitHooks;
            headroom-overlay = overlayRegression;
          };
          devShell = pkgs.mkShell {
            inputsFrom = [
              pkgs.headroom-proxy
              pkgs.headroom
            ];
            packages =
              gitHooks.enabledPackages
              ++ builtins.attrValues {
                inherit (pkgs)
                  rustc
                  cargo
                  maturin
                  uv
                  ;
              }
              ++ [ treefmt ];
            inherit (gitHooks) shellHook;
          };
        };
      treefmtEval = forAllSystems (
        system:
        treefmt-nix.lib.evalModule nixpkgs.legacyPackages.${system} {
          projectRootFile = "flake.nix";
          programs.nixfmt.enable = true;
          programs.rustfmt.enable = true;
        }
      );
    in
    {
      packages = forAllSystems (
        system:
        (headroomFor system).packages
        // {
          gh-token-manager = (ghTokenManagerFor system).package;
          default = self.packages.${system}.gh-token-manager;
        }
      );
      apps = forAllSystems (system: {
        inherit ((headroomFor system).apps) headroom headroom-proxy;
      });
      devShells = forAllSystems (system: {
        gh-token-manager = (ghTokenManagerFor system).devShell;
        headroom = (headroomFor system).devShell;
      });
      checks = forAllSystems (
        system:
        (headroomFor system).checks
        // {
          gh-token-manager = self.packages.${system}.gh-token-manager;
          coverage = (ghTokenManagerFor system).coverage;
          formatting = treefmtEval.${system}.config.build.check self;
          pre-commit-check = (ghTokenManagerFor system).pre-commit-check;
        }
      );
      formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);
      overlays.default =
        final: prev:
        let
          system = final.stdenv.hostPlatform.system;
          unstable = nixpkgs-unstable.legacyPackages.${system};
          headroomSource = import ./pkgs/by-name/he/headroom-proxy/headroom-source.nix { pkgs = final; };
          python3Packages = import ./pkgs/by-name/he/headroom-py/headroom-python.nix {
            pkgs = final;
            inherit unstable;
          };
          codebaseMemoryMcp = codebase-memory-mcp.packages.${system}.default.overrideAttrs (_: {
            version = "0.11.0";
            src = codebase-memory-mcp.outPath;
            # Keep the embedded binary version aligned with this flake pin.
            CFLAGS_EXTRA = "-DCBM_VERSION=\\\"0.11.0\\\"";
          });
          # Keep pinned defaults, but honor a dependency changed by a later overlay.
          onnxruntime =
            if final.onnxruntime.drvPath == prev.onnxruntime.drvPath then
              unstable.onnxruntime
            else
              final.onnxruntime;
          selectedRtk = if final.rtk.drvPath == prev.rtk.drvPath then unstable.rtk else final.rtk;
          byNameOverlay = import "${nixpkgs}/pkgs/top-level/by-name-overlay.nix" ./pkgs/by-name;
          packageScopes = {
            headroom-proxy = final // {
              inherit headroomSource onnxruntime;
              lib = unstable.lib;
              rustPlatform = unstable.rustPlatform;
              pkg-config = unstable.pkg-config;
              cmake = unstable.cmake;
              perl = unstable.perl;
              makeWrapper = unstable.makeWrapper;
              clippy = unstable.clippy;
              python3 = unstable.python3;
              stdenv = unstable.stdenv;
              libiconv = unstable.libiconv;
            };
            headroom-py = final // {
              inherit headroomSource python3Packages onnxruntime;
              lib = unstable.lib;
              writeText = unstable.writeText;
              rustPlatform = unstable.rustPlatform;
              pkg-config = unstable.pkg-config;
              cmake = unstable.cmake;
              perl = unstable.perl;
              stdenv = unstable.stdenv;
            };
            headroom = final // {
              inherit headroomSource python3Packages codebaseMemoryMcp;
              onnxruntime = onnxruntime;
              rtk = selectedRtk;
            };
            headroom-hermes-plugin = final // {
              inherit headroomSource;
            };
          };
          packageScopeFor =
            fn:
            let
              path = toString fn;
            in
            if nixpkgs.lib.hasInfix "/headroom-proxy/package.nix" path then
              packageScopes.headroom-proxy
            else if nixpkgs.lib.hasInfix "/headroom-py/package.nix" path then
              packageScopes.headroom-py
            else if nixpkgs.lib.hasInfix "/headroom/package.nix" path then
              packageScopes.headroom
            else if nixpkgs.lib.hasInfix "/headroom-hermes-plugin/package.nix" path then
              packageScopes.headroom-hermes-plugin
            else
              final;
          packageScope = final // {
            callPackage = fn: args: final.lib.callPackageWith (packageScopeFor fn) fn args;
          };
        in
        (byNameOverlay packageScope prev)
        // {
          gh-token-manager = self.packages.${system}.gh-token-manager;
        };
      githubActions = nix-github-actions.lib.mkGithubMatrix {
        checks = nixpkgs.lib.getAttrs [ "x86_64-linux" "aarch64-linux" ] self.checks;
      };
    };
}
