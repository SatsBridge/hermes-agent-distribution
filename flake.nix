{
  description = "Hermes Agent distribution and supporting tools";

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
          coveragePkgs = nixpkgs-unstable.legacyPackages.${system};
          ghTokenManager = import ./gh-token-manager/nix.nix {
            inherit pkgs coveragePkgs;
            gitHooks = git-hooks.lib.${system};
          };
        in
        {
          gh-token-manager = ghTokenManager.package;
          default = self.packages.${system}.gh-token-manager;
        }
      );
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          coveragePkgs = nixpkgs-unstable.legacyPackages.${system};
          ghTokenManager = import ./gh-token-manager/nix.nix {
            inherit pkgs coveragePkgs;
            gitHooks = git-hooks.lib.${system};
          };
        in
        {
          default = ghTokenManager.devShell;
        }
      );
      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          coveragePkgs = nixpkgs-unstable.legacyPackages.${system};
          ghTokenManager = import ./gh-token-manager/nix.nix {
            inherit pkgs coveragePkgs;
            gitHooks = git-hooks.lib.${system};
          };
        in
        {
          gh-token-manager = self.packages.${system}.gh-token-manager;
          coverage = ghTokenManager.coverage;
          formatting = treefmtEval.${system}.config.build.check self;
          pre-commit-check = ghTokenManager.pre-commit-check;
        }
      );
      formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);
    };
}
