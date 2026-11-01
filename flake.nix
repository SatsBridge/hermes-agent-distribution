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
      hermesAgentClosure = hermesModuleVm.pkgs.closureInfo {
        rootPaths = [ hermesModuleVm.pkgs.hermes-agent ];
      };
      defaultOnProbe = hermesModuleVm.extendModules {
        modules = [
          ({ lib, ... }: {
            services.hermes-specialised-agent = {
              installDefaultSkills = lib.mkForce true;
              agents.vm.headroomEnable = lib.mkForce true;
            };
          })
        ];
      };
      defaultOnRuntimeVm = internetEnabledVm.extendModules {
        modules = [
          ({ lib, ... }: {
            services.hermes-specialised-agent = {
              installDefaultSkills = lib.mkForce true;
              agents.vm.headroomEnable = lib.mkForce true;
            };

            systemd.services.hermes-module-vm-agent-smoke.environment.HERMES_VM_DEFAULT_ON_TEST =
              lib.mkForce "1";
            systemd.services.hermes-module-vm-agent-smoke.environment.HERMES_VM_SECURITY_ONLY = lib.mkForce "1";
            systemd.services.hermes-module-vm-agent-smoke.environment.HERMES_VM_PROFILE_IDENTITY_ONLY =
              lib.mkForce "1";
            systemd.services.hermes-module-vm-agent-smoke.environment.HERMES_VM_INTERNET_RECOVERY_ONLY =
              lib.mkOverride 40 "0";
          })
        ];
      };
      defaultOnFullProbe = defaultOnRuntimeVm.extendModules {
        modules = [
          ({ lib, ... }: {
            systemd.services.hermes-module-vm-agent-smoke.environment = {
              HERMES_VM_SECURITY_ONLY = lib.mkOverride 40 "0";
              HERMES_VM_PROFILE_IDENTITY_ONLY = lib.mkOverride 40 "0";
              HERMES_VM_INTERNET_RECOVERY_ONLY = lib.mkOverride 30 "0";
            };
          })
        ];
      };
      securityOnlyVm = hermesModuleVm.extendModules {
        modules = [
          ({ lib, ... }: {
            systemd.services.hermes-module-vm-agent-smoke.environment.HERMES_VM_SECURITY_ONLY = lib.mkForce "1";
          })
        ];
      };
      explicitDashboardProbe = hermesModuleVm.extendModules {
        modules = [
          {
            services.hermes-specialised-agent.agents.vm.portMappings = [
              {
                hostPort = 18199;
                agentPort = 9119;
                target = "loopback";
                protocol = "both";
              }
            ];
          }
        ];
      };
      networkManagerProbe = hermesModuleVm.extendModules {
        modules = [ ({ lib, ... }: { networking.networkmanager.enable = lib.mkForce true; }) ];
      };
      existingNetworkdProbe = hermesModuleVm.extendModules {
        modules = [ ({ lib, ... }: { networking.useNetworkd = lib.mkForce true; }) ];
      };
      dhcpcdUplinkProbe = hermesModuleVm.extendModules {
        modules = [ ({ lib, ... }: { networking.useNetworkd = lib.mkForce false; }) ];
      };
      explicitNetworkdWaitOnlineProbe = dhcpcdUplinkProbe.extendModules {
        modules = [ ({ lib, ... }: { systemd.network.wait-online.enable = lib.mkForce true; }) ];
      };
      # Keep the activation fixture's uplink networkd-owned; the Internet VM tests NM coexistence separately.
      networkdActivationBaseVm = hermesModuleVm;
      networkdRemovedVm = networkdActivationBaseVm.extendModules {
        modules = [
          ({ lib, ... }: {
            services.hermes-specialised-agent.agents.vm.enable = lib.mkForce false;
            services.hermes-specialised-agent.agents.vm-peer.enable = lib.mkForce false;
          })
        ];
      };
      internetEnabledVm = networkManagerProbe.extendModules {
        modules = [
          ({ lib, ... }: {
            virtualisation.restrictNetwork = lib.mkForce false;
            services.dnsmasq.settings.server = lib.mkForce [ "1.1.1.1" ];
            systemd.services.hermes-vm-late-resolver.script = lib.mkForce ''
              sleep 5
              # Keep .test lookups local; the host dnsmasq forwards public queries upstream.
              printf 'nameserver 127.0.0.1\n' > /run/hermes-vm-resolv.conf
              touch /run/hermes-vm-resolver-ready
            '';
            systemd.services.hermes-module-vm-agent-smoke.environment.HERMES_VM_INTERNET_TEST = lib.mkForce "1";
            systemd.services.hermes-module-vm-agent-smoke.environment.HERMES_VM_INTERNET_RECOVERY_ONLY =
              lib.mkForce "1";
            systemd.services.hermes-module-vm-agent-smoke.environment.HERMES_VM_NM_UPLINK_TEST =
              lib.mkForce "1";
          })
        ];
      };
      networkdIdleVm = networkdRemovedVm.extendModules {
        modules = [
          ({ lib, ... }: {
            systemd.services.hermes-module-vm-agent-smoke = {
              enable = lib.mkForce false;
              wantedBy = lib.mkForce [ ];
              requiredBy = lib.mkForce [ ];
              upheldBy = lib.mkForce [ ];
            };
            systemd.services.hermes-vm-generation-rollback-launcher = {
              enable = lib.mkForce false;
              wantedBy = lib.mkForce [ ];
              requiredBy = lib.mkForce [ ];
              upheldBy = lib.mkForce [ ];
            };
          })
        ];
      };
      networkdDisabledVm = networkdIdleVm.extendModules {
        modules = [ ({ lib, ... }: { services.hermes-specialised-agent.enable = lib.mkForce false; }) ];
      };
      networkdChangedVm = networkdActivationBaseVm.extendModules {
        modules = [
          ({ lib, ... }: {
            systemd = {
              network.networks."40-hermes-agent-0".extraConfig = "# Hermes networkd activation change probe";
              services = {
                hermes-module-vm-agent-smoke = {
                  enable = lib.mkForce false;
                  wantedBy = lib.mkForce [ ];
                  requiredBy = lib.mkForce [ ];
                  upheldBy = lib.mkForce [ ];
                };
                hermes-vm-generation-rollback-launcher = {
                  enable = lib.mkForce false;
                  wantedBy = lib.mkForce [ ];
                  requiredBy = lib.mkForce [ ];
                  upheldBy = lib.mkForce [ ];
                };
              };
            };
          })
        ];
      };
      networkdActivationVm = networkdActivationBaseVm.extendModules {
        modules = [
          ({ lib, ... }: {
            systemd.services = {
              hermes-module-vm-agent-smoke = {
                enable = lib.mkForce false;
                wantedBy = lib.mkForce [ ];
                requiredBy = lib.mkForce [ ];
                upheldBy = lib.mkForce [ ];
              };
              hermes-vm-generation-rollback-launcher = {
                wantedBy = [ "multi-user.target" ];
                environment.HERMES_VM_PREVIOUS_SYSTEM = lib.mkForce networkdDisabledVm.config.system.build.toplevel;
                environment.HERMES_VM_UPDATED_SYSTEM = lib.mkForce networkdChangedVm.config.system.build.toplevel;
                environment.HERMES_VM_REMOVED_SYSTEM = lib.mkForce networkdIdleVm.config.system.build.toplevel;
              };
            };
          })
        ];
      };
      hermesModuleVmGatewayStart = builtins.elemAt (nixpkgs.lib.splitString " "
        hermesModuleVm.config.systemd.services."hermes@vm".serviceConfig.ExecStart
      ) 3;
      defaultOnGatewayCommand =
        defaultOnProbe.config.systemd.services."hermes@vm".serviceConfig.ExecStart;
      defaultOnGatewayStart = builtins.elemAt (nixpkgs.lib.splitString " " defaultOnGatewayCommand) 3;
      defaultOnGatewaySettings = builtins.fromJSON (
        builtins.unsafeDiscardStringContext (
          builtins.readFile (nixpkgs.lib.last (nixpkgs.lib.splitString " " defaultOnGatewayCommand))
        )
      );
      hermesModuleVmConfigCheck =
        nixpkgs-unstable.legacyPackages.x86_64-linux.runCommand "hermes-module-vm-config-check" { }
          ''
            test ${toString hermesModuleVm.config.virtualisation.memorySize} -le 2048
            test ${toString hermesModuleVm.config.virtualisation.diskSize} -le 1024
            ${hermesModuleVm.config.systemd.services.hermes-vm-network-record-tests.serviceConfig.ExecStart}
            ${hermesModuleVm.pkgs.python3}/bin/python3 -I -B ${./nixos/tests/hermes-runtime/contracts.py} ${./modules/services/agent/hermes-runtime} ${hermesModuleVm.pkgs.coreutils}/bin/chown
            ${hermesModuleVm.pkgs.python3}/bin/python3 -c 'import pathlib,sys; [compile(pathlib.Path(p).read_text(),p,"exec") for p in sys.argv[1:]]; print("Generated network Python syntax: PASS")' ${
              nixpkgs-unstable.lib.escapeShellArgs (
                nixpkgs-unstable.lib.unique (
                  builtins.filter (path: nixpkgs-unstable.lib.hasSuffix ".py" path) (
                    nixpkgs-unstable.lib.concatMap
                      (role: hermesModuleVm.config.systemd.services."hermes-${role}@vm".serviceConfig.BindReadOnlyPaths)
                      [
                        "host-control"
                        "network-observer"
                        "dns"
                        "host-proxy"
                        "agent-relay"
                        "network-ready"
                      ]
                  )
                )
              )
            }
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
                unitFiles = hermesModuleVm.config.systemd.units;
                tmpfilesRules = hermesModuleVm.config.systemd.tmpfiles.rules;
                defaultOnUnits = defaultOnProbe.config.systemd.services;
                defaultOnTmpfilesRules = defaultOnProbe.config.systemd.tmpfiles.rules;
                disabledAgentProbe = hermesModuleVm.extendModules {
                  modules = [
                    ({ lib, ... }: {
                      services.hermes-specialised-agent.enable = lib.mkForce false;
                    })
                  ];
                };
                hostNetworkSource =
                  hermesModuleVm.config.environment.etc."systemd/network/40-hermes-agent-0.network".source;
                hostNetworkConfig = builtins.readFile hostNetworkSource;
                networkdReloadTriggers = hermesModuleVm.config.systemd.services.systemd-networkd.reloadTriggers;
                idleNetworkdReloadTriggers = networkdIdleVm.config.systemd.services.systemd-networkd.reloadTriggers;
                changedHostNetworkSource =
                  networkdChangedVm.config.environment.etc."systemd/network/40-hermes-agent-0.network".source;
                changedNetworkdReloadTriggers =
                  networkdChangedVm.config.systemd.services.systemd-networkd.reloadTriggers;
                networkdConfigSetTriggers =
                  triggers:
                  builtins.filter (
                    source: nixpkgs-unstable.lib.hasSuffix "-hermes-networkd-config-set" source
                  ) triggers;
                guardConfig = hermesModuleVm.config.networking.nftables.tables."hermes-agent-guard".content;
                hasMnemosyne = value: nixpkgs-unstable.lib.hasInfix "mnemosyne" value;
                hasMnemosyneEnvironment =
                  environment:
                  builtins.any (name: nixpkgs-unstable.lib.hasPrefix "MNEMOSYNE_" name) (
                    builtins.attrNames environment
                  );
                hasMnemosyneRuntimePath = service: builtins.any hasMnemosyne service.path;
                hasMnemosyneClosure =
                  service: builtins.any hasMnemosyne (service.serviceConfig.BindReadOnlyPaths or [ ]);
                storeBinds =
                  name:
                  map (
                    path: builtins.head (nixpkgs-unstable.lib.splitString ":" path)
                  ) units.${name}.serviceConfig.BindReadOnlyPaths;
                storeRoot =
                  path:
                  let
                    source = builtins.head (nixpkgs-unstable.lib.splitString ":" path);
                  in
                  nixpkgs-unstable.lib.concatStringsSep "/" (
                    nixpkgs-unstable.lib.take 4 (nixpkgs-unstable.lib.splitString "/" source)
                  );
                hasStoreRoot = executable: binds: builtins.elem (storeRoot executable) (map storeRoot binds);
                networkSetup = builtins.elemAt (nixpkgs-unstable.lib.splitString " "
                  units."hermes-network@vm".serviceConfig.ExecStart
                ) 3;
                gatewayStart = builtins.elemAt (nixpkgs-unstable.lib.splitString " "
                  units."hermes@vm".serviceConfig.ExecStart
                ) 3;
                closureProbe = hermesModuleVm.extendModules {
                  modules = [
                    (
                      { pkgs, ... }:
                      let
                        directExecProbe = pkgs.writeShellScriptBin "hermes-direct-exec-probe" "exit 0";
                        gatewayResource = pkgs.writeText "hermes-gateway-exec-resource" "resource\n";
                        gatewayQuotedResource = pkgs.writeText "hermes-gateway-quoted-exec-resource" "quoted\n";
                        networkResource = pkgs.writeText "hermes-network-exec-resource" "resource\n";
                        networkQuotedResource = pkgs.writeText "hermes-network-quoted-exec-resource" "quoted\n";
                        publicStateResource = pkgs.writeText "hermes-public-state-exec-resource" "resource\n";
                        publicStateQuotedResource = pkgs.writeText "hermes-public-state-quoted-exec-resource" "quoted\n";
                        discardedGatewayResource = pkgs.writeText "hermes-discarded-gateway-exec-resource" "discarded\n";
                        discardedNetworkResource = pkgs.writeText "hermes-discarded-network-exec-resource" "discarded\n";
                      in
                      {
                        systemd.services."hermes@vm".preStart = "${pkgs.hello}/bin/hello";
                        systemd.services."hermes-network@vm".preStart = "${pkgs.hello}/bin/hello";
                        systemd.services."hermes-pf@vm".preStart = "${pkgs.hello}/bin/hello";
                        systemd.services."hermes-dhcp@vm".preStart = "${pkgs.hello}/bin/hello";
                        systemd.services."hermes-network-ready@vm".preStart = "${pkgs.hello}/bin/hello";
                        systemd.services."hermes@".preStart = "${pkgs.hello}/bin/hello";
                        systemd.services."hermes-network@".preStart = "${pkgs.hello}/bin/hello";
                        systemd.services."hermes-network@".serviceConfig.ExecStartPost = "${pkgs.toilet}/bin/toilet";
                        systemd.services."hermes-pf@".preStart = "${pkgs.hello}/bin/hello";
                        systemd.services."hermes-pf@vm".path = [ pkgs.hello ];
                        systemd.services."hermes@vm".serviceConfig.ExecStartPost =
                          "${directExecProbe}/bin/hermes-direct-exec-probe";
                        systemd.services."hermes-network@vm".serviceConfig.ExecStop =
                          "${directExecProbe}/bin/hermes-direct-exec-probe";
                        systemd.services."hermes-pf@vm".serviceConfig.ExecStartPre =
                          "${directExecProbe}/bin/hermes-direct-exec-probe";
                        systemd.services."hermes-dhcp@vm".serviceConfig.ExecStopPost =
                          "${directExecProbe}/bin/hermes-direct-exec-probe";
                        systemd.services."hermes-network-ready@vm".serviceConfig.ExecStopPost =
                          "${directExecProbe}/bin/hermes-direct-exec-probe";
                        systemd.services."hermes-network@vm".serviceConfig.ExecReload = "${pkgs.figlet}/bin/figlet";
                        systemd.services."hermes@vm".serviceConfig.ExecReloadPost = [
                          "${pkgs.coreutils}/bin/cat ${gatewayResource} -- \"${gatewayQuotedResource}\""
                        ];
                        systemd.services."hermes-network@vm".serviceConfig.ExecReloadPost = [
                          "${pkgs.coreutils}/bin/cat ${networkResource} -- \"${networkQuotedResource}\""
                        ];
                        systemd.services."hermes-pf@vm".serviceConfig.ExecReloadPost = [
                          "${pkgs.coreutils}/bin/cat ${publicStateResource} -- \"${publicStateQuotedResource}\""
                        ];
                        systemd.services."hermes@".serviceConfig.ExecReload = "${discardedGatewayResource}";
                        systemd.services."hermes-network@".serviceConfig.ExecStop = "${discardedNetworkResource}";
                      }
                    )
                    (
                      { pkgs, lib, ... }:
                      {
                        systemd.services."hermes@vm" = lib.mkIf true {
                          serviceConfig.ExecCondition = "${pkgs.figlet}/bin/figlet";
                        };
                        systemd.services."hermes-network@vm" = lib.mkIf true {
                          serviceConfig = {
                            ExecReloadPost = lib.mkAfter [ "${pkgs.cowsay}/bin/cowsay" ];
                            ExecReload = lib.mkForce "${pkgs.coreutils}/bin/true";
                          };
                        };
                        systemd.services."hermes-pf@vm" = lib.mkMerge [
                          {
                            serviceConfig.ExecStopPost = "${pkgs.toilet}/bin/toilet";
                          }
                        ];
                        systemd.services."hermes-network@" = lib.mkIf true {
                          serviceConfig.ExecStartPost = lib.mkForce "${pkgs.coreutils}/bin/true";
                        };
                        systemd.services."hermes-network@vm-peer".serviceConfig = lib.mkIf true {
                          ExecStartPost = "${pkgs.figlet}/bin/figlet";
                        };
                        systemd.services."hermes-pf@vm-peer".serviceConfig = lib.mkIf false {
                          ExecStartPost = "${pkgs.toilet}/bin/toilet";
                        };
                      }
                    )
                    (
                      { lib, pkgs, ... }:
                      {
                        systemd.services."hermes@".serviceConfig = lib.mkForce (
                          hermesModuleVm.config.systemd.services."hermes@".serviceConfig
                          // {
                            ExecStartPost = "${pkgs.coreutils}/bin/true";
                          }
                        );
                        systemd.services."hermes-network@".serviceConfig = lib.mkForce (
                          hermesModuleVm.config.systemd.services."hermes-network@".serviceConfig
                          // {
                            ExecStartPost = "${pkgs.coreutils}/bin/true";
                          }
                        );
                      }
                    )
                  ];
                };
                assertionCheckFails =
                  probe:
                  let
                    result = builtins.tryEval (builtins.all (assertion: assertion.assertion) probe.config.assertions);
                  in
                  !result.success || !result.value;
                duplicateMappingProbe = hermesModuleVm.extendModules {
                  modules = [
                    {
                      services.hermes-specialised-agent.agents.vm-peer.portMappings = [
                        {
                          hostPort = 18194;
                          agentPort = 18090;
                          protocol = "tcp";
                        }
                      ];
                    }
                  ];
                };
                dashboardMappingCollisionProbe = hermesModuleVm.extendModules {
                  modules = [
                    {
                      services.hermes-specialised-agent.agents.vm-peer.portMappings = [
                        {
                          hostPort = 9119;
                          agentPort = 18199;
                          protocol = "udp";
                        }
                      ];
                    }
                  ];
                };
                invalidAddressProbe = hermesModuleVm.extendModules {
                  modules = [
                    {
                      services.hermes-specialised-agent.agents.vm.networkAllow = [
                        { address = "10.0.0.1/24"; }
                      ];
                    }
                  ];
                };
                invalidProtocolProbe = hermesModuleVm.extendModules {
                  modules = [
                    {
                      services.hermes-specialised-agent.agents.vm-peer.portMappings = [
                        {
                          hostPort = 18199;
                          agentPort = 18199;
                          protocol = "sctp";
                        }
                      ];
                    }
                  ];
                };
                closureProbeUnits = closureProbe.config.systemd.services;
                closureProbeBinds = name: closureProbeUnits.${name}.serviceConfig.BindReadOnlyPaths or [ ];
                hasJobScripts =
                  name:
                  builtins.all (
                    script: hasStoreRoot script (closureProbeBinds name)
                  ) closureProbeUnits.${name}.jobScripts;
                hasTemplateJobScripts =
                  name: template:
                  builtins.all (
                    script: hasStoreRoot script (closureProbeBinds name ++ closureProbeBinds template)
                  ) closureProbeUnits.${template}.jobScripts;
                hello = "${nixpkgs-unstable.legacyPackages.x86_64-linux.hello}/bin/hello";
                figlet = "${closureProbe.pkgs.figlet}/bin/figlet";
                cowsay = "${closureProbe.pkgs.cowsay}/bin/cowsay";
                toilet = "${closureProbe.pkgs.toilet}/bin/toilet";
                effectiveReload = closureProbeUnits."hermes-network@vm".serviceConfig.ExecReload;
                effectiveReloadPost = closureProbeUnits."hermes-network@vm".serviceConfig.ExecReloadPost;
                effectiveCondition = closureProbeUnits."hermes@vm".serviceConfig.ExecCondition;
                effectivePfStopPost = closureProbeUnits."hermes-pf@vm".serviceConfig.ExecStopPost;
                effectiveTemplateExecPost = closureProbeUnits."hermes-network@".serviceConfig.ExecStartPost;
                effectiveGatewayReload = closureProbeUnits."hermes@".serviceConfig.ExecReload or null;
                effectiveNetworkStop = closureProbeUnits."hermes-network@".serviceConfig.ExecStop or null;
                effectivePeerExec = closureProbeUnits."hermes-network@vm-peer".serviceConfig.ExecStartPost;
                disabledPeerExec = closureProbeUnits."hermes-pf@vm-peer".serviceConfig;
                directExec = closureProbeUnits."hermes@vm".serviceConfig.ExecStartPost;
                gatewayTemplateScript = builtins.head closureProbeUnits."hermes@".jobScripts;
                networkTemplateScript = builtins.head closureProbeUnits."hermes-network@".jobScripts;
                publicStateTemplateScript = builtins.head closureProbeUnits."hermes-pf@".jobScripts;
                gatewayResource = nixpkgs-unstable.legacyPackages.x86_64-linux.writeText "hermes-gateway-exec-resource" "resource\n";
                gatewayQuotedResource = nixpkgs-unstable.legacyPackages.x86_64-linux.writeText "hermes-gateway-quoted-exec-resource" "quoted\n";
                networkResource = nixpkgs-unstable.legacyPackages.x86_64-linux.writeText "hermes-network-exec-resource" "resource\n";
                networkQuotedResource = nixpkgs-unstable.legacyPackages.x86_64-linux.writeText "hermes-network-quoted-exec-resource" "quoted\n";
                publicStateResource = nixpkgs-unstable.legacyPackages.x86_64-linux.writeText "hermes-public-state-exec-resource" "resource\n";
                publicStateQuotedResource = nixpkgs-unstable.legacyPackages.x86_64-linux.writeText "hermes-public-state-quoted-exec-resource" "quoted\n";
                discardedGatewayResource = nixpkgs-unstable.legacyPackages.x86_64-linux.writeText "hermes-discarded-gateway-exec-resource" "discarded\n";
                discardedNetworkResource = nixpkgs-unstable.legacyPackages.x86_64-linux.writeText "hermes-discarded-network-exec-resource" "discarded\n";
                hasSandbox =
                  name: template:
                  let
                    text = unitFiles.${name}.text;
                    templateText = if template == null then "" else unitFiles.${template}.text;
                    has =
                      pattern:
                      nixpkgs-unstable.lib.hasInfix pattern text || nixpkgs-unstable.lib.hasInfix pattern templateText;
                  in
                  has "TemporaryFileSystem=/nix:ro"
                  && has "InaccessiblePaths=-/run/current-system"
                  && !has "BindReadOnlyPaths=/nix\n";
                hasStoreView =
                  name: template:
                  hasSandbox name template
                  && (nixpkgs-unstable.lib.hasInfix "BindReadOnlyPaths=/nix/store/" unitFiles.${name}.text);
              in
              if
                (
                  (assertionCheckFails duplicateMappingProbe)
                  || builtins.trace "Hermes config assertion 1: assertionCheckFails duplicateMappingProbe" false
                )
                && (
                  (assertionCheckFails dashboardMappingCollisionProbe)
                  || builtins.trace "Hermes config assertion 2: assertionCheckFails dashboardMappingCollisionProbe" false
                )
                && (
                  (assertionCheckFails invalidAddressProbe)
                  || builtins.trace "Hermes config assertion 3: assertionCheckFails invalidAddressProbe" false
                )
                && (
                  (assertionCheckFails invalidProtocolProbe)
                  || builtins.trace "Hermes config assertion 4: assertionCheckFails invalidProtocolProbe" false
                )
                && (
                  (nixpkgs-unstable.lib.hasInfix "ct direction reply"
                    hermesModuleVm.config.networking.nftables.tables."hermes-agent-guard".content
                  )
                  || builtins.trace "Hermes config assertion 5: nixpkgs-unstable.lib.hasInfix \"ct direction reply\" hermesModuleVm.config.networking.nftables.tables.\"hermes-agent-guard\".content" false
                )
                && (agent.enable || builtins.trace "Hermes config assertion 6: agent.enable" false)
                && (
                  (agent.mainAgent == "vm")
                  || builtins.trace "Hermes config assertion 7: agent.mainAgent == \"vm\"" false
                )
                && (
                  (!agent.installDefaultSkills)
                  || builtins.trace "Hermes config assertion 8: !agent.installDefaultSkills" false
                )
                && (
                  agent.agents.vm.enable || builtins.trace "Hermes config assertion 9: agent.agents.vm.enable" false
                )
                && (
                  (agent.agents.vm.headroomPort == 18080)
                  || builtins.trace "Hermes config assertion 10: agent.agents.vm.headroomPort == 18080" false
                )
                && (
                  (!agent.agents.vm.headroomEnable)
                  || builtins.trace "Hermes config assertion 11: !agent.agents.vm.headroomEnable" false
                )
                && (
                  (agent.agents.vm.portMappings == null)
                  || builtins.trace "Hermes config assertion 12: agent.agents.vm.portMappings == null" false
                )
                && (
                  (agent.agents.vm.settings.kanban.default_assignee == "hermes-vm")
                  || builtins.trace "Hermes config assertion 13: agent.agents.vm.settings.kanban.default_assignee == \"hermes-vm\"" false
                )
                && (
                  agent.agents.vm-peer.enable
                  || builtins.trace "Hermes config assertion 14: agent.agents.vm-peer.enable" false
                )
                && (
                  (agent.agents.vm-peer.fullName != agent.agents.vm.fullName)
                  || builtins.trace "Hermes config assertion 15: agent.agents.vm-peer.fullName != agent.agents.vm.fullName" false
                )
                && (
                  (agent.agents.vm-peer.headroomPort == 18081)
                  || builtins.trace "Hermes config assertion 16: agent.agents.vm-peer.headroomPort == 18081" false
                )
                && (
                  (!agent.agents.vm-peer.headroomEnable)
                  || builtins.trace "Hermes config assertion 17: !agent.agents.vm-peer.headroomEnable" false
                )
                && (
                  (builtins.hasAttr "hermes@vm" units)
                  || builtins.trace "Hermes config assertion 18: builtins.hasAttr \"hermes@vm\" units" false
                )
                && (
                  (builtins.hasAttr "hermes@vm-peer" units)
                  || builtins.trace "Hermes config assertion 19: builtins.hasAttr \"hermes@vm-peer\" units" false
                )
                && (
                  (builtins.hasAttr "hermes@" units)
                  || builtins.trace "Hermes config assertion 20: builtins.hasAttr \"hermes@\" units" false
                )
                && (
                  (builtins.hasAttr "hermes-network@" units)
                  || builtins.trace "Hermes config assertion 21: builtins.hasAttr \"hermes-network@\" units" false
                )
                && (
                  (builtins.hasAttr "hermes-network@vm" units)
                  || builtins.trace "Hermes config assertion 22: builtins.hasAttr \"hermes-network@vm\" units" false
                )
                && (
                  (builtins.hasAttr "hermes-network@vm-peer" units)
                  || builtins.trace "Hermes config assertion 23: builtins.hasAttr \"hermes-network@vm-peer\" units" false
                )
                && (
                  (builtins.hasAttr "hermes-pf@vm" units)
                  || builtins.trace "Hermes config assertion 24: builtins.hasAttr \"hermes-pf@vm\" units" false
                )
                && (
                  (builtins.hasAttr "hermes-pf@vm-peer" units)
                  || builtins.trace "Hermes config assertion 25: builtins.hasAttr \"hermes-pf@vm-peer\" units" false
                )
                && (
                  (hasStoreView "hermes@vm.service" "hermes@.service")
                  || builtins.trace "Hermes config assertion 26: hasStoreView \"hermes@vm.service\" \"hermes@.service\"" false
                )
                && (
                  (hasStoreView "hermes@vm-peer.service" "hermes@.service")
                  || builtins.trace "Hermes config assertion 27: hasStoreView \"hermes@vm-peer.service\" \"hermes@.service\"" false
                )
                && (
                  (hasStoreView "hermes-network@vm.service" "hermes-network@.service")
                  || builtins.trace "Hermes config assertion 28: hasStoreView \"hermes-network@vm.service\" \"hermes-network@.service\"" false
                )
                && (
                  (hasStoreView "hermes-network@vm-peer.service" "hermes-network@.service")
                  || builtins.trace "Hermes config assertion 29: hasStoreView \"hermes-network@vm-peer.service\" \"hermes-network@.service\"" false
                )
                && (
                  (hasSandbox "hermes-pf@.service" null)
                  || builtins.trace "Hermes config assertion 30: hasSandbox \"hermes-pf@.service\" null" false
                )
                && (
                  (hasStoreView "hermes-pf@vm.service" "hermes-pf@.service")
                  || builtins.trace "Hermes config assertion 31: hasStoreView \"hermes-pf@vm.service\" \"hermes-pf@.service\"" false
                )
                && (
                  (hasStoreView "hermes-pf@vm-peer.service" "hermes-pf@.service")
                  || builtins.trace "Hermes config assertion 32: hasStoreView \"hermes-pf@vm-peer.service\" \"hermes-pf@.service\"" false
                )
                && (
                  (!(hasStoreRoot networkSetup (storeBinds "hermes@vm")))
                  || builtins.trace "Hermes config assertion 33: !(hasStoreRoot networkSetup (storeBinds \"hermes@vm\"))" false
                )
                && (
                  (hasStoreRoot networkSetup (storeBinds "hermes@vm" ++ [ networkSetup ]))
                  || builtins.trace "Hermes config assertion 34: hasStoreRoot networkSetup (storeBinds \"hermes@vm\" ++ [ networkSetup ])" false
                )
                && (
                  (!(hasStoreRoot gatewayStart (storeBinds "hermes-network@vm")))
                  || builtins.trace "Hermes config assertion 35: !(hasStoreRoot gatewayStart (storeBinds \"hermes-network@vm\"))" false
                )
                && (
                  (hasStoreRoot gatewayStart (storeBinds "hermes-network@vm" ++ [ gatewayStart ]))
                  || builtins.trace "Hermes config assertion 36: hasStoreRoot gatewayStart (storeBinds \"hermes-network@vm\" ++ [ gatewayStart ])" false
                )
                && (
                  (hasStoreRoot hello (closureProbeBinds "hermes@vm"))
                  || builtins.trace "Hermes config assertion 37: hasStoreRoot hello (closureProbeBinds \"hermes@vm\")" false
                )
                && (
                  (hasJobScripts "hermes@vm")
                  || builtins.trace "Hermes config assertion 38: hasJobScripts \"hermes@vm\"" false
                )
                && (
                  (hasTemplateJobScripts "hermes@vm" "hermes@")
                  || builtins.trace "Hermes config assertion 39: hasTemplateJobScripts \"hermes@vm\" \"hermes@\"" false
                )
                && (
                  (hasStoreRoot directExec (closureProbeBinds "hermes@vm"))
                  || builtins.trace "Hermes config assertion 40: hasStoreRoot directExec (closureProbeBinds \"hermes@vm\")" false
                )
                && (
                  (!(hasStoreRoot directExec (closureProbeBinds "hermes@vm-peer")))
                  || builtins.trace "Hermes config assertion 41: !(hasStoreRoot directExec (closureProbeBinds \"hermes@vm-peer\"))" false
                )
                && (
                  (hasStoreRoot gatewayResource (closureProbeBinds "hermes@vm"))
                  || builtins.trace "Hermes config assertion 42: hasStoreRoot gatewayResource (closureProbeBinds \"hermes@vm\")" false
                )
                && (
                  (hasStoreRoot gatewayQuotedResource (closureProbeBinds "hermes@vm"))
                  || builtins.trace "Hermes config assertion 43: hasStoreRoot gatewayQuotedResource (closureProbeBinds \"hermes@vm\")" false
                )
                && (
                  (!(hasStoreRoot gatewayResource (closureProbeBinds "hermes@vm-peer")))
                  || builtins.trace "Hermes config assertion 44: !(hasStoreRoot gatewayResource (closureProbeBinds \"hermes@vm-peer\"))" false
                )
                && (
                  (!(hasStoreRoot networkResource (closureProbeBinds "hermes@vm")))
                  || builtins.trace "Hermes config assertion 45: !(hasStoreRoot networkResource (closureProbeBinds \"hermes@vm\"))" false
                )
                && (
                  (!(hasStoreRoot publicStateResource (closureProbeBinds "hermes@vm")))
                  || builtins.trace "Hermes config assertion 46: !(hasStoreRoot publicStateResource (closureProbeBinds \"hermes@vm\"))" false
                )
                && (
                  (
                    !(hasStoreRoot gatewayTemplateScript (
                      closureProbeBinds "hermes-network@vm" ++ closureProbeBinds "hermes-network@"
                    ))
                  )
                  || builtins.trace "Hermes config assertion 47: !(hasStoreRoot gatewayTemplateScript ( closureProbeBinds \"hermes-network@vm\" ++ closureProbeBinds \"hermes-network@\" ))" false
                )
                && (
                  (hasStoreRoot hello (closureProbeBinds "hermes-network@vm"))
                  || builtins.trace "Hermes config assertion 48: hasStoreRoot hello (closureProbeBinds \"hermes-network@vm\")" false
                )
                && (
                  (hasJobScripts "hermes-network@vm")
                  || builtins.trace "Hermes config assertion 49: hasJobScripts \"hermes-network@vm\"" false
                )
                && (
                  (hasTemplateJobScripts "hermes-network@vm" "hermes-network@")
                  || builtins.trace "Hermes config assertion 50: hasTemplateJobScripts \"hermes-network@vm\" \"hermes-network@\"" false
                )
                && (
                  (hasStoreRoot directExec (closureProbeBinds "hermes-network@vm"))
                  || builtins.trace "Hermes config assertion 51: hasStoreRoot directExec (closureProbeBinds \"hermes-network@vm\")" false
                )
                && (
                  (!(hasStoreRoot directExec (closureProbeBinds "hermes-network@vm-peer")))
                  || builtins.trace "Hermes config assertion 52: !(hasStoreRoot directExec (closureProbeBinds \"hermes-network@vm-peer\"))" false
                )
                && (
                  (hasStoreRoot networkResource (closureProbeBinds "hermes-network@vm"))
                  || builtins.trace "Hermes config assertion 53: hasStoreRoot networkResource (closureProbeBinds \"hermes-network@vm\")" false
                )
                && (
                  (hasStoreRoot networkQuotedResource (closureProbeBinds "hermes-network@vm"))
                  || builtins.trace "Hermes config assertion 54: hasStoreRoot networkQuotedResource (closureProbeBinds \"hermes-network@vm\")" false
                )
                && (
                  (!(hasStoreRoot networkResource (closureProbeBinds "hermes-network@vm-peer")))
                  || builtins.trace "Hermes config assertion 55: !(hasStoreRoot networkResource (closureProbeBinds \"hermes-network@vm-peer\"))" false
                )
                && (
                  (!(hasStoreRoot gatewayResource (closureProbeBinds "hermes-network@vm")))
                  || builtins.trace "Hermes config assertion 56: !(hasStoreRoot gatewayResource (closureProbeBinds \"hermes-network@vm\"))" false
                )
                && (
                  (!(hasStoreRoot publicStateResource (closureProbeBinds "hermes-network@vm")))
                  || builtins.trace "Hermes config assertion 57: !(hasStoreRoot publicStateResource (closureProbeBinds \"hermes-network@vm\"))" false
                )
                && (
                  (!(hasStoreRoot networkTemplateScript (closureProbeBinds "hermes-pf@")))
                  || builtins.trace "Hermes config assertion 58: !(hasStoreRoot networkTemplateScript (closureProbeBinds \"hermes-pf@\"))" false
                )
                && (
                  (hasStoreRoot hello (closureProbeBinds "hermes-pf@vm"))
                  || builtins.trace "Hermes config assertion 59: hasStoreRoot hello (closureProbeBinds \"hermes-pf@vm\")" false
                )
                && (
                  (hasJobScripts "hermes-pf@vm")
                  || builtins.trace "Hermes config assertion 60: hasJobScripts \"hermes-pf@vm\"" false
                )
                && (
                  (hasTemplateJobScripts "hermes-pf@" "hermes-pf@")
                  || builtins.trace "Hermes config assertion 61: hasTemplateJobScripts \"hermes-pf@\" \"hermes-pf@\"" false
                )
                && (
                  (hasStoreRoot hello (closureProbeBinds "hermes-pf@"))
                  || builtins.trace "Hermes config assertion 62: hasStoreRoot hello (closureProbeBinds \"hermes-pf@\")" false
                )
                && (
                  (hasStoreRoot directExec (closureProbeBinds "hermes-pf@vm"))
                  || builtins.trace "Hermes config assertion 63: hasStoreRoot directExec (closureProbeBinds \"hermes-pf@vm\")" false
                )
                && (
                  (!(hasStoreRoot directExec (closureProbeBinds "hermes-pf@vm-peer")))
                  || builtins.trace "Hermes config assertion 64: !(hasStoreRoot directExec (closureProbeBinds \"hermes-pf@vm-peer\"))" false
                )
                && (
                  (hasStoreRoot publicStateResource (closureProbeBinds "hermes-pf@vm"))
                  || builtins.trace "Hermes config assertion 65: hasStoreRoot publicStateResource (closureProbeBinds \"hermes-pf@vm\")" false
                )
                && (
                  (hasStoreRoot publicStateQuotedResource (closureProbeBinds "hermes-pf@vm"))
                  || builtins.trace "Hermes config assertion 66: hasStoreRoot publicStateQuotedResource (closureProbeBinds \"hermes-pf@vm\")" false
                )
                && (
                  (!(hasStoreRoot publicStateResource (closureProbeBinds "hermes-pf@vm-peer")))
                  || builtins.trace "Hermes config assertion 67: !(hasStoreRoot publicStateResource (closureProbeBinds \"hermes-pf@vm-peer\"))" false
                )
                && (
                  (!(hasStoreRoot gatewayResource (closureProbeBinds "hermes-pf@vm")))
                  || builtins.trace "Hermes config assertion 68: !(hasStoreRoot gatewayResource (closureProbeBinds \"hermes-pf@vm\"))" false
                )
                && (
                  (!(hasStoreRoot networkResource (closureProbeBinds "hermes-pf@vm")))
                  || builtins.trace "Hermes config assertion 69: !(hasStoreRoot networkResource (closureProbeBinds \"hermes-pf@vm\"))" false
                )
                && (
                  (hasStoreRoot hello (closureProbeBinds "hermes-dhcp@vm"))
                  || builtins.trace "Hermes config assertion 70: hasStoreRoot hello (closureProbeBinds \"hermes-dhcp@vm\")" false
                )
                && (
                  (hasJobScripts "hermes-dhcp@vm")
                  || builtins.trace "Hermes config assertion 71: hasJobScripts \"hermes-dhcp@vm\"" false
                )
                && (
                  (hasTemplateJobScripts "hermes-dhcp@vm" "hermes-dhcp@")
                  || builtins.trace "Hermes config assertion 72: hasTemplateJobScripts \"hermes-dhcp@vm\" \"hermes-dhcp@\"" false
                )
                && (
                  (hasStoreRoot directExec (closureProbeBinds "hermes-dhcp@vm"))
                  || builtins.trace "Hermes config assertion 73: hasStoreRoot directExec (closureProbeBinds \"hermes-dhcp@vm\")" false
                )
                && (
                  (hasStoreRoot hello (closureProbeBinds "hermes-network-ready@vm"))
                  || builtins.trace "Hermes config assertion 74: hasStoreRoot hello (closureProbeBinds \"hermes-network-ready@vm\")" false
                )
                && (
                  (hasJobScripts "hermes-network-ready@vm")
                  || builtins.trace "Hermes config assertion 75: hasJobScripts \"hermes-network-ready@vm\"" false
                )
                && (
                  (hasTemplateJobScripts "hermes-network-ready@vm" "hermes-network-ready@")
                  || builtins.trace "Hermes config assertion 76: hasTemplateJobScripts \"hermes-network-ready@vm\" \"hermes-network-ready@\"" false
                )
                && (
                  (hasStoreRoot directExec (closureProbeBinds "hermes-network-ready@vm"))
                  || builtins.trace "Hermes config assertion 77: hasStoreRoot directExec (closureProbeBinds \"hermes-network-ready@vm\")" false
                )
                && (
                  (hasStoreRoot figlet (closureProbeBinds "hermes@vm"))
                  || builtins.trace "Hermes config assertion 78: hasStoreRoot figlet (closureProbeBinds \"hermes@vm\")" false
                )
                && (
                  (effectiveCondition == figlet)
                  || builtins.trace "Hermes config assertion 79: effectiveCondition == figlet" false
                )
                && (
                  (builtins.elem cowsay effectiveReloadPost)
                  || builtins.trace "Hermes config assertion 80: builtins.elem cowsay effectiveReloadPost" false
                )
                && (
                  (hasStoreRoot cowsay (closureProbeBinds "hermes-network@vm"))
                  || builtins.trace "Hermes config assertion 81: hasStoreRoot cowsay (closureProbeBinds \"hermes-network@vm\")" false
                )
                && (
                  (!(disabledPeerExec ? ExecStartPost))
                  || builtins.trace "Hermes config assertion 82: !(disabledPeerExec ? ExecStartPost)" false
                )
                && (
                  (!(hasStoreRoot toilet (closureProbeBinds "hermes-pf@vm-peer")))
                  || builtins.trace "Hermes config assertion 83: !(hasStoreRoot toilet (closureProbeBinds \"hermes-pf@vm-peer\"))" false
                )
                && (
                  (effectivePeerExec == figlet)
                  || builtins.trace "Hermes config assertion 84: effectivePeerExec == figlet" false
                )
                && (
                  (hasStoreRoot figlet (closureProbeBinds "hermes-network@vm-peer"))
                  || builtins.trace "Hermes config assertion 85: hasStoreRoot figlet (closureProbeBinds \"hermes-network@vm-peer\")" false
                )
                && (
                  (effectivePfStopPost == toilet)
                  || builtins.trace "Hermes config assertion 86: effectivePfStopPost == toilet" false
                )
                && (
                  (hasStoreRoot toilet (closureProbeBinds "hermes-pf@vm"))
                  || builtins.trace "Hermes config assertion 87: hasStoreRoot toilet (closureProbeBinds \"hermes-pf@vm\")" false
                )
                && (
                  (effectiveTemplateExecPost == "${closureProbe.pkgs.coreutils}/bin/true")
                  || builtins.trace "Hermes config assertion 88: effectiveTemplateExecPost == \"\${closureProbe.pkgs.coreutils}/bin/true\"" false
                )
                && (
                  (hasStoreRoot effectiveTemplateExecPost (closureProbeBinds "hermes-network@vm"))
                  || builtins.trace "Hermes config assertion 89: hasStoreRoot effectiveTemplateExecPost (closureProbeBinds \"hermes-network@vm\")" false
                )
                && (
                  (!(hasStoreRoot toilet (closureProbeBinds "hermes-network@")))
                  || builtins.trace "Hermes config assertion 90: !(hasStoreRoot toilet (closureProbeBinds \"hermes-network@\"))" false
                )
                && (
                  (effectiveReload == "${closureProbe.pkgs.coreutils}/bin/true")
                  || builtins.trace "Hermes config assertion 91: effectiveReload == \"\${closureProbe.pkgs.coreutils}/bin/true\"" false
                )
                && (
                  (effectiveGatewayReload == null)
                  || builtins.trace "Hermes config assertion 92: effectiveGatewayReload == null" false
                )
                && (
                  (effectiveNetworkStop == null)
                  || builtins.trace "Hermes config assertion 93: effectiveNetworkStop == null" false
                )
                && (
                  (
                    units."hermes@".serviceConfig.TemporaryFileSystem
                    == hermesModuleVm.config.systemd.services."hermes@".serviceConfig.TemporaryFileSystem
                  )
                  || builtins.trace "Hermes config assertion 94: units.\"hermes@\".serviceConfig.TemporaryFileSystem == hermesModuleVm.config.systemd.services.\"hermes@\".serviceConfig.TemporaryFileS" false
                )
                && (
                  (units."hermes@".serviceConfig.TemporaryFileSystem == [ "/nix:ro" ])
                  || builtins.trace "Hermes config assertion 95: units.\"hermes@\".serviceConfig.TemporaryFileSystem == [ \"/nix:ro\" ]" false
                )
                && (
                  (!hasMnemosyneEnvironment units."hermes@".environment)
                  || builtins.trace "Hermes config assertion 96: !hasMnemosyneEnvironment units.\"hermes@\".environment" false
                )
                && (
                  (!hasMnemosyneEnvironment units."hermes@vm".environment)
                  || builtins.trace "Hermes config assertion 97: !hasMnemosyneEnvironment units.\"hermes@vm\".environment" false
                )
                && (
                  (!hasMnemosyneRuntimePath units."hermes@")
                  || builtins.trace "Hermes config assertion 98: !hasMnemosyneRuntimePath units.\"hermes@\"" false
                )
                && (
                  (!hasMnemosyneRuntimePath units."hermes@vm")
                  || builtins.trace "Hermes config assertion 99: !hasMnemosyneRuntimePath units.\"hermes@vm\"" false
                )
                && (
                  (!hasMnemosyneClosure units."hermes@")
                  || builtins.trace "Hermes config assertion 100: !hasMnemosyneClosure units.\"hermes@\"" false
                )
                && (
                  (!hasMnemosyneClosure units."hermes@vm")
                  || builtins.trace "Hermes config assertion 101: !hasMnemosyneClosure units.\"hermes@vm\"" false
                )
                && (
                  (!(builtins.elem hermesModuleVm.pkgs.mnemosyne units."hermes@".path))
                  || builtins.trace "Hermes config assertion 102: !(builtins.elem hermesModuleVm.pkgs.mnemosyne units.\"hermes@\".path)" false
                )
                && (
                  (builtins.all (rule: !(hasMnemosyne rule)) tmpfilesRules)
                  || builtins.trace "Hermes config assertion 103: builtins.all (rule: !(hasMnemosyne rule)) tmpfilesRules" false
                )
                && (
                  (builtins.any (rule: nixpkgs-unstable.lib.hasInfix "/.hermes/memories" rule) tmpfilesRules)
                  || builtins.trace "Hermes config assertion 104: builtins.any (rule: nixpkgs-unstable.lib.hasInfix \"/.hermes/memories\" rule) tmpfilesRules" false
                )
                && (
                  (builtins.any (rule: nixpkgs-unstable.lib.hasInfix "/.hermes/plugins" rule) tmpfilesRules)
                  || builtins.trace "Hermes config assertion 105: builtins.any (rule: nixpkgs-unstable.lib.hasInfix \"/.hermes/plugins\" rule) tmpfilesRules" false
                )
                && (
                  (!hasMnemosyneEnvironment defaultOnUnits."hermes@".environment)
                  || builtins.trace "Hermes config assertion 106: !hasMnemosyneEnvironment defaultOnUnits.\"hermes@\".environment" false
                )
                && (
                  (!hasMnemosyneEnvironment defaultOnUnits."hermes@vm".environment)
                  || builtins.trace "Hermes config assertion 107: !hasMnemosyneEnvironment defaultOnUnits.\"hermes@vm\".environment" false
                )
                && (
                  (!hasMnemosyneRuntimePath defaultOnUnits."hermes@")
                  || builtins.trace "Hermes config assertion 108: !hasMnemosyneRuntimePath defaultOnUnits.\"hermes@\"" false
                )
                && (
                  (!hasMnemosyneRuntimePath defaultOnUnits."hermes@vm")
                  || builtins.trace "Hermes config assertion 109: !hasMnemosyneRuntimePath defaultOnUnits.\"hermes@vm\"" false
                )
                && (
                  (!hasMnemosyneClosure defaultOnUnits."hermes@")
                  || builtins.trace "Hermes config assertion 110: !hasMnemosyneClosure defaultOnUnits.\"hermes@\"" false
                )
                && (
                  (!hasMnemosyneClosure defaultOnUnits."hermes@vm")
                  || builtins.trace "Hermes config assertion 111: !hasMnemosyneClosure defaultOnUnits.\"hermes@vm\"" false
                )
                && (
                  (!(builtins.elem hermesModuleVm.pkgs.mnemosyne defaultOnUnits."hermes@".path))
                  || builtins.trace "Hermes config assertion 112: !(builtins.elem hermesModuleVm.pkgs.mnemosyne defaultOnUnits.\"hermes@\".path)" false
                )
                && (
                  (builtins.elem hermesModuleVm.pkgs.headroom defaultOnUnits."hermes@".path)
                  || builtins.trace "Hermes config assertion 113: builtins.elem hermesModuleVm.pkgs.headroom defaultOnUnits.\"hermes@\".path" false
                )
                && (
                  (defaultOnUnits."hermes@vm".serviceConfig.ExecStartPre != [ ])
                  || builtins.trace "Hermes config assertion 114: defaultOnUnits.\"hermes@vm\".serviceConfig.ExecStartPre != [ ]" false
                )
                && (
                  (builtins.any (
                    path: nixpkgs-unstable.lib.hasSuffix "-install_skills.py" path
                  ) defaultOnUnits."hermes@vm".serviceConfig.BindReadOnlyPaths)
                  || builtins.trace "Hermes config assertion 115: default skill installer is bound in gateway closure" false
                )
                && (
                  (builtins.all (rule: !(hasMnemosyne rule)) defaultOnTmpfilesRules)
                  || builtins.trace "Hermes config assertion 116: builtins.all (rule: !(hasMnemosyne rule)) defaultOnTmpfilesRules" false
                )
                && (
                  (builtins.any (rule: nixpkgs-unstable.lib.hasInfix "/.hermes/memories" rule) defaultOnTmpfilesRules)
                  || builtins.trace "Hermes config assertion 117: builtins.any ( rule: nixpkgs-unstable.lib.hasInfix \"/.hermes/memories\" rule ) defaultOnTmpfilesRules" false
                )
                && (
                  hermesModuleVm.config.virtualisation.restrictNetwork
                  || builtins.trace "Hermes config assertion 118: hermesModuleVm.config.virtualisation.restrictNetwork" false
                )
                && (
                  (!internetEnabledVm.config.virtualisation.restrictNetwork)
                  || builtins.trace "Hermes config assertion 119: !internetEnabledVm.config.virtualisation.restrictNetwork" false
                )
                && (
                  internetEnabledVm.config.networking.networkmanager.enable
                  || builtins.trace "Hermes config assertion 120: internetEnabledVm.config.networking.networkmanager.enable" false
                )
                && (
                  (internetEnabledVm.config.networking.networkmanager.unmanaged == [ "interface-name:ha*" ])
                  || builtins.trace "Hermes config assertion 121: internetEnabledVm.config.networking.networkmanager.unmanaged == [ \"interface-name:ha*\" ]" false
                )
                && (
                  internetEnabledVm.config.networking.useNetworkd
                  || builtins.trace "Hermes config assertion 122: internetEnabledVm.config.networking.useNetworkd" false
                )
                && (
                  (
                    internetEnabledVm.config.systemd.services.hermes-module-vm-agent-smoke.environment.HERMES_VM_INTERNET_TEST
                    == "1"
                  )
                  || builtins.trace "Hermes config assertion 123: internetEnabledVm.config.systemd.services.hermes-module-vm-agent-smoke.environment.HERMES_VM_INTERNET_TEST == \"1\"" false
                )
                && (
                  (
                    internetEnabledVm.config.systemd.services.hermes-module-vm-agent-smoke.environment.HERMES_VM_INTERNET_RECOVERY_ONLY
                    == "1"
                  )
                  || builtins.trace "Hermes config assertion 124: internetEnabledVm.config.systemd.services.hermes-module-vm-agent-smoke.environment.HERMES_VM_INTERNET_RECOVERY_ONLY == \"1\"" false
                )
                && (
                  (
                    internetEnabledVm.config.systemd.services.hermes-module-vm-agent-smoke.environment.HERMES_VM_NM_UPLINK_TEST
                    == "1"
                  )
                  || builtins.trace "Hermes config assertion 125: internetEnabledVm.config.systemd.services.hermes-module-vm-agent-smoke.environment.HERMES_VM_NM_UPLINK_TEST == \"1\"" false
                )
                && (
                  (builtins.elem "1.1.1.1" internetEnabledVm.config.services.dnsmasq.settings.server)
                  || builtins.trace "Hermes config assertion 126: builtins.elem \"1.1.1.1\" internetEnabledVm.config.services.dnsmasq.settings.server" false
                )
                && (
                  (nixpkgs-unstable.lib.hasInfix "nameserver 127.0.0.1" internetEnabledVm.config.systemd.services.hermes-vm-late-resolver.script)
                  || builtins.trace "Hermes config assertion 127: nixpkgs-unstable.lib.hasInfix \"nameserver 127.0.0.1\" internetEnabledVm.config.systemd.services.hermes-vm-late-resolver.script" false
                )
                && (
                  (
                    !nixpkgs-unstable.lib.hasInfix "nameserver 1.1.1.1" internetEnabledVm.config.systemd.services.hermes-vm-late-resolver.script
                  )
                  || builtins.trace "Hermes config assertion 128: !nixpkgs-unstable.lib.hasInfix \"nameserver 1.1.1.1\" internetEnabledVm.config.systemd.services.hermes-vm-late-resolver.script" false
                )
                && (
                  (
                    units."hermes-network@".serviceConfig.TemporaryFileSystem
                    == hermesModuleVm.config.systemd.services."hermes-network@".serviceConfig.TemporaryFileSystem
                  )
                  || builtins.trace "Hermes config assertion 129: units.\"hermes-network@\".serviceConfig.TemporaryFileSystem == hermesModuleVm.config.systemd.services.\"hermes-network@\".serviceConfi" false
                )
                && (
                  (
                    !(hasStoreRoot discardedGatewayResource (
                      closureProbeBinds "hermes@vm" ++ closureProbeBinds "hermes@"
                    ))
                  )
                  || builtins.trace "Hermes config assertion 130: !(hasStoreRoot discardedGatewayResource ( closureProbeBinds \"hermes@vm\" ++ closureProbeBinds \"hermes@\" ))" false
                )
                && (
                  (
                    !(hasStoreRoot discardedNetworkResource (
                      closureProbeBinds "hermes-network@vm" ++ closureProbeBinds "hermes-network@"
                    ))
                  )
                  || builtins.trace "Hermes config assertion 131: !(hasStoreRoot discardedNetworkResource ( closureProbeBinds \"hermes-network@vm\" ++ closureProbeBinds \"hermes-network@\" ))" false
                )
                && (
                  (
                    !(hasStoreRoot figlet (
                      closureProbeBinds "hermes-network@vm" ++ closureProbeBinds "hermes-network@"
                    ))
                  )
                  || builtins.trace "Hermes config assertion 132: !(hasStoreRoot figlet ( closureProbeBinds \"hermes-network@vm\" ++ closureProbeBinds \"hermes-network@\" ))" false
                )
                && (
                  (
                    !(hasStoreRoot publicStateTemplateScript (
                      closureProbeBinds "hermes@vm" ++ closureProbeBinds "hermes@"
                    ))
                  )
                  || builtins.trace "Hermes config assertion 133: !(hasStoreRoot publicStateTemplateScript ( closureProbeBinds \"hermes@vm\" ++ closureProbeBinds \"hermes@\" ))" false
                )
                && (
                  (units."hermes@vm".serviceConfig ? ExecStart)
                  || builtins.trace "Hermes config assertion 134: units.\"hermes@vm\".serviceConfig ? ExecStart" false
                )
                && (
                  (units."hermes@vm-peer".serviceConfig ? ExecStart)
                  || builtins.trace "Hermes config assertion 135: units.\"hermes@vm-peer\".serviceConfig ? ExecStart" false
                )
                && (
                  (!(builtins.elem "multi-user.target" unitFiles."hermes@.service".wantedBy))
                  || builtins.trace "Hermes config assertion 136: !(builtins.elem \"multi-user.target\" unitFiles.\"hermes@.service\".wantedBy)" false
                )
                && (
                  (!(builtins.elem "multi-user.target" unitFiles."hermes-network@.service".wantedBy))
                  || builtins.trace "Hermes config assertion 137: !(builtins.elem \"multi-user.target\" unitFiles.\"hermes-network@.service\".wantedBy)" false
                )
                && (
                  (builtins.elem "multi-user.target" unitFiles."hermes@vm.service".wantedBy)
                  || builtins.trace "Hermes config assertion 138: builtins.elem \"multi-user.target\" unitFiles.\"hermes@vm.service\".wantedBy" false
                )
                && (
                  (builtins.elem "multi-user.target" unitFiles."hermes@vm-peer.service".wantedBy)
                  || builtins.trace "Hermes config assertion 139: builtins.elem \"multi-user.target\" unitFiles.\"hermes@vm-peer.service\".wantedBy" false
                )
                && (
                  (
                    explicitDashboardProbe.config.services.hermes-specialised-agent.agents.vm.portMappings == [
                      {
                        hostPort = 18199;
                        agentPort = 9119;
                        target = "loopback";
                        protocol = "both";
                      }
                    ]
                  )
                  || builtins.trace "Hermes config assertion 140: explicitDashboardProbe.config.services.hermes-specialised-agent.agents.vm.portMappings == [ { hostPort = 18199; agentPort = 9119; " false
                )
                && (
                  units."hermes@".serviceConfig.PrivateNetwork
                  || builtins.trace "Hermes config assertion 141: units.\"hermes@\".serviceConfig.PrivateNetwork" false
                )
                && (
                  (builtins.elem "hermes-network@%i.service" units."hermes@".bindsTo)
                  || builtins.trace "Hermes config assertion 142: builtins.elem \"hermes-network@%i.service\" units.\"hermes@\".bindsTo" false
                )
                && (
                  (builtins.elem "hermes-network@%i.service" units."hermes@".after)
                  || builtins.trace "Hermes config assertion 143: builtins.elem \"hermes-network@%i.service\" units.\"hermes@\".after" false
                )
                && (
                  (builtins.elem "hermes-network@%i.service" units."hermes@".unitConfig.JoinsNamespaceOf)
                  || builtins.trace "Hermes config assertion 144: builtins.elem \"hermes-network@%i.service\" units.\"hermes@\".unitConfig.JoinsNamespaceOf" false
                )
                && (
                  (builtins.elem "network-online.target" units."hermes-host-control@".after)
                  || builtins.trace "Hermes config assertion 145: builtins.elem \"network-online.target\" units.\"hermes-host-control@\".after" false
                )
                && (
                  (builtins.elem "network-online.target" units."hermes-host-control@".wants)
                  || builtins.trace "Hermes config assertion 146: builtins.elem \"network-online.target\" units.\"hermes-host-control@\".wants" false
                )
                && (
                  (builtins.hasAttr "hermes-vm-late-resolver" units)
                  || builtins.trace "Hermes config assertion 147: builtins.hasAttr \"hermes-vm-late-resolver\" units" false
                )
                && (
                  (builtins.elem "network-online.target" units.hermes-vm-late-resolver.before)
                  || builtins.trace "Hermes config assertion 148: builtins.elem \"network-online.target\" units.hermes-vm-late-resolver.before" false
                )
                && (
                  (!hermesModuleVm.config.networking.resolvconf.enable)
                  || builtins.trace "Hermes config assertion 149: !hermesModuleVm.config.networking.resolvconf.enable" false
                )
                && (
                  hermesModuleVm.config.networking.useNetworkd
                  || builtins.trace "Hermes config assertion 150: hermesModuleVm.config.networking.useNetworkd" false
                )
                && (
                  networkManagerProbe.config.networking.networkmanager.enable
                  || builtins.trace "Hermes config assertion 151: networkManagerProbe.config.networking.networkmanager.enable" false
                )
                && (
                  (networkManagerProbe.config.networking.networkmanager.unmanaged == [ "interface-name:ha*" ])
                  || builtins.trace "Hermes config assertion 152: networkManagerProbe.config.networking.networkmanager.unmanaged == [ \"interface-name:ha*\" ]" false
                )
                && (
                  networkManagerProbe.config.networking.useNetworkd
                  || builtins.trace "Hermes config assertion 153: networkManagerProbe.config.networking.useNetworkd" false
                )
                && (
                  (
                    networkManagerProbe.config.networking.dhcpcd.enable
                    == hermesModuleVm.config.networking.dhcpcd.enable
                  )
                  || builtins.trace "Hermes config assertion 154: Hermes leaves the host dhcpcd enablement unchanged" false
                )
                && (
                  (builtins.elem "ha*" networkManagerProbe.config.networking.dhcpcd.denyInterfaces)
                  || builtins.trace "Hermes config assertion 155: builtins.elem \"ha*\" networkManagerProbe.config.networking.dhcpcd.denyInterfaces" false
                )
                && (
                  (units."hermes-dhcp@".serviceConfig.RootDirectory == "%t/hermes-dhcp-%i/root")
                  || builtins.trace "Hermes config assertion 156: units.\"hermes-dhcp@\".serviceConfig.RootDirectory == \"%t/hermes-dhcp-%i/root\"" false
                )
                && (
                  (units."hermes-network@".serviceConfig.RootDirectory == "%t/hermes-network-%i/root")
                  || builtins.trace "Hermes config assertion 157: units.\"hermes-network@\".serviceConfig.RootDirectory == \"%t/hermes-network-%i/root\"" false
                )
                && (
                  (units."hermes-network-ready@".serviceConfig.RootDirectory == "%t/hermes-network-ready-%i/root")
                  || builtins.trace "Hermes config assertion 158: units.\"hermes-network-ready@\".serviceConfig.RootDirectory == \"%t/hermes-network-ready-%i/root\"" false
                )
                && (
                  (units."hermes-pf@".serviceConfig.RootDirectory == "%t/hermes-%i-pf/root")
                  || builtins.trace "Hermes config assertion 159: units.\"hermes-pf@\".serviceConfig.RootDirectory == \"%t/hermes-%i-pf/root\"" false
                )
                && (
                  (units."hermes@".serviceConfig.RootDirectory == "%t/hermes-%i/root")
                  || builtins.trace "Hermes config assertion 160: units.\"hermes@\".serviceConfig.RootDirectory == \"%t/hermes-%i/root\"" false
                )
                && (
                  (
                    units."hermes-network@".serviceConfig.RuntimeDirectory == [
                      "hermes-network-%i"
                      "hermes-network-%i/root"
                    ]
                  )
                  || builtins.trace "Hermes config assertion 161: units.\"hermes-network@\".serviceConfig.RuntimeDirectory == [ \"hermes-network-%i\" \"hermes-network-%i/root\" ]" false
                )
                && (
                  (
                    units."hermes-network-ready@".serviceConfig.RuntimeDirectory == [
                      "hermes-network-ready-%i"
                      "hermes-network-ready-%i/root"
                    ]
                  )
                  || builtins.trace "Hermes config assertion 162: units.\"hermes-network-ready@\".serviceConfig.RuntimeDirectory == [ \"hermes-network-ready-%i\" \"hermes-network-ready-%i/root\" ]" false
                )
                && (
                  (
                    units."hermes-pf@".serviceConfig.RuntimeDirectory == [
                      "hermes-%i-pf"
                      "hermes-%i-pf/root"
                      "hermes-%i-pf/root/etc"
                    ]
                  )
                  || builtins.trace "Hermes config assertion 163: units.\"hermes-pf@\".serviceConfig.RuntimeDirectory == [ \"hermes-%i-pf\" \"hermes-%i-pf/root\" \"hermes-%i-pf/root/etc\" ]" false
                )
                && (
                  (
                    units."hermes@".serviceConfig.RuntimeDirectory == [
                      "hermes-%i"
                      "hermes-%i/root"
                      "hermes-%i/root/etc"
                    ]
                  )
                  || builtins.trace "Hermes config assertion 164: units.\"hermes@\".serviceConfig.RuntimeDirectory == [ \"hermes-%i\" \"hermes-%i/root\" \"hermes-%i/root/etc\" ]" false
                )
                && (
                  (builtins.all (unit: !(units.${unit}.serviceConfig ? MemoryKSM)) [
                    "hermes-dhcp@"
                    "hermes-network@"
                    "hermes-network-ready@"
                    "hermes-pf@"
                    "hermes@"
                  ])
                  || builtins.trace "Hermes config assertion 165: builtins.all (unit: !(units.\${unit}.serviceConfig ? MemoryKSM)) [ \"hermes-dhcp@\" \"hermes-network@\" \"hermes-network-ready@\" \"hermes" false
                )
                && (
                  (builtins.all (unit: builtins.elem "~@privileged" units.${unit}.serviceConfig.SystemCallFilter) [
                    "hermes-dhcp@"
                    "hermes-network@"
                    "hermes-network-ready@"
                    "hermes-pf@"
                    "hermes@"
                  ])
                  || builtins.trace "Hermes config assertion 166: builtins.all (unit: builtins.elem \"~@privileged\" units.\${unit}.serviceConfig.SystemCallFilter) [ \"hermes-dhcp@\" \"hermes-network@\" " false
                )
                && (
                  units."hermes-dhcp@".serviceConfig.RestrictSUIDSGID
                  || builtins.trace "Hermes config assertion 167: units.\"hermes-dhcp@\".serviceConfig.RestrictSUIDSGID" false
                )
                && (
                  units."hermes-pf@".serviceConfig.RestrictSUIDSGID
                  || builtins.trace "Hermes config assertion 168: units.\"hermes-pf@\".serviceConfig.RestrictSUIDSGID" false
                )
                && (
                  units."hermes@".serviceConfig.RestrictSUIDSGID
                  || builtins.trace "Hermes config assertion 169: units.\"hermes@\".serviceConfig.RestrictSUIDSGID" false
                )
                && (
                  units."hermes-network@".serviceConfig.RestrictSUIDSGID
                  || builtins.trace "Hermes config assertion 170: units.\"hermes-network@\".serviceConfig.RestrictSUIDSGID" false
                )
                && (
                  units."hermes-network-ready@".serviceConfig.RestrictSUIDSGID
                  || builtins.trace "Hermes config assertion 171: units.\"hermes-network-ready@\".serviceConfig.RestrictSUIDSGID" false
                )
                && (
                  units."hermes-dhcp@".serviceConfig.MemoryDenyWriteExecute
                  || builtins.trace "Hermes config assertion 172: units.\"hermes-dhcp@\".serviceConfig.MemoryDenyWriteExecute" false
                )
                && (
                  units."hermes-network@".serviceConfig.MemoryDenyWriteExecute
                  || builtins.trace "Hermes config assertion 173: units.\"hermes-network@\".serviceConfig.MemoryDenyWriteExecute" false
                )
                && (
                  units."hermes-network-ready@".serviceConfig.MemoryDenyWriteExecute
                  || builtins.trace "Hermes config assertion 174: units.\"hermes-network-ready@\".serviceConfig.MemoryDenyWriteExecute" false
                )
                && (
                  units."hermes-pf@".serviceConfig.MemoryDenyWriteExecute
                  || builtins.trace "Hermes config assertion 175: units.\"hermes-pf@\".serviceConfig.MemoryDenyWriteExecute" false
                )
                && (
                  (!(units."hermes@".serviceConfig ? MemoryDenyWriteExecute))
                  || builtins.trace "Hermes config assertion 176: !(units.\"hermes@\".serviceConfig ? MemoryDenyWriteExecute)" false
                )
                && (
                  (units."hermes-host-control@".serviceConfig.BindPaths == [ "/run/systemd/network" ])
                  || builtins.trace "Hermes config assertion 177: units.\"hermes-host-control@\".serviceConfig.BindPaths == [ \"/run/systemd/network\" ]" false
                )
                && (
                  (builtins.elem "/run/systemd/network" units."hermes-host-control@".serviceConfig.ReadWritePaths)
                  || builtins.trace "Hermes config assertion 178: builtins.elem \"/run/systemd/network\" units.\"hermes-host-control@\".serviceConfig.ReadWritePaths" false
                )
                && (
                  (builtins.elem "/run/dbus/system_bus_socket"
                    units."hermes-host-control@".serviceConfig.BindReadOnlyPaths
                  )
                  || builtins.trace "Hermes config assertion 179: builtins.elem \"/run/dbus/system_bus_socket\" units.\"hermes-host-control@\".serviceConfig.BindReadOnlyPaths" false
                )
                && (
                  (builtins.elem "/run/systemd/netif/io.systemd.Network"
                    units."hermes-host-control@".serviceConfig.BindReadOnlyPaths
                  )
                  || builtins.trace "Hermes config assertion 180: builtins.elem \"/run/systemd/netif/io.systemd.Network\" units.\"hermes-host-control@\".serviceConfig.BindReadOnlyPaths" false
                )
                && (
                  (
                    !(builtins.elem "/run/systemd/private" units."hermes-host-control@".serviceConfig.BindReadOnlyPaths)
                  )
                  || builtins.trace "Hermes config assertion 181: !(builtins.elem \"/run/systemd/private\" units.\"hermes-host-control@\".serviceConfig.BindReadOnlyPaths )" false
                )
                && (
                  (!(builtins.elem "/etc/group" units."hermes-pf@".serviceConfig.BindReadOnlyPaths))
                  || builtins.trace "Hermes config assertion 182: !(builtins.elem \"/etc/group\" units.\"hermes-pf@\".serviceConfig.BindReadOnlyPaths)" false
                )
                && (
                  (units."hermes-pf@".serviceConfig.Group == "hermes-shared")
                  || builtins.trace "Hermes config assertion 183: units.\"hermes-pf@\".serviceConfig.Group == \"hermes-shared\"" false
                )
                && (
                  (builtins.elem "/dev/null:/etc/dhcpcd.exit-hook"
                    units."hermes-dhcp@".serviceConfig.BindReadOnlyPaths
                  )
                  || builtins.trace "Hermes config assertion 184: builtins.elem \"/dev/null:/etc/dhcpcd.exit-hook\" units.\"hermes-dhcp@\".serviceConfig.BindReadOnlyPaths" false
                )
                && (
                  (builtins.elem "%S/hermes-%i" units."hermes-pf@".serviceConfig.BindPaths)
                  || builtins.trace "Hermes config assertion 185: builtins.elem \"%S/hermes-%i\" units.\"hermes-pf@\".serviceConfig.BindPaths" false
                )
                && (
                  (!(units."hermes-pf@".serviceConfig ? StateDirectory))
                  || builtins.trace "Hermes config assertion 186: !(units.\"hermes-pf@\".serviceConfig ? StateDirectory)" false
                )
                && (
                  (
                    units."hermes-dhcp@".serviceConfig.StateDirectory == [
                      "hermes-dhcp-%i"
                    ]
                  )
                  || builtins.trace "Hermes config assertion 187: units.\"hermes-dhcp@\".serviceConfig.StateDirectory == [ \"hermes-dhcp-%i\" ]" false
                )
                && (
                  (
                    units."hermes-dhcp@".serviceConfig.RuntimeDirectory == [
                      "hermes-dhcp-%i/root"
                      "hermes-dhcp-%i/root/var/lib"
                      "hermes-dhcp-%i/dhcpcd"
                    ]
                  )
                  || builtins.trace "Hermes config assertion 188: DHCP managed runtime paths contain only its root, in-root state-link parent, and per-instance client runtime directory" false
                )
                && (
                  (
                    units."hermes-dhcp@".serviceConfig.BindPaths == [
                      "%t/hermes-dhcp-%i/dhcpcd:/run/dhcpcd"
                      "%t/hermes-dhcp-%i/dhcpcd:/var/run/dhcpcd"
                    ]
                  )
                  || builtins.trace "Hermes config assertion 189: DHCP bind mounts expose only per-instance runtime client paths" false
                )
                && (
                  units."hermes-dhcp@".serviceConfig.TemporaryFileSystem == [ "/nix:ro" ]
                  || builtins.trace "Hermes config assertion 316: DHCP has no broad writable temporary filesystem exception" false
                )
                && (
                  units."hermes-dhcp@".serviceConfig.ReadWritePaths == [ "+/var/lib" ]
                  || builtins.trace "Hermes config assertion 190: DHCP can write only the in-root state-symlink directory, not host /var" false
                )
                && (
                  units."hermes-dhcp@".serviceConfig.PrivateNetwork
                  || builtins.trace "Hermes config assertion 191: units.\"hermes-dhcp@\".serviceConfig.PrivateNetwork" false
                )
                && (
                  units."hermes-dhcp@".serviceConfig.NoNewPrivileges
                  || builtins.trace "Hermes config assertion 192: units.\"hermes-dhcp@\".serviceConfig.NoNewPrivileges" false
                )
                && (
                  (units."hermes-dhcp@".serviceConfig.ProtectSystem == "strict")
                  || builtins.trace "Hermes config assertion 193: units.\"hermes-dhcp@\".serviceConfig.ProtectSystem == \"strict\"" false
                )
                && (
                  (units."hermes-dhcp@".serviceConfig.ProtectProc == "invisible")
                  || builtins.trace "Hermes config assertion 194: units.\"hermes-dhcp@\".serviceConfig.ProtectProc == \"invisible\"" false
                )
                && (
                  units."hermes-dhcp@".serviceConfig.RestrictNamespaces
                  || builtins.trace "Hermes config assertion 195: units.\"hermes-dhcp@\".serviceConfig.RestrictNamespaces" false
                )
                && (
                  (units."hermes-dhcp@".serviceConfig.DevicePolicy == "closed")
                  || builtins.trace "Hermes config assertion 196: units.\"hermes-dhcp@\".serviceConfig.DevicePolicy == \"closed\"" false
                )
                && (
                  (
                    units."hermes-dhcp@".serviceConfig.SystemCallFilter == [
                      "@system-service"
                      "~@resources"
                      "~@privileged"
                    ]
                  )
                  || builtins.trace "Hermes config assertion 197: units.\"hermes-dhcp@\".serviceConfig.SystemCallFilter == [ \"@system-service\" \"~@resources\" \"~@privileged\" ]" false
                )
                && (
                  (
                    units."hermes-dhcp@".serviceConfig.CapabilityBoundingSet == [
                      "CAP_NET_ADMIN"
                      "CAP_NET_BIND_SERVICE"
                      "CAP_NET_RAW"
                    ]
                  )
                  || builtins.trace "Hermes config assertion 198: units.\"hermes-dhcp@\".serviceConfig.CapabilityBoundingSet == [ \"CAP_NET_ADMIN\" \"CAP_NET_BIND_SERVICE\" \"CAP_NET_RAW\" ]" false
                )
                && (
                  (
                    units."hermes-dhcp@".serviceConfig.AmbientCapabilities == [
                      "CAP_NET_ADMIN"
                      "CAP_NET_BIND_SERVICE"
                      "CAP_NET_RAW"
                    ]
                  )
                  || builtins.trace "Hermes config assertion 199: units.\"hermes-dhcp@\".serviceConfig.AmbientCapabilities == [ \"CAP_NET_ADMIN\" \"CAP_NET_BIND_SERVICE\" \"CAP_NET_RAW\" ]" false
                )
                && (
                  units."hermes-dhcp@".serviceConfig.DynamicUser
                  || builtins.trace "Hermes config assertion 200: units.\"hermes-dhcp@\".serviceConfig.DynamicUser" false
                )
                && (
                  (units."hermes-dhcp@".serviceConfig.User == "hn-dh-%i")
                  || builtins.trace "Hermes config assertion 201: units.\"hermes-dhcp@\".serviceConfig.User == \"hn-dh-%i\"" false
                )
                && (
                  (units."hermes-dhcp@".unitConfig.JoinsNamespaceOf == [ "hermes-network@%i.service" ])
                  || builtins.trace "Hermes config assertion 202: units.\"hermes-dhcp@\".unitConfig.JoinsNamespaceOf == [ \"hermes-network@%i.service\" ]" false
                )
                && (
                  (units."hermes-dhcp@vm".serviceConfig ? ExecStart)
                  || builtins.trace "Hermes config assertion 203: units.\"hermes-dhcp@vm\".serviceConfig ? ExecStart" false
                )
                && (
                  (builtins.any (
                    path: nixpkgs-unstable.lib.hasInfix "dhcpcd-10.3.2" path
                  ) units."hermes-dhcp@vm".serviceConfig.BindReadOnlyPaths)
                  || builtins.trace "Hermes config assertion 204: builtins.any ( path: nixpkgs-unstable.lib.hasInfix \"dhcpcd-10.3.2\" path ) units.\"hermes-dhcp@vm\".serviceConfig.BindReadOnlyPaths" false
                )
                && (
                  (builtins.elem "hermes-dhcp@%i.service" units."hermes-network-ready@".requires)
                  || builtins.trace "Hermes config assertion 205: builtins.elem \"hermes-dhcp@%i.service\" units.\"hermes-network-ready@\".requires" false
                )
                && (
                  (builtins.elem "hermes-dhcp@%i.service" units."hermes-network-ready@".bindsTo)
                  || builtins.trace "Hermes config assertion 206: builtins.elem \"hermes-dhcp@%i.service\" units.\"hermes-network-ready@\".bindsTo" false
                )
                && (
                  (builtins.elem "nftables.service" units."hermes-dhcp@".partOf)
                  || builtins.trace "Hermes config assertion 207: builtins.elem \"nftables.service\" units.\"hermes-dhcp@\".partOf" false
                )
                && (
                  (builtins.elem "systemd-networkd.service" units."hermes-dhcp@".after)
                  || builtins.trace "Hermes config assertion 208: builtins.elem \"systemd-networkd.service\" units.\"hermes-dhcp@\".after" false
                )
                && (
                  (builtins.elem "systemd-networkd.service" units."hermes-dhcp@".partOf)
                  || builtins.trace "Hermes config assertion 209: builtins.elem \"systemd-networkd.service\" units.\"hermes-dhcp@\".partOf" false
                )
                && (
                  (units."hermes-network-ready@".serviceConfig.Type == "notify")
                  || builtins.trace "Hermes config assertion 210: units.\"hermes-network-ready@\".serviceConfig.Type == \"notify\"" false
                )
                && (
                  (units."hermes-network-ready@".serviceConfig.Restart == "no")
                  || builtins.trace "Hermes config assertion 211: units.\"hermes-network-ready@\".serviceConfig.Restart == \"no\"" false
                )
                && (
                  (units."hermes-network-ready@".serviceConfig.TimeoutStartSec == "60s")
                  || builtins.trace "Hermes config assertion 212: units.\"hermes-network-ready@\".serviceConfig.TimeoutStartSec == \"60s\"" false
                )
                && (
                  (units."hermes@".serviceConfig.TimeoutStartSec == "180s")
                  || builtins.trace "Hermes config assertion 318: units.\"hermes@\".serviceConfig.TimeoutStartSec == \"180s\"" false
                )
                && (
                  (builtins.elem "hermes-network-ready@%i.service" units."hermes@".bindsTo)
                  || builtins.trace "Hermes config assertion 213: builtins.elem \"hermes-network-ready@%i.service\" units.\"hermes@\".bindsTo" false
                )
                && (
                  (nixpkgs-unstable.lib.hasInfix "Name=ha0" hostNetworkConfig)
                  || builtins.trace "Hermes config assertion 214: nixpkgs-unstable.lib.hasInfix \"Name=ha0\" hostNetworkConfig" false
                )
                && (
                  (nixpkgs-unstable.lib.hasInfix "Kind=veth" hostNetworkConfig)
                  || builtins.trace "Hermes config assertion 215: nixpkgs-unstable.lib.hasInfix \"Kind=veth\" hostNetworkConfig" false
                )
                && (
                  (nixpkgs-unstable.lib.hasInfix "Address=0.0.0.0/30" hostNetworkConfig)
                  || builtins.trace "Hermes config assertion 216: nixpkgs-unstable.lib.hasInfix \"Address=0.0.0.0/30\" hostNetworkConfig" false
                )
                && (
                  (nixpkgs-unstable.lib.hasInfix "Address=::/64" hostNetworkConfig)
                  || builtins.trace "Hermes config assertion 217: nixpkgs-unstable.lib.hasInfix \"Address=::/64\" hostNetworkConfig" false
                )
                && (
                  (nixpkgs-unstable.lib.hasInfix "DHCPServer=true" hostNetworkConfig)
                  || builtins.trace "Hermes config assertion 218: nixpkgs-unstable.lib.hasInfix \"DHCPServer=true\" hostNetworkConfig" false
                )
                && (
                  (nixpkgs-unstable.lib.hasInfix "IPv4Forwarding=true" hostNetworkConfig)
                  || builtins.trace "Hermes config assertion 219: nixpkgs-unstable.lib.hasInfix \"IPv4Forwarding=true\" hostNetworkConfig" false
                )
                && (
                  (nixpkgs-unstable.lib.hasInfix "IPv6Forwarding=true" hostNetworkConfig)
                  || builtins.trace "Hermes config assertion 220: nixpkgs-unstable.lib.hasInfix \"IPv6Forwarding=true\" hostNetworkConfig" false
                )
                && (
                  (nixpkgs-unstable.lib.hasInfix "IPv6SendRA=true" hostNetworkConfig)
                  || builtins.trace "Hermes config assertion 221: nixpkgs-unstable.lib.hasInfix \"IPv6SendRA=true\" hostNetworkConfig" false
                )
                && (
                  (nixpkgs-unstable.lib.hasInfix "RequiredForOnline=no" hostNetworkConfig)
                  || builtins.trace "Hermes config assertion 222: nixpkgs-unstable.lib.hasInfix \"RequiredForOnline=no\" hostNetworkConfig" false
                )
                && (
                  (nixpkgs-unstable.lib.hasInfix "PersistLeases=runtime" hostNetworkConfig)
                  || builtins.trace "Hermes config assertion 223: nixpkgs-unstable.lib.hasInfix \"PersistLeases=runtime\" hostNetworkConfig" false
                )
                && (
                  (nixpkgs-unstable.lib.hasInfix "PoolOffset=2" hostNetworkConfig)
                  || builtins.trace "Hermes config assertion 224: nixpkgs-unstable.lib.hasInfix \"PoolOffset=2\" hostNetworkConfig" false
                )
                && (
                  (nixpkgs-unstable.lib.hasInfix "PoolSize=1" hostNetworkConfig)
                  || builtins.trace "Hermes config assertion 225: nixpkgs-unstable.lib.hasInfix \"PoolSize=1\" hostNetworkConfig" false
                )
                && (
                  (!(nixpkgs-unstable.lib.hasInfix "Router=" hostNetworkConfig))
                  || builtins.trace "Hermes config assertion 226: !(nixpkgs-unstable.lib.hasInfix \"Router=\" hostNetworkConfig)" false
                )
                && (
                  (!(disabledAgentProbe.config.systemd.network.networks ? "40-hermes-agent-0"))
                  || builtins.trace "Hermes config assertion 227: !(disabledAgentProbe.config.systemd.network.networks ? \"40-hermes-agent-0\")" false
                )
                && (
                  disabledAgentProbe.config.systemd.network.enable
                  || builtins.trace "Hermes config assertion 228: host-owned networkd stays enabled when Hermes is disabled" false
                )
                && (
                  units."hermes-network@".serviceConfig.RestrictNamespaces
                  || builtins.trace "Hermes config assertion 229: units.\"hermes-network@\".serviceConfig.RestrictNamespaces" false
                )
                && (
                  units."hermes-network@".serviceConfig.DynamicUser
                  || builtins.trace "Hermes config assertion 230: units.\"hermes-network@\".serviceConfig.DynamicUser" false
                )
                && (
                  (units."hermes-network@".serviceConfig.AmbientCapabilities == [ "CAP_NET_ADMIN" ])
                  || builtins.trace "Hermes config assertion 231: units.\"hermes-network@\".serviceConfig.AmbientCapabilities == [ \"CAP_NET_ADMIN\" ]" false
                )
                && (
                  units."hermes-host-control@".serviceConfig.RestrictNamespaces
                  || builtins.trace "Hermes config assertion 232: units.\"hermes-host-control@\".serviceConfig.RestrictNamespaces" false
                )
                && (
                  units."hermes-netns@".serviceConfig.RestrictNamespaces
                  || builtins.trace "Hermes config assertion 233: units.\"hermes-netns@\".serviceConfig.RestrictNamespaces" false
                )
                && (
                  (units."hermes-netns@".serviceConfig.CapabilityBoundingSet == "")
                  || builtins.trace "Hermes config assertion 234: units.\"hermes-netns@\".serviceConfig.CapabilityBoundingSet == \"\"" false
                )
                && (
                  (units."hermes-host-control@".serviceConfig.CapabilityBoundingSet == [ "CAP_NET_ADMIN" ])
                  || builtins.trace "Hermes config assertion 235: units.\"hermes-host-control@\".serviceConfig.CapabilityBoundingSet == [ \"CAP_NET_ADMIN\" ]" false
                )
                && (
                  (units."hermes-host-control@".serviceConfig.NetworkNamespacePath == "/proc/1/ns/net")
                  || builtins.trace "Hermes config assertion 236: units.\"hermes-host-control@\".serviceConfig.NetworkNamespacePath == \"/proc/1/ns/net\"" false
                )
                && (
                  (!(units."hermes-host-control@".unitConfig ? JoinsNamespaceOf))
                  || builtins.trace "Hermes config assertion 237: !(units.\"hermes-host-control@\".unitConfig ? JoinsNamespaceOf)" false
                )
                && (
                  (units."hermes-network@".unitConfig.JoinsNamespaceOf == [ "hermes-netns@%i.service" ])
                  || builtins.trace "Hermes config assertion 238: units.\"hermes-network@\".unitConfig.JoinsNamespaceOf == [ \"hermes-netns@%i.service\" ]" false
                )
                && (
                  (builtins.elem "hermes-host-control@%i.service" units."hermes-network@".bindsTo)
                  || builtins.trace "Hermes config assertion 239: builtins.elem \"hermes-host-control@%i.service\" units.\"hermes-network@\".bindsTo" false
                )
                && (
                  (builtins.elem "hermes-netns@%i.service" units."hermes-host-control@".bindsTo)
                  || builtins.trace "Hermes config assertion 240: builtins.elem \"hermes-netns@%i.service\" units.\"hermes-host-control@\".bindsTo" false
                )
                && (
                  (builtins.elem "hermes-network-failure@%i.service"
                    units."hermes-host-control@".unitConfig.OnFailure
                  )
                  || builtins.trace "Hermes config assertion 260: host-control OnFailure schedules the namespace stop helper" false
                )
                && (
                  (units."hermes-network-failure@".serviceConfig.RootDirectory == "%t/hermes-network-failure-%i/root")
                  || builtins.trace "Hermes config assertion 261: network-failure has an isolated root" false
                )
                && (
                  (units."hermes-network-failure@".serviceConfig.CapabilityBoundingSet == "")
                  || builtins.trace "Hermes config assertion 262: network-failure has an empty capability bounding set" false
                )
                && (
                  (units."hermes-network-failure@".serviceConfig.RestrictAddressFamilies == [ "AF_UNIX" ])
                  || builtins.trace "Hermes config assertion 263: network-failure only opens AF_UNIX" false
                )
                && (
                  (builtins.elem "/run/dbus/system_bus_socket"
                    units."hermes-network-failure@".serviceConfig.BindReadOnlyPaths
                  )
                  || builtins.trace "Hermes config assertion 264: network-failure gets only the D-Bus manager socket" false
                )
                && (
                  units."hermes-network-ready@".serviceConfig.RestrictNamespaces
                  || builtins.trace "Hermes config assertion 241: units.\"hermes-network-ready@\".serviceConfig.RestrictNamespaces" false
                )
                && (
                  units."hermes-network-ready@".serviceConfig.MemoryDenyWriteExecute
                  || builtins.trace "Hermes config assertion 242: units.\"hermes-network-ready@\".serviceConfig.MemoryDenyWriteExecute" false
                )
                && (
                  (!(units."hermes-network-ready@".serviceConfig ? ReadWritePaths))
                  || builtins.trace "Hermes config assertion 243: !(units.\"hermes-network-ready@\".serviceConfig ? ReadWritePaths)" false
                )
                && (
                  (builtins.any (
                    path: nixpkgs-unstable.lib.hasInfix "/run/hermes-observation-vm" path
                  ) units."hermes-network-ready@vm".serviceConfig.BindReadOnlyPaths)
                  || builtins.trace "Hermes config assertion 255: network-ready instance binds its observer telemetry read-only" false
                )
                && (
                  (builtins.elem "~@privileged" units."hermes-network@".serviceConfig.SystemCallFilter)
                  || builtins.trace "Hermes config assertion 244: builtins.elem \"~@privileged\" units.\"hermes-network@\".serviceConfig.SystemCallFilter" false
                )
                && (
                  (builtins.elem "~@privileged" units."hermes-network-ready@".serviceConfig.SystemCallFilter)
                  || builtins.trace "Hermes config assertion 245: builtins.elem \"~@privileged\" units.\"hermes-network-ready@\".serviceConfig.SystemCallFilter" false
                )
                && (
                  (!(builtins.elem "setns" units."hermes-network@".serviceConfig.SystemCallFilter))
                  || builtins.trace "Hermes config assertion 246: !(builtins.elem \"setns\" units.\"hermes-network@\".serviceConfig.SystemCallFilter)" false
                )
                && (
                  (!(builtins.elem "setns" units."hermes-host-control@".serviceConfig.SystemCallFilter))
                  || builtins.trace "Hermes config assertion 247: !(builtins.elem \"setns\" units.\"hermes-host-control@\".serviceConfig.SystemCallFilter)" false
                )
                && (
                  (!(builtins.elem "setns" units."hermes-network-ready@".serviceConfig.SystemCallFilter))
                  || builtins.trace "Hermes config assertion 248: !(builtins.elem \"setns\" units.\"hermes-network-ready@\".serviceConfig.SystemCallFilter)" false
                )
                && (
                  (builtins.all
                    (syscall: !(builtins.elem syscall units."hermes-network@".serviceConfig.SystemCallFilter))
                    [
                      "setgid"
                      "setgroups"
                      "setresgid"
                      "setresuid"
                      "setuid"
                    ]
                  )
                  || builtins.trace "Hermes config assertion 249: builtins.all (syscall: !(builtins.elem syscall units.\"hermes-network@\".serviceConfig.SystemCallFilter)) [ \"setgid\" \"setgroups\" \"se" false
                )
                && (
                  (builtins.all
                    (syscall: !(builtins.elem syscall units."hermes-network-ready@".serviceConfig.SystemCallFilter))
                    [
                      "setgid"
                      "setgroups"
                      "setresgid"
                      "setresuid"
                      "setuid"
                    ]
                  )
                  || builtins.trace "Hermes config assertion 250: builtins.all (syscall: !(builtins.elem syscall units.\"hermes-network-ready@\".serviceConfig.SystemCallFilter)) [ \"setgid\" \"setgroup" false
                )
                && (
                  (
                    units."hermes-network@".serviceConfig.CapabilityBoundingSet == [
                      "CAP_NET_ADMIN"
                    ]
                  )
                  || builtins.trace "Hermes config assertion 251: units.\"hermes-network@\".serviceConfig.CapabilityBoundingSet == [ \"CAP_NET_ADMIN\" ]" false
                )
                && (
                  (units."hermes-network-ready@".serviceConfig.CapabilityBoundingSet == "")
                  || builtins.trace "Hermes config assertion 252: units.\"hermes-network-ready@\".serviceConfig.CapabilityBoundingSet == \"\"" false
                )
                && (
                  units."hermes-network-ready@".serviceConfig.DynamicUser
                  || builtins.trace "Hermes config assertion 253: units.\"hermes-network-ready@\".serviceConfig.DynamicUser" false
                )
                && (
                  (units."hermes-network-ready@".serviceConfig.RestrictAddressFamilies == [ "AF_UNIX" ])
                  || builtins.trace "Hermes config assertion 254: units.\"hermes-network-ready@\".serviceConfig.RestrictAddressFamilies == [ \"AF_UNIX\" ]" false
                )
                && (
                  (units."hermes-network-observer@".serviceConfig.CapabilityBoundingSet == "")
                  || builtins.trace "Hermes config assertion 255: units.\"hermes-network-observer@\".serviceConfig.CapabilityBoundingSet == \"\"" false
                )
                && (
                  (units."hermes-host-proxy@".serviceConfig.CapabilityBoundingSet == "")
                  || builtins.trace "Hermes config assertion 256: units.\"hermes-host-proxy@\".serviceConfig.CapabilityBoundingSet == \"\"" false
                )
                && (
                  (units."hermes-dns@".serviceConfig.CapabilityBoundingSet == [ "CAP_NET_BIND_SERVICE" ])
                  || builtins.trace "Hermes config assertion 257: units.\"hermes-dns@\".serviceConfig.CapabilityBoundingSet == [ \"CAP_NET_BIND_SERVICE\" ]" false
                )
                && (
                  (builtins.all
                    (
                      role:
                      let
                        service = units."hermes-${role}@".serviceConfig;
                      in
                      service.DynamicUser
                      && service.RestrictNamespaces
                      && service.DevicePolicy == "closed"
                      && service.ProtectSystem == "strict"
                      && builtins.elem "~@privileged" service.SystemCallFilter
                      && !(builtins.elem "setns" service.SystemCallFilter)
                      && !(service ? BindPaths)
                    )
                    [
                      "network-observer"
                      "dns"
                      "host-proxy"
                      "agent-relay"
                      "network-ready"
                    ]
                  )
                  || builtins.trace "Hermes config assertion 258: builtins.all ( role: let service = units.\"hermes-\${role}@\".serviceConfig; in service.DynamicUser && service.RestrictNamespaces && " false
                )
                && (
                  existingNetworkdProbe.config.networking.useNetworkd
                  || builtins.trace "Hermes config assertion 259: existingNetworkdProbe.config.networking.useNetworkd" false
                )
                && (
                  existingNetworkdProbe.config.systemd.network.wait-online.enable
                  || builtins.trace "Hermes config assertion 260: existingNetworkdProbe.config.systemd.network.wait-online.enable" false
                )
                && (
                  networkManagerProbe.config.systemd.network.wait-online.enable
                  || builtins.trace "Hermes config assertion 261: networkManagerProbe preserves networkd wait-online default" false
                )
                && (
                  (!dhcpcdUplinkProbe.config.networking.useNetworkd)
                  && dhcpcdUplinkProbe.config.networking.dhcpcd.enable
                  && dhcpcdUplinkProbe.config.systemd.network.enable
                  && (!dhcpcdUplinkProbe.config.systemd.network.wait-online.enable)
                  && (!dhcpcdUplinkProbe.config.systemd.services.systemd-networkd-wait-online.enable)
                  || builtins.trace "Hermes config assertion: dhcpcd uplinks retain dhcpcd ownership without a new networkd wait-online gate" false
                )
                && (
                  explicitNetworkdWaitOnlineProbe.config.systemd.network.wait-online.enable
                  || builtins.trace "Hermes config assertion: explicit networkd wait-online policy is preserved" false
                )
                && (
                  (
                    networkManagerProbe.config.networking.dhcpcd.enable
                    == hermesModuleVm.config.networking.dhcpcd.enable
                  )
                  || builtins.trace "Hermes config assertion 262: Hermes preserves host dhcpcd enablement" false
                )
                && (
                  units."hermes-network@".serviceConfig.PrivateNetwork
                  || builtins.trace "Hermes config assertion 263: units.\"hermes-network@\".serviceConfig.PrivateNetwork" false
                )
                && (
                  (units."hermes-network@".serviceConfig.Type == "oneshot")
                  || builtins.trace "Hermes config assertion 264: units.\"hermes-network@\".serviceConfig.Type == \"oneshot\"" false
                )
                && (
                  (units."hermes-network@vm".serviceConfig ? ExecStart)
                  || builtins.trace "Hermes config assertion 265: units.\"hermes-network@vm\".serviceConfig ? ExecStart" false
                )
                && (
                  (units."hermes-host-control@vm".serviceConfig ? ExecStopPost)
                  || builtins.trace "Hermes config assertion 266: units.\"hermes-host-control@vm\".serviceConfig ? ExecStopPost" false
                )
                && (
                  (units."hermes-network@vm-peer".serviceConfig ? ExecStart)
                  || builtins.trace "Hermes config assertion 267: units.\"hermes-network@vm-peer\".serviceConfig ? ExecStart" false
                )
                && (
                  (units."hermes-host-control@vm-peer".serviceConfig ? ExecStopPost)
                  || builtins.trace "Hermes config assertion 268: units.\"hermes-host-control@vm-peer\".serviceConfig ? ExecStopPost" false
                )
                && (
                  (!(builtins.elem "CAP_SYS_PTRACE" units."hermes-network@".serviceConfig.CapabilityBoundingSet))
                  || builtins.trace "Hermes config assertion 269: !(builtins.elem \"CAP_SYS_PTRACE\" units.\"hermes-network@\".serviceConfig.CapabilityBoundingSet)" false
                )
                && (
                  units."hermes-pf@".serviceConfig.PrivateNetwork
                  || builtins.trace "Hermes config assertion 270: units.\"hermes-pf@\".serviceConfig.PrivateNetwork" false
                )
                && (
                  (units."hermes-pf@".serviceConfig.RestrictAddressFamilies == [ ])
                  || builtins.trace "Hermes config assertion 271: units.\"hermes-pf@\".serviceConfig.RestrictAddressFamilies == [ ]" false
                )
                && (
                  (builtins.elem "~socket" units."hermes-pf@".serviceConfig.SystemCallFilter)
                  || builtins.trace "Hermes config assertion 272: builtins.elem \"~socket\" units.\"hermes-pf@\".serviceConfig.SystemCallFilter" false
                )
                && (
                  (builtins.elem "hermes@%i.service" units."hermes-pf@".partOf)
                  || builtins.trace "Hermes config assertion 273: builtins.elem \"hermes@%i.service\" units.\"hermes-pf@\".partOf" false
                )
                && (
                  (builtins.length units."hermes@".serviceConfig.ExecStartPre == 1)
                  || builtins.trace "Hermes config assertion 274: builtins.length units.\"hermes@\".serviceConfig.ExecStartPre == 1" false
                )
                && (
                  (units."hermes-pf@".serviceConfig ? ExecStart)
                  || builtins.trace "Hermes config assertion 275: units.\"hermes-pf@\".serviceConfig ? ExecStart" false
                )
                && (
                  hermesModuleVm.config.networking.nftables.enable
                  || builtins.trace "Hermes config assertion 276: hermesModuleVm.config.networking.nftables.enable" false
                )
                && (
                  (hermesModuleVm.config.networking.firewall.backend == "nftables")
                  || builtins.trace "Hermes config assertion 277: hermesModuleVm.config.networking.firewall.backend == \"nftables\"" false
                )
                && (
                  hermesModuleVm.config.networking.firewall.filterForward
                  || builtins.trace "Hermes config assertion 278: hermesModuleVm.config.networking.firewall.filterForward" false
                )
                && (
                  hermesModuleVm.config.networking.nat.enable
                  || builtins.trace "Hermes config assertion 279: hermesModuleVm.config.networking.nat.enable" false
                )
                && (
                  hermesModuleVm.config.networking.nat.enableIPv6
                  || builtins.trace "Hermes config assertion 280: hermesModuleVm.config.networking.nat.enableIPv6" false
                )
                && (
                  hermesModuleVm.config.systemd.network.enable
                  || builtins.trace "Hermes config assertion 281: hermesModuleVm.config.systemd.network.enable" false
                )
                && (
                  hermesModuleVm.config.systemd.network.wait-online.enable
                  || builtins.trace "Hermes config assertion 282: hermesModuleVm.config.systemd.network.wait-online.enable" false
                )
                && (
                  hermesModuleVm.config.services.resolved.enable
                  || builtins.trace "Hermes config assertion 283: Hermes preserves the resolved default on the supported networkd host" false
                )
                && (
                  (builtins.elem hostNetworkSource networkdReloadTriggers)
                  || builtins.trace "Hermes config assertion 284: builtins.elem hostNetworkSource networkdReloadTriggers" false
                )
                && (
                  (!hermesModuleVm.config.systemd.services.systemd-networkd.stopIfChanged)
                  || builtins.trace "Hermes config assertion 285: !hermesModuleVm.config.systemd.services.systemd-networkd.stopIfChanged" false
                )
                && (
                  (nixpkgs-unstable.lib.hasInfix "policy drop" guardConfig)
                  || builtins.trace "Hermes config assertion 286: nixpkgs-unstable.lib.hasInfix \"policy drop\" guardConfig" false
                )
                && (
                  (nixpkgs-unstable.lib.hasInfix "iifname != { \"ha0\", \"ha1\" } accept" guardConfig)
                  || builtins.trace "Hermes config assertion 287: nixpkgs-unstable.lib.hasInfix \"iifname != { \\\"ha0\\\", \\\"ha1\\\" } accept\" guardConfig" false
                )
                && (
                  (builtins.elem "ha0" hermesModuleVm.config.networking.nat.internalInterfaces)
                  || builtins.trace "Hermes config assertion 288: builtins.elem \"ha0\" hermesModuleVm.config.networking.nat.internalInterfaces" false
                )
                && (
                  (builtins.elem "ha1" hermesModuleVm.config.networking.nat.internalInterfaces)
                  || builtins.trace "Hermes config assertion 289: builtins.elem \"ha1\" hermesModuleVm.config.networking.nat.internalInterfaces" false
                )
                && (
                  (builtins.hasAttr "hermes-agent-guard" hermesModuleVm.config.networking.nftables.tables)
                  || builtins.trace "Hermes config assertion 290: builtins.hasAttr \"hermes-agent-guard\" hermesModuleVm.config.networking.nftables.tables" false
                )
                && (
                  (nixpkgs-unstable.lib.hasInfix "ha0" hermesModuleVm.config.networking.firewall.extraInputRules)
                  || builtins.trace "Hermes config assertion 291: nixpkgs-unstable.lib.hasInfix \"ha0\" hermesModuleVm.config.networking.firewall.extraInputRules" false
                )
                && (
                  (nixpkgs-unstable.lib.hasInfix "ha1" hermesModuleVm.config.networking.firewall.extraInputRules)
                  || builtins.trace "Hermes config assertion 292: nixpkgs-unstable.lib.hasInfix \"ha1\" hermesModuleVm.config.networking.firewall.extraInputRules" false
                )
                && (
                  (nixpkgs-unstable.lib.hasInfix "ha0" hermesModuleVm.config.networking.firewall.extraForwardRules)
                  || builtins.trace "Hermes config assertion 293: nixpkgs-unstable.lib.hasInfix \"ha0\" hermesModuleVm.config.networking.firewall.extraForwardRules" false
                )
                && (
                  (nixpkgs-unstable.lib.hasInfix "ha1" hermesModuleVm.config.networking.firewall.extraForwardRules)
                  || builtins.trace "Hermes config assertion 294: nixpkgs-unstable.lib.hasInfix \"ha1\" hermesModuleVm.config.networking.firewall.extraForwardRules" false
                )
                && (
                  (builtins.elem "%S/hermes-vm-peer" units."hermes@vm".serviceConfig.BindPaths)
                  || builtins.trace "Hermes config assertion 295: builtins.elem \"%S/hermes-vm-peer\" units.\"hermes@vm\".serviceConfig.BindPaths" false
                )
                && (
                  (builtins.elem "%S/hermes-vm" units."hermes@vm-peer".serviceConfig.BindPaths)
                  || builtins.trace "Hermes config assertion 296: builtins.elem \"%S/hermes-vm\" units.\"hermes@vm-peer\".serviceConfig.BindPaths" false
                )
                && (
                  networkdIdleVm.config.systemd.network.enable
                  || builtins.trace "Hermes config assertion 297: networkdIdleVm.config.systemd.network.enable" false
                )
                && (
                  (
                    !builtins.hasAttr "40-hermes-agent-0" networkdIdleVm.config.systemd.network.networks
                    && !builtins.hasAttr "40-hermes-agent-1" networkdIdleVm.config.systemd.network.networks
                  )
                  || builtins.trace "Hermes config assertion 298: previous-generation network entries are removed" false
                )
                && (
                  (
                    !builtins.hasAttr "systemd/network/40-hermes-agent-0.network" networkdIdleVm.config.environment.etc
                    && !builtins.hasAttr "systemd/network/40-hermes-agent-1.network" networkdIdleVm.config.environment.etc
                  )
                  || builtins.trace "Hermes config assertion 299: previous generation has no Hermes .network sources" false
                )
                && (
                  (changedHostNetworkSource != hostNetworkSource)
                  || builtins.trace "Hermes config assertion 300: changedHostNetworkSource != hostNetworkSource" false
                )
                && (
                  (builtins.elem changedHostNetworkSource changedNetworkdReloadTriggers)
                  || builtins.trace "Hermes config assertion 301: changed network source is in reloadTriggers" false
                )
                && (
                  (nixpkgs-unstable.lib.hasInfix "# Hermes networkd activation change probe" (
                    builtins.readFile changedHostNetworkSource
                  ))
                  || builtins.trace "Hermes config assertion 302: changed network source has the activation probe comment" false
                )
                && (
                  (
                    networkdActivationVm.config.systemd.services.hermes-vm-generation-rollback-launcher.environment.HERMES_VM_PREVIOUS_SYSTEM
                    == networkdDisabledVm.config.system.build.toplevel
                  )
                  || builtins.trace "Hermes config assertion 303: launcher module-disabled previous system path is pinned" false
                )
                && (
                  (
                    networkdActivationVm.config.systemd.services.hermes-vm-generation-rollback-launcher.environment.HERMES_VM_UPDATED_SYSTEM
                    == networkdChangedVm.config.system.build.toplevel
                  )
                  || builtins.trace "Hermes config assertion 304: launcher changed system path is pinned" false
                )
                && (
                  (builtins.elem "multi-user.target"
                    networkdActivationVm.config.systemd.units."hermes-vm-generation-rollback-launcher.service".wantedBy
                  )
                  || builtins.trace "Hermes config assertion 305: activation launcher is enabled only for the probe VM" false
                )
                && (
                  (
                    !(builtins.hasAttr "hermes@vm" networkdDisabledVm.config.systemd.services)
                    && !(builtins.hasAttr "hermes-pf@vm" networkdDisabledVm.config.systemd.services)
                  )
                  || builtins.trace "Hermes config assertion 306: previous generation has module and agents disabled" false
                )
                && (
                  builtins.length (networkdConfigSetTriggers networkdReloadTriggers) == 1
                  && builtins.length (networkdConfigSetTriggers idleNetworkdReloadTriggers) == 1
                  && builtins.length (networkdConfigSetTriggers changedNetworkdReloadTriggers) == 1
                  || builtins.trace "Hermes config assertion 307: active and zero-agent networkd generations retain one membership reload trigger" false
                )
                && (
                  (builtins.head (networkdConfigSetTriggers networkdReloadTriggers))
                  != (builtins.head (networkdConfigSetTriggers idleNetworkdReloadTriggers))
                  || builtins.trace "Hermes config assertion 308: removal changes membership reload trigger" false
                )
                && (
                  (builtins.head (networkdConfigSetTriggers networkdReloadTriggers))
                  != (builtins.head (networkdConfigSetTriggers changedNetworkdReloadTriggers))
                  || builtins.trace "Hermes config assertion 309: source update changes membership reload trigger" false
                )
                && (
                  builtins.readFile (builtins.head (networkdConfigSetTriggers idleNetworkdReloadTriggers)) == "[]"
                  || builtins.trace "Hermes config assertion 310: last-agent removal leaves an empty membership trigger" false
                )
                && (
                  (
                    builtins.length (
                      networkdConfigSetTriggers (
                        disabledAgentProbe.config.systemd.services.systemd-networkd.reloadTriggers or [ ]
                      )
                    ) == 1
                  )
                  && disabledAgentProbe.config.networking.useNetworkd
                  && disabledAgentProbe.config.systemd.network.enable
                  &&
                    builtins.head (
                      networkdConfigSetTriggers disabledAgentProbe.config.systemd.services.systemd-networkd.reloadTriggers
                    ) != builtins.head (networkdConfigSetTriggers networkdReloadTriggers)
                  || builtins.trace "Hermes config assertion 311: module disable preserves a changed membership reload trigger for the supported networkd host" false
                )
                && (
                  networkdRemovedVm.config.systemd.network.enable
                  && networkdRemovedVm.config.systemd.network.wait-online.enable
                  && !builtins.hasAttr "40-hermes-agent-0" networkdRemovedVm.config.systemd.network.networks
                  && !builtins.hasAttr "40-hermes-agent-1" networkdRemovedVm.config.systemd.network.networks
                  &&
                    builtins.length (
                      networkdConfigSetTriggers networkdRemovedVm.config.systemd.services.systemd-networkd.reloadTriggers
                    ) == 1
                  &&
                    builtins.head (networkdConfigSetTriggers networkdReloadTriggers) != builtins.head (
                      networkdConfigSetTriggers networkdRemovedVm.config.systemd.services.systemd-networkd.reloadTriggers
                    )
                  &&
                    builtins.readFile (
                      builtins.head (
                        networkdConfigSetTriggers networkdRemovedVm.config.systemd.services.systemd-networkd.reloadTriggers
                      )
                    ) == "[]"
                  || builtins.trace (
                    "Hermes config assertion 313: last-agent removal "
                    + builtins.toJSON {
                      networkEnabled = networkdRemovedVm.config.systemd.network.enable;
                      waitOnline = networkdRemovedVm.config.systemd.network.wait-online.enable;
                      networks = builtins.attrNames networkdRemovedVm.config.systemd.network.networks;
                      triggers = networkdRemovedVm.config.systemd.services.systemd-networkd.reloadTriggers or [ ];
                    }
                  ) false
                )
                && (
                  (
                    networkdActivationVm.config.systemd.services.hermes-vm-generation-rollback-launcher.environment.HERMES_VM_REMOVED_SYSTEM
                    == networkdIdleVm.config.system.build.toplevel
                  )
                  || builtins.trace "Hermes config assertion 314: launcher last-agent-removal system path is pinned" false
                )
                && (
                  defaultOnRuntimeVm.config.services.hermes-specialised-agent.installDefaultSkills
                  && defaultOnRuntimeVm.config.services.hermes-specialised-agent.agents.vm.headroomEnable
                  &&
                    defaultOnRuntimeVm.config.systemd.services.hermes-module-vm-agent-smoke.environment.HERMES_VM_DEFAULT_ON_TEST
                    == "1"
                  &&
                    defaultOnRuntimeVm.config.systemd.services.hermes-module-vm-agent-smoke.environment.HERMES_VM_SECURITY_ONLY
                    == "1"
                  &&
                    defaultOnRuntimeVm.config.systemd.services.hermes-module-vm-agent-smoke.environment.HERMES_VM_PROFILE_IDENTITY_ONLY
                    == "1"
                  || builtins.trace "Hermes config assertion 312: runtime default-on probe enables skills and Headroom" false
                )
                && (
                  defaultOnFullProbe.config.services.hermes-specialised-agent.installDefaultSkills
                  && defaultOnFullProbe.config.services.hermes-specialised-agent.agents.vm.headroomEnable
                  &&
                    defaultOnFullProbe.config.systemd.services.hermes-module-vm-agent-smoke.environment.HERMES_VM_DEFAULT_ON_TEST
                    == "1"
                  &&
                    defaultOnFullProbe.config.systemd.services.hermes-module-vm-agent-smoke.environment.HERMES_VM_INTERNET_TEST
                    == "1"
                  &&
                    defaultOnFullProbe.config.systemd.services.hermes-module-vm-agent-smoke.environment.HERMES_VM_SECURITY_ONLY
                    == "0"
                  &&
                    defaultOnFullProbe.config.systemd.services.hermes-module-vm-agent-smoke.environment.HERMES_VM_PROFILE_IDENTITY_ONLY
                    == "0"
                  &&
                    defaultOnFullProbe.config.systemd.services.hermes-module-vm-agent-smoke.environment.HERMES_VM_INTERNET_RECOVERY_ONLY
                    == "0"
                  || builtins.trace "Hermes config assertion 319: full Internet matrix enables default skills and Headroom" false
                )
                && (
                  securityOnlyVm.config.systemd.services.hermes-module-vm-agent-smoke.environment.HERMES_VM_SECURITY_ONLY
                  == "1"
                  || builtins.trace "Hermes config assertion 315: focused security probe enables instantiated-unit verification" false
                )
              then
                "true"
              else
                "false"
            } = true
            test ${
              if
                builtins.hasAttr "hermes-module-vm-smoke" hermesModuleVm.config.systemd.services
                && builtins.hasAttr "hermes-module-vm-agent-smoke" hermesModuleVm.config.systemd.services
                &&
                  hermesModuleVm.config.systemd.services.hermes-module-vm-agent-smoke.serviceConfig.TimeoutStartSec
                  == "5400s"
              then
                "true"
              else
                "false"
            } = true
            test -f ${nixpkgs-unstable.legacyPackages.x86_64-linux.writeText "hermes-gateway-exec-resource" "resource\n"}
            test -f ${nixpkgs-unstable.legacyPackages.x86_64-linux.writeText "hermes-gateway-quoted-exec-resource" "quoted\n"}
            test -f ${nixpkgs-unstable.legacyPackages.x86_64-linux.writeText "hermes-network-exec-resource" "resource\n"}
            test -f ${nixpkgs-unstable.legacyPackages.x86_64-linux.writeText "hermes-network-quoted-exec-resource" "quoted\n"}
            test -f ${nixpkgs-unstable.legacyPackages.x86_64-linux.writeText "hermes-public-state-exec-resource" "resource\n"}
            test -f ${nixpkgs-unstable.legacyPackages.x86_64-linux.writeText "hermes-public-state-quoted-exec-resource" "quoted\n"}
            test -f ${nixpkgs-unstable.legacyPackages.x86_64-linux.writeText "hermes-discarded-gateway-exec-resource" "discarded\n"}
            test -f ${nixpkgs-unstable.legacyPackages.x86_64-linux.writeText "hermes-discarded-network-exec-resource" "discarded\n"}
            test -f ${hermesModuleVmGatewayStart}
            test -f ${defaultOnGatewayStart}
            ! grep -Fq -- '--intercept-tool-results' ${defaultOnGatewayStart}
            test ${
              if
                defaultOnGatewaySettings.headroom != null
                && builtins.elem "--memory" defaultOnGatewaySettings.headroom
                && builtins.elem "--learn" defaultOnGatewaySettings.headroom
                && builtins.elem "--code-graph" defaultOnGatewaySettings.headroom
                && !(builtins.elem "--intercept-tool-results" defaultOnGatewaySettings.headroom)
              then
                "true"
              else
                "false"
            } = true
            ! grep -Fqi 'mnemosyne' ${hermesAgentClosure}/store-paths
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
      nixosModules.hermes-specialised-agent = ./modules/services/agent/hermes.nix;
      nixosConfigurations.hermes-module-vm = hermesModuleVm;
      nixosConfigurations.hermes-module-vm-explicit-dashboard = explicitDashboardProbe;
      nixosConfigurations.hermes-module-vm-internet = internetEnabledVm;
      nixosConfigurations.hermes-module-vm-default-on = defaultOnRuntimeVm;
      nixosConfigurations.hermes-module-vm-default-on-full = defaultOnFullProbe;
      nixosConfigurations.hermes-module-vm-security = securityOnlyVm;
      nixosConfigurations.hermes-module-vm-networkd-activation = networkdActivationVm;
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
