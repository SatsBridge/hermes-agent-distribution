{
  description = "Hermes Agent distribution and supporting tools";

  inputs = {
    codebase-memory-mcp = {
      url = "github:DeusData/codebase-memory-mcp/v0.11.0";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    flake-compat.url = "github:NixOS/flake-compat";
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.flake-compat.follows = "flake-compat";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
    nix-github-actions.url = "github:nix-community/nix-github-actions";
    nix-github-actions.inputs.nixpkgs.follows = "nixpkgs";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      git-hooks,
      nix-github-actions,
      nixpkgs,
      nixpkgs-unstable,
      self,
      treefmt-nix,
      ...
    }@inputs:
    let
      forAllSystems = nixpkgs.lib.genAttrs systems;
      packagesFor =
        system:
        let
          pkgs = nixpkgs-unstable.legacyPackages.${system}.extend self.overlays.default;
        in
        {
          apps = {
            gh-token-manager = {
              type = "app";
              program = nixpkgs.lib.getExe pkgs.gh-token-manager;
            };
            headroom = {
              type = "app";
              program = nixpkgs.lib.getExe pkgs.headroom;
            };
            headroom-proxy = {
              type = "app";
              program = nixpkgs.lib.getExe pkgs.headroom-proxy;
            };
          };
          checks = {
            inherit (pkgs)
              headroom
              headroom-hermes-plugin
              headroom-proxy
              headroom-py
              ;
            git-hooks-gh-token-manager = pkgs.gh-token-manager.git-hooks;
            git-hooks-gh-token-manager-coverage = pkgs.gh-token-manager.coverage;
            git-hooks-git-hooks-headroom-hermes-plugin = pkgs.headroom-hermes-plugin.git-hooks;
            git-hooks-headroom = pkgs.headroom.git-hooks;
            git-hooks-headroom-proxy = pkgs.headroom-proxy.git-hooks;
            git-hooks-headroom-py = pkgs.headroom-py.git-hooks;
          };
          packages = {
            inherit (pkgs)
              gh-token-manager
              headroom
              headroom-hermes-plugin
              headroom-proxy
              headroom-py
              ;
          };
          devShells = {
            gh-token-manager = pkgs.gh-token-manager.devShell;
            headroom = pkgs.headroom.devShell;
            headroom-hermes-plugin = pkgs.headroom-hermes-plugin.devShell;
            headroom-proxy = pkgs.headroom-proxy.devShell;
            headroom-py = pkgs.headroom-py.devShell;
          };
        };
      rootTreefmtFor = system: treefmt-nix.lib.evalModule nixpkgs.legacyPackages.${system} ./treefmt.nix;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      apps = forAllSystems (system: (packagesFor system).apps);
      checks = forAllSystems (
        system:
        let
          packageChecks = (packagesFor system).checks;
        in
        packageChecks // { formatting = (rootTreefmtFor system).config.build.check self; }
      );
      devShells = forAllSystems (system: (packagesFor system).devShells);
      formatter = forAllSystems (system: (rootTreefmtFor system).config.build.wrapper);
      githubActions = nix-github-actions.lib.mkGithubMatrix {
        checks = nixpkgs.lib.getAttrs systems self.checks;
      };
      overlays.default =
        final: prev:
        let
          system = final.stdenv.hostPlatform.system;
          codebase-memory-mcp = inputs.codebase-memory-mcp.packages.${system}.default.overrideAttrs (
            _:
            let
              version = "0.11.0";
            in
            {
              inherit version;
              src = inputs.codebase-memory-mcp.outPath;
              # Keep the embedded binary version aligned with this flake pin.
              CFLAGS_EXTRA = "-DCBM_VERSION=\\\"${version}\\\"";
            }
          );
          packageScope = final // {
            callPackage = fn: args: final.lib.callPackageWith packageScope fn args;
            inherit codebase-memory-mcp;
            gitHooks = git-hooks.lib.${system};
            treefmtEval = module: treefmt-nix.lib.evalModule final module;
          };
          byNameOverlay = import "${nixpkgs-unstable}/pkgs/top-level/by-name-overlay.nix" ./pkgs/by-name;
        in
        byNameOverlay packageScope prev;
      packages = forAllSystems (system: (packagesFor system).packages);
    };
}
