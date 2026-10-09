{
  description = "Small Rust utilities packaged with nixpkgs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-compat.url = "github:NixOS/flake-compat";
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
    git-hooks.inputs.flake-compat.follows = "flake-compat";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      git-hooks,
      treefmt-nix,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
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
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          gh-token-manager = pkgs.rustPlatform.buildRustPackage {
            pname = "gh-token-manager";
            version = "0.1.0";
            src = ./gh-token-manager;
            nativeBuildInputs = [ pkgs.cacert ];
            cargoLock.lockFile = ./gh-token-manager/Cargo.lock;
          };
          default = self.packages.${system}.gh-token-manager;
        }
      );
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          coveragePkgs = nixpkgs-unstable.legacyPackages.${system};
          hooks = self.checks.${system}.pre-commit-check;
        in
        {
          default = pkgs.mkShell {
            packages =
              builtins.attrValues {
                inherit (pkgs)
                  cargo
                  rustc
                  clippy
                  rustfmt
                  cacert
                  ;
              }
              ++ [
                coveragePkgs.cargo-llvm-cov
                coveragePkgs.llvmPackages.llvm
                coveragePkgs.python3
              ]
              ++ hooks.enabledPackages;
            LLVM_COV = "${coveragePkgs.llvmPackages.llvm}/bin/llvm-cov";
            LLVM_PROFDATA = "${coveragePkgs.llvmPackages.llvm}/bin/llvm-profdata";
            shellHook = hooks.shellHook;
          };
        }
      );
      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          coveragePkgs = nixpkgs-unstable.legacyPackages.${system};
          coverageCheck = coveragePkgs.rustPlatform.buildRustPackage {
            pname = "gh-token-manager-coverage";
            version = "0.1.0";
            src = ./gh-token-manager;
            cargoLock.lockFile = ./gh-token-manager/Cargo.lock;
            doCheck = false;
            nativeBuildInputs = [
              coveragePkgs.cacert
              coveragePkgs.cargo-llvm-cov
              coveragePkgs.llvmPackages.llvm
              coveragePkgs.python3
            ];
            LLVM_COV = "${coveragePkgs.llvmPackages.llvm}/bin/llvm-cov";
            LLVM_PROFDATA = "${coveragePkgs.llvmPackages.llvm}/bin/llvm-profdata";
            RUSTC_BOOTSTRAP = "1";
            postBuild = ''
              mkdir -p coverage
              cargo llvm-cov --manifest-path Cargo.toml --offline --branch --json \
                --output-path coverage/report.json
              python3 check_coverage.py coverage/report.json
            '';
            installPhase = ''
              mkdir -p "$out"
              cp coverage/report.json "$out/coverage.json"
            '';
          };
        in
        {
          gh-token-manager = self.packages.${system}.gh-token-manager;
          coverage = coverageCheck;
          formatting = treefmtEval.${system}.config.build.check self;
          pre-commit-check = git-hooks.lib.${system}.run {
            src = ./gh-token-manager;
            rootSrc = pkgs.lib.mkForce (
              pkgs.runCommand "gh-token-manager-hook-source" { } ''
                mkdir -p "$out"
                cp -r ${./.}/. "$out/"
                cp ${./gh-token-manager/Cargo.lock} "$out/Cargo.lock"
              ''
            );
            package = pkgs.prek;
            settings.rust = {
              cargoManifestPath = "gh-token-manager/Cargo.toml";
              check.cargoDeps = pkgs.rustPlatform.importCargoLock {
                lockFile = ./gh-token-manager/Cargo.lock;
              };
            };
            hooks.clippy = {
              enable = true;
              packageOverrides = {
                inherit (pkgs) cargo clippy;
              };
              settings = {
                denyWarnings = true;
                offline = false;
              };
            };
          };
        }
      );
      formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);
    };
}
