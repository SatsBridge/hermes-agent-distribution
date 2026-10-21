{
  config,
  lib,
  pkgs,
  ...
}:
let
  agentFullNameDuplicatesMessage = lib.concatStringsSep ", " (
    mapAttrsToList (n: count: "\"${n}\" (${toString count} times)") duplicateAgentFullNamesCounts
  );
  agentFullNames = mapAttrsToList (name: { enable, fullName, ... }: {
    inherit enable fullName;
    name = "hermes-${name}";
  }) cfg.agents;
  agentOpts =
    { lib, ... }:
    let
      deepConfigType = types.mkOptionType {
        check = builtins.isAttrs;
        description = "Hermes Agent YAML config (attrset), merged deeply via lib.recursiveUpdate.";
        merge = _loc: defs: foldl' recursiveUpdate { } (map (d: d.value) defs);
        name = "hermes-config-attrs";
      };
      inherit (lib)
        foldl'
        literalExpression
        mkEnableOption
        mkOption
        mkPackageOption
        recursiveUpdate
        types
        ;
    in
    {
      options = {
        enable = mkEnableOption "Hermes Agent gateway service";
        extraArgs = mkOption {
          default = [ ];
          description = "Extra command-line arguments for `hermes gateway`.";
          type = types.listOf types.str;
        };
        extraPlugins = mkOption {
          default = [ ];
          description = ''
            Directory-based plugin packages to symlink into the hermes plugins
            directory. Each package should contain a plugin.yaml and __init__.py
            at its root. Hermes discovers these automatically on startup.
          '';
          example = literalExpression ''
            [
              (pkgs.fetchFromGitHub {
                owner = "stephenschoettler";
                repo = "hermes-lcm";
                name = "hermes-lcm";
                rev = "v0.7.0";
                hash = "sha256-...";
              })
            ]
          '';
          type = types.listOf types.package;
        };
        fullName = mkOption { type = types.str; };
        headroomPort = mkOption { type = types.port; };
        package = mkPackageOption pkgs "hermes-agent" { };
        settings = mkOption {
          default = { };
          description = ''
            Declarative Hermes Agent config (attrset). Deep-merged across module
            definitions and rendered as config.yaml.
          '';
          example = literalExpression ''
            {
              model = "anthropic/claude-sonnet-4";
              terminal.backend = "local";
              compression = { enabled = true; threshold = 0.85; };
              toolsets = [ "all" ];
            }
          '';
          type = deepConfigType;
        };
      };
    };
  cfg = config.services.hermes-specialised-agent;
  inherit (lib)
    concatStringsSep
    filterAttrs
    getName
    mapAttrsToList
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    optional
    types
    ;
  duplicateAgentFullNamesCounts = filterAttrs (_: count: count > 1) (
    builtins.foldl' (
      acc: { fullName, ... }: acc // { ${fullName} = (acc.${fullName} or 0) + 1; }
    ) { } agentFullNames
  );
  mkAgent =
    _agents: agentFullNames: name: agentCfg:
    let
      agentStateId = "hermes-${name}";
      agentStatePath = "%S/${agentStateId}";
      hermesAgentStatePath = "${agentStatePath}/.hermes";
    in
    mkIf (cfg.enable && agentCfg.enable) {
      services = {
        "hermes-pf@${name}" = {
          overrideStrategy = "asDropin";
          wantedBy = [ "multi-user.target" ];
        };
        "hermes@${name}" = {
          after = [
            "network-online.target"
          ]
          ++ optional (cfg.mainAgent != name) "hermes@${cfg.mainAgent}.service";
          bindsTo = [
            "network-online.target"
          ]
          ++ optional (cfg.mainAgent != name) "hermes@${cfg.mainAgent}.service";
          environment = {
            HERMES_PROFILE_NAME = agentCfg.fullName;
            WEBHOOK_ENABLED = if cfg.mainAgent == name then "true" else "false";
            #ANTHROPIC_BASE_URL = "http://localhost:${builtins.toString agentCfg.headroomPort}";
            #OPENAI_BASE_URL = "http://localhost:${builtins.toString agentCfg.headroomPort}/v1";
          };
          overrideStrategy = "asDropin";
          path = config.systemd.services."hermes@".path ++ [ agentCfg.package ];
          serviceConfig = {
            BindPaths = [
              "/dev/kvm"
              sharedStatePath
            ]
            ++ map ({ name, ... }: "%S/${name}") (
              builtins.filter (agent: agent.enable && agent.name != agentStateId) agentFullNames
            );
            ExecStart = lib.getExe (
              pkgs.writeShellApplication {
                name = "hermes-agent-exec-start";
                text = ''
                  cd ~/
                  headroom proxy \
                    --port ${toString agentCfg.headroomPort} \
                    --intercept-tool-results \
                    --memory \
                    --learn \
                    --code-graph &
                  ${
                    concatStringsSep " " (
                      [
                        "hermes"
                        "gateway"
                      ]
                      ++ agentCfg.extraArgs
                    )
                  } &
                  ${lib.optionalString (cfg.mainAgent == name) ''
                    ${
                      concatStringsSep " " [
                        "hermes"
                        "dashboard"
                      ]
                    } &
                  ''}
                  wait -n
                '';
              }
            );
          };
          wantedBy = [ "multi-user.target" ];
        };
      };
      tmpfiles.rules =
        let
          config = (pkgs.formats.yaml { }).generate "${agentStateId}-config.yaml" (
            lib.recursiveUpdate agentCfg.settings {
              kanban = {
                agent_profile_name = agentCfg.fullName;
                dispatch_profiles = [ agentCfg.fullName ];
              };
            }
          );
          mnemosyneConfig = (pkgs.formats.yaml { }).generate "${agentStateId}-mnemosyne-config.yaml" (
            agentCfg.settings.memory.nix-managed-mnemosyne-hermes or { }
          );
        in
        [
          "d %S/private 0700 - - - -"
          "d %S/private/${agentStateId} 2700 - - - -"
          "L+ ${agentStatePath} - - - - private/${agentStateId}"
          "d ${hermesAgentStatePath} 2700 - - - -"
          "f ${hermesAgentStatePath}/.managed 0600 - - - -"
          "d ${hermesAgentStatePath}/cron 2700 - - - -"
          "d ${hermesAgentStatePath}/cron/output 2700 - - - -"
          "d ${hermesAgentStatePath}/logs 2700 - - - -"
          "d ${hermesAgentStatePath}/memories 2700 - - - -"
          "d ${hermesAgentStatePath}/sessions 2700 - - - -"
          "d ${hermesAgentStatePath}/skills 2700 - - - -"
          "d ${hermesAgentStatePath}/skills/software-development 2700 - - - -"
          #"L+ ${hermesAgentStatePath}/skills/software-development/agent-delivery-governance - - - - ${./../../../skills/software-development/agent-delivery-governance}"
          "f ${hermesAgentStatePath}/.env 0600 - - - -"
          "L+ ${hermesAgentStatePath}/config.yaml - - - - ${config}"
          "d ${hermesAgentStatePath}/mnemosyne 2700 - - - -"
          "L+ ${hermesAgentStatePath}/mnemosyne/config.yaml - - - - ${mnemosyneConfig}"
          "L+ ${hermesAgentStatePath}/profiles - - - - ${
            pkgs.linkFarm "hermes-${name}-profiles" (
              map ({ fullName, name, ... }: {
                name = fullName;
                path = "/var/lib/${name}/.hermes";
              }) (builtins.filter (agent: agent.enable && agent.name != agentStateId) agentFullNames)
            )
          }"
          "d ${hermesAgentStatePath}/plugins 2700 - - - -"
        ]
        ++ map (
          plugin: "L+ ${hermesAgentStatePath}/plugins/nix-managed-${getName plugin} - - - - ${plugin}"
        ) agentCfg.extraPlugins;
    };
  mkAgentTemplate =
    let
      agentStateSystemdId = "hermes-%i";
      agentStateSystemdPath = "%S/${agentStateSystemdId}";
      hermesAgentStateSystemdPath = "${agentStateSystemdPath}/.hermes";
      publicStateFixerSystemdId = "hermes-%i-pf";
    in
    mkIf cfg.enable {
      services = {
        "hermes-pf@" =
          let
            grantSkillsAcl = pkgs.writeShellApplication {
              name = "grant-skills-acl";
              runtimeInputs = builtins.attrValues { inherit (pkgs) acl coreutils findutils; };
              text = ''
                skills_dir="$1"
                jobs="''${2:-$(nproc)}"
                scope="''${3:-}"

                [[ -d "$skills_dir" ]] || exit 0

                skills_dir_real=$(realpath -m -- "$skills_dir")

                if [[ -n "$scope" ]]; then
                    scope_real=$(realpath -m -- "$scope")

                    case "$scope_real" in
                    "$skills_dir_real"|"$skills_dir_real"/*) ;;
                    *)
                        echo "grant-skills-acl: refusing scope outside skills_dir: $scope (resolved: $scope_real, skills_dir resolved: $skills_dir_real)" >&2
                        exit 1
                    ;;
                    esac

                    search_root="$scope_real"
                else
                    search_root="$skills_dir_real"
                fi

                declare -A dirs_to_grant=()
                declare -a skill_files=()

                if [[ -f "$search_root" ]]; then
                    [[ "$(basename "$search_root")" == "SKILL.md" ]] || exit 0
                    skill_files+=("$search_root")
                elif [[ -d "$search_root" ]]; then
                    while IFS= read -r -d ${"''"} skill_file; do
                    skill_files+=("$skill_file")
                    done < <(find "$search_root" -name 'SKILL.md' -type f -print0)
                else
                    exit 0
                fi

                for skill_file in "''${skill_files[@]}"; do
                    dir=$(dirname "$skill_file")

                    while [[ "$dir" != "$skills_dir_real" && "$dir" != "/" ]]; do
                    dirs_to_grant["$dir"]=1
                    dir=$(dirname "$dir")
                    done
                done

                dirs_to_grant["$skills_dir_real"]=1

                if [[ "''${#skill_files[@]}" -gt 0 ]]; then
                    printf '%s\0' "''${skill_files[@]}" | \
                    xargs -0P "$jobs" -n 50 setfacl -m "g:${sharedStateId}:r--" --
                fi

                printf '%s\0' "''${!dirs_to_grant[@]}" | \
                    xargs -0P "$jobs" -n 50 setfacl -m "g:${sharedStateId}:r-x" --
              '';
            };
          in
          {
            after = [ "hermes@%i.service" ];
            description = "Hermes Agent Public State Fixer";
            enableDefaultPath = false;
            environment = {
              HERMES_HOME = hermesAgentStateSystemdPath;
              HOME = agentStateSystemdPath;
            };
            path =
              builtins.attrValues {
                inherit (pkgs)
                  acl
                  bash
                  coreutils
                  findutils
                  inotify-tools
                  ;
              }
              ++ [ grantSkillsAcl ];
            serviceConfig = {
              AmbientCapabilities = [
                "CAP_DAC_READ_SEARCH"
                "CAP_FOWNER"
              ];
              CapabilityBoundingSet = [
                "CAP_DAC_READ_SEARCH"
                "CAP_FOWNER"
              ];
              CoredumpFilter = "0x00";
              DelegateNamespaces = false;
              DevicePolicy = "closed";
              DynamicUser = true;
              ExecStart = [
                (lib.getExe (
                  pkgs.writeShellApplication {
                    name = "hermes-agent-pf-exec-start";
                    runtimeInputs =
                      builtins.attrValues {
                        inherit (pkgs)
                          acl
                          bash
                          coreutils
                          findutils
                          inotify-tools
                          ;
                      }
                      ++ [ grantSkillsAcl ];
                    text = ''
                      # StateDirectoryMode=2700 can leave the ACL mask at ---; raise it so the shared-group r-x grant is effective.
                      setfacl -m "g:${sharedStateId}:r-x,m::r-x" -- "$HOME/"
                      setfacl -m "g:${sharedStateId}:r-x,m::r-x" -- "$HERMES_HOME/"
                      setfacl -m "g:${sharedStateId}:r-x" -- "$HERMES_HOME/cron"
                      setfacl -m "g:${sharedStateId}:r--" -- "$HERMES_HOME/cron/output"

                      grant-skills-acl "$HERMES_HOME/skills" 1 "$HERMES_HOME/skills" &

                      find "$HERMES_HOME/gateway.pid" "$HERMES_HOME/gateway_state.json" -type f -exec setfacl -m "g:${sharedStateId}:r--" -- {} \; &

                      find "$HERMES_HOME/logs" "$HERMES_HOME/logs/curator" -type d -exec setfacl -m "g:${sharedStateId}:r--" -- {} \; &

                      wait

                      (sleep 5;

                       grant-skills-acl "$HERMES_HOME/skills" 1 "$HERMES_HOME/skills" &
                       find "$HERMES_HOME/gateway.pid" "$HERMES_HOME/gateway_state.json" "$HERMES_HOME/gateway_state.json" -type f -exec setfacl -m "g:${sharedStateId}:r--" -- {} \; &

                       find "$HERMES_HOME/logs" "$HERMES_HOME/logs/curator" -type d -exec setfacl -m "g:${sharedStateId}:r--" -- {} \; &) &

                      exec inotifywait -mrqe create,moved_to --format '%w%f%0' --no-newline -- "$HERMES_HOME/skills" | xargs -0P 1 -n 50 grant-skills-acl "$HERMES_HOME/skills" 1
                    '';
                  }
                ))
              ];
              Group = publicStateFixerSystemdId;
              KeyringMode = "private";
              LockPersonality = true;
              MemoryDenyWriteExecute = true;
              MemoryKSM = true;
              MountAPIVFS = true;
              NoNewPrivileges = true;
              NotifyAccess = "none";
              #PrivateBPF = true;
              PrivateDevices = true;
              PrivateIPC = true;
              PrivateMounts = true;
              PrivateNetwork = true;
              #PrivatePIDs = true;
              PrivateTmp = true;
              # TODO: PrivateUsers = "self" after https://github.com/systemd/systemd/issues/41994
              PrivateUsers = "identity";
              ProcSubset = "pid";
              ProtectClock = true;
              ProtectControlGroups = "strict";
              ProtectHome = true;
              ProtectHostname = "private";
              ProtectKernelLogs = true;
              ProtectKernelModules = true;
              ProtectKernelTunables = true;
              ProtectProc = "invisible";
              ProtectSystem = "strict";
              ReadWritePaths = [ agentStateSystemdPath ];
              RemoveIPC = true;
              Restart = "always";
              RestrictAddressFamilies = [ "AF_UNIX" ];
              RestrictNamespaces = true;
              RestrictRealtime = true;
              RestrictSUIDSGID = true;
              SetLoginEnvironment = false;
              SupplementaryGroups = [ sharedStateId ];
              SystemCallArchitectures = "native";
              SystemCallErrorNumber = "EPERM";
              SystemCallFilter = [
                "@system-service"
                "~@resources"
                "~@privileged"
              ];
              Type = "exec";
              UMask = "0077";
              User = publicStateFixerSystemdId;
            };
            wantedBy = [ "hermes@%i.service" ];
          };
        "hermes@" = {
          after = [ "network-online.target" ];
          bindsTo = [ "network-online.target" ];
          description = "Hermes Agent Gateway";
          enableDefaultPath = false;
          environment = {
            HEADROOM_BEACON = "off";
            #HEADROOM_OTEL_METRICS_ENABLED = "1";
            HEADROOM_SAVINGS_PROFILE = "coding";
            HEADROOM_TELEMETRY = "on";
            HERMES_HOME = hermesAgentStateSystemdPath;
            HERMES_KANBAN_HOME = sharedStatePath;
            HOME = agentStateSystemdPath;
            MNEMOSYNE_AUTO_MIGRATE = "1";
            MNEMOSYNE_AUTO_SLEEP_ENABLED = "1";
            MNEMOSYNE_CROSS_SESSION = "1";
            MNEMOSYNE_DEFAULT_SCOPE = "global";
            MNEMOSYNE_DEGRADE_BATCH = "200";
            MNEMOSYNE_EMBEDDING_MODEL = "text-embedding-3-large";
            MNEMOSYNE_ENHANCED_RECALL = "1";
            MNEMOSYNE_EP_LIMIT = "100000";
            MNEMOSYNE_FACT_RECALL_ENABLED = "1";
            MNEMOSYNE_FORCE_LOCAL = "0";
            MNEMOSYNE_FTS_WEIGHT = "0.2";
            MNEMOSYNE_HOST_LLM_ENABLED = "1";
            MNEMOSYNE_HOST_LLM_N_CTX = "64000";
            MNEMOSYNE_IMPORTANCE_WEIGHT = "0.2";
            MNEMOSYNE_LENIENT_FACT_MATCH = "1";
            MNEMOSYNE_LLM_CONFLICT_DETECTION = "1";
            MNEMOSYNE_LLM_ENABLED = "1";
            MNEMOSYNE_LLM_MAX_TOKENS = "4096";
            MNEMOSYNE_LLM_N_CTX = "4096";
            MNEMOSYNE_LLM_N_THREADS = "8";
            MNEMOSYNE_LLM_TIMEOUT = "120";
            MNEMOSYNE_PERSONA_DAILY_SYNC_HOUR = "3";
            MNEMOSYNE_PERSONA_ENABLED = "1";
            MNEMOSYNE_PERSONA_INTERVAL = "25";
            MNEMOSYNE_PERSONA_TOKEN_CAP = "2000";
            MNEMOSYNE_POLYPHONIC_RECALL = "1";
            MNEMOSYNE_PREFETCH_CONTENT_CHARS = "1000";
            MNEMOSYNE_PROACTIVE_LINKING = "1";
            MNEMOSYNE_PROFILE_ISOLATION = "1";
            MNEMOSYNE_QUERY_INTENT = "1";
            MNEMOSYNE_RECALL_DIAGNOSTICS = "1";
            MNEMOSYNE_RECENCY_HALFLIFE = "336";
            MNEMOSYNE_REFLECT_DISABLED_FOR_CRON = "1";
            MNEMOSYNE_REFLECT_MAX_CALLS_PER_SESSION = "5";
            MNEMOSYNE_SHARED_SURFACE_READ = "1";
            MNEMOSYNE_SHMR_BATCH_SIZE = "100";
            MNEMOSYNE_SHMR_HARMONY_THRESHOLD = "0.55";
            MNEMOSYNE_SHMR_MAX_ITERATIONS = "5";
            MNEMOSYNE_SHMR_MIN_CLUSTER_SIZE = "2";
            MNEMOSYNE_SHMR_SIMILARITY_THRESHOLD = "0.65";
            MNEMOSYNE_SHMR_TEMPERATURE = "0.3";
            MNEMOSYNE_SLEEP_BATCH = "10000";
            MNEMOSYNE_SLEEP_MODEL_REFRESH_AUTO_APPLY = "1";
            MNEMOSYNE_SLEEP_MODEL_REFRESH_ENABLED = "1";
            MNEMOSYNE_SLEEP_THRESHOLD = "25";
            MNEMOSYNE_SMART_COMPRESS = "1";
            MNEMOSYNE_SP_MAX = "5000";
            MNEMOSYNE_SYNC_ROLES = "user,assistant";
            MNEMOSYNE_SYNC_TURN_ASSISTANT_LIMIT = "1500";
            MNEMOSYNE_SYNC_TURN_USER_LIMIT = "1000";
            MNEMOSYNE_TEMPORAL_HALFLIFE_HOURS = "48";
            MNEMOSYNE_TIER1_WEIGHT = "1.0";
            MNEMOSYNE_TIER2_DAYS = "90";
            MNEMOSYNE_TIER2_WEIGHT = "0.7";
            MNEMOSYNE_TIER3_DAYS = "365";
            MNEMOSYNE_TIER3_MAX_CHARS = "500";
            MNEMOSYNE_TIER3_WEIGHT = "0.5";
            MNEMOSYNE_VEC_TYPE = "float32";
            MNEMOSYNE_VEC_WEIGHT = "0.6";
            MNEMOSYNE_WM_BUMP_CAP_HOURS = "48";
            MNEMOSYNE_WM_MAX_ITEMS = "50000";
            MNEMOSYNE_WM_TTL_HOURS = "720";
            MNEMOSYNE_WRITE_CLASSIFIER = "strict";
            PONYTAIL_DEFAULT_MODE = "ultra";
            RTK_TELEMETRY_DISABLED = "1";
            SSH_AUTH_SOCK = "%t/${agentStateSystemdId}/ssh-agent.socket";
            SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          };
          path = builtins.attrValues {
            inherit (pkgs)
              ast-grep
              bash
              coreutils
              diffutils
              findutils
              git
              gnugrep
              gnused
              headroom
              headroom-proxy
              mnemosyne
              nix
              openssh
              ripgrep
              util-linux
              ;
          };
          serviceConfig = {
            AmbientCapabilities = [ "" ];
            BindPaths = [
              "/dev/kvm"
              sharedStatePath
            ];
            BindReadOnlyPaths = [
              "/nix"
              "${lib.getExe' pkgs.bash "sh"}:/bin/sh"
              "${lib.getExe' pkgs.bash "bash"}:/bin/bash"
              "${lib.getExe' pkgs.coreutils "env"}:/usr/bin/env"
              "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt:/etc/ssl/certs/ca-bundle.crt"
              "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt"
            ];
            CapabilityBoundingSet = [ "" ];
            CoredumpFilter = "0x00";
            DelegateNamespaces = false;
            DeviceAllow = [ "/dev/kvm rw" ];
            DevicePolicy = "closed";
            DynamicUser = true;
            ExecStartPre = [
              "+${
                lib.getExe (
                  pkgs.writeShellApplication {
                    name = "hermes-agent-exec-start-pre";
                    runtimeInputs = [ pkgs.coreutils ];
                    text = ''
                      uid="$(stat --printf=%u -- "''${RUNTIME_DIRECTORY%%:*}")"
                      gid="$(stat --printf=%g -- "''${RUNTIME_DIRECTORY%%:*}")"

                      exec chown -R "$uid:$gid" -- "$HOME"
                    '';
                  }
                )
              }"
            ]
            ++ optional cfg.installDefaultSkills (
              lib.getExe (
                pkgs.writeShellApplication {
                  name = "hermes-agent-exec-start-pre";
                  text = ''
                    hermes skills install -y official/creative/concept-diagrams
                    hermes skills install -y official/creative/creative-ideation
                    hermes skills install -y official/software-development/ast-grep
                    hermes skills install -y official/software-development/code-wiki
                    hermes skills install -y official/software-development/subagent-driven-development
                  '';
                }
              )
            );
            Group = agentStateSystemdId;
            InaccessiblePaths = "";
            KeyringMode = "private";
            LockPersonality = true;
            #MemoryDenyWriteExecute = true;
            MemoryKSM = true;
            MountAPIVFS = true;
            NoNewPrivileges = true;
            NotifyAccess = "none";
            #PrivateBPF = true;
            PrivateDevices = true;
            PrivateIPC = true;
            PrivateMounts = true;
            #PrivateNetwork = true;
            #PrivatePIDs = true;
            PrivateTmp = true;
            # TODO: PrivateUsers = "self" after https://github.com/systemd/systemd/issues/41994
            PrivateUsers = "identity";
            #ProcSubset = "pid"; # ONNX bug
            ProtectClock = true;
            ProtectControlGroups = "strict";
            ProtectHome = true;
            ProtectHostname = "private";
            ProtectKernelLogs = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectProc = "invisible";
            ProtectSystem = "strict";
            ReadOnlyPaths = [ "/proc/cpuinfo" ];
            #ReadWritePaths = [ sharedStatePath ];
            RemoveIPC = true;
            Restart = "always";
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
              "AF_UNIX"
            ];
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            RootDirectory = "%t/${agentStateSystemdId}/root";
            RuntimeDirectory = [
              agentStateSystemdId
              "${agentStateSystemdId}/root"
            ];
            RuntimeDirectoryMode = "0700";
            RuntimeDirectoryPreserve = false;
            SetLoginEnvironment = false;
            StateDirectory = [ agentStateSystemdId ];
            StateDirectoryMode = "2700";
            SupplementaryGroups = [ sharedStateId ];
            SystemCallArchitectures = "native";
            SystemCallErrorNumber = "EPERM";
            SystemCallFilter = [
              "@system-service"
              "~@resources"
              "~@privileged"
            ];
            Type = "exec";
            UMask = "0007";
            User = agentStateSystemdId;
          };
          unitConfig.PropagatesStopTo = [ "hermes-pf@%i.service" ];
          wantedBy = [ "multi-user.target" ];
        };
      };
    };
  sharedState.tmpfiles.rules = [
    "d ${sharedStatePath} 2770 root ${sharedStateId} - -"
    "d ${sharedStatePath}/kanban 2770 root ${sharedStateId} - -"
    "d ${sharedStatePath}/kanban/logs 2770 root ${sharedStateId} - -"
    "d ${sharedStatePath}/kanban/workspaces 2770 root ${sharedStateId} - -"
  ];
  sharedStateId = "hermes-shared";
  sharedStatePath = "%S/${sharedStateId}";
in
{
  config = {
    assertions = [
      {
        assertion = duplicateAgentFullNamesCounts == { };
        message = "services.hermes-agent: agent `fullName` values must be unique, but found duplicates: ${agentFullNameDuplicatesMessage}";
      }
    ];

    nix.settings.allowed-users = map (name: "hermes-${name}") (builtins.attrNames cfg.agents);

    systemd = mkMerge (
      (mapAttrsToList (mkAgent cfg.agents agentFullNames) cfg.agents)
      ++ [
        mkAgentTemplate
        sharedState
      ]
    );
    users.groups.hermes-shared = { };
  };
  options.services.hermes-specialised-agent = {
    agents = mkOption {
      default = { };
      type = types.attrsOf (types.submodule agentOpts);
    };
    enable = mkEnableOption "Hermes Agent gateway services";
    installDefaultSkills = mkOption {
      default = true;
      description = "Install the default Hermes skills before starting agent services.";
      type = types.bool;
    };
    mainAgent = mkOption { type = types.str; };
  };
}
