{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let

  networkRecord = pkgs.writeTextFile {
    name = "hermes-network-record";
    destination = "/network_record.py";
    text = builtins.readFile ./hermes-network/network_record.py;
  };
  networkPython = pkgs.python3.withPackages (p: [ p.dbus-python ]);
  controllerLibrary = pkgs.linkFarm "hermes-controller-lib" [
    {
      name = "setup.py";
      path = ./hermes-network/setup.py;
    }
    {
      name = "systemd_manager.py";
      path = ./hermes-network/systemd_manager.py;
    }
  ];
  pythonCommand =
    script: settings:
    let
      settingsFile = pkgs.writeText "${baseNameOf script}.json" (builtins.toJSON settings);
    in
    "${pkgs.python3}/bin/python3 -I -B ${script} ${settingsFile}";
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
  gatewayOwnershipExecStartPre = "${pkgs.python3}/bin/python3 -I -B ${./hermes-runtime/ownership.py} ${pkgs.coreutils}/bin/chown";

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
  networkdConfigSetTrigger = pkgs.writeText "hermes-networkd-config-set" (
    builtins.toJSON (
      map (
        network:
        let
          file = "systemd/network/40-hermes-agent-${toString network.index}.network";
        in
        if builtins.hasAttr file config.environment.etc then
          config.environment.etc.${file}.source
        else
          "removed:${file}"
      ) (builtins.attrValues agentNetworks)
    )
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
      networkPublication = "/run/hermes-agent-network-${toString agentNetwork.index}";
      observerPublication = "/run/hermes-observation-${name}";
      proxyRoles = [
        "dns"
      ]
      ++ optional (portMappings != [ ]) "host-proxy"
      ++ optional (builtins.any (mapping: mapping.target == "loopback") portMappings) "agent-relay";
      commonSettings = {
        publication = networkPublication;
        observation_path = "${observerPublication}/observation.json";
        interface = agentNetwork.peerIf;
        mac = agentNetwork.peerMac;
      };
      networkCommand =
        role: script: settings:
        let
          settingsFile = pkgs.writeText "hermes-${role}-${name}.json" (builtins.toJSON settings);
        in
        "${
          if role == "host-control" then networkPython else pkgs.python3
        }/bin/python3 -I -B ${script} ${networkRecord} ${settingsFile}";
      hostRecord = networkCommand "host-control" ./hermes-network/host.py (
        commonSettings
        // {
          inherit name;
          controller_library = controllerLibrary;
          ra_dropin = "/run/systemd/network/40-hermes-agent-${toString agentNetwork.index}.network.d/50-hermes-ipv6-prefix.conf";
          policy = builtins.hashString "sha256" (
            builtins.toJSON [
              agentInputGuardRules
              agentForwardGuardRules
            ]
          );
          host_interface = agentNetwork.hostIf;
          proxy_roles = proxyRoles;
          mappings = expandMappings portMappings;
          set_names = [
            agentNetwork.host4Set
            agentNetwork.peer4Set
            agentNetwork.host6Set
            agentNetwork.peer6Set
          ];
          policy_rules = [
            [
              "input"
              agentInputGuardRules
            ]
            [
              "forward"
              agentForwardGuardRules
            ]
          ];
          tools = {
            networkctl = "${pkgs.systemd}/bin/networkctl";
            ip = "${pkgs.iproute2}/bin/ip";
            ss = "${pkgs.iproute2}/bin/ss";
            nft = "${pkgs.nftables}/bin/nft";
          };
        }
      );
      networkFailureStop = "${networkPython}/bin/python3 -I -B ${./hermes-network/stop.py} ${controllerLibrary} ${name}";
      observer = networkCommand "network-observer" ./hermes-network/observer.py (
        commonSettings
        // {
          tools = {
            ip = "${pkgs.iproute2}/bin/ip";
            ss = "${pkgs.iproute2}/bin/ss";
          };
        }
      );
      readiness = networkCommand "network-ready" ./hermes-network/ready.py (
        commonSettings // { publication = networkPublication; }
      );
      proxyProgram =
        role:
        networkCommand role ./hermes-network/proxy.py (
          commonSettings
          // {
            inherit role;
            tools =
              if role == "dns" then
                { dnsmasq = "${pkgs.dnsmasq}/bin/dnsmasq"; }
              else
                { socat = "${pkgs.socat}/bin/socat"; };
          }
          // lib.optionalAttrs (role != "dns") {
            mappings =
              if role == "host-proxy" then
                expandMappings portMappings
              else
                lib.unique (
                  lib.concatMap (
                    mapping:
                    map (protocol: {
                      inherit protocol;
                      inherit (mapping) agentPort;
                    }) (mappingProtocols mapping)
                  ) (builtins.filter (mapping: mapping.target == "loopback") portMappings)
                );
          }
        );
      networkLocalSetup = pythonCommand ./hermes-runtime/local.py {
        interface = agentNetwork.peerIf;
        ip = "${pkgs.iproute2}/bin/ip";
      };
      dhcpExecStart = pythonCommand ./hermes-runtime/dhcp.py {
        interface = agentNetwork.peerIf;
        dhcpcd = lib.getExe pkgs.dhcpcd;
        state = "/var/lib/hermes-dhcp-${name}";
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
      execStart = pythonCommand ./hermes-runtime/gateway.py {
        headroom =
          if agentCfg.headroomEnable then
            [
              "${pkgs.headroom}/bin/headroom"
              "proxy"
              "--port"
              (toString agentCfg.headroomPort)
              "--memory"
              "--learn"
              "--code-graph"
            ]
          else
            null;
        gateway = [
          (lib.getExe agentCfg.package)
          "gateway"
        ]
        ++ agentCfg.extraArgs;
        dashboard =
          if cfg.mainAgent == name then
            [
              (lib.getExe agentCfg.package)
              "dashboard"
              "--no-open"
            ]
          else
            null;
      };
      installSkillsExecStartPre = pythonCommand ./hermes-runtime/install_skills.py {
        hermes = lib.getExe agentCfg.package;
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
          agentConfig
          profileFarm
          pkgs.cacert
        ]
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
      );
      hostControlClosure = closureStorePaths (
        config.systemd.services."hermes-host-control@".path
        ++ config.systemd.services."hermes-host-control@".jobScripts
        ++ serviceExecRoots "hermes-host-control@"
        ++ config.systemd.services."hermes-host-control@${name}".path
        ++ config.systemd.services."hermes-host-control@${name}".jobScripts
        ++ serviceExecRoots "hermes-host-control@${name}"
      );
      networkFailureClosure = closureStorePaths (
        config.systemd.services."hermes-network-failure@".path
        ++ config.systemd.services."hermes-network-failure@".jobScripts
        ++ serviceExecRoots "hermes-network-failure@"
        ++ config.systemd.services."hermes-network-failure@${name}".path
        ++ config.systemd.services."hermes-network-failure@${name}".jobScripts
        ++ serviceExecRoots "hermes-network-failure@${name}"
      );
      netnsClosure = closureStorePaths (
        config.systemd.services."hermes-netns@".path
        ++ config.systemd.services."hermes-netns@".jobScripts
        ++ serviceExecRoots "hermes-netns@"
        ++ config.systemd.services."hermes-netns@${name}".path
        ++ config.systemd.services."hermes-netns@${name}".jobScripts
        ++ serviceExecRoots "hermes-netns@${name}"
      );
      networkReadyClosure = closureStorePaths (
        config.systemd.services."hermes-network-ready@".path
        ++ config.systemd.services."hermes-network-ready@".jobScripts
        ++ serviceExecRoots "hermes-network-ready@"
        ++ config.systemd.services."hermes-network-ready@${name}".path
        ++ config.systemd.services."hermes-network-ready@${name}".jobScripts
        ++ serviceExecRoots "hermes-network-ready@${name}"

      );
      payloadServices = builtins.listToAttrs (
        map (
          role:
          let
            unit = "hermes-${role}@${name}";
            program = if role == "network-observer" then observer else proxyProgram role;
            needsBind =
              role == "dns"
              || (
                role == "agent-relay"
                && builtins.any (mapping: mapping.target == "loopback" && mapping.agentPort < 1024) portMappings
              )
              || (role == "host-proxy" && builtins.any (mapping: mapping.hostPort < 1024) portMappings);
            closure = closureStorePaths (
              config.systemd.services."hermes-${role}@".path
              ++ config.systemd.services."hermes-${role}@".jobScripts
              ++ serviceExecRoots "hermes-${role}@"
              ++ config.systemd.services.${unit}.path
              ++ config.systemd.services.${unit}.jobScripts
              ++ serviceExecRoots unit

            );
          in
          {
            name = unit;
            value = {
              overrideStrategy = "asDropin";
              serviceConfig = {
                BindReadOnlyPaths = [
                  networkPublication
                ]
                ++ optional (role != "network-observer" && role != "dns") "-${observerPublication}"
                ++ closure;
                ExecStart = program;
                CapabilityBoundingSet = lib.mkForce (if needsBind then [ "CAP_NET_BIND_SERVICE" ] else "");
                AmbientCapabilities = lib.mkForce (if needsBind then [ "CAP_NET_BIND_SERVICE" ] else "");
              }
              // lib.optionalAttrs (role == "network-observer") {
                RuntimeDirectory = [ "hermes-observation-${name}" ];
              };
            };
          }
        ) ([ "network-observer" ] ++ proxyRoles)
      );
      dhcpClosure = closureStorePaths (
        config.systemd.services."hermes-dhcp@".path
        ++ config.systemd.services."hermes-dhcp@".jobScripts
        ++ serviceExecRoots "hermes-dhcp@"
        ++ config.systemd.services."hermes-dhcp@${name}".path
        ++ config.systemd.services."hermes-dhcp@${name}".jobScripts
        ++ serviceExecRoots "hermes-dhcp@${name}"
        ++ [ pkgs.dhcpcd ]
      );
      publicStateClosure = closureStorePaths (
        lib.subtractLists config.systemd.services."hermes-pf@".path
          config.systemd.services."hermes-pf@${name}".path
        ++ serviceExecRoots "hermes-pf@${name}"
        ++ config.systemd.services."hermes-pf@${name}".jobScripts
      );
    in
    mkIf (cfg.enable && agentCfg.enable) {
      services = payloadServices // {
        "hermes-netns@${name}" = {
          overrideStrategy = "asDropin";
          serviceConfig = {
            BindReadOnlyPaths = netnsClosure;
            RuntimeDirectory = [ "hermes-agent-network-${toString agentNetwork.index}::ro" ];
          };
        };
        "hermes-host-control@${name}" = {
          overrideStrategy = "asDropin";
          serviceConfig = {
            BindPaths = [ networkPublication ];
            BindReadOnlyPaths = [ "-${observerPublication}" ] ++ hostControlClosure;
            ExecStart = "${hostRecord} host-setup";
            ExecStopPost = "${hostRecord} host-cleanup";
          };
        };
        "hermes-network-failure@${name}" = {
          overrideStrategy = "asDropin";
          serviceConfig = {
            BindReadOnlyPaths = networkFailureClosure;
            ExecStart = networkFailureStop;
          };
        };
        "hermes-network@${name}" = {
          overrideStrategy = "asDropin";
          serviceConfig = {
            BindReadOnlyPaths = networkClosure;
            ExecStart = networkLocalSetup;
          };
        };
        "hermes-dhcp@${name}" = {
          after = [ "hermes-network@${name}.service" ];
          bindsTo = [ "hermes-network@${name}.service" ];
          overrideStrategy = "asDropin";
          serviceConfig = {
            BindReadOnlyPaths = dhcpClosure;
            ExecStart = dhcpExecStart;
          };
        };
        "hermes-network-ready@${name}" = {
          after = map (role: "hermes-${role}@${name}.service") ([ "network-observer" ] ++ proxyRoles);
          bindsTo = map (role: "hermes-${role}@${name}.service") ([ "network-observer" ] ++ proxyRoles);
          requires = map (role: "hermes-${role}@${name}.service") ([ "network-observer" ] ++ proxyRoles);
          overrideStrategy = "asDropin";
          serviceConfig = {
            BindReadOnlyPaths = [
              networkPublication
              "-${observerPublication}"
            ]
            ++ networkReadyClosure;
            ExecStart = readiness;
          };
        };
        "hermes-pf@${name}" = {
          overrideStrategy = "asDropin";
          serviceConfig = {
            BindReadOnlyPaths = publicStateClosure;
          };
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
            ExecStartPre = optional cfg.installDefaultSkills installSkillsExecStartPre;
            ExecStart = execStart;
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
      payloadSandbox =
        role:
        {
          AmbientCapabilities = "";
          CapabilityBoundingSet = "";
          RootDirectory = "%t/hermes-${role}-%i/root";
          RuntimeDirectory = [
            "hermes-${role}-%i"
            "hermes-${role}-%i/root"
          ];
          RuntimeDirectoryMode = "0700";
          RuntimeDirectoryPreserve = false;
          InaccessiblePaths = nixStoreAliasPaths;
          KeyringMode = "private";
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          MountAPIVFS = true;
          NoNewPrivileges = true;
          NotifyAccess = "none";
          DevicePolicy = "closed";
          PrivateDevices = true;
          PrivateIPC = true;
          PrivateMounts = true;
          PrivateNetwork = true;
          PrivateTmp = true;
          ProcSubset = "pid";
          ProtectClock = true;
          ProtectControlGroups = "strict";
          ProtectHome = true;
          ProtectSystem = "strict";
          ProtectHostname = "private";
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectProc = "invisible";
          RemoveIPC = true;
          RestrictAddressFamilies = [ ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          SystemCallArchitectures = "native";
          SystemCallErrorNumber = "EPERM";
          SystemCallFilter = [
            "@system-service"
            "~@resources"
            "~@privileged"
          ];
          TemporaryFileSystem = [ "/nix:ro" ];
          TimeoutStartSec = "60s";
          TimeoutStopSec = "15s";
          Type = "exec";
          Restart = "no";
          UMask = "0077";
        }
        //
          lib.optionalAttrs
            (
              !(builtins.elem role [
                "netns"
                "host-control"
                "network-failure"
              ])
            )
            {
              DynamicUser = true;
              User = "hn-${
                {
                  network = "if";
                  dhcp = "dh";
                  network-observer = "ob";
                  network-ready = "rd";
                  dns = "dn";
                  host-proxy = "hp";
                  agent-relay = "ar";
                }
                .${role}
              }-%i";
            };
      agentStateSystemdId = "hermes-%i";
      agentStateSystemdPath = "%S/${agentStateSystemdId}";
      hermesAgentStateSystemdPath = "${agentStateSystemdPath}/.hermes";
      publicStateFixerSystemdId = "hermes-%i-pf";
      skillsLibrary = pkgs.writeTextFile {
        name = "hermes-skills-acl";
        destination = "/skills_acl.py";
        text = builtins.readFile ./hermes-runtime/skills_acl.py;
      };
      grantSkillsAcl = pkgs.writeTextFile {
        name = "grant-skills-acl";
        destination = "/bin/grant-skills-acl";
        executable = true;
        text =
          builtins.replaceStrings
            [ "@python@" "@skills_library@" "@setfacl@" ]
            [ (toString pkgs.python3) (toString skillsLibrary) "${pkgs.acl}/bin/setfacl" ]
            (builtins.readFile ./hermes-runtime/grant_skills_acl.py);
      };
      publicStatePath = [
        pkgs.acl
        pkgs.python3
        pkgs.inotify-tools
        grantSkillsAcl
      ];
      publicStateSettings = pkgs.writeText "hermes-public-state.json" (
        builtins.toJSON {
          setfacl = "${pkgs.acl}/bin/setfacl";
          inotifywait = "${pkgs.inotify-tools}/bin/inotifywait";
        }
      );
      publicStateExecStart = "${pkgs.python3}/bin/python3 -I -B ${./hermes-runtime/public_state.py} ${skillsLibrary} ${publicStateSettings}";
      publicStateTemplateClosure = closureStorePaths (
        config.systemd.services."hermes-pf@".path
        ++ config.systemd.services."hermes-pf@".jobScripts
        ++ serviceExecRoots "hermes-pf@"
      );
    in
    mkIf cfg.enable {
      services =
        (builtins.listToAttrs (
          map
            (role: {
              name = "hermes-${role}@";
              value = {
                description = "Hermes ${role} for agent %i";
                after = [
                  "hermes-netns@%i.service"
                ]
                ++ lib.optionals (role != "network-observer") [
                  "hermes-dhcp@%i.service"
                  "hermes-network-observer@%i.service"
                ];
                bindsTo = [
                  "hermes-netns@%i.service"
                ]
                ++ lib.optionals (role != "network-observer") [
                  "hermes-dhcp@%i.service"
                  "hermes-network-observer@%i.service"
                ];
                requires = [ "hermes-netns@%i.service" ];
                partOf = [ "hermes-network@%i.service" ];
                unitConfig.JoinsNamespaceOf = lib.optionals (role == "network-observer" || role == "agent-relay") [
                  "hermes-netns@%i.service"
                ];
                serviceConfig =
                  payloadSandbox role
                  // {
                    NetworkNamespacePath = if role == "dns" || role == "host-proxy" then "/proc/1/ns/net" else "";
                    RestrictAddressFamilies =
                      if role == "network-observer" then
                        [ "AF_NETLINK" ]
                      else if role == "dns" then
                        [
                          "AF_INET"
                          "AF_INET6"
                          "AF_NETLINK"
                        ]
                      else
                        [ "AF_INET" ];
                  }
                  // lib.optionalAttrs (role == "dns") {
                    CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
                    AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
                  }
                  // lib.optionalAttrs (role == "dns") {
                    BindReadOnlyPaths = [ "/etc/resolv.conf:/run/hermes-host-resolv.conf" ];
                  };
              };
            })
            [
              "network-observer"
              "dns"
              "host-proxy"
              "agent-relay"
            ]
        ))
        // {
          "hermes-netns@" = {
            description = "Private network namespace lifetime for Hermes agent %i";
            partOf = [ "hermes-network@%i.service" ];
            serviceConfig = payloadSandbox "netns" // {
              ExecStart = "${lib.getExe' pkgs.coreutils "sleep"} infinity";
              SystemCallFilter = [
                "@system-service"
                "~@resources"
                "~@privileged"
                "~socket"
              ];
              TimeoutStartSec = "30s";
            };
          };
          "hermes-network@" = {
            description = "Bring up the isolated local link for Hermes agent %i";
            after = [
              "hermes-netns@%i.service"
              "hermes-host-control@%i.service"
            ];
            bindsTo = [
              "hermes-netns@%i.service"
              "hermes-host-control@%i.service"
            ];
            requires = [
              "hermes-netns@%i.service"
              "hermes-host-control@%i.service"
            ];
            partOf = [
              "nftables.service"
              "systemd-networkd.service"
              "hermes-network-ready@%i.service"
              "hermes@%i.service"
            ];
            unitConfig.JoinsNamespaceOf = [ "hermes-netns@%i.service" ];
            serviceConfig = payloadSandbox "network" // {
              CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
              AmbientCapabilities = [ "CAP_NET_ADMIN" ];
              RestrictAddressFamilies = [ "AF_NETLINK" ];
              TimeoutStartSec = "30s";
              Type = "oneshot";
              RemainAfterExit = true;
            };
          };
          "hermes-host-control@" = {
            after = [
              "dbus.service"
              "hermes-netns@%i.service"
              "hermes-network-observer@%i.service"
              "network-online.target"
              "nftables.service"
              "systemd-networkd.service"
            ];
            bindsTo = [
              "dbus.service"
              "hermes-netns@%i.service"
              "hermes-network-observer@%i.service"
            ];
            description = "Configure host veth and networkd for Hermes agent %i";
            partOf = [
              "nftables.service"
              "systemd-networkd.service"
              "hermes-network@%i.service"
            ];
            requires = [
              "dbus.service"
              "hermes-netns@%i.service"
              "hermes-network-observer@%i.service"
              "nftables.service"
              "systemd-networkd.service"
            ];
            wants = [ "network-online.target" ];
            unitConfig.OnFailure = [ "hermes-network-failure@%i.service" ];
            serviceConfig = payloadSandbox "host-control" // {
              NetworkNamespacePath = "/proc/1/ns/net";
              BindPaths = [ "/run/systemd/network" ];
              BindReadOnlyPaths = [
                "${pkgs.writeTextDir ".keep" ""}:/run/systemd/system"
                "/run/dbus/system_bus_socket"
                "/run/systemd/netif/io.systemd.Network"
              ];
              CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
              ReadWritePaths = [ "/run/systemd/network" ];
              RestrictAddressFamilies = [
                "AF_NETLINK"
                "AF_UNIX"
              ];
              TimeoutStartSec = "30s";
              Type = "notify";
              NotifyAccess = "main";
            };
          };
          "hermes-network-failure@" = {
            description = "Stop failed Hermes network namespace for agent %i";
            after = [ "hermes-host-control@%i.service" ];
            enableDefaultPath = false;
            serviceConfig = payloadSandbox "network-failure" // {
              AmbientCapabilities = "";
              BindReadOnlyPaths = [ "/run/dbus/system_bus_socket" ];
              CapabilityBoundingSet = "";
              DynamicUser = false;
              RestrictAddressFamilies = [ "AF_UNIX" ];
              Type = "oneshot";
              User = "root";
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
            serviceConfig = payloadSandbox "dhcp" // {
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
              BindReadOnlyPaths = [ "/dev/null:/etc/dhcpcd.exit-hook" ];
              CoredumpFilter = "0x00";
              StateDirectory = [ "hermes-dhcp-%i" ];
              RuntimeDirectory = [
                "hermes-dhcp-%i/root"
                "hermes-dhcp-%i/root/var/lib"
                "hermes-dhcp-%i/dhcpcd"
              ];
              BindPaths = [
                "%t/hermes-dhcp-%i/dhcpcd:/run/dhcpcd"
                "%t/hermes-dhcp-%i/dhcpcd:/var/run/dhcpcd"
              ];
              # This is /var/lib inside RootDirectory, not the host path.
              ReadWritePaths = [ "+/var/lib" ];
              RestrictAddressFamilies = [
                "AF_INET"
                "AF_INET6"
                "AF_NETLINK"
                "AF_PACKET"
                "AF_UNIX"
              ];
              TemporaryFileSystem = [ "/nix:ro" ];
              TimeoutStartSec = "30s";
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
            unitConfig.JoinsNamespaceOf = [ "hermes-netns@%i.service" ];
            serviceConfig = payloadSandbox "network-ready" // {
              Type = "notify";
              NotifyAccess = "main";
              RestrictAddressFamilies = [ "AF_UNIX" ];
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
              ExecStart = [ publicStateExecStart ];
              Group = sharedStateId;
              KeyringMode = "private";
              LockPersonality = true;
              MemoryDenyWriteExecute = true;
              MountAPIVFS = true;
              NoNewPrivileges = true;
              NotifyAccess = "none";
              PrivateDevices = true;
              PrivateIPC = true;
              PrivateMounts = true;
              PrivateNetwork = true;
              PrivateTmp = true;
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
              # RootDirectory hides the host state tree; the fixer must change gateway ACLs there.
              BindPaths = [ agentStateSystemdPath ];
              RestrictAddressFamilies = [ ];
              RestrictNamespaces = true;
              RestrictRealtime = true;
              RestrictSUIDSGID = true;
              RootDirectory = "%t/hermes-%i-pf/root";
              RuntimeDirectory = [
                "hermes-%i-pf"
                "hermes-%i-pf/root"
                "hermes-%i-pf/root/etc"
              ];
              RuntimeDirectoryMode = "0700";
              RuntimeDirectoryPreserve = false;
              SetLoginEnvironment = false;
              SupplementaryGroups = [ sharedStateId ];
              SystemCallArchitectures = "native";
              SystemCallErrorNumber = "EPERM";
              SystemCallFilter = [
                "@system-service"
                "~@resources"
                "~@privileged"
                "~socket"
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
              ExecStartPre = [ "+${gatewayOwnershipExecStartPre}" ];
              Group = agentStateSystemdId;

              KeyringMode = "private";
              LockPersonality = true;
              MountAPIVFS = true;
              NoNewPrivileges = true;
              NotifyAccess = "none";
              PrivateDevices = true;
              PrivateIPC = true;
              PrivateMounts = true;
              PrivateNetwork = true;
              PrivateTmp = true;
              PrivateUsers = "identity";
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
              RemoveIPC = true;
              Restart = "always";
              TimeoutStartSec = "180s";
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
      {
        assertion = !(cfg.enable && activeAgentNames != [ ]) || config.services.dbus.enable;
        message = "Hermes host control requires the host system D-Bus service; explicit services.dbus.enable=false is incompatible";
      }
    ];

    services.dbus.enable = lib.mkIf (cfg.enable && activeAgentNames != [ ]) (lib.mkDefault true);
    networking.nftables.enable = lib.mkIf (cfg.enable && activeAgentNames != [ ]) true;
    networking.firewall.backend = lib.mkIf (cfg.enable && activeAgentNames != [ ]) "nftables";
    networking.firewall.filterForward = lib.mkIf (cfg.enable && activeAgentNames != [ ]) true;
    networking.firewall.extraInputRules = lib.mkIf (
      cfg.enable && activeAgentNames != [ ]
    ) agentFirewallInputRules;
    networking.firewall.extraForwardRules = lib.mkIf (cfg.enable && activeAgentNames != [ ]) (
      lib.mkBefore agentFirewallForwardRules
    );
    services.resolved.enable = lib.mkIf (
      cfg.enable && activeAgentNames != [ ] && !config.networking.useNetworkd
    ) (lib.mkOverride 999 false);
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
          network.enable = lib.mkIf (cfg.enable && activeAgentNames != [ ]) true;
          network.wait-online.enable = lib.mkIf (cfg.enable && activeAgentNames != [ ]) (
            lib.mkDefault config.networking.useNetworkd
          );
          network.networks = lib.mkIf (cfg.enable && activeAgentNames != [ ]) (
            lib.mapAttrs' (_: network: {
              name = "40-hermes-agent-${toString network.index}";
              value = {
                matchConfig = {
                  Name = network.hostIf;
                  Kind = "veth";
                };
                linkConfig.RequiredForOnline = "no";
                networkConfig = {
                  Address = [
                    "0.0.0.0/30"
                    "::/64"
                  ];
                  DHCPServer = true;
                  IPv4Forwarding = true;
                  IPv6Forwarding = true;
                  IPv6SendRA = true;
                };
                dhcpServerConfig = {
                  PersistLeases = "runtime";
                  PoolOffset = 2;
                  PoolSize = 1;
                };
              };
            }) agentNetworks
          );
          # Keep the membership trigger across agent and module removal while networkd remains enabled.
          services.systemd-networkd.reloadTriggers = lib.mkIf config.systemd.network.enable (
            lib.mkAfter [ networkdConfigSetTrigger ]
          );
          tmpfiles.rules = lib.mkIf (cfg.enable && activeAgentNames != [ ]) [
            "d /run/systemd/network 0755 root root - -"
          ];
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
