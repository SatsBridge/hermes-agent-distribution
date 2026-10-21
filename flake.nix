{
  description = "Hermes Agent distribution and supporting tools";

  inputs = {
    codebase-memory-mcp = {
      inputs.nixpkgs.follows = "nixpkgs-unstable";
      url = "github:DeusData/codebase-memory-mcp/v0.11.0";
    };
    flake-compat.url = "github:NixOS/flake-compat";
    git-hooks.inputs.flake-compat.follows = "flake-compat";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
    git-hooks.url = "github:cachix/git-hooks.nix";
    nix-github-actions.inputs.nixpkgs.follows = "nixpkgs";
    nix-github-actions.url = "github:nix-community/nix-github-actions";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    treefmt-nix.url = "github:numtide/treefmt-nix";
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
      hermesModuleVm = nixpkgs-unstable.lib.nixosSystem {
        modules = [
          "${nixpkgs-unstable}/nixos/modules/virtualisation/qemu-vm.nix"
          ./nixos/hermes-module-vm.nix
          { nixpkgs.overlays = [ self.overlays.default ]; }
        ];
        system = "x86_64-linux";
      };
      hermesModuleVmConfigCheck =
        nixpkgs-unstable.legacyPackages.x86_64-linux.runCommand "hermes-module-vm-config-check" { }
          ''
            test ${toString hermesModuleVm.config.virtualisation.memorySize} -le 1024
            test ${toString hermesModuleVm.config.virtualisation.diskSize} -le 1024
            test ${if hermesModuleVm.config.virtualisation.useNixStoreImage then "false" else "true"} = true
            test ${
              if builtins.hasAttr "nix-store" hermesModuleVm.config.virtualisation.sharedDirectories then
                "false"
              else
                "true"
            } = true
            test ${
              if hermesModuleVm.config.fileSystems."/nix/.ro-store".fsType == "9p" then "true" else "false"
            } = true
            test ${
              if nixpkgs-unstable.lib.elem "ro" hermesModuleVm.config.fileSystems."/nix/.ro-store".options then
                "true"
              else
                "false"
            } = true
            test ${
              if
                builtins.any (
                  option:
                  nixpkgs-unstable.lib.hasInfix "mount_tag=nix-store" option
                  && nixpkgs-unstable.lib.hasInfix "readonly=on" option
                ) hermesModuleVm.config.virtualisation.qemu.options
              then
                "true"
              else
                "false"
            } = true
            test ${
              let
                agent = hermesModuleVm.config.services.hermes-specialised-agent;
                units = hermesModuleVm.config.systemd.services;
              in
              if
                agent.enable
                && agent.mainAgent == "vm"
                && !agent.installDefaultSkills
                && agent.agents.vm.enable
                && agent.agents.vm.headroomPort == 18080
                && !agent.agents.vm.headroomEnable
                && agent.agents.vm.portMappings == null
                && agent.agents.vm.settings.kanban.default_assignee == "hermes-vm"
                && agent.agents.vm-peer.enable
                && agent.agents.vm-peer.fullName != agent.agents.vm.fullName
                && agent.agents.vm-peer.headroomPort == 18081
                && !agent.agents.vm-peer.headroomEnable
                && builtins.hasAttr "hermes@vm" units
                && builtins.hasAttr "hermes@vm-peer" units
                && builtins.hasAttr "hermes@" units
                && builtins.hasAttr "hermes-network@vm" units
                && builtins.hasAttr "hermes-network@vm-peer" units
                && builtins.hasAttr "hermes-pf@vm" units
                && builtins.hasAttr "hermes-pf@vm-peer" units
                && units."hermes@vm".serviceConfig ? ExecStart
                && units."hermes@vm-peer".serviceConfig ? ExecStart
                && units."hermes@".serviceConfig.PrivateNetwork
                && builtins.elem "hermes-network@%i.service" units."hermes@".requires
                && builtins.elem "hermes-network@%i.service" units."hermes@".after
                && builtins.elem "hermes-network@vm.service" units."hermes@vm".unitConfig.JoinsNamespaceOf
                && builtins.elem "network-online.target" units."hermes-network@vm".after
                && builtins.elem "network-online.target" units."hermes-network@vm".wants
                && builtins.hasAttr "hermes-vm-late-resolver" units
                && builtins.elem "network-online.target" units.hermes-vm-late-resolver.before
                && !hermesModuleVm.config.networking.resolvconf.enable
                && units."hermes-network@vm".serviceConfig.PrivateNetwork
                && units."hermes-network@vm-peer".serviceConfig.PrivateNetwork
                && builtins.elem "CAP_SYS_PTRACE" units."hermes-network@vm".serviceConfig.CapabilityBoundingSet
                && units."hermes-pf@".serviceConfig.PrivateNetwork
                && units."hermes-pf@".serviceConfig.RestrictAddressFamilies == [ "AF_UNIX" ]
                && builtins.length units."hermes@".serviceConfig.ExecStartPre == 1
                && units."hermes-pf@".serviceConfig ? ExecStart
                && hermesModuleVm.config.networking.nftables.enable
                && hermesModuleVm.config.networking.firewall.backend == "nftables"
                && hermesModuleVm.config.networking.firewall.filterForward
                && hermesModuleVm.config.networking.nat.enable
                && hermesModuleVm.config.networking.nat.enableIPv6
                && builtins.elem "ha0" hermesModuleVm.config.networking.nat.internalInterfaces
                && builtins.elem "ha1" hermesModuleVm.config.networking.nat.internalInterfaces
                && builtins.hasAttr "hermes-agent-guard" hermesModuleVm.config.networking.nftables.tables
                && nixpkgs-unstable.lib.hasInfix "ha0" hermesModuleVm.config.networking.firewall.extraInputRules
                && nixpkgs-unstable.lib.hasInfix "ha1" hermesModuleVm.config.networking.firewall.extraInputRules
                && nixpkgs-unstable.lib.hasInfix "ha0" hermesModuleVm.config.networking.firewall.extraForwardRules
                && nixpkgs-unstable.lib.hasInfix "ha1" hermesModuleVm.config.networking.firewall.extraForwardRules
                && builtins.elem "%S/hermes-vm-peer" units."hermes@vm".serviceConfig.BindPaths
                && builtins.elem "%S/hermes-vm" units."hermes@vm-peer".serviceConfig.BindPaths
              then
                "true"
              else
                "false"
            } = true
            test ${
              if
                builtins.hasAttr "hermes-module-vm-smoke" hermesModuleVm.config.systemd.services
                && builtins.hasAttr "hermes-module-vm-agent-smoke" hermesModuleVm.config.systemd.services
              then
                "true"
              else
                "false"
            } = true
            touch "$out"
          '';
      packagesFor =
        system:
        let
          pkgs = nixpkgs-unstable.legacyPackages.${system}.extend self.overlays.default;
        in
        {
          apps = {
            gh-token-manager = {
              program = nixpkgs.lib.getExe pkgs.gh-token-manager;
              type = "app";
            };
            headroom = {
              program = nixpkgs.lib.getExe pkgs.headroom;
              type = "app";
            };
            headroom-proxy = {
              program = nixpkgs.lib.getExe pkgs.headroom-proxy;
              type = "app";
            };
          };
          checks = {
            git-hooks-gh-token-manager = pkgs.gh-token-manager.git-hooks;
            git-hooks-gh-token-manager-coverage = pkgs.gh-token-manager.coverage;
            git-hooks-git-hooks-headroom-hermes-plugin = pkgs.headroom-hermes-plugin.git-hooks;
            git-hooks-headroom = pkgs.headroom.git-hooks;
            git-hooks-headroom-proxy = pkgs.headroom-proxy.git-hooks;
            git-hooks-headroom-py = pkgs.headroom-py.git-hooks;
            inherit (pkgs)
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
          packages = {
            inherit (pkgs)
              gh-token-manager
              headroom
              headroom-hermes-plugin
              headroom-proxy
              headroom-py
              ;
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
      nixosConfigurations.hermes-module-vm = hermesModuleVm;
      overlays.default =
        final: prev:
        let
          byNameOverlay = import "${nixpkgs-unstable}/pkgs/top-level/by-name-overlay.nix" ./pkgs/by-name;
          codebase-memory-mcp = inputs.codebase-memory-mcp.packages.${system}.default.overrideAttrs (
            _:
            let
              version = "0.11.0";
            in
            {
              # Keep the embedded binary version aligned with this flake pin.
              CFLAGS_EXTRA = "-DCBM_VERSION=\\\"${version}\\\"";
              src = inputs.codebase-memory-mcp.outPath;
              inherit version;
            }
          );
          packageScope = final // {
            callPackage = fn: args: final.lib.callPackageWith packageScope fn args;
            inherit codebase-memory-mcp;
            gitHooks = git-hooks.lib.${system};
            treefmtEval = module: treefmt-nix.lib.evalModule final module;
          };
          system = final.stdenv.hostPlatform.system;
        in
        byNameOverlay packageScope prev;
      packages = forAllSystems (
        system:
        (packagesFor system).packages
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          hermes-module-vm-config-check = hermesModuleVmConfigCheck;
        }
      );
    };
}
