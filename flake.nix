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
        import ./headroom-nix/nix {
          pkgs = nixpkgs.legacyPackages.${system};
          unstable = nixpkgs-unstable.legacyPackages.${system};
          codebaseMemory = codebase-memory-mcp.packages.${system}.default.overrideAttrs (_: {
            version = "0.11.0";
            src = codebase-memory-mcp.outPath;
            # Keep the embedded binary version aligned with this flake pin.
            CFLAGS_EXTRA = "-DCBM_VERSION=\\\"0.11.0\\\"";
          });
          lib = nixpkgs.lib;
          inherit system treefmt-nix;
          inherit git-hooks;
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
      overlays.default = final: _prev: {
        gh-token-manager = self.packages.${final.stdenv.hostPlatform.system}.gh-token-manager;
        inherit ((headroomFor final.stdenv.hostPlatform.system).packages)
          headroom-proxy
          headroom-py
          headroom
          headroom-hermes-plugin
          ;
      };
      githubActions = nix-github-actions.lib.mkGithubMatrix {
        checks = nixpkgs.lib.getAttrs [ "x86_64-linux" "aarch64-linux" ] self.checks;
      };
    };
}
