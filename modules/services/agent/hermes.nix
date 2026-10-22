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
        headroomEnable = mkOption {
          default = true;
          description = "Run the Headroom optimization proxy alongside this Hermes agent.";
          type = types.bool;
        };
        headroomPort = mkOption { type = types.port; };
        package = mkPackageOption pkgs "hermes-agent" { };
        portMappings = mkOption {
          default = null;
          description = ''
            TCP ports forwarded from host loopback to this agent's network namespace.
            Null uses the main-agent dashboard default (127.0.0.1:9119 -> 9119);
            an explicit empty list disables mappings.
          '';
          example = literalExpression "[{ hostPort = 9119; agentPort = 9119; }]";
          type = types.nullOr (
            types.listOf (
              types.submodule {
                options = {
                  agentPort = mkOption { type = types.port; };
                  hostPort = mkOption { type = types.port; };
                  target = mkOption {
                    default = "veth";
                    description = "Where to connect inside the namespace: a veth-bound listener, or its loopback interface.";
                    type = types.enum [
                      "loopback"
                      "veth"
                    ];
                  };
                };
              }
            )
          );
        };
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
  activeAgentNames = builtins.filter (name: cfg.agents.${name}.enable) (
    builtins.attrNames cfg.agents
  );
  closureStorePaths =
    rootPaths:
    let
      closureInfo = pkgs.closureInfo { inherit rootPaths; };
    in
    builtins.filter (path: path != "") (
      lib.splitString "\n" (builtins.readFile "${closureInfo}/store-paths")
    );
  nixStoreAliasPaths = [
    "-/etc/profiles"
    "-/etc/static"
    "-/etc/systemd"
    "-/nix/var/nix/profiles"
    "-/root/.nix-defexpr"
    "-/root/.nix-profile"
    "-/run/booted-system"
    "-/run/current-system"
    "-/run/wrappers"
  ];
  hermesRuntimePath = builtins.attrValues {
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
  gatewayOwnershipExecStartPre = pkgs.writeShellApplication {
    name = "hermes-agent-exec-start-pre";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      uid="$(stat --printf=%u -- "''${RUNTIME_DIRECTORY%%:*}")"
      gid="$(stat --printf=%g -- "''${RUNTIME_DIRECTORY%%:*}")"

      exec chown -R "$uid:$gid" -- "$HOME"
    '';
  };

  activePortMappings =
    if cfg.enable then
      lib.concatMap (
        name:
        let
          configured = cfg.agents.${name}.portMappings;
        in
        if configured == null then
          optional (cfg.mainAgent == name) {
            hostPort = 9119;
            agentPort = 9119;
            target = "loopback";
          }
        else
          configured
      ) activeAgentNames
    else
      [ ];
  mappedHostPorts = map (mapping: mapping.hostPort) activePortMappings;
  agentNetworks = builtins.listToAttrs (
    lib.imap0 (
      index: name:
      let
        block = index - (builtins.div index 16384) * 16384;
        octet2 = 18 + builtins.div index 16384;
        octet3 = builtins.div block 64;
        octet4 = (index - (builtins.div index 64) * 64) * 4;
        network = "198.${toString octet2}.${toString octet3}.${toString octet4}";
        ipv6High = builtins.div index 256;
        ipv6Low = index - ipv6High * 256;
        ipv6Network =
          if ipv6High == 0 && ipv6Low == 0 then
            "fd42:198:18::"
          else if ipv6Low == 0 then
            "fd42:198:18:${toString ipv6High}::"
          else
            "fd42:198:18:${toString ipv6High}:${toString ipv6Low}::";
      in
      {
        inherit name;
        value = {
          inherit index network;
          hostIf = "ha${toString index}";
          peerIf = "hb${toString index}";
          hostIp = "198.${toString octet2}.${toString octet3}.${toString (octet4 + 1)}";
          agentIp = "198.${toString octet2}.${toString octet3}.${toString (octet4 + 2)}";
          subnet = "${network}/30";
          inherit ipv6Network;
          hostIpv6 = "${ipv6Network}1";
          agentIpv6 = "${ipv6Network}2";
          ipv6Subnet = "${ipv6Network}/80";
        };
      }
    ) activeAgentNames
  );
  agentFirewallInputRules = concatStringsSep "\n" (
    map (network: ''
      iifname "${network.hostIf}" ip saddr ${network.agentIp} ip daddr ${network.hostIp} udp dport 53 accept
      iifname "${network.hostIf}" ip saddr ${network.agentIp} ip daddr ${network.hostIp} tcp dport 53 accept
      iifname "${network.hostIf}" ip6 saddr ${network.agentIpv6} ip6 daddr ${network.hostIpv6} udp dport 53 accept
      iifname "${network.hostIf}" ip6 saddr ${network.agentIpv6} ip6 daddr ${network.hostIpv6} tcp dport 53 accept
    '') (builtins.attrValues agentNetworks)
  );
  agentInputGuardRules = concatStringsSep "\n" (
    map (network: ''
      iifname "${network.hostIf}" ct state established,related accept
      iifname "${network.hostIf}" meta l4proto ipv6-icmp icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-neighbor-solicit, nd-neighbor-advert } accept
      iifname "${network.hostIf}" ip saddr ${network.agentIp} ip daddr ${network.hostIp} udp dport 53 accept
      iifname "${network.hostIf}" ip saddr ${network.agentIp} ip daddr ${network.hostIp} tcp dport 53 accept
      iifname "${network.hostIf}" ip6 saddr ${network.agentIpv6} ip6 daddr ${network.hostIpv6} udp dport 53 accept
      iifname "${network.hostIf}" ip6 saddr ${network.agentIpv6} ip6 daddr ${network.hostIpv6} tcp dport 53 accept
      iifname "${network.hostIf}" drop
    '') (builtins.attrValues agentNetworks)
  );
  agentForwardGuardRules = concatStringsSep "\n" (
    map (
      network:
      let
        otherNetworks = builtins.filter (other: other.index != network.index) (
          builtins.attrValues agentNetworks
        );
        peerDrops = concatStringsSep "\n" (
          map (other: ''
            iifname "${network.hostIf}" ip saddr ${network.agentIp} ip daddr ${other.subnet} drop
            iifname "${network.hostIf}" ip6 saddr ${network.agentIpv6} ip6 daddr ${other.ipv6Subnet} drop
          '') otherNetworks
        );
      in
      ''
        ${peerDrops}
        iifname "${network.hostIf}" ip saddr != ${network.agentIp} drop
        iifname "${network.hostIf}" ip6 saddr != ${network.agentIpv6} drop
        oifname "${network.hostIf}" ip daddr ${network.agentIp} ct state established,related accept
        oifname "${network.hostIf}" ip6 daddr ${network.agentIpv6} ct state established,related accept
        oifname "${network.hostIf}" ip daddr ${network.agentIp} drop
        oifname "${network.hostIf}" ip6 daddr ${network.agentIpv6} drop
      ''
    ) (builtins.attrValues agentNetworks)
  );
  agentFirewallForwardRules = concatStringsSep "\n" (
    map (network: ''
      iifname "${network.hostIf}" ip saddr ${network.agentIp} accept
      iifname "${network.hostIf}" ip6 saddr ${network.agentIpv6} accept
    '') (builtins.attrValues agentNetworks)
  );
  mkAgentNetworkSetup =
    name: network: portMappings:
    let
      loopbackPorts = lib.unique (
        map (mapping: mapping.agentPort) (
          builtins.filter (mapping: mapping.target == "loopback") portMappings
        )
      );
      namespaceRelayCommands = concatStringsSep "\n" (
        map (agentPort: ''
          ${lib.getExe' pkgs.util-linux "setpriv"} --no-new-privs --reuid=nobody --regid=nogroup --clear-groups -- \
            ${lib.getExe' pkgs.socat "socat"} \
            TCP4-LISTEN:${toString agentPort},bind=${network.agentIp},reuseaddr,fork \
            TCP4:127.0.0.1:${toString agentPort} >/dev/null 2>&1 &
          relay_pid=$!
          relay_pids+=("$relay_pid")
          for _ in {1..50}; do
            if ${lib.getExe' pkgs.iproute2 "ss"} -H -ltn "sport = :${toString agentPort}" | grep -Fq "${network.agentIp}:${toString agentPort}"; then break; fi
            sleep 0.1
          done
          ${lib.getExe' pkgs.iproute2 "ss"} -H -ltn "sport = :${toString agentPort}" | grep -Fq "${network.agentIp}:${toString agentPort}" || {
            echo "Loopback relay failed to bind namespace port ${toString agentPort}" >&2
            exit 1
          }
        '') loopbackPorts
      );
      hostForwardCommands = concatStringsSep "\n" (
        map (mapping: ''
          if host ${lib.getExe' pkgs.iproute2 "ss"} -H -ltn "sport = :${toString mapping.hostPort}" | grep -q .; then
            echo "Host loopback port ${toString mapping.hostPort} is already in use" >&2
            exit 1
          fi
          ${lib.getExe' pkgs.util-linux "nsenter"} --net=/proc/1/ns/net -- ${lib.getExe' pkgs.util-linux "setpriv"} \
            --no-new-privs --reuid=nobody --regid=nogroup --clear-groups -- \
            ${lib.getExe' pkgs.socat "socat"} \
            TCP4-LISTEN:${toString mapping.hostPort},bind=127.0.0.1,reuseaddr,fork \
            TCP4:${network.agentIp}:${toString mapping.agentPort} >/dev/null &
          proxy_pid=$!
          proxy_pids+=("$proxy_pid")
          for _ in {1..50}; do
            if host ${lib.getExe' pkgs.iproute2 "ss"} -H -ltn "sport = :${toString mapping.hostPort}" | grep -Fq "127.0.0.1:${toString mapping.hostPort}"; then
              echo "Forwarding host 127.0.0.1:${toString mapping.hostPort} to hermes@${name} port ${toString mapping.agentPort}"
              break
            fi
            sleep 0.1
          done
          host ${lib.getExe' pkgs.iproute2 "ss"} -H -ltn "sport = :${toString mapping.hostPort}" | grep -Fq "127.0.0.1:${toString mapping.hostPort}" || {
            echo "Host loopback forwarding proxy failed to bind port ${toString mapping.hostPort}" >&2
            exit 1
          }
        '') portMappings
      );
    in
    pkgs.writeShellApplication {
      name = "hermes-agent-network-${toString network.index}";
      runtimeInputs = builtins.attrValues {
        inherit (pkgs)
          coreutils
          gawk
          gnugrep
          iproute2
          python3
          util-linux
          ;
      };
      text = ''
                host() { ${lib.getExe' pkgs.util-linux "nsenter"} --net=/proc/1/ns/net -- "$@"; }
                host_if=${network.hostIf}
                peer_if=${network.peerIf}
                host_ip=${network.hostIp}
                agent_ip=${network.agentIp}
                subnet=${network.subnet}
                host_ip6=${network.hostIpv6}
                agent_ip6=${network.agentIpv6}
                subnet6=${network.ipv6Subnet}
                alias=hermes-agent-${name}

                dns_pid=
                proxy_pids=()
                relay_pids=()
                created_link=0

                cleanup() {
                  set +e
                  if [[ -n "$dns_pid" ]]; then
                    kill "$dns_pid" 2>/dev/null || true
                    wait "$dns_pid" 2>/dev/null || true
                  fi
                  for proxy_pid in "''${proxy_pids[@]}"; do
                    kill "$proxy_pid" 2>/dev/null || true
                    wait "$proxy_pid" 2>/dev/null || true
                  done
                  for relay_pid in "''${relay_pids[@]}"; do
                    kill "$relay_pid" 2>/dev/null || true
                    wait "$relay_pid" 2>/dev/null || true
                  done
                  if (( created_link )); then
                    host ${lib.getExe' pkgs.iproute2 "ip"} link delete dev "$host_if" 2>/dev/null || true
                  elif host ${lib.getExe' pkgs.iproute2 "ip"} -details link show dev "$host_if" 2>/dev/null | grep -Fq "alias $alias"; then
                    host ${lib.getExe' pkgs.iproute2 "ip"} link delete dev "$host_if" 2>/dev/null || true
                  fi
                }

                if [[ "''${1:-setup}" == cleanup ]]; then
                  cleanup
                  exit 0
                fi
                [[ "''${1:-setup}" == setup ]] || { echo "usage: $0 [setup|cleanup]" >&2; exit 2; }
                trap cleanup ERR INT TERM

                if host ${lib.getExe' pkgs.iproute2 "ip"} link show dev "$host_if" >/dev/null 2>&1 \
                  || host ${lib.getExe' pkgs.iproute2 "ip"} link show dev "$peer_if" >/dev/null 2>&1; then
                  echo "Refusing to replace an existing Hermes network interface: $host_if/$peer_if" >&2
                  exit 1
                fi
                routes="$(host ${lib.getExe' pkgs.iproute2 "ip"} -4 route show table all)"
                addresses="$(host ${lib.getExe' pkgs.iproute2 "ip"} -o -4 address show)"
                routes6="$(host ${lib.getExe' pkgs.iproute2 "ip"} -6 route show table all)"
                addresses6="$(host ${lib.getExe' pkgs.iproute2 "ip"} -o -6 address show)"
                ${lib.getExe' pkgs.python3 "python3"} - "$subnet" "$routes" "$addresses" "$subnet6" "$routes6" "$addresses6" <<'PY'
        import ipaddress
        import sys

        def check(target_text, routes_text, addresses_text, family):
            target = ipaddress.ip_network(target_text)
            address_key = "inet6" if family == 6 else "inet"
            for line in routes_text.splitlines():
                destination = line.split()[0]
                if destination == "default":
                    continue
                try:
                    route = ipaddress.ip_network(destination, strict=False)
                except ValueError:
                    continue
                if route.version == family and route.prefixlen and target.overlaps(route):
                    raise SystemExit(f"Hermes subnet {target} overlaps host route {route}: {line}")
            for line in addresses_text.splitlines():
                fields = line.split()
                try:
                    address = ipaddress.ip_interface(fields[fields.index(address_key) + 1])
                except (ValueError, IndexError):
                    continue
                if target.overlaps(address.network):
                    raise SystemExit(f"Hermes subnet {target} overlaps host address {address}: {line}")

        check(sys.argv[1], sys.argv[2], sys.argv[3], 4)
        check(sys.argv[4], sys.argv[5], sys.argv[6], 6)
        PY

                host ${lib.getExe' pkgs.iproute2 "ip"} link add "$host_if" type veth peer name "$peer_if"
                created_link=1
                host ${lib.getExe' pkgs.iproute2 "ip"} link set dev "$host_if" alias "$alias"
                host ${lib.getExe' pkgs.iproute2 "ip"} address add "$host_ip/30" dev "$host_if"
                host ${lib.getExe' pkgs.iproute2 "ip"} -6 address add "$host_ip6/80" dev "$host_if" nodad
                host ${lib.getExe' pkgs.iproute2 "ip"} link set dev "$peer_if" netns "$$"
                ${lib.getExe' pkgs.iproute2 "ip"} address add "$agent_ip/30" dev "$peer_if"
                ${lib.getExe' pkgs.iproute2 "ip"} -6 address add "$agent_ip6/80" dev "$peer_if" nodad
                ${lib.getExe' pkgs.iproute2 "ip"} link set dev "$peer_if" up
                ${lib.getExe' pkgs.iproute2 "ip"} route add default via "$host_ip" dev "$peer_if"
                ${lib.getExe' pkgs.iproute2 "ip"} -6 route add default via "$host_ip6" dev "$peer_if"

                host ${lib.getExe' pkgs.iproute2 "ip"} link set dev "$host_if" up
                mapfile -t dns_upstreams < <(awk '$1 == "nameserver" && NF >= 2 { print $2 }' /run/hermes-host-resolv.conf)
                ((''${#dns_upstreams[@]} > 0)) || { echo "No host nameservers in /etc/resolv.conf" >&2; exit 1; }
                dns_args=()
                for dns_upstream in "''${dns_upstreams[@]}"; do dns_args+=("--server=$dns_upstream"); done
                ${lib.getExe' pkgs.util-linux "nsenter"} --net=/proc/1/ns/net -- ${lib.getExe' pkgs.dnsmasq "dnsmasq"} \
                  --no-daemon --no-resolv --no-hosts --bind-dynamic \
                  --listen-address="$host_ip" --listen-address="$host_ip6" \
                  --user=nobody --group=nogroup --port=53 "''${dns_args[@]}" >/dev/null 2>&1 &
                dns_pid=$!
                dns_ready=0
                for _ in {1..50}; do
                  if host ${lib.getExe' pkgs.iproute2 "ss"} -H -lun 'sport = :53' | grep -Fq "$host_ip:53"; then
                    dns_ready=1
                    break
                  fi
                  sleep 0.1
                done
                (( dns_ready )) || { echo "DNS forwarder did not bind $host_ip/$host_ip6:53" >&2; exit 1; }
                ${namespaceRelayCommands}
                ${hostForwardCommands}
                trap - ERR INT TERM
                echo "Configured $host_if <-> $peer_if for hermes@${name}: $agent_ip/$agent_ip6 via $host_ip/$host_ip6; DNS upstreams: ''${dns_upstreams[*]}"
      '';
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
      agentNetwork = agentNetworks.${name};
      portMappings =
        if agentCfg.portMappings == null then
          optional (cfg.mainAgent == name) {
            hostPort = 9119;
            agentPort = 9119;
            target = "loopback";
          }
        else
          agentCfg.portMappings;
      networkSetup = mkAgentNetworkSetup name agentNetwork portMappings;
      resolvConf = pkgs.writeText "${agentStateId}-resolv.conf" "nameserver ${agentNetwork.hostIp}\nnameserver ${agentNetwork.hostIpv6}\noptions attempts:1 timeout:2\n";
      agentConfig = (pkgs.formats.yaml { }).generate "${agentStateId}-config.yaml" (
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
      profileFarm = pkgs.linkFarm "hermes-${name}-profiles" (
        map ({ fullName, name, ... }: {
          name = fullName;
          path = "/var/lib/${name}/.hermes";
        }) (builtins.filter (agent: agent.enable && agent.name != agentStateId) agentFullNames)
      );
      execStart = pkgs.writeShellApplication {
        name = "hermes-agent-exec-start";
        runtimeInputs = [ agentCfg.package ] ++ optional agentCfg.headroomEnable pkgs.headroom;
        text = ''
          cd ~/
          ${lib.optionalString agentCfg.headroomEnable ''
            headroom proxy \
              --port ${toString agentCfg.headroomPort} \
              --intercept-tool-results \
              --memory \
              --learn \
              --code-graph &
          ''}
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
                "--no-open"
              ]
            } &
          ''}
          wait -n
        '';
      };
      installSkillsExecStartPre = pkgs.writeShellApplication {
        name = "hermes-agent-exec-start-pre";
        runtimeInputs = [ agentCfg.package ];
        text = ''
          hermes skills install -y official/creative/concept-diagrams
          hermes skills install -y official/creative/creative-ideation
          hermes skills install -y official/software-development/ast-grep
          hermes skills install -y official/software-development/code-wiki
          hermes skills install -y official/software-development/subagent-driven-development
        '';
      };

      peerNames = builtins.filter (peer: peer != name && _agents.${peer}.enable) (
        builtins.attrNames _agents
      );
      peerConfigs = lib.concatMap (peer: [
        ((pkgs.formats.yaml { }).generate "hermes-${peer}-config.yaml" (
          lib.recursiveUpdate _agents.${peer}.settings {
            kanban = {
              agent_profile_name = _agents.${peer}.fullName;
              dispatch_profiles = [ _agents.${peer}.fullName ];
            };
          }
        ))
        ((pkgs.formats.yaml { }).generate "hermes-${peer}-mnemosyne-config.yaml" (
          _agents.${peer}.settings.memory.nix-managed-mnemosyne-hermes or { }
        ))
        (pkgs.linkFarm "hermes-${peer}-profiles" (
          map ({ fullName, name, ... }: {
            name = fullName;
            path = "/var/lib/${name}/.hermes";
          }) (builtins.filter (agent: agent.enable && agent.name != "hermes-${peer}") agentFullNames)
        ))
      ]) peerNames;
      peerPlugins = lib.concatMap (peer: _agents.${peer}.extraPlugins) peerNames;
      gatewayClosure = closureStorePaths (
        config.systemd.services."hermes@${name}".path
        ++ config.systemd.services."hermes@${name}".jobScripts
        ++ [
          agentCfg.package
          execStart
          gatewayOwnershipExecStartPre
          resolvConf
          agentConfig
          mnemosyneConfig
          profileFarm
          pkgs.cacert
        ]
        ++ optional cfg.installDefaultSkills installSkillsExecStartPre
        ++ agentCfg.extraPlugins
        ++ peerConfigs
        ++ peerPlugins
      );
      networkClosure = closureStorePaths (
        config.systemd.services."hermes-network@${name}".path
        ++ config.systemd.services."hermes-network@${name}".jobScripts
        ++ [ networkSetup ]
      );
      publicStateClosure = closureStorePaths (
        lib.subtractLists config.systemd.services."hermes-pf@".path
          config.systemd.services."hermes-pf@${name}".path
        ++ config.systemd.services."hermes-pf@${name}".jobScripts
      );
    in
    mkIf (cfg.enable && agentCfg.enable) {
      services = {
        "hermes-network@${name}" = {
          overrideStrategy = "asDropin";
          serviceConfig = {
            BindReadOnlyPaths = [ "/etc/resolv.conf:/run/hermes-host-resolv.conf" ] ++ networkClosure;
            ExecStart = "${lib.getExe networkSetup} setup";
            ExecStopPost = "${lib.getExe networkSetup} cleanup";
          };
        };
        "hermes-pf@${name}" = {
          overrideStrategy = "asDropin";
          serviceConfig.BindReadOnlyPaths = publicStateClosure;
          wantedBy = [ "multi-user.target" ];
        };
        "hermes@${name}" = {
          after = [
            "network-online.target"
            "hermes-network@${name}.service"
          ]
          ++ optional (cfg.mainAgent != name) "hermes@${cfg.mainAgent}.service";
          bindsTo = [
            "network-online.target"
            "hermes-network@${name}.service"
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
            BindReadOnlyPaths = [ "${resolvConf}:/etc/resolv.conf" ] ++ gatewayClosure;
            InaccessiblePaths = nixStoreAliasPaths;
            TemporaryFileSystem = [ "/nix:ro" ];
            ExecStartPre = optional cfg.installDefaultSkills (lib.getExe installSkillsExecStartPre);
            ExecStart = lib.getExe execStart;
          };
          wantedBy = [ "multi-user.target" ];
        };
      };
      tmpfiles.rules =
        let
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
          "L+ ${hermesAgentStatePath}/config.yaml - - - - ${agentConfig}"
          "d ${hermesAgentStatePath}/mnemosyne 2700 - - - -"
          "L+ ${hermesAgentStatePath}/mnemosyne/config.yaml - - - - ${mnemosyneConfig}"
          "L+ ${hermesAgentStatePath}/profiles - - - - ${profileFarm}"
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
      publicStatePath =
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
      publicStateExecStart = pkgs.writeShellApplication {
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
      };
      publicStateTemplateClosure = closureStorePaths (
        config.systemd.services."hermes-pf@".path ++ [ publicStateExecStart ]
      );
    in
    mkIf cfg.enable {
      services = {
        "hermes-network@" = {
          after = [
            "network-online.target"
            "nftables.service"
          ];
          description = "Configure isolated network for Hermes agent %i";
          partOf = [
            "nftables.service"
            "hermes@%i.service"
          ];
          requires = [ "nftables.service" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            AmbientCapabilities = [ ];
            CapabilityBoundingSet = [
              "CAP_NET_ADMIN"
              "CAP_NET_BIND_SERVICE"
              "CAP_SETGID"
              "CAP_SETUID"
              "CAP_SYS_ADMIN"
              "CAP_SYS_PTRACE"
            ];
            InaccessiblePaths = nixStoreAliasPaths;
            NoNewPrivileges = true;
            PrivateDevices = true;
            PrivateIPC = true;
            PrivateNetwork = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
              "AF_NETLINK"
              "AF_UNIX"
            ];
            TemporaryFileSystem = [ "/nix:ro" ];
            TimeoutStartSec = "30s";
            TimeoutStopSec = "15s";
            Type = "oneshot";
            RemainAfterExit = true;
          };
        };
        "hermes-pf@" = {
          after = [ "hermes@%i.service" ];
          description = "Hermes Agent Public State Fixer";
          partOf = [ "hermes@%i.service" ];
          enableDefaultPath = false;
          environment = {
            HERMES_HOME = hermesAgentStateSystemdPath;
            HOME = agentStateSystemdPath;
          };
          path = publicStatePath;
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
            InaccessiblePaths = nixStoreAliasPaths;
            TemporaryFileSystem = [ "/nix:ro" ];
            ExecStart = [ (lib.getExe publicStateExecStart) ];
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
            BindReadOnlyPaths = publicStateTemplateClosure;
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
          after = [
            "network-online.target"
            "hermes-network@%i.service"
          ];
          bindsTo = [
            "network-online.target"
            "hermes-network@%i.service"
          ];
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
          path = hermesRuntimePath;
          serviceConfig = {
            AmbientCapabilities = [ "" ];
            BindPaths = [
              "/dev/kvm"
              sharedStatePath
            ];
            BindReadOnlyPaths = [
              "${lib.getExe' pkgs.bash "sh"}:/bin/sh"
              "${lib.getExe' pkgs.bash "bash"}:/bin/bash"
              "${lib.getExe' pkgs.coreutils "env"}:/usr/bin/env"
              "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt:/etc/ssl/certs/ca-bundle.crt"
              "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt"
            ];
            InaccessiblePaths = nixStoreAliasPaths;
            TemporaryFileSystem = [ "/nix:ro" ];
            CapabilityBoundingSet = [ "" ];
            CoredumpFilter = "0x00";
            DelegateNamespaces = false;
            DeviceAllow = [ "/dev/kvm rw" ];
            DevicePolicy = "closed";
            DynamicUser = true;
            ExecStartPre = [ "+${lib.getExe gatewayOwnershipExecStartPre}" ];
            Group = agentStateSystemdId;

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
            PrivateNetwork = true;
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
              "${agentStateSystemdId}/root/etc"
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
          unitConfig.JoinsNamespaceOf = [ "hermes-network@%i.service" ];
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
      {
        assertion = !cfg.enable || builtins.length activeAgentNames <= 32768;
        message = "services.hermes-agent: at most 32768 active agents can be assigned isolated IPv4 veth subnets";
      }
      {
        assertion = !cfg.enable || activeAgentNames == [ ] || config.networking.firewall.enable;
        message = "services.hermes-agent: the host firewall must be enabled to enforce per-agent network isolation";
      }
      {
        assertion = builtins.length mappedHostPorts == builtins.length (lib.unique mappedHostPorts);
        message = "services.hermes-agent: each host port mapping must use a unique host port";
      }
      {
        assertion = builtins.all (port: port > 1024) mappedHostPorts;
        message = "services.hermes-agent: host port mappings must use unprivileged ports above 1024";
      }
    ];

    networking.nftables.enable = lib.mkIf (cfg.enable && activeAgentNames != [ ]) true;
    networking.firewall.backend = lib.mkIf (cfg.enable && activeAgentNames != [ ]) "nftables";
    networking.firewall.filterForward = lib.mkIf (cfg.enable && activeAgentNames != [ ]) true;
    networking.firewall.extraInputRules = lib.mkIf (
      cfg.enable && activeAgentNames != [ ]
    ) agentFirewallInputRules;
    networking.firewall.extraForwardRules = lib.mkIf (cfg.enable && activeAgentNames != [ ]) (
      lib.mkBefore agentFirewallForwardRules
    );
    networking.nftables.tables."hermes-agent-guard" = lib.mkIf (cfg.enable && activeAgentNames != [ ]) {
      family = "inet";
      content = ''
        chain hermes_agent_input_guard {
          type filter hook input priority -150; policy accept;
          ${agentInputGuardRules}
        }
        chain hermes_agent_forward_guard {
          type filter hook forward priority -150; policy accept;
          ${agentForwardGuardRules}
        }
      '';
    };
    networking.nat = lib.mkIf (cfg.enable && activeAgentNames != [ ]) {
      enable = true;
      enableIPv6 = true;
      internalInterfaces = map (network: network.hostIf) (builtins.attrValues agentNetworks);
    };
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
