{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  addressFilter = pkgs.writeText "hermes-agent-address-filter.py" ''
    import json
    import sys

    def usable(item, family, prefix):
        if item.get("family") != family or item.get("prefixlen") != prefix or item.get("scope") != "global":
            return False
        if set(item.get("flags", [])) & {"tentative", "dadfailed", "deprecated"} or any(item.get(flag) for flag in ("tentative", "dadfailed", "deprecated")):
            return False
        return not any(value is not None and value != "forever" and int(value) <= 0 for value in (item.get("valid_life_time"), item.get("preferred_life_time")))

    if sys.argv[1:] == ["--self-test"]:
        fixture = [
            {"family": "inet6", "prefixlen": 64, "scope": "global", "local": "2001:db8::1"},
            {"family": "inet6", "prefixlen": 64, "scope": "global", "local": "2001:db8::2", "tentative": True},
            {"family": "inet6", "prefixlen": 64, "scope": "global", "local": "2001:db8::3", "dadfailed": True},
            {"family": "inet6", "prefixlen": 64, "scope": "global", "local": "2001:db8::4", "deprecated": True},
            {"family": "inet6", "prefixlen": 64, "scope": "global", "local": "2001:db8::5", "flags": ["tentative"]},
            {"family": "inet6", "prefixlen": 64, "scope": "global", "local": "2001:db8::6", "preferred_life_time": 0},
            {"family": "inet6", "prefixlen": 64, "scope": "global", "local": "2001:db8::7", "valid_life_time": 0},
        ]
        assert [item["local"] for item in fixture if usable(item, "inet6", 64)] == ["2001:db8::1"]
        sys.exit(0)

    expected_family, expected_prefix = sys.argv[1], int(sys.argv[2])
    data = json.load(sys.stdin)
    for link in data:
        for item in link.get("addr_info", []):
            if usable(item, expected_family, expected_prefix):
                print(item["local"])
  '';
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
            TCP/UDP ports forwarded from host loopback to this agent's network namespace.
            Null uses the main-agent dashboard default (127.0.0.1:9119 -> 9119);
            an explicit empty list disables mappings.
          '';
          example = literalExpression "[{ hostPort = 18199; agentPort = 9119; target = \"loopback\"; }]";
          type = types.nullOr (
            types.listOf (
              types.submodule {
                options = {
                  agentPort = mkOption { type = types.port; };
                  hostPort = mkOption { type = types.port; };
                  protocol = mkOption {
                    default = "both";
                    description = "Transport to forward; both TCP and UDP by default.";
                    type = types.enum [
                      "tcp"
                      "udp"
                      "both"
                    ];
                  };
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
        networkAllow = mkOption {
          default = [ ];
          description = ''
            Per-agent permissions for a single host or private destination address.
            Each entry may set protocol (TCP and UDP by default), address (the
            agent's host-side IPv4 and IPv6 addresses by default), and port (any
            port by default). Addresses must be literal IPv4 or IPv6 addresses.
          '';
          example = literalExpression ''
            [ { address = "10.20.0.2"; port = 443; protocol = "tcp"; } ]
          '';
          type = types.listOf (
            types.submodule {
              options = {
                address = mkOption {
                  default = null;
                  type = types.nullOr types.str;
                };
                port = mkOption {
                  default = null;
                  type = types.nullOr (types.addCheck types.port (port: port > 0));
                };
                protocol = mkOption {
                  default = "both";
                  type = types.enum [
                    "tcp"
                    "udp"
                    "both"
                  ];
                };
              };
            }
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
  serviceExecRoots =
    unitName:
    let
      serviceConfigOption = (options.systemd.services.type.getSubOptions [ ]).serviceConfig.type;
      execOptions = [
        "ExecCondition"
        "ExecStartPre"
        "ExecStart"
        "ExecStartPost"
        "ExecReload"
        "ExecReloadPost"
        "ExecStop"
        "ExecStopPost"
      ];
      projectPath =
        path: missing: value:
        if path == [ ] then
          value
        else if !builtins.isAttrs value then
          missing
        else if value ? _type then
          if value._type == "merge" then
            let
              projected = builtins.filter (item: item != null) (
                map (item: projectPath path missing item) value.contents
              );
            in
            if projected == [ ] then missing else lib.mkMerge projected
          else
            let
              projected = projectPath path missing value.content;
            in
            if projected == null then
              missing
            else if value._type == "if" then
              lib.mkIf value.condition projected
            else if value._type == "override" then
              lib.mkOverride value.priority projected
            else if value._type == "order" then
              lib.mkOrder value.priority projected
            else
              null
        else
          let
            key = builtins.head path;
          in
          if builtins.hasAttr key value then projectPath (lib.tail path) missing value.${key} else missing;
      projectExecConfig =
        value:
        if !builtins.isAttrs value then
          value
        else if value ? _type then
          if value._type == "merge" then
            lib.mkMerge (map projectExecConfig value.contents)
          else
            let
              projected = projectExecConfig value.content;
            in
            if value._type == "if" then
              lib.mkIf value.condition projected
            else if value._type == "override" then
              lib.mkOverride value.priority projected
            else if value._type == "order" then
              lib.mkOrder value.priority projected
            else
              value
        else
          builtins.listToAttrs (
            map (name: {
              inherit name;
              value = value.${name};
            }) (builtins.filter (name: builtins.hasAttr name value) execOptions)
          );
      commands = lib.concatMap (
        name:
        let
          definitions = lib.concatMap (
            definition:
            let
              service = projectPath [ unitName ] null definition.value;
              config = if service == null then null else projectPath [ "serviceConfig" ] { } service;
              value = if config == null then null else projectExecConfig config;
            in
            lib.optional (value != null) {
              inherit (definition) file;
              inherit value;
            }
          ) options.systemd.services.definitionsWithLocations;
          merged = lib.modules.mergeDefinitions [
            "systemd"
            "services"
            unitName
            "serviceConfig"
          ] serviceConfigOption definitions;
          serviceConfig = merged.mergedValue or { };
        in
        if !merged.isDefined || !(builtins.hasAttr name serviceConfig) then
          [ ]
        else if builtins.isList serviceConfig.${name} then
          serviceConfig.${name}
        else
          lib.optional (builtins.isString serviceConfig.${name}) serviceConfig.${name}
      ) execOptions;
    in
    lib.concatMap (
      command:
      let
        storeRoot =
          suffix:
          let
            storeName = builtins.match "^([a-zA-Z0-9+._?=-]+).*" suffix;
          in
          if storeName == null then
            null
          else
            "/nix/store/${builtins.substring 0 (builtins.stringLength (builtins.head storeName)) suffix}";
      in
      builtins.filter (path: path != null) (
        map storeRoot (lib.tail (lib.splitString "/nix/store/" command))
      )
    ) commands;
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

  isIPv4Address =
    address:
    let
      octets = lib.splitString "." address;
      validOctet =
        octet:
        let
          matched = builtins.match "^(0|[1-9][0-9]{0,2})$" octet;
        in
        matched != null && builtins.fromJSON octet <= 255;
    in
    builtins.length octets == 4 && builtins.all validOctet octets;
  isIP =
    address:
    isIPv4Address address
    || (
      lib.hasInfix ":" address
      && !lib.hasInfix "/" address
      && (builtins.tryEval (
        let
          parsed = lib.network.ipv6.fromString address;
        in
        parsed.prefixLength == 128 && builtins.stringLength parsed.address > 0
      )).value
    );
  # shortcut: curated special-use prefixes, not every IANA allocation; update before tightening public-like egress policy.
  privateIPv4 = "0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.31.196.0/24, 192.52.193.0/24, 192.88.99.0/24, 192.168.0.0/16, 192.175.48.0/24, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4";
  privateIPv6 = "::/96, ::ffff:0:0/96, 64:ff9b:1::/48, 100::/64, 100:0:0:1::/64, 2001::/32, 2001:2::/48, 2001:10::/28, 2001:db8::/32, 2002::/16, 3fff::/20, 5f00::/16, fc00::/7, fe80::/10, ff00::/8";
  permissionAddresses =
    network: permission:
    if permission.address == null then
      [
        {
          family = 4;
          address = "@${network.host4Set}";
          source = "@${network.peer4Set}";
        }
        {
          family = 6;
          address = "@${network.host6Set}";
          source = "@${network.peer6Set}";
        }
      ]
    else
      [
        {
          family = if isIPv4Address permission.address then 4 else 6;
          inherit (permission) address;
          source =
            if isIPv4Address permission.address then "@${network.peer4Set}" else "@${network.peer6Set}";
        }
      ];
  protocolsFor =
    protocol:
    if protocol == "both" then
      [
        "tcp"
        "udp"
      ]
    else
      [ protocol ];
  permissionRules =
    network: permissions:
    concatStringsSep "\n" (
      lib.concatMap (
        permission:
        lib.concatMap (
          {
            family,
            address,
            source,
          }:
          map (
            protocol:
            ''iifname "${network.hostIf}" ${
              if family == 4 then "ip saddr ${source} ip daddr" else "ip6 saddr ${source} ip6 daddr"
            } ${address} ${
              if permission.port == null then
                "meta l4proto ${protocol}"
              else
                "${protocol} dport ${toString permission.port}"
            } accept''
          ) (protocolsFor permission.protocol)
        ) (permissionAddresses network permission)
      ) permissions
    );
  permissionReplyRules =
    network: permissions:
    concatStringsSep "\n" (
      lib.concatMap (
        permission:
        lib.concatMap (
          {
            family,
            address,
            source,
          }:
          map (
            protocol:
            ''oifname "${network.hostIf}" ${
              if family == 4 then "ip daddr ${source} ip saddr" else "ip6 daddr ${source} ip6 saddr"
            } ${address} ${
              if permission.port == null then
                "meta l4proto ${protocol}"
              else
                "${protocol} sport ${toString permission.port}"
            } ct state established accept''
          ) (protocolsFor permission.protocol)
        ) (permissionAddresses network permission)
      ) permissions
    );
  mappingProtocols = mapping: protocolsFor (mapping.protocol or "both");
  expandMappings =
    mappings:
    lib.concatMap (
      mapping: map (protocol: mapping // { inherit protocol; }) (mappingProtocols mapping)
    ) mappings;
  portMappingsForAgent =
    name:
    let
      configured = cfg.agents.${name}.portMappings;
    in
    if configured == null then
      optional (cfg.mainAgent == name) {
        hostPort = 9119;
        agentPort = 9119;
        protocol = "both";
        target = "loopback";
      }
    else
      configured;

  activePortMappings =
    if cfg.enable then lib.concatMap portMappingsForAgent activeAgentNames else [ ];
  mappedHostPorts = map (mapping: mapping.hostPort) activePortMappings;
  mappedHostReservations = lib.concatMap (
    mapping: map (protocol: "${protocol}:${toString mapping.hostPort}") (mappingProtocols mapping)
  ) activePortMappings;
  configuredNetworkPermissions = lib.concatMap (name: cfg.agents.${name}.networkAllow) (
    builtins.attrNames cfg.agents
  );
  agentNetworks = builtins.listToAttrs (
    lib.imap0 (index: name: {
      inherit name;
      value =
        let
          macHash = builtins.substring 0 10 (builtins.hashString "sha256" name);
        in
        {
          inherit index name;
          hostIf = "ha${toString index}";
          peerIf = "hb${toString index}";
          peerMac = "02:${builtins.substring 0 2 macHash}:${builtins.substring 2 2 macHash}:${builtins.substring 4 2 macHash}:${builtins.substring 6 2 macHash}:${builtins.substring 8 2 macHash}";
          host4Set = "ha${toString index}_host4";
          peer4Set = "ha${toString index}_peer4";
          host6Set = "ha${toString index}_host6";
          peer6Set = "ha${toString index}_peer6";
        };
    }) activeAgentNames
  );
  # The priority -150 guard owns per-agent authorization before these NixOS chain passthroughs.
  agentFirewallInputRules = concatStringsSep "\n" (
    map (network: ''iifname "${network.hostIf}" accept'') (builtins.attrValues agentNetworks)
  );
  tagPolicyRules =
    label: policy:
    concatStringsSep "\n" (
      lib.imap0 (
        index: rule:
        let
          marker = "hermes-policy-${label}-${toString index}-${
            builtins.substring 0 16 (builtins.hashString "sha256" rule)
          }";
        in
        "${rule} comment \"${marker}\""
      ) (builtins.filter (rule: builtins.match "^[ ]*$" rule == null) (lib.splitString "\n" policy))
    );
  agentInputGuardRules = tagPolicyRules "input" ''
    iifname != { ${
      concatStringsSep ", " (map (network: "\"${network.hostIf}\"") (builtins.attrValues agentNetworks))
    } } accept
    ${concatStringsSep "\n" (
      map (network: ''
        iifname "${network.hostIf}" ip6 saddr @${network.peer6Set} icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert } accept
        iifname "${network.hostIf}" ip6 saddr { ::, fe80::/10 } icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert } accept
        iifname "${network.hostIf}" udp sport 68 udp dport 67 accept
        iifname "${network.hostIf}" ip saddr @${network.peer4Set} ip daddr @${network.host4Set} udp dport 53 accept
        iifname "${network.hostIf}" ip saddr @${network.peer4Set} ip daddr @${network.host4Set} tcp dport 53 accept
        iifname "${network.hostIf}" ip6 saddr @${network.peer6Set} ip6 daddr @${network.host6Set} udp dport 53 accept
        iifname "${network.hostIf}" ip6 saddr @${network.peer6Set} ip6 daddr @${network.host6Set} tcp dport 53 accept
        iifname "${network.hostIf}" ip saddr @${network.peer4Set} ct direction reply ct state established accept
        iifname "${network.hostIf}" ip6 saddr @${network.peer6Set} ct direction reply ct state established accept
        ${permissionRules network cfg.agents.${network.name}.networkAllow}
        iifname "${network.hostIf}" drop
      '') (builtins.attrValues agentNetworks)
    )}
  '';
  agentForwardGuardRules = tagPolicyRules "forward" ''
    iifname != { ${
      concatStringsSep ", " (map (network: "\"${network.hostIf}\"") (builtins.attrValues agentNetworks))
    } } oifname != { ${
      concatStringsSep ", " (map (network: "\"${network.hostIf}\"") (builtins.attrValues agentNetworks))
    } } accept
    ${concatStringsSep "\n" (
      map (
        network:
        let
          otherNetworks = builtins.filter (other: other.index != network.index) (
            builtins.attrValues agentNetworks
          );
          peerDrops = concatStringsSep "\n" (
            map (other: ''
              iifname "${network.hostIf}" oifname "${other.hostIf}" drop
              oifname "${network.hostIf}" iifname "${other.hostIf}" drop
            '') otherNetworks
          );
          permissions = cfg.agents.${network.name}.networkAllow;
        in
        ''
          ${peerDrops}
          iifname "${network.hostIf}" ip saddr != @${network.peer4Set} drop
          iifname "${network.hostIf}" ip6 saddr != @${network.peer6Set} drop
          ${permissionRules network permissions}
          iifname "${network.hostIf}" ip saddr @${network.peer4Set} ip daddr { ${privateIPv4} } drop
          iifname "${network.hostIf}" ip6 saddr @${network.peer6Set} ip6 daddr { ${privateIPv6} } drop
          iifname "${network.hostIf}" ip saddr @${network.peer4Set} accept
          iifname "${network.hostIf}" ip6 saddr @${network.peer6Set} accept
          ${permissionReplyRules network permissions}
          oifname "${network.hostIf}" meta l4proto ipv6-icmp ct state related accept
          oifname "${network.hostIf}" ip daddr @${network.peer4Set} ip saddr { ${privateIPv4} } drop
          oifname "${network.hostIf}" ip6 daddr @${network.peer6Set} ip6 saddr { ${privateIPv6} } drop
          oifname "${network.hostIf}" ip daddr @${network.peer4Set} ct state established,related accept
          oifname "${network.hostIf}" ip6 daddr @${network.peer6Set} ct state established,related accept
          oifname "${network.hostIf}" ip daddr @${network.peer4Set} drop
          oifname "${network.hostIf}" ip6 daddr @${network.peer6Set} drop
        ''
      ) (builtins.attrValues agentNetworks)
    )}
  '';
  # The earlier forward guard owns source, destination, peer, and port policy.
  agentFirewallForwardRules = concatStringsSep "\n" (
    map (network: ''iifname "${network.hostIf}" accept'') (builtins.attrValues agentNetworks)
  );
  mkAgentNetworkSetup =
    name: network: portMappings:
    let
      loopbackMappings = lib.unique (
        lib.concatMap (
          mapping:
          map (protocol: {
            inherit protocol;
            inherit (mapping) agentPort;
          }) (mappingProtocols mapping)
        ) (builtins.filter (mapping: mapping.target == "loopback") portMappings)
      );
      namespaceRelayCommands = concatStringsSep "\n" (
        map (
          mapping:
          let
            checkFlags = if mapping.protocol == "tcp" then "-ltn" else "-lun";
            relay =
              if mapping.protocol == "tcp" then
                "TCP4-LISTEN:${toString mapping.agentPort},bind=\"$agent_ip\",reuseaddr,fork TCP4:127.0.0.1:${toString mapping.agentPort}"
              else
                "UDP4-RECVFROM:${toString mapping.agentPort},bind=\"$agent_ip\",fork UDP4-SENDTO:127.0.0.1:${toString mapping.agentPort}";
          in
          ''
            ${lib.getExe' pkgs.util-linux "setpriv"} --no-new-privs --reuid=nobody --regid=nogroup --clear-groups -- \
              ${lib.getExe' pkgs.socat "socat"} \
              ${relay} >/dev/null 2>&1 &
            relay_pid=$!
            relay_pids+=("$relay_pid")
            for _ in {1..50}; do
              if ${lib.getExe' pkgs.iproute2 "ss"} -H ${checkFlags} "sport = :${toString mapping.agentPort}" | grep -Fq "$agent_ip:${toString mapping.agentPort}"; then break; fi
              sleep 0.1
            done
            ${lib.getExe' pkgs.iproute2 "ss"} -H ${checkFlags} "sport = :${toString mapping.agentPort}" | grep -Fq "$agent_ip:${toString mapping.agentPort}" || {
              fail_ready "${mapping.protocol} loopback relay failed to bind namespace port ${toString mapping.agentPort}"
            }
          ''
        ) loopbackMappings
      );
      hostForwardCommands = concatStringsSep "\n" (
        map (
          mapping:
          let
            checkFlags = if mapping.protocol == "tcp" then "-ltn" else "-lun";
            proxy =
              if mapping.protocol == "tcp" then
                "TCP4-LISTEN:${toString mapping.hostPort},bind=127.0.0.1,reuseaddr,fork TCP4:\"$agent_ip\":${toString mapping.agentPort}"
              else
                "UDP4-RECVFROM:${toString mapping.hostPort},bind=127.0.0.1,fork UDP4-SENDTO:\"$agent_ip\":${toString mapping.agentPort}";
          in
          ''
            if host ${lib.getExe' pkgs.iproute2 "ss"} -H ${checkFlags} "sport = :${toString mapping.hostPort}" | grep -q .; then
              fail_ready "Host loopback port ${toString mapping.hostPort} is already in use"
            fi
            ${lib.getExe' pkgs.util-linux "nsenter"} --net=/proc/1/ns/net -- ${lib.getExe' pkgs.util-linux "setpriv"} \
              --no-new-privs --reuid=nobody --regid=nogroup --clear-groups -- \
              ${lib.getExe' pkgs.socat "socat"} \
              ${proxy} >/dev/null &
            proxy_pid=$!
            proxy_pids+=("$proxy_pid")
            for _ in {1..50}; do
              if host ${lib.getExe' pkgs.iproute2 "ss"} -H ${checkFlags} "sport = :${toString mapping.hostPort}" | grep -Fq "127.0.0.1:${toString mapping.hostPort}"; then
                echo "Forwarding host 127.0.0.1:${toString mapping.hostPort} (${mapping.protocol}) to hermes@${name} port ${toString mapping.agentPort}"
                break
              fi
              sleep 0.1
            done
            host ${lib.getExe' pkgs.iproute2 "ss"} -H ${checkFlags} "sport = :${toString mapping.hostPort}" | grep -Fq "127.0.0.1:${toString mapping.hostPort}" || {
              fail_ready "Host loopback ${mapping.protocol} forwarding proxy failed to bind port ${toString mapping.hostPort}"
            }
          ''
        ) (expandMappings portMappings)
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
          nftables
          python3
          systemd
          util-linux
          dnsmasq
          socat
          ;
      };
      text = ''
        host() { ${lib.getExe' pkgs.util-linux "nsenter"} --net=/proc/1/ns/net -- "$@"; }
        host_if=${lib.escapeShellArg network.hostIf}
        peer_if=${lib.escapeShellArg network.peerIf}
        peer_mac=${lib.escapeShellArg network.peerMac}
        alias=${lib.escapeShellArg "hermes-agent-${name}"}
        host4_set=${lib.escapeShellArg network.host4Set}
        peer4_set=${lib.escapeShellArg network.peer4Set}
        host6_set=${lib.escapeShellArg network.host6Set}
        peer6_set=${lib.escapeShellArg network.peer6Set}
        ra_dropin=/run/systemd/network/40-hermes-agent-${toString network.index}.network.d/50-hermes-ipv6-prefix.conf
        runtime_dir=/run/hermes-agent-network-${toString network.index}
        policy_hash=${
          lib.escapeShellArg (
            builtins.hashString "sha256" (
              builtins.toJSON [
                agentInputGuardRules
                agentForwardGuardRules
              ]
            )
          )
        }
        operation=''${1:-setup}

        dns_pid=
        proxy_pids=()
        relay_pids=()
        created_link=0

        read_addresses() {
          local family="$1" device="$2" prefix="$3" output
          if [[ "$device" == "$host_if" ]]; then
            output=$(host ${lib.getExe' pkgs.iproute2 "ip"} -j "$family" address show dev "$device")
          else
            output=$(${lib.getExe' pkgs.iproute2 "ip"} -j "$family" address show dev "$device")
          fi
          ${lib.getExe' pkgs.python3 "python3"} ${addressFilter} \
            "$([[ "$family" == -4 ]] && printf inet || printf inet6)" "$prefix" <<<"$output" | sort -u
        }

        flush_firewall() {
          {
            printf 'flush set inet hermes-agent-guard %s\n' "$host4_set" "$peer4_set" "$host6_set" "$peer6_set"
          } | host ${lib.getExe' pkgs.nftables "nft"} -f - 2>/dev/null || true
        }

        stop_gateway() {
          ${lib.getExe' pkgs.systemd "systemctl"} --no-block stop "hermes@${name}.service" || true
        }

        fail_ready() {
          echo "${name}: $*" >&2
          flush_firewall
          stop_gateway
          ${lib.getExe' pkgs.systemd "systemctl"} --no-block stop "hermes-network@${name}.service" || true
          exit 1
        }

        networkd_reload() {
          ${lib.getExe' pkgs.util-linux "flock"} --exclusive --wait 15 /run/systemd/network/.hermes-networkd.lock \
            ${lib.getExe' pkgs.util-linux "nsenter"} --net=/proc/1/ns/net -- ${lib.getExe' pkgs.systemd "networkctl"} reload
        }

        networkd_reconfigure() {
          # shellcheck disable=SC2016
          ${lib.getExe' pkgs.util-linux "flock"} --exclusive --wait 15 /run/systemd/network/.hermes-networkd.lock \
            ${lib.getExe' pkgs.bash "bash"} -c '
              ${lib.getExe' pkgs.util-linux "nsenter"} --net=/proc/1/ns/net -- ${lib.getExe' pkgs.systemd "networkctl"} reload &&
              ${lib.getExe' pkgs.util-linux "nsenter"} --net=/proc/1/ns/net -- ${lib.getExe' pkgs.systemd "networkctl"} reconfigure "$1"
            ' -- "$host_if"
        }

        verify_guard_chain() {
          local chain="$1" hook="$2" expected="$3" actual
          actual=$(host ${lib.getExe' pkgs.nftables "nft"} list chain inet hermes-agent-guard "$chain") || return
          ${lib.getExe' pkgs.python3 "python3"} -c '
        import difflib, ipaddress, re, sys
        hook, expected = sys.argv[1:]
        actual = sys.stdin.read()
        if not re.search(rf"type filter hook {hook} priority (?:-150|mangle); policy drop;", actual):
            raise SystemExit(f"{hook} guard hook/priority/policy readback mismatch")
        def rules(text, live=False):
            lines = []
            for line in text.splitlines():
                line = line.strip()
                if not line or (live and line.startswith(("table ", "chain ", "type ", "}"))):
                    continue
                marker = line.find("hermes-policy-")
                if marker >= 0:
                    line = line[:line.rfind("comment", 0, marker)].rstrip()
                line = line.replace("meta l4proto tcp", "meta l4proto 6")
                line = line.replace("meta l4proto udp", "meta l4proto 17")
                line = line.replace("meta l4proto ipv6-icmp", "meta l4proto 58")
                def canonicalize_addresses(match):
                    keyword, values = match.groups()
                    networks = [ipaddress.ip_network(value.strip(), strict=False) for value in values.split(",")]
                    return keyword + "{ " + ", ".join(map(str, ipaddress.collapse_addresses(networks))) + " }"
                line = re.sub(r"(ip6? (?:saddr|daddr) )[{]([^}]*)[}]", canonicalize_addresses, line)
                lines.append(" ".join(line.split()))
            return lines
        expected_rules = rules(expected)
        actual_rules = rules(actual, live=True)
        if expected_rules != actual_rules:
            diff = chr(10).join(difflib.unified_diff(expected_rules, actual_rules, fromfile="configured", tofile="live", lineterm=""))
            raise SystemExit(f"{hook} guard policy differs from the current configured rules{chr(10)}{diff}")
        ' "$hook" "$expected" <<<"$actual"
        }

        verify_guard_policy() {
          verify_guard_chain hermes_agent_input_guard input ${lib.escapeShellArg agentInputGuardRules} || return
          verify_guard_chain hermes_agent_forward_guard forward ${lib.escapeShellArg agentForwardGuardRules}
        }

        cleanup() {
          set +e
          flush_firewall

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
          if [[ "$operation" != ready && -e "$ra_dropin" ]]; then
            rm -f -- "$ra_dropin"
            networkd_reload >/dev/null 2>&1 || true
          fi
          if (( created_link )); then
            host ${lib.getExe' pkgs.iproute2 "ip"} link delete dev "$host_if" 2>/dev/null || true
          elif [[ "$operation" != ready ]] && host ${lib.getExe' pkgs.iproute2 "ip"} -details link show dev "$host_if" 2>/dev/null | grep -Fq "alias $alias"; then
            host ${lib.getExe' pkgs.iproute2 "ip"} link delete dev "$host_if" 2>/dev/null || true
          fi
        }
        setup_error() {
          local status=$?
          trap - ERR EXIT
          cleanup
          if [[ "$operation" == ready ]]; then
            ${lib.getExe' pkgs.systemd "systemctl"} --no-block stop "hermes-network@${name}.service" || true
          fi
          exit "$status"
        }

        check_routes() {
          local subnet4="$1" subnet6="$2" routes4 routes6 addresses4 addresses6
          routes4="$(host ${lib.getExe' pkgs.iproute2 "ip"} -4 route show table all)"
          routes6="$(host ${lib.getExe' pkgs.iproute2 "ip"} -6 route show table all)"
          addresses4="$(host ${lib.getExe' pkgs.iproute2 "ip"} -o -4 address show)"
          addresses6="$(host ${lib.getExe' pkgs.iproute2 "ip"} -o -6 address show)"
          ${lib.getExe' pkgs.python3 "python3"} - "$subnet4" "$subnet6" "$host_if" "$routes4" "$routes6" "$addresses4" "$addresses6" <<'PY'
        import ipaddress
        import sys

        subnet4, subnet6, interface, routes4, routes6, addresses4, addresses6 = sys.argv[1:]
        for target, routes, addresses, family, key in (
            (subnet4, routes4, addresses4, 4, "inet"),
            (subnet6, routes6, addresses6, 6, "inet6"),
        ):
            target = ipaddress.ip_network(target)
            for line in routes.splitlines():
                if f"dev {interface}" in line or line.split()[0] == "default":
                    continue
                try:
                    route = ipaddress.ip_network(line.split()[0], strict=False)
                except ValueError:
                    continue
                if route.version == family and route.prefixlen and target.overlaps(route):
                    raise SystemExit(f"Hermes subnet {target} overlaps host route {route}: {line}")
            for line in addresses.splitlines():
                fields = line.split()
                if len(fields) < 4 or fields[1] == interface:
                    continue
                try:
                    address = ipaddress.ip_interface(fields[fields.index(key) + 1])
                except (ValueError, IndexError):
                    continue
                if target.overlaps(address.network):
                    raise SystemExit(f"Hermes subnet {target} overlaps host address {address}: {line}")
        PY
        }

        if [[ "$operation" == cleanup ]]; then
          cleanup
          exit 0
        fi
        if [[ "$operation" == ready ]]; then
          trap cleanup EXIT
          trap 'exit 130' INT
          trap 'exit 143' TERM
          trap setup_error ERR
          for attempt in {1..300}; do
            mapfile -t host4 < <(read_addresses -4 "$host_if" 30)
            mapfile -t peer4 < <(read_addresses -4 "$peer_if" 30)
            mapfile -t host6 < <(read_addresses -6 "$host_if" 64)
            if (( ''${#host4[@]} == 1 && ''${#peer4[@]} == 1 && ''${#host6[@]} > 0 )); then
              host_ip="''${host4[0]}"
              agent_ip="''${peer4[0]}"
              host_ip6="''${host6[0]}"
              prefix6=$(${lib.getExe' pkgs.python3 "python3"} -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]+"/64").network)' "$host_ip6")
              mapfile -t peer6 < <(read_addresses -6 "$peer_if" 64 | ${lib.getExe' pkgs.python3 "python3"} -c 'import ipaddress,sys; n=ipaddress.ip_network(sys.argv[1]); sys.stdout.write("\n".join(a for a in sys.stdin.read().splitlines() if ipaddress.ip_address(a) in n))' "$prefix6")
              if (( attempt % 25 == 0 && ''${#peer6[@]} == 0 )) \
                && ${lib.getExe' pkgs.python3 "python3"} -c 'import json,sys; sys.exit(not any(a.get("dadfailed", False) for l in json.load(sys.stdin) for a in l.get("addr_info", [])))' \
                  <<<"$(${lib.getExe' pkgs.iproute2 "ip"} -j -6 address show dev "$peer_if")"; then
                fail_ready "SLAAC DAD failed on $peer_if"
              fi
              if (( ''${#peer6[@]} > 0 )) \
                && ${lib.getExe' pkgs.iproute2 "ip"} -4 route show default | grep -Fq "via $host_ip dev $peer_if" \
                && ${lib.getExe' pkgs.iproute2 "ip"} -6 route show default | grep -Fq "dev $peer_if"; then
                break
              fi
            fi
            if (( attempt == 300 )); then fail_ready "DHCP/SLAAC readiness timed out on $peer_if"; fi
            sleep 0.1
          done
          subnet4=$(${lib.getExe' pkgs.python3 "python3"} -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]+"/30").network)' "$host_ip")
          check_routes "$subnet4" "$prefix6"
          {
            for set in "$host4_set" "$peer4_set" "$host6_set" "$peer6_set"; do printf 'flush set inet hermes-agent-guard %s\n' "$set"; done
            printf 'add element inet hermes-agent-guard %s { %s }\n' "$host4_set" "$host_ip"
            printf 'add element inet hermes-agent-guard %s { %s }\n' "$peer4_set" "$agent_ip"
            for address in "''${host6[@]}"; do printf 'add element inet hermes-agent-guard %s { %s }\n' "$host6_set" "$address"; done
            for address in "''${peer6[@]}"; do printf 'add element inet hermes-agent-guard %s { %s }\n' "$peer6_set" "$address"; done
          } | host ${lib.getExe' pkgs.nftables "nft"} -f -
          verify_set() {
            local set="$1" expected="$2" actual
            actual=$(host ${lib.getExe' pkgs.nftables "nft"} -n list set inet hermes-agent-guard "$set" | ${lib.getExe' pkgs.python3 "python3"} -c 'import re,sys; s=sys.stdin.read(); m=re.search(r"elements\s*=\s*\{([^}]*)\}",s); print(",".join(sorted(x.strip() for x in m.group(1).split(",") if x.strip())) if m else "")') || return
            [[ "$actual" == "$expected" ]]
          }
          expected_host6=$(printf '%s\n' "''${host6[@]}" | sort -u | paste -sd,)
          expected_peer6=$(printf '%s\n' "''${peer6[@]}" | sort -u | paste -sd,)
          if ! verify_set "$host4_set" "$host_ip" || ! verify_set "$peer4_set" "$agent_ip" \
            || ! verify_set "$host6_set" "$expected_host6" || ! verify_set "$peer6_set" "$expected_peer6"; then
            fail_ready "firewall set readback did not match allocation"
          fi
          verify_guard_policy || fail_ready "current nftables guard policy readback failed"
          install -d -m 0750 "$runtime_dir"
          printf 'nameserver %s\nnameserver %s\noptions attempts:1 timeout:2\n' "$host_ip" "$host_ip6" >"$runtime_dir/resolv.conf.tmp"
          chmod 0644 "$runtime_dir/resolv.conf.tmp"
          mv -f -- "$runtime_dir/resolv.conf.tmp" "$runtime_dir/resolv.conf"
          mapfile -t dns_upstreams < <(awk '$1 == "nameserver" && NF >= 2 { print $2 }' /run/hermes-host-resolv.conf)
          ((''${#dns_upstreams[@]} > 0)) || fail_ready "No host nameservers in /etc/resolv.conf"
          dns_args=()
          for dns_upstream in "''${dns_upstreams[@]}"; do dns_args+=("--server=$dns_upstream"); done
          ${lib.getExe' pkgs.util-linux "nsenter"} --net=/proc/1/ns/net -- ${lib.getExe' pkgs.dnsmasq "dnsmasq"} \
            --no-daemon --no-resolv --no-hosts --bind-dynamic --listen-address="$host_ip" --listen-address="$host_ip6" \
            --user=nobody --group=nogroup --port=53 "''${dns_args[@]}" >/dev/null 2>&1 &
          dns_pid=$!
          ${namespaceRelayCommands}
          ${hostForwardCommands}
          for _ in {1..50}; do
            if host ${lib.getExe' pkgs.iproute2 "ss"} -H -lun 'sport = :53' | grep -Fq "$host_ip:53" \
              && host ${lib.getExe' pkgs.iproute2 "ss"} -H -ltn 'sport = :53' | grep -Fq "$host_ip:53" \
              && host ${lib.getExe' pkgs.iproute2 "ss"} -6 -H -lun 'sport = :53' | grep -Fq "$host_ip6" \
              && host ${lib.getExe' pkgs.iproute2 "ss"} -6 -H -ltn 'sport = :53' | grep -Fq "$host_ip6"; then break; fi
            sleep 0.1
          done
          if ! host ${lib.getExe' pkgs.iproute2 "ss"} -H -lun 'sport = :53' | grep -Fq "$host_ip:53" \
            || ! host ${lib.getExe' pkgs.iproute2 "ss"} -H -ltn 'sport = :53' | grep -Fq "$host_ip:53" \
            || ! host ${lib.getExe' pkgs.iproute2 "ss"} -6 -H -lun 'sport = :53' | grep -Fq "$host_ip6" \
            || ! host ${lib.getExe' pkgs.iproute2 "ss"} -6 -H -ltn 'sport = :53' | grep -Fq "$host_ip6"; then
            fail_ready "DNS listener readiness failed for $host_ip/$host_ip6"
          fi
          generation=$(printf '%s\n' "$host_ip" "$agent_ip" "''${host6[*]}" "''${peer6[*]}" "$policy_hash" | sha256sum | cut -d' ' -f1)
          ${lib.getExe' pkgs.systemd "systemd-notify"} --ready --status="${name} network generation $generation verified"
          echo "${name}: network generation $generation ready on $host_if/$peer_if; DHCPv4, SLAAC, DNS and nftables verified"
          while sleep 1; do
            if ! verify_guard_policy; then
              fail_ready "current nftables guard policy lost; ordinary traffic revoked"
            fi
            mapfile -t current_host4 < <(read_addresses -4 "$host_if" 30)
            mapfile -t current_peer4 < <(read_addresses -4 "$peer_if" 30)
            mapfile -t current_host6 < <(read_addresses -6 "$host_if" 64)
            mapfile -t current_peer6 < <(read_addresses -6 "$peer_if" 64 | ${lib.getExe' pkgs.python3 "python3"} -c 'import ipaddress,sys; n=ipaddress.ip_network(sys.argv[1]); sys.stdout.write("\n".join(a for a in sys.stdin.read().splitlines() if ipaddress.ip_address(a) in n))' "$prefix6")
            if [[ "''${current_host4[*]}" == "''${host4[*]}" && "''${current_peer4[*]}" == "''${peer4[*]}" \
              && "''${current_host6[*]}" == "''${host6[*]}" && "''${current_peer6[*]}" == "''${peer6[*]}" ]] \
              && ${lib.getExe' pkgs.iproute2 "ip"} -4 route show default | grep -Fq "via $host_ip dev $peer_if" \
              && ${lib.getExe' pkgs.iproute2 "ip"} -6 route show default | grep -Fq "dev $peer_if"; then
              :
            else
              fail_ready "DHCP/SLAAC address or route changed; ordinary traffic revoked"
            fi
            if ! verify_set "$host4_set" "$host_ip" || ! verify_set "$peer4_set" "$agent_ip" \
              || ! verify_set "$host6_set" "$expected_host6" || ! verify_set "$peer6_set" "$expected_peer6"; then
              fail_ready "firewall generation lost; ordinary traffic revoked"
            fi
          done
        fi
        [[ "''${1:-setup}" == setup ]] || { echo "usage: $0 [setup|ready|cleanup]" >&2; exit 2; }
        [[ "''${1:-setup}" == setup ]] || { echo "usage: $0 [setup|ready|cleanup]" >&2; exit 2; }
        trap cleanup EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        trap setup_error ERR

        if host ${lib.getExe' pkgs.iproute2 "ip"} link show dev "$host_if" >/dev/null 2>&1 \
          || host ${lib.getExe' pkgs.iproute2 "ip"} link show dev "$peer_if" >/dev/null 2>&1; then
          echo "Refusing to replace an existing Hermes network interface: $host_if/$peer_if" >&2
          exit 1
        fi
        if [[ -e "$ra_dropin" ]]; then
          rm -f -- "$ra_dropin"
          networkd_reload
        fi
        host ${lib.getExe' pkgs.iproute2 "ip"} link add "$host_if" type veth peer name "$peer_if"
        created_link=1
        host ${lib.getExe' pkgs.iproute2 "ip"} link set dev "$host_if" alias "$alias"
        host ${lib.getExe' pkgs.iproute2 "ip"} link set dev "$peer_if" address "$peer_mac"
        host ${lib.getExe' pkgs.iproute2 "ip"} link set dev "$peer_if" netns "$$"
        ${lib.getExe' pkgs.iproute2 "ip"} link set dev lo up
        ${lib.getExe' pkgs.iproute2 "ip"} link set dev "$peer_if" up
        host ${lib.getExe' pkgs.iproute2 "ip"} link set dev "$host_if" up
        host_ip=
        host_ip6=
        for attempt in {1..300}; do
          mapfile -t host4 < <(read_addresses -4 "$host_if" 30)
          mapfile -t host6 < <(read_addresses -6 "$host_if" 64)
          if (( ''${#host4[@]} == 1 && ''${#host6[@]} > 0 )); then host_ip="''${host4[0]}"; host_ip6="''${host6[0]}"; break; fi
          sleep 0.1
        done
        [[ -n "$host_ip" && -n "$host_ip6" ]] || { echo "${name}: networkd did not allocate host veth addresses within 30s" >&2; exit 1; }
        subnet4=$(${lib.getExe' pkgs.python3 "python3"} -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]+"/30").network)' "$host_ip")
        subnet6=$(${lib.getExe' pkgs.python3 "python3"} -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]+"/64").network)' "$host_ip6")
        check_routes "$subnet4" "$subnet6"
        install -d -m 0755 "''${ra_dropin%/*}"
        printf '[IPv6Prefix]\nPrefix=%s\nAddressAutoconfiguration=yes\nOnLink=yes\n' "$subnet6" >"$ra_dropin"
        chmod 0644 "$ra_dropin"
        networkd_reconfigure
        trap - ERR INT TERM EXIT
        echo "${name}: networkd allocated $host_if $host_ip/$subnet4 and $host_ip6/$subnet6; dynamic SLAAC prefix published"
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
      portMappings = portMappingsForAgent name;
      networkSetup = mkAgentNetworkSetup name agentNetwork portMappings;
      dhcpExecStart = pkgs.writeShellApplication {
        name = "hermes-dhcp-${toString agentNetwork.index}";
        runtimeInputs = [ pkgs.dhcpcd ];
        text = ''
          exec ${lib.getExe pkgs.dhcpcd} --nobackground --waitip=4 --timeout=25 \
            --nohook=resolv.conf,hostname,ntp.conf --config=/dev/null ${agentNetwork.peerIf}
        '';
      };
      agentConfig = (pkgs.formats.yaml { }).generate "${agentStateId}-config.yaml" (
        lib.recursiveUpdate agentCfg.settings {
          kanban = {
            agent_profile_name = agentCfg.fullName;
            dispatch_profiles = [ agentCfg.fullName ];
          };
        }
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
          headroom_pid=
          ${lib.optionalString agentCfg.headroomEnable ''
            headroom proxy \
              --port ${toString agentCfg.headroomPort} \
              --memory \
              --learn \
              --code-graph &
            headroom_pid=$!
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
          gateway_pid=$!
          dashboard_pid=
          ${lib.optionalString (cfg.mainAgent == name) ''
            ${
              concatStringsSep " " [
                "hermes"
                "dashboard"
                "--no-open"
              ]
            } &
            dashboard_pid=$!
          ''}
          exited_child=
          if wait -n -p exited_child; then
            child_status=0
          else
            child_status=$?
          fi
          case "$exited_child" in
            "$headroom_pid") child_name="Headroom proxy" ;;
            "$gateway_pid") child_name="Hermes gateway" ;;
            "$dashboard_pid") child_name="Hermes dashboard" ;;
            *) child_name="unknown child" ;;
          esac
          echo "$child_name (pid $exited_child) exited with status $child_status" >&2
          exit "$child_status"
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
        (pkgs.linkFarm "hermes-${peer}-profiles" (
          map ({ fullName, name, ... }: {
            name = fullName;
            path = "/var/lib/${name}/.hermes";
          }) (builtins.filter (agent: agent.enable && agent.name != "hermes-${peer}") agentFullNames)
        ))
      ]) peerNames;
      peerPlugins = lib.concatMap (peer: _agents.${peer}.extraPlugins) peerNames;
      gatewayClosure = closureStorePaths (
        config.systemd.services."hermes@".path
        ++ config.systemd.services."hermes@".jobScripts
        ++ serviceExecRoots "hermes@"
        ++ config.systemd.services."hermes@${name}".path
        ++ config.systemd.services."hermes@${name}".jobScripts
        ++ serviceExecRoots "hermes@${name}"
        ++ [
          agentCfg.package
          execStart
          gatewayOwnershipExecStartPre
          agentConfig
          profileFarm
          pkgs.cacert
        ]
        ++ optional cfg.installDefaultSkills installSkillsExecStartPre
        ++ agentCfg.extraPlugins
        ++ peerConfigs
        ++ peerPlugins
      );
      networkClosure = closureStorePaths (
        config.systemd.services."hermes-network@".path
        ++ config.systemd.services."hermes-network@".jobScripts
        ++ serviceExecRoots "hermes-network@"
        ++ config.systemd.services."hermes-network@${name}".path
        ++ config.systemd.services."hermes-network@${name}".jobScripts
        ++ serviceExecRoots "hermes-network@${name}"
        ++ [ networkSetup ]
      );
      dhcpClosure = closureStorePaths [
        dhcpExecStart
        pkgs.dhcpcd
      ];
      publicStateClosure = closureStorePaths (
        lib.subtractLists config.systemd.services."hermes-pf@".path
          config.systemd.services."hermes-pf@${name}".path
        ++ serviceExecRoots "hermes-pf@${name}"
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
        "hermes-dhcp@${name}" = {
          after = [ "hermes-network@${name}.service" ];
          bindsTo = [ "hermes-network@${name}.service" ];
          overrideStrategy = "asDropin";
          serviceConfig = {
            BindReadOnlyPaths = [ "/dev/null:/etc/dhcpcd.exit-hook" ] ++ dhcpClosure;
            ExecStart = lib.getExe dhcpExecStart;
          };
        };
        "hermes-network-ready@${name}" = {
          overrideStrategy = "asDropin";
          serviceConfig = {
            BindReadOnlyPaths = [ "/etc/resolv.conf:/run/hermes-host-resolv.conf" ] ++ networkClosure;
            ExecStart = "${lib.getExe networkSetup} ready";
            RuntimeDirectory = [ "hermes-agent-network-${toString agentNetwork.index}" ];
            ReadWritePaths = [
              "/run/systemd/network"
              "/run/hermes-agent-network-${toString agentNetwork.index}"
            ];
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
            "hermes-network-ready@${name}.service"
          ]
          ++ optional (cfg.mainAgent != name) "hermes@${cfg.mainAgent}.service";
          bindsTo = [
            "network-online.target"
            "hermes-network@${name}.service"
            "hermes-network-ready@${name}.service"
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
            BindReadOnlyPaths = [
              "/run/hermes-agent-network-${toString agentNetwork.index}/resolv.conf:/etc/resolv.conf"
            ]
            ++ gatewayClosure;
            InaccessiblePaths = nixStoreAliasPaths;
            TemporaryFileSystem = [ "/nix:ro" ];
            ExecStartPre = optional cfg.installDefaultSkills (lib.getExe installSkillsExecStartPre);
            ExecStart = lib.getExe execStart;
          };
          wantedBy = [ "multi-user.target" ];
        };
      };
      tmpfiles.rules = [
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
        config.systemd.services."hermes-pf@".path
        ++ config.systemd.services."hermes-pf@".jobScripts
        ++ serviceExecRoots "hermes-pf@"
        ++ [ publicStateExecStart ]
      );
    in
    mkIf cfg.enable {
      services = {
        "hermes-network@" = {
          after = [
            "network-online.target"
            "nftables.service"
            "systemd-networkd.service"
          ];
          description = "Configure isolated network for Hermes agent %i";
          partOf = [
            "nftables.service"
            "systemd-networkd.service"
            "hermes-network-ready@%i.service"
            "hermes@%i.service"
          ];
          requires = [
            "nftables.service"
            "systemd-networkd.service"
          ];
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
            ReadWritePaths = [ "/run/systemd/network" ];
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
        "hermes-dhcp@" = {
          after = [
            "hermes-network@%i.service"
            "systemd-networkd.service"
          ];
          bindsTo = [ "hermes-network@%i.service" ];
          description = "Acquire the isolated DHCP lease for Hermes agent %i";
          partOf = [
            "nftables.service"
            "systemd-networkd.service"
          ];
          unitConfig.JoinsNamespaceOf = [ "hermes-network@%i.service" ];
          serviceConfig = {
            AmbientCapabilities = [
              "CAP_NET_ADMIN"
              "CAP_NET_BIND_SERVICE"
              "CAP_NET_RAW"
            ];
            CapabilityBoundingSet = [
              "CAP_NET_ADMIN"
              "CAP_NET_BIND_SERVICE"
              "CAP_NET_RAW"
            ];
            NoNewPrivileges = true;
            BindReadOnlyPaths = [ "/dev/null:/etc/dhcpcd.exit-hook" ];
            CoredumpFilter = "0x00";
            DevicePolicy = "closed";
            InaccessiblePaths = nixStoreAliasPaths;
            KeyringMode = "private";
            LockPersonality = true;
            MemoryKSM = true;
            PrivateDevices = true;
            PrivateNetwork = true;
            PrivateMounts = true;
            PrivateTmp = true;
            MountAPIVFS = true;
            ProtectClock = true;
            ProtectControlGroups = "strict";
            ProtectHome = true;
            ProtectHostname = "private";
            ProtectKernelLogs = true;
            ProtectKernelModules = true;
            ProtectKernelTunables = true;
            ProtectProc = "invisible";
            ProtectSystem = "strict";
            ReadWritePaths = [
              "/run"
              "/var/run"
              "/var/lib/dhcpcd"
            ];
            RootDirectory = "%t/hermes-dhcp-%i/root";
            RuntimeDirectory = [
              "hermes-dhcp-%i"
              "hermes-dhcp-%i/root"
              "hermes-dhcp-%i/root/etc"
              "hermes-dhcp-%i/root/run"
              "hermes-dhcp-%i/root/var"
              "hermes-dhcp-%i/root/var/lib"
              "hermes-dhcp-%i/root/var/lib/dhcpcd"
              "hermes-dhcp-%i/root/var/run"
              "hermes-dhcp-%i/root/var/run/dhcpcd"
            ];
            RuntimeDirectoryMode = "0700";
            RuntimeDirectoryPreserve = false;
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
              "AF_NETLINK"
              "AF_PACKET"
              "AF_UNIX"
            ];
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            RemoveIPC = true;
            SystemCallArchitectures = "native";
            SystemCallErrorNumber = "EPERM";
            SystemCallFilter = [
              "@system-service"
              "~@resources"
              "~@privileged"
            ];
            TemporaryFileSystem = [
              "/nix:ro"
              "/run"
              "/var/run"
              "/var/lib/dhcpcd"
            ];
            TimeoutStartSec = "30s";
            TimeoutStopSec = "15s";
            Type = "exec";
            Restart = "no";
            UMask = "0077";
          };
        };
        "hermes-network-ready@" = {
          after = [
            "hermes-network@%i.service"
            "hermes-dhcp@%i.service"
          ];
          bindsTo = [
            "hermes-network@%i.service"
            "hermes-dhcp@%i.service"
          ];
          description = "Verify DHCP, SLAAC and firewall readiness for Hermes agent %i";
          partOf = [
            "nftables.service"
            "systemd-networkd.service"
            "hermes@%i.service"
          ];
          requires = [
            "hermes-network@%i.service"
            "hermes-dhcp@%i.service"
          ];
          unitConfig.JoinsNamespaceOf = [ "hermes-network@%i.service" ];
          serviceConfig = {
            AmbientCapabilities = [
              "CAP_NET_ADMIN"
              "CAP_NET_BIND_SERVICE"
              "CAP_SETGID"
              "CAP_SETUID"
              "CAP_SYS_ADMIN"
              "CAP_SYS_PTRACE"
            ];
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
            NotifyAccess = "all";
            PrivateDevices = true;
            PrivateIPC = true;
            PrivateNetwork = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            ReadWritePaths = [ "/run/systemd/network" ];
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
              "AF_NETLINK"
              "AF_UNIX"
            ];
            TemporaryFileSystem = [ "/nix:ro" ];
            TimeoutStartSec = "60s";
            TimeoutStopSec = "15s";
            Type = "notify";
            Restart = "no";
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
            "hermes-network-ready@%i.service"
          ];
          bindsTo = [
            "network-online.target"
            "hermes-network@%i.service"
            "hermes-network-ready@%i.service"
          ];
          partOf = [
            "nftables.service"
            "systemd-networkd.service"
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
        assertion =
          builtins.length (map (network: network.peerMac) (builtins.attrValues agentNetworks))
          == builtins.length (
            lib.unique (map (network: network.peerMac) (builtins.attrValues agentNetworks))
          );
        message = "services.hermes-agent: generated DHCP client MAC addresses must be unique";
      }
      {
        assertion = !cfg.enable || activeAgentNames == [ ] || config.networking.firewall.enable;
        message = "services.hermes-agent: the host firewall must be enabled to enforce per-agent network isolation";
      }
      {
        assertion =
          builtins.length mappedHostReservations == builtins.length (lib.unique mappedHostReservations);
        message = "services.hermes-agent: host port mappings may not reserve the same protocol and host port twice";
      }
      {
        assertion = builtins.all (port: port > 1024) mappedHostPorts;
        message = "services.hermes-agent: host port mappings must use unprivileged ports above 1024";
      }
      {
        assertion = builtins.all (
          permission: (permission.address == null || isIP permission.address)
        ) configuredNetworkPermissions;
        message = "services.hermes-agent: network permission addresses must be literal IPv4 or IPv6 addresses";
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
    environment.etc = lib.mkIf (cfg.enable && activeAgentNames != [ ]) (
      lib.mapAttrs' (_: network: {
        name = "systemd/network/40-hermes-agent-${toString network.index}.network";
        value.text = ''
          [Match]
          Name=${network.hostIf}
          Kind=veth

          [Link]
          RequiredForOnline=no

          [Network]
          Address=0.0.0.0/30
          Address=::/64
          DHCPServer=yes
          IPv4Forwarding=yes
          IPv6Forwarding=yes
          IPv6SendRA=yes

          [DHCPServer]
          PersistLeases=runtime
          PoolOffset=2
          PoolSize=1
          Router=_server_address
        '';
      }) agentNetworks
    );
    networking.nftables.tables."hermes-agent-guard" = lib.mkIf (cfg.enable && activeAgentNames != [ ]) {
      family = "inet";
      content = ''
        ${concatStringsSep "\n" (
          lib.concatMap (network: [
            "set ${network.host4Set} { type ipv4_addr; }"
            "set ${network.peer4Set} { type ipv4_addr; }"
            "set ${network.host6Set} { type ipv6_addr; }"
            "set ${network.peer6Set} { type ipv6_addr; }"
          ]) (builtins.attrValues agentNetworks)
        )}
        chain hermes_agent_input_guard {
          type filter hook input priority -150; policy drop;
          ${agentInputGuardRules}
        }
        chain hermes_agent_forward_guard {
          type filter hook forward priority -150; policy drop;
          ${agentForwardGuardRules}
        }
      '';
    };
    networking.dhcpcd.denyInterfaces = lib.mkIf (cfg.enable && activeAgentNames != [ ]) [ "ha*" ];
    networking.networkmanager.unmanaged = lib.mkIf (cfg.enable && activeAgentNames != [ ]) [
      "interface-name:ha*"
    ];
    networking.nat = lib.mkIf (cfg.enable && activeAgentNames != [ ]) {
      enable = true;
      enableIPv6 = true;
      internalInterfaces = map (network: network.hostIf) (builtins.attrValues agentNetworks);
    };
    nix.settings.allowed-users = map (name: "hermes-${name}") (builtins.attrNames cfg.agents);

    systemd = mkMerge (
      [
        {
          tmpfiles.rules = lib.mkIf (cfg.enable && activeAgentNames != [ ]) [
            "d /run/systemd/network 0755 root root - -"
          ];
          additionalUpstreamSystemUnits =
            lib.mkIf (cfg.enable && activeAgentNames != [ ] && !config.systemd.network.enable)
              [
                "systemd-networkd.service"
                "systemd-networkd.socket"
              ];
          sockets.systemd-networkd.wantedBy = lib.mkIf (
            cfg.enable && activeAgentNames != [ ] && !config.systemd.network.enable
          ) [ "sockets.target" ];
          services.systemd-networkd.wantedBy = lib.mkIf (
            cfg.enable && activeAgentNames != [ ] && !config.systemd.network.enable
          ) [ "multi-user.target" ];
        }
      ]
      ++ (mapAttrsToList (mkAgent cfg.agents agentFullNames) cfg.agents)
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
