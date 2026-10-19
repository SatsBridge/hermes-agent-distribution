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
          gitHooks = git-hooks.lib.${system}.run {
            src = ./headroom-nix;
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
          codebaseMemoryMcp = codebase-memory-mcp.packages.${system}.default.overrideAttrs (_: {
            version = "0.11.0";
            src = codebase-memory-mcp.outPath;
            # Keep the embedded binary version aligned with this flake pin.
            CFLAGS_EXTRA = "-DCBM_VERSION=\\\"0.11.0\\\"";
          });
          byNameOverlay = import "${nixpkgs}/pkgs/top-level/by-name-overlay.nix" ./pkgs/by-name;
          packageScope = final // {
            callPackage = final.lib.callPackageWith (
              final
              // {
                inherit unstable codebaseMemoryMcp;
                onnxruntime = unstable.onnxruntime;
                rtk = unstable.rtk;
              }
            );
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
