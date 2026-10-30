{
  config,
  lib,
  pkgs,
  ...
}:
let
  networkRecordPath =
    let
      closurePaths =
        config.systemd.services."hermes-network-ready@vm".serviceConfig.BindReadOnlyPaths or [ ];
      closureModule = lib.findFirst (path: lib.hasSuffix "-hermes-network-record" path) null closurePaths;
    in
    if closureModule == null then
      ../modules/services/agent/hermes-network/network_record.py
    else
      closureModule;
  hostRecordPath = ../modules/services/agent/hermes-network/host.py;
  vmNetworkRecordTests = ./tests/hermes-network/records.py;
  vmNetworkObserver = ../modules/services/agent/hermes-network/observer.py;
  vmPayloadBoundaryProbe = ./tests/hermes-network/payload_boundary.py;
  vmPayloadHook = role: {
    serviceConfig.ExecStartPost = [ "${pkgs.python3}/bin/python3 ${vmPayloadBoundaryProbe} ${role}" ];
    serviceConfig.BindReadOnlyPaths = lib.optionals (role != "netns") [ "/dev/kvm" ];
  };
  vmNetworkLocalBoundaryProbe = ./tests/hermes-network/local_boundary.py;
  agentAddressFilter = ../modules/services/agent/hermes-network/address_filter.py;
  dashboardHostPort =
    let
      mappings = config.services.hermes-specialised-agent.agents.vm.portMappings;
      dashboardMapping =
        if mappings == null then
          null
        else
          lib.findFirst (mapping: mapping.agentPort == 9119 && mapping.target == "loopback") null mappings;
    in
    if dashboardMapping == null then 9119 else dashboardMapping.hostPort;
  peerHostPorts = lib.unique (
    map (
      mapping: toString mapping.hostPort
    ) config.services.hermes-specialised-agent.agents.vm-peer.portMappings
  );
  vmNetworkProbeServer = ./tests/hermes-network/probe_server.py;
  vmDadInjector = ./tests/hermes-network/inject_dad.py;
  vmNetworkReadinessBarrierProbe = pkgs.writeShellApplication {
    name = "hermes-vm-network-readiness-barrier-probe";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.iproute2
      pkgs.nftables
      pkgs.python3
      pkgs.systemd
      pkgs.util-linux
    ];
    text = ''
      export SYSTEMD_OFFLINE=0
      gateway_start=$(systemctl show --property=ExecMainStartTimestampMonotonic --value hermes@vm.service)
      [[ "$gateway_start" == 0 ]] || exit 0
      for _ in {1..300}; do
        if python3 -c 'import json; d=json.load(open("/run/hermes-observation-vm/observation.json")); assert d["peer4"] and d["peer6"] and d["route4"] and d["route6"] and not d["dadfailed"]' 2>/dev/null; then
          break
        fi
        sleep 0.1
      done
      if ! python3 -c 'import json; d=json.load(open("/run/hermes-observation-vm/observation.json")); assert d["peer4"] and d["peer6"] and d["route4"] and d["route6"] and not d["dadfailed"]'; then
        echo "DHCP/SLAAC were not ready before the test firewall delay" >&2
        exit 1
      fi
      for set in ha0_peer4 ha0_peer6; do
        host_set=$(nft -n list set inet hermes-agent-guard "$set")
        if grep -Eq 'elements[[:space:]]*=[[:space:]]*\{[^}]*[^[:space:]}][^}]*\}' <<< "$host_set"; then
          echo "Firewall set $set was populated before the delayed readiness phase" >&2
          exit 1
        fi
      done
      echo "VM_TEST_DHCP_SLAAC_PRESENT_FIREWALL_UNPUBLISHED"
      sleep 5
      gateway_start=$(systemctl show --property=ExecMainStartTimestampMonotonic --value hermes@vm.service)
      [[ "$gateway_start" == 0 ]] || { echo "Gateway ExecStart ran before firewall publication" >&2; exit 1; }
      echo "VM_TEST_GATEWAY_BLOCKED_DURING_FIREWALL_DELAY"
    '';
  };
  vmNetworkReadinessBarrierClosure =
    let
      closureInfo = pkgs.closureInfo { rootPaths = [ vmNetworkReadinessBarrierProbe ]; };
    in
    lib.filter (path: path != "") (
      lib.splitString "\n" (builtins.readFile "${closureInfo}/store-paths")
    );
  vmGenerationRollbackProbe = pkgs.writeShellApplication {
    name = "hermes-vm-generation-rollback-probe";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.iproute2
      pkgs.nftables
      pkgs.python3
      pkgs.systemd
      pkgs.util-linux
    ];
    text = ''
      previous_system="$HERMES_VM_PREVIOUS_SYSTEM"
      candidate_system=$(readlink -f /run/current-system)
      updated_system="$HERMES_VM_UPDATED_SYSTEM"
      profile=/nix/var/nix/profiles/system
      install -d /nix/var/nix/profiles
      main_sentinel=/var/lib/hermes-vm/.hermes/skills/.generation-rollback-sentinel
      peer_sentinel=/var/lib/hermes-vm-peer/.hermes/skills/.generation-rollback-sentinel
      dhcp_main_sentinel=/var/lib/hermes-dhcp-vm/.generation-rollback-sentinel
      dhcp_peer_sentinel=/var/lib/hermes-dhcp-vm-peer/.generation-rollback-sentinel
      if [[ ! -x "$previous_system/bin/switch-to-configuration" \
        || ! -x "$candidate_system/bin/switch-to-configuration" \
        || ! -x "$updated_system/bin/switch-to-configuration" ]]; then
        previous_switch=missing
        candidate_switch=missing
        updated_switch=missing
        [[ -x "$previous_system/bin/switch-to-configuration" ]] && previous_switch=available
        [[ -x "$candidate_system/bin/switch-to-configuration" ]] && candidate_switch=available
        [[ -x "$updated_system/bin/switch-to-configuration" ]] && updated_switch=available
        echo "Generation closure unavailable: previous=$previous_system ($previous_switch); candidate=$candidate_system ($candidate_switch); updated=$updated_system ($updated_switch)" >&2
        exit 1
      fi
      [[ ! -e "$main_sentinel" && ! -e "$peer_sentinel" \
        && ! -e "$dhcp_main_sentinel" && ! -e "$dhcp_peer_sentinel" ]] || {
        echo "Rollback sentinel already exists" >&2
        exit 1
      }
      for sentinel in "$main_sentinel" "$peer_sentinel" "$dhcp_main_sentinel" "$dhcp_peer_sentinel"; do
        printf 'keep-across-generation-switches\n' >"$sentinel"
      done
      uplink_line=$(ip -o -4 address show scope global | awk '$2 != "ha0" && $2 != "ha1" { print $2, $4; exit }')
      uplink_iface="''${uplink_line%% *}"
      uplink_ipv4_before="''${uplink_line#* }"
      uplink_route_before=$(ip -4 route show table all dev "$uplink_iface")
      [[ -n "$uplink_iface" && -n "$uplink_ipv4_before" ]] || {
        echo "Unrelated uplink is unavailable before generation test: $uplink_line" >&2
        exit 1
      }
      echo "NETWORKD_ACTIVATION_UPLINK device=$uplink_iface ipv4=$uplink_ipv4_before route=$uplink_route_before"
      cleanup() { rm -f -- "$main_sentinel" "$peer_sentinel" "$dhcp_main_sentinel" "$dhcp_peer_sentinel"; }
      trap cleanup EXIT

      mapfile -t candidate_networks < <(python3 - <<'PY'
      import ipaddress, json, subprocess

      for device in ("ha0", "ha1"):
          for family, prefix in ((4, 30), (6, 64)):
              links = json.loads(subprocess.check_output(["ip", "-j", f"-{family}", "address", "show", "dev", device]))
              info = next(
                  address for address in links[0].get("addr_info", [])
                  if address.get("scope") == "global"
                  and address.get("prefixlen") == prefix
                  and not any(address.get(flag) for flag in ("tentative", "dadfailed", "deprecated"))
              )
              interface = ipaddress.ip_interface(f"{info['local']}/{prefix}")
              print(info["local"])
              print(interface.network)
      PY
      )
      candidate_host4="''${candidate_networks[0]}"
      candidate_prefix4="''${candidate_networks[1]}"
      candidate_host6="''${candidate_networks[2]}"
      candidate_prefix6="''${candidate_networks[3]}"
      candidate_peer4="''${candidate_networks[4]}"
      candidate_peer_prefix4="''${candidate_networks[5]}"
      candidate_peer6="''${candidate_networks[6]}"
      candidate_peer_prefix6="''${candidate_networks[7]}"
      [[ -n "$candidate_host4" && -n "$candidate_host6" && -n "$candidate_prefix4" && -n "$candidate_prefix6" \
        && -n "$candidate_peer4" && -n "$candidate_peer6" && -n "$candidate_peer_prefix4" && -n "$candidate_peer_prefix6" ]] || {
        echo "Could not snapshot candidate network allocation before rollback test" >&2
        exit 1
      }

      wait_for_generation() {
        local target="$1"
        for _ in {1..900}; do
          if [[ "$(readlink -f /run/current-system)" == "$target" ]]; then
            if [[ "$target" == "$previous_system" ]]; then
              if systemctl is-active --quiet systemd-networkd.service \
                && ! ip link show dev ha0 >/dev/null 2>&1 \
                && ! ip link show dev ha1 >/dev/null 2>&1 \
                && ! systemctl is-active --quiet hermes@vm.service \
                && ! systemctl is-active --quiet hermes@vm-peer.service; then return 0; fi
            elif systemctl is-active --quiet hermes@vm.service \
              && systemctl is-active --quiet hermes@vm-peer.service \
              && systemctl is-active --quiet hermes-network@vm.service \
              && systemctl is-active --quiet hermes-network@vm-peer.service \
              && systemctl is-active --quiet hermes-network-ready@vm.service \
              && systemctl is-active --quiet hermes-network-ready@vm-peer.service; then
              return 0
            fi
          fi
          sleep 0.2
        done
        echo "NixOS generation $target did not restore agent networking within 180 seconds" >&2
        systemctl status --no-pager --full hermes@vm.service hermes@vm-peer.service \
          hermes-network@vm.service hermes-network@vm-peer.service \
          hermes-network-ready@vm.service hermes-network-ready@vm-peer.service >&2 || true
        return 1
      }

      stop_agent_stack() {
        timeout --kill-after=5s 120 systemctl stop \
          hermes@vm.service hermes@vm-peer.service \
          hermes-pf@vm.service hermes-pf@vm-peer.service \
          hermes-network@vm.service hermes-network@vm-peer.service \
          hermes-dhcp@vm.service hermes-dhcp@vm-peer.service \
          hermes-network-ready@vm.service hermes-network-ready@vm-peer.service \
          hermes-network-observer@vm.service hermes-network-observer@vm-peer.service \
          hermes-dns@vm.service hermes-dns@vm-peer.service \
          hermes-host-proxy@vm.service hermes-host-proxy@vm-peer.service \
          hermes-agent-relay@vm.service hermes-agent-relay@vm-peer.service \
          hermes-host-control@vm.service hermes-host-control@vm-peer.service \
          hermes-network-failure@vm.service hermes-network-failure@vm-peer.service \
          hermes-netns@vm.service hermes-netns@vm-peer.service
      }

      switch_generation() {
        local label="$1" target="$2" link="$profile-$1-link" reload_before reload_after networkd_pid_before networkd_pid_after
        if [[ "$(readlink -f /run/current-system)" != "$previous_system" ]]; then
          stop_agent_stack
        fi
        ln -sfn "$target" "$link"
        ln -sfn "''${link##*/}" "$profile"
        reload_before=$(systemctl show --property=StateChangeTimestampMonotonic --value systemd-networkd.service)
        networkd_pid_before=$(systemctl show --property=MainPID --value systemd-networkd.service)
        echo "Applying NixOS generation $label ($target) without changing the disposable VM bootloader"
        timeout --kill-after=10s 240 "$target/bin/switch-to-configuration" test
        if [[ "$target" != "$previous_system" ]]; then
          timeout 30s systemctl reset-failed
          timeout --kill-after=5s 180 systemctl start hermes@vm.service hermes@vm-peer.service \
            hermes-pf@vm.service hermes-pf@vm-peer.service
        fi
        wait_for_generation "$target"
        reload_after=$(systemctl show --property=StateChangeTimestampMonotonic --value systemd-networkd.service)
        networkd_pid_after=$(systemctl show --property=MainPID --value systemd-networkd.service)
        [[ "$reload_before" =~ ^[0-9]+$ && "$reload_after" =~ ^[0-9]+$ \
          && "$reload_after" -gt "$reload_before" && "$networkd_pid_after" == "$networkd_pid_before" ]] || {
          echo "NixOS activation did not reload (without restarting) systemd-networkd for generation $label: state=$reload_before -> $reload_after pid=$networkd_pid_before -> $networkd_pid_after" >&2
          return 1
        }
        grep -Fxq 'keep-across-generation-switches' "$main_sentinel"
        grep -Fxq 'keep-across-generation-switches' "$peer_sentinel"
        grep -Fxq 'keep-across-generation-switches' "$dhcp_main_sentinel"
        grep -Fxq 'keep-across-generation-switches' "$dhcp_peer_sentinel"
        [[ "$(ip -o -4 address show dev "$uplink_iface" scope global | awk '{print $4}')" == "$uplink_ipv4_before" \
          && "$(ip -4 route show table all dev "$uplink_iface")" == "$uplink_route_before" ]] || {
          echo "Unrelated uplink $uplink_iface changed during generation $label" >&2
          return 1
        }
        echo "Generation $label preserved both gateway and both DHCP state sentinels"
      }

      assert_candidate_ready() {
        local main_pid peer_pid main_start peer_start main_ready peer_ready
        main_pid=$(systemctl show --property=MainPID --value hermes@vm.service)
        peer_pid=$(systemctl show --property=MainPID --value hermes@vm-peer.service)
        main_start=$(systemctl show --property=ExecMainStartTimestampMonotonic --value hermes@vm.service)
        peer_start=$(systemctl show --property=ExecMainStartTimestampMonotonic --value hermes@vm-peer.service)
        main_ready=$(systemctl show --property=ActiveEnterTimestampMonotonic --value hermes-network-ready@vm.service)
        peer_ready=$(systemctl show --property=ActiveEnterTimestampMonotonic --value hermes-network-ready@vm-peer.service)
        [[ "$main_pid" =~ ^[1-9][0-9]*$ && "$peer_pid" =~ ^[1-9][0-9]*$ \
          && "$main_start" =~ ^[0-9]+$ && "$peer_start" =~ ^[0-9]+$ \
          && "$main_ready" =~ ^[0-9]+$ && "$peer_ready" =~ ^[0-9]+$ ]] || {
          echo "Candidate gateway/readiness generation timestamps are missing" >&2
          return 1
        }
        (( main_start >= main_ready && peer_start >= peer_ready )) || {
          echo "Candidate gateway ExecStart preceded its network-ready notification" >&2
          return 1
        }
        [[ -e /etc/systemd/network/40-hermes-agent-0.network \
          && -e /etc/systemd/network/40-hermes-agent-1.network ]] || {
          echo "Candidate NixOS generation did not install both declarative .network files" >&2
          return 1
        }
        echo "Candidate generation restored DHCP/SLAAC/firewall readiness before both gateway starts"
      }

      assert_updated_network_config() {
        grep -Fxq '# Hermes networkd activation change probe' /etc/systemd/network/40-hermes-agent-0.network || {
          echo "Changed NixOS generation did not install the updated .network source" >&2
          return 1
        }
        assert_candidate_ready
        echo "Changed .network source was applied and both gateways restarted behind readiness"
      }

      assert_previous_network_restored() {
        local candidate_firewall
        systemctl is-active --quiet systemd-networkd.service || {
          echo "systemd-networkd stopped in the previous generation" >&2
          return 1
        }
        for iface in ha0 ha1; do
          if ip link show dev "$iface" >/dev/null 2>&1; then
            echo "Previous generation retained Hermes interface $iface" >&2
            return 1
          fi
        done
        [[ ! -e /etc/systemd/network/40-hermes-agent-0.network \
          && ! -e /etc/systemd/network/40-hermes-agent-1.network ]] || {
          echo "Previous generation retained generated Hermes .network files" >&2
          return 1
        }
        for unit in \
          hermes@vm.service hermes@vm-peer.service \
          hermes-network@vm.service hermes-network@vm-peer.service \
          hermes-netns@vm.service hermes-netns@vm-peer.service \
          hermes-host-control@vm.service hermes-host-control@vm-peer.service \
          hermes-network-failure@vm.service hermes-network-failure@vm-peer.service \
          hermes-dhcp@vm.service hermes-dhcp@vm-peer.service \
          hermes-network-ready@vm.service hermes-network-ready@vm-peer.service \
          hermes-network-observer@vm.service hermes-network-observer@vm-peer.service \
          hermes-dns@vm.service hermes-dns@vm-peer.service \
          hermes-host-proxy@vm.service hermes-host-proxy@vm-peer.service \
          hermes-agent-relay@vm.service hermes-agent-relay@vm-peer.service \
          hermes-pf@vm.service hermes-pf@vm-peer.service; do
          if systemctl is-active --quiet "$unit"; then
            echo "Previous generation left Hermes service active: $unit" >&2
            return 1
          fi
        done
        if ip -o address show | grep -Fq "$candidate_host4" || ip -o address show | grep -Fq "$candidate_host6" \
          || ip -o address show | grep -Fq "$candidate_peer4" || ip -o address show | grep -Fq "$candidate_peer6"; then
          echo "Candidate networkd address remained after restoring the previous generation" >&2
          return 1
        fi
        if ip -4 route show table all | grep -Fq "$candidate_prefix4" \
          || ip -4 route show table all | grep -Fq "$candidate_peer_prefix4" \
          || ip -6 route show table all | grep -Fq "$candidate_prefix6" \
          || ip -6 route show table all | grep -Fq "$candidate_peer_prefix6"; then
          echo "Candidate network route remained after restoring the previous generation" >&2
          return 1
        fi
        candidate_firewall=$(nft -n list ruleset)
        for address in "$candidate_host4" "$candidate_peer4" "$candidate_host6" "$candidate_peer6"; do
          if grep -Fq "$address" <<< "$candidate_firewall"; then
            echo "Candidate address $address remained in the firewall ruleset after rollback" >&2
            return 1
          fi
        done
        for dropin in \
          /run/systemd/network/40-hermes-agent-0.network.d/50-hermes-ipv6-prefix.conf \
          /run/systemd/network/40-hermes-agent-1.network.d/50-hermes-ipv6-prefix.conf; do
          [[ ! -e "$dropin" ]] || { echo "Candidate RA drop-in survived rollback: $dropin" >&2; return 1; }
        done
        if systemctl is-active --quiet hermes-dhcp@vm.service \
          || systemctl is-active --quiet hermes-dhcp@vm-peer.service \
          || systemctl is-active --quiet hermes-network-ready@vm.service \
          || systemctl is-active --quiet hermes-network-ready@vm-peer.service; then
          echo "Candidate DHCP/readiness service remained active after rollback" >&2
          return 1
        fi
        if ss -H -lunpt 'sport = :53' | grep -Fq "$candidate_host4:53" \
          || ss -H -lunpt 'sport = :53' | grep -Fq "$candidate_peer4:53" \
          || ss -6 -H -lunpt 'sport = :53' | grep -Fq "$candidate_host6" \
          || ss -6 -H -lunpt 'sport = :53' | grep -Fq "$candidate_peer6"; then
          echo "Candidate DNS listener remained after rollback" >&2
          return 1
        fi
        echo "Previous generation removed Hermes .network files, interfaces, routes, RA drop-ins, DHCP/readiness and DNS listeners"
      }

      switch_generation previous "$previous_system"
      assert_previous_network_restored
      switch_generation candidate "$candidate_system"
      assert_candidate_ready
      switch_generation updated "$updated_system"
      assert_updated_network_config
      switch_generation rollback "$previous_system"
      assert_previous_network_restored
      echo "HERMES_VM_GENERATION_ROLLBACK_PASSED previous -> added -> changed -> rollback; uplink and skill sentinels preserved"
    '';
  };
  vmGenerationRollbackLaunch = pkgs.writeShellApplication {
    name = "hermes-vm-generation-rollback-launch";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      marker=/run/hermes-vm-generation-rollback-launched
      [[ -e "$marker" ]] && exit 0
      touch "$marker"
      exec systemd-run --no-block --collect --unit=hermes-vm-generation-rollback \
        --setenv="HERMES_VM_PREVIOUS_SYSTEM=$HERMES_VM_PREVIOUS_SYSTEM" \
        --setenv="HERMES_VM_UPDATED_SYSTEM=$HERMES_VM_UPDATED_SYSTEM" \
        --property=TimeoutStartSec=2400s --property=SuccessAction=poweroff --property=FailureAction=poweroff \
        --property=StandardOutput=journal+console --property=StandardError=journal+console \
        ${lib.getExe vmGenerationRollbackProbe}
    '';
  };
  vmStoreSentinel = pkgs.writeText "hermes-vm-unrelated-store-sentinel" "Hermes VM unrelated store sentinel\n";
  vmAgentRuntimeSmoke = pkgs.writeShellApplication {
    name = "hermes-module-vm-agent-smoke";
    runtimeInputs = [
      pkgs.gawk
      pkgs.acl
      pkgs.coreutils
      pkgs.curl
      pkgs.dnsutils
      pkgs.dhcpcd
      pkgs.hermes-agent
      pkgs.iproute2
      pkgs.nftables
      pkgs.python3
      pkgs.systemd
      pkgs.tcpdump
      pkgs.util-linux
    ];
    text = ''
      store_sentinel=${vmStoreSentinel}
      store_sentinel_text='Hermes VM unrelated store sentinel'
      store_probe=${lib.getExe' pkgs.coreutils "stat"}
      dhcpcd_exe=${lib.getExe pkgs.dhcpcd}


      units=(
        hermes@vm.service
        hermes@vm-peer.service
        hermes-pf@vm.service
        hermes-pf@vm-peer.service
        hermes-network@vm.service
        hermes-network@vm-peer.service
        hermes-netns@vm.service
        hermes-netns@vm-peer.service
        hermes-host-control@vm.service
        hermes-host-control@vm-peer.service
        hermes-dhcp@vm.service
        hermes-dhcp@vm-peer.service
        hermes-network-ready@vm.service
        hermes-network-ready@vm-peer.service
        hermes-network-observer@vm.service
        hermes-network-observer@vm-peer.service
        hermes-dns@vm.service
        hermes-dns@vm-peer.service
        hermes-host-proxy@vm.service
        hermes-host-proxy@vm-peer.service
        hermes-agent-relay@vm.service
        hermes-agent-relay@vm-peer.service
      )
      agent_units=(hermes@vm.service hermes@vm-peer.service)
      public_state_units=(hermes-pf@vm.service hermes-pf@vm-peer.service)
      host_probe_pid=
      peer_probe_pids=()
      endpoint_pid=
      dhcp_block=0
      dad_netns_fd=
      dad_netns_path=
      dad_peer_if=
      dad_test_address=
      dad_sender_pid=
      dad_sender_log=
      dad_event_observed=0
      dad_namespace_revoked=0
      ipv6_route_pid=
      ipv6_route_gateway=
      startup_phases_reported=0
      root_boundary_marker=/run/hermes-vm-root-boundary-complete
      split_frozen_pid=
      split_override=/run/systemd/system/hermes@vm.service.d/90-vm-slow-stop.conf
      ipv6_readiness_override=/run/systemd/system/hermes-network-ready@vm.service.d/90-ipv6-route-test.conf
      ipv6_route_ra_dropin=/run/systemd/network/40-hermes-agent-0.network.d/99-hermes-vm-disable-ra.conf
      host_vm_ip="" agent_vm_ip="" host_peer_ip="" peer_agent_ip=""
      host_vm_ip6="" agent_vm_ip6="" host_peer_ip6="" peer_agent_ip6=""
      agent_vm_subnet4="" peer_agent_subnet4="" agent_vm_subnet6="" peer_agent_subnet6=""
      dashboard_host_port="$HERMES_VM_DASHBOARD_HOST_PORT"
      read -r -a peer_host_ports <<< "$HERMES_VM_PEER_HOST_PORTS"

      cleanup_dad_fault() {
        [[ -z "$dad_sender_pid" ]] || { kill "$dad_sender_pid" 2>/dev/null || true; wait "$dad_sender_pid" 2>/dev/null || true; }
        [[ -z "$dad_netns_fd" ]] || {
          nsenter --net="$dad_netns_path" -- ip -6 address del "$dad_test_address/64" dev "$dad_peer_if" 2>/dev/null || true
          exec {dad_netns_fd}<&-
        }
        unset dad_sender_pid dad_sender_log dad_netns_fd dad_netns_path dad_peer_if dad_test_address
        dad_event_observed=0 dad_namespace_revoked=0
      }

      disable_test_ipv6_ra() {
        local interface="$1"
        install -d -m 0755 "''${ipv6_route_ra_dropin%/*}"
        # The positional parameters belong to the lock-held inner shell.
        # shellcheck disable=SC2016
        flock -x /run/systemd/network/.hermes-networkd.lock ${pkgs.bash}/bin/bash -c 'set -e; printf "[Network]\nIPv6SendRA=no\n" > "$1"; networkctl reload; networkctl reconfigure "$2"' _ "$ipv6_route_ra_dropin" "$interface"
      }

      restore_test_ipv6_ra() {
        [[ -e "$ipv6_route_ra_dropin" ]] || return 0
        # The positional parameter belongs to the lock-held inner shell.
        # shellcheck disable=SC2016
        flock -x /run/systemd/network/.hermes-networkd.lock ${pkgs.bash}/bin/bash -c 'set -e; rm -f "$1"; networkctl reload' _ "$ipv6_route_ra_dropin"
      }

      cleanup_test_network() {
        if [[ -n "$ipv6_route_pid" && -n "$ipv6_route_gateway" ]]; then
          nsenter --target "$ipv6_route_pid" --net -- ${pkgs.bash}/bin/bash -c 'set -e; printf 1 > /proc/sys/net/ipv6/conf/hb0/accept_ra' 2>/dev/null || true
          nsenter --target "$ipv6_route_pid" --net -- ip -6 route replace default via "$ipv6_route_gateway" dev hb0 2>/dev/null || true
        fi
        unset ipv6_route_pid ipv6_route_gateway
        [[ -z "$split_frozen_pid" ]] || kill -CONT "$split_frozen_pid" 2>/dev/null || true
        if [[ -e "$split_override" ]]; then
          rm -f -- "$split_override"
          systemctl daemon-reload || true
        fi
        if [[ -e "$ipv6_readiness_override" ]]; then
          rm -f -- "$ipv6_readiness_override"
          systemctl daemon-reload || true
        fi
        restore_test_ipv6_ra || true
        remove_host_revocation_rules
        remove_dhcp_block
        cleanup_dad_fault
        [[ -z "$endpoint_pid" ]] || kill "$endpoint_pid" 2>/dev/null || true
        stop_peer_probes
        [[ -z "$host_probe_pid" ]] || kill "$host_probe_pid" 2>/dev/null || true
        ip netns del hermes-vm-endpoint 2>/dev/null || true
        ip link delete dev hda0 2>/dev/null || true
        ip link delete dev he0 2>/dev/null || true
        [[ -z "$agent_vm_subnet4" ]] || ip route del "$agent_vm_subnet4" dev hvm-overlap 2>/dev/null || true
        ip link delete dev hvm-overlap 2>/dev/null || true
      }
      trap cleanup_test_network EXIT
      python3 ${agentAddressFilter} --self-test

      remove_dhcp_block() {
        (( dhcp_block )) || return 0
        nft delete table inet hermes-vm-dhcp-block 2>/dev/null || true
        dhcp_block=0
      }

      remove_host_revocation_rules() {
        local entry family table chain handle
        for entry in "inet hermes-agent-guard hermes_agent_input_guard" "inet nixos-fw input-allow"; do
          read -r family table chain <<< "$entry"
          while handle=$(nft -a list chain "$family" "$table" "$chain" 2>/dev/null | awk '/comment "hermes-vm-host-permission-revocation"/ { print $NF; exit }') && [[ -n "$handle" ]]; do
            nft delete rule "$family" "$table" "$chain" handle "$handle" 2>/dev/null || break
          done
        done
      }

      diagnose() {
        echo "Hermes VM runtime check failed; unit status follows:" >&2
        timeout 15s systemctl status --no-pager --full "''${units[@]}" >&2 || true
        for unit in "''${units[@]}"; do
          timeout 15s journalctl -b -u "$unit" --no-pager -n 80 >&2 || true
        done
        getfacl -p -- /var/lib/hermes-vm /var/lib/hermes-vm/.hermes /var/lib/hermes-vm-peer /var/lib/hermes-vm-peer/.hermes >&2 || true
        ip -o link show >&2 || true
        ip -4 route show table all >&2 || true
        ip -6 route show table all >&2 || true
        ip -j address show dev ha0 >&2 || true
        ip -j address show dev ha1 >&2 || true
        timeout 15s networkctl status --no-pager ha0 ha1 >&2 || true
        timeout 15s journalctl -b -u systemd-networkd.service --no-pager -n 80 >&2 || true
        nft list table ip nixos-nat >&2 || true
        nft list table ip6 nixos-nat >&2 || true
        nft list ruleset >&2 || true
        ss -H -lunpt 'sport = :53' >&2 || true
        cat /etc/resolv.conf >&2 || true
      }

      assert_no_mnemosyne_provisioning() {
        local unit cgroup proc_file pid config
        for unit in "''${agent_units[@]}"; do
          cgroup=$(timeout 5s systemctl show --property=ControlGroup --value "$unit")
          proc_file="/sys/fs/cgroup$cgroup/cgroup.procs"
          [[ -r "$proc_file" ]] || { echo "$unit cgroup process list is unavailable: $proc_file" >&2; return 1; }
          while IFS= read -r pid; do
            if tr '\0' '\n' <"/proc/$pid/environ" | grep -q '^MNEMOSYNE_'; then
              echo "$unit process $pid has a module-injected MNEMOSYNE_ environment variable" >&2
              return 1
            fi
          done <"$proc_file"
        done
        for config in \
          /var/lib/hermes-vm/.hermes/mnemosyne/config.yaml \
          /var/lib/hermes-vm-peer/.hermes/mnemosyne/config.yaml; do
          [[ ! -e "$config" && ! -L "$config" ]] || {
            echo "Fresh VM unexpectedly provisioned Mnemosyne config: $config" >&2
            return 1
          }
        done
        echo "No Mnemosyne environment defaults or generated config in either Hermes service"
      }

      assert_agents_stable() {
        local deadline=$((SECONDS + 10)) unit state substate pid restarts current expected=
        echo "Checking agent stability for 10 seconds"
        while (( SECONDS < deadline )); do
          current=
          for unit in "''${agent_units[@]}"; do
            state=$(timeout 5s systemctl show --property=ActiveState --value "$unit" 2>/dev/null || true)
            substate=$(timeout 5s systemctl show --property=SubState --value "$unit" 2>/dev/null || true)
            pid=$(timeout 5s systemctl show --property=MainPID --value "$unit" 2>/dev/null || true)
            restarts=$(timeout 5s systemctl show --property=NRestarts --value "$unit" 2>/dev/null || true)
            if [[ "$state" != active || "$substate" != running || ! "$pid" =~ ^[1-9][0-9]*$ ]]; then
              echo "$unit is not stably running: $state/$substate pid=$pid" >&2
              return 1
            fi
            current+="$unit:$pid:$restarts "
          done
          if [[ -z "$expected" ]]; then
            expected="$current"
          elif [[ "$current" != "$expected" ]]; then
            echo "Hermes agent PID or restart count changed during stability window: $expected -> $current" >&2
            return 1
          fi
          sleep 1
        done
        echo "Hermes agents stable for 10 seconds: $expected"
      }

      report_startup_phases() {
        local unit network_online_usec network_active_usec main_active_usec peer_start_usec peer_active_usec
        echo "Hermes startup phases (monotonic timestamps in usec; ExecStartPre includes per-command start/stop times):"
        for unit in hermes-network@vm.service "''${agent_units[@]}"; do
          systemctl show --no-pager \
            --property=MainPID \
            --property=NRestarts \
            --property=ExecMainStartTimestampMonotonic \
            --property=ExecMainExitTimestampMonotonic \
            --property=ActiveEnterTimestampMonotonic \
            --property=ExecStartPre \
            "$unit"
        done
        echo "Initial agent readiness guest uptime: $(awk '{print $1}' /proc/uptime) seconds"
        network_online_usec=$(systemctl show --property=ActiveEnterTimestampMonotonic --value network-online.target)
        network_active_usec=$(systemctl show --property=ActiveEnterTimestampMonotonic --value hermes-network@vm.service)
        main_active_usec=$(systemctl show --property=ActiveEnterTimestampMonotonic --value hermes@vm.service)
        peer_start_usec=$(systemctl show --property=ExecMainStartTimestampMonotonic --value hermes@vm-peer.service)
        peer_active_usec=$(systemctl show --property=ActiveEnterTimestampMonotonic --value hermes@vm-peer.service)
        awk -v online="$network_online_usec" -v network="$network_active_usec" -v main="$main_active_usec" -v peer_start="$peer_start_usec" -v peer_active="$peer_active_usec" -v ready="$dashboard_ready_usec" 'BEGIN { printf "Activation timestamps: network-online=%.3fs, agent network ready=%.3fs, main active=%.3fs, dashboard READY=%.3fs\nPeer timing: ExecStart=%.3fs (%.3fs after main active, %+.3fs after dashboard READY); active=%.3fs (%.3fs after main active, %+.3fs after dashboard READY); own activation=%.3fs\n", online/1000000, network/1000000, main/1000000, ready/1000000, peer_start/1000000, (peer_start-main)/1000000, (peer_start-ready)/1000000, peer_active/1000000, (peer_active-main)/1000000, (peer_active-ready)/1000000, (peer_active-peer_start)/1000000 }'
      }

      assert_network_startup_barrier() {
        local app ready ready_time exec_time log
        for app in hermes@vm.service hermes@vm-peer.service; do
          ready="''${app/hermes@/hermes-network-ready@}"
          ready_time=$(systemctl show --property=ActiveEnterTimestampMonotonic --value "$ready")
          exec_time=$(systemctl show --property=ExecMainStartTimestampMonotonic --value "$app")
          if [[ "$ready_time" =~ ^[1-9][0-9]*$ && "$exec_time" =~ ^[1-9][0-9]*$ ]] && (( exec_time > ready_time )); then
            :
          else
            echo "$app ExecStart was not ordered after its verified network readiness notification" >&2
            return 1
          fi
        done
        log=$(journalctl -b -u hermes-vm-before-proxies.service --no-pager -o cat)
        if ! grep -Fq VM_TEST_DHCP_SLAAC_PRESENT_FIREWALL_UNPUBLISHED <<< "$log" \
          || ! grep -Fq VM_TEST_GATEWAY_BLOCKED_DURING_FIREWALL_DELAY <<< "$log"; then
          echo "The DHCP/SLAAC-present firewall-publication delay probe did not run" >&2
          return 1
        fi
        echo "Verified both gateway ExecStart timestamps followed their readiness notifications; DHCP/SLAAC delay saw empty firewall sets and no gateway start"
      }

      check_dashboard_startup() {
        local mode="$1" boundary="$2" record pid first_usec ready_usec first_latency ready_latency boundary_boot
        for _ in {1..150}; do
          record=$(timeout 5s journalctl -b -u hermes@vm.service -u hermes-host-control@vm.service --no-pager -o json | "${lib.getExe' pkgs.python3 "python3"}" -c 'import json,sys; mode=sys.argv[1]; boundary=int(sys.argv[2]); rows=[json.loads(line) for line in sys.stdin if line.strip()]; ready_rows=sorted((row for row in rows if row.get("MESSAGE")=="HERMES_DASHBOARD_READY port=9119"),key=lambda row:int(row["__MONOTONIC_TIMESTAMP"])); ready=ready_rows[0] if mode=="boot" else next(row for row in ready_rows if int(row["__MONOTONIC_TIMESTAMP"])>=boundary); ready_usec=int(ready["__MONOTONIC_TIMESTAMP"]); boundary=min(int(row["__MONOTONIC_TIMESTAMP"]) for row in rows if row.get("MESSAGE","").startswith("Starting Configure host veth and networkd for Hermes agent vm") and int(row["__MONOTONIC_TIMESTAMP"])<=ready_usec) if mode=="boot" else boundary; pid=ready["_PID"]; first=min((row for row in rows if row.get("_PID")==pid and int(row["__MONOTONIC_TIMESTAMP"])>=boundary),key=lambda row:int(row["__MONOTONIC_TIMESTAMP"])); print(boundary,pid,first["__MONOTONIC_TIMESTAMP"],ready["__MONOTONIC_TIMESTAMP"])' "$mode" "$boundary" 2>/dev/null) && break
          sleep 0.1
        done
        [[ -n "$record" ]] || { echo "Could not find a real dashboard PID log and HERMES_DASHBOARD_READY for $mode boundary" >&2; return 1; }
        read -r boundary pid first_usec ready_usec <<< "$record"
        dashboard_ready_usec="$ready_usec"
        boundary_boot=$(awk -v value="$boundary" 'BEGIN { printf "%.3f", value / 1000000 }')
        first_latency=$(awk -v start="$boundary" -v finish="$first_usec" 'BEGIN { printf "%.3f", (finish - start) / 1000000 }')
        ready_latency=$(awk -v start="$boundary" -v finish="$ready_usec" 'BEGIN { printf "%.3f", (finish - start) / 1000000 }')
        echo "Dashboard startup boundary=$mode at guest uptime ''${boundary_boot}s; first real dashboard PID=$pid log at $(awk -v value="$first_usec" 'BEGIN { printf "%.3f", value / 1000000 }')s (''${first_latency}s after boundary); HERMES_DASHBOARD_READY at $(awk -v value="$ready_usec" 'BEGIN { printf "%.3f", value / 1000000 }')s (''${ready_latency}s after boundary)"
        if awk -v value="$first_latency" 'BEGIN { exit !(value > 15) }'; then
          echo "Startup latency requirement MISSED: first real dashboard log exceeds 15 seconds; timing is reported, not used to gate this smoke"
        elif awk -v value="$first_latency" 'BEGIN { exit !(value > 10) }'; then
          echo "Startup latency target missed: first real dashboard log is within the 15-second maximum"
        else
          echo "Startup latency target met: first real dashboard log is within 10 seconds"
        fi
      }

      assert_no_stray_template_instances() {
        local failed
        failed=$(systemctl --failed --no-legend --plain)
        if grep -Fq 'hermes@multi-user.service' <<< "$failed" || grep -Fq 'hermes-network@multi-user.service' <<< "$failed"; then
          echo "Unexpected failed hermes@multi-user or hermes-network@multi-user template instance:" >&2
          grep -F -e 'hermes@multi-user.service' -e 'hermes-network@multi-user.service' <<< "$failed" >&2
          return 1
        fi
        echo "No failed hermes@multi-user.service or hermes-network@multi-user.service instances"
      }

      wait_for_active() {
        local deadline=$((SECONDS + 180)) next_report=$SECONDS ready state unit
        while (( SECONDS < deadline )); do
          ready=1
          for unit in "''${units[@]}"; do
            state=$(timeout 5s systemctl show --property=ActiveState --value "$unit" 2>/dev/null || true)
            if [[ "$state" != active ]]; then
              ready=0
              if (( SECONDS >= next_report )); then
                echo "Waiting for $unit (ActiveState=$state)"
                next_report=$((SECONDS + 10))
              fi
              break
            fi
          done
          if (( ready == 1 )); then
            discover_network_values || return 1
            if (( startup_phases_reported == 0 )); then
              dashboard_ready_usec=0
              check_dashboard_startup boot 0 || return 1
              assert_network_startup_barrier || return 1
              report_startup_phases
              startup_phases_reported=1
              assert_no_stray_template_instances || return 1
              dashboard_http_ok "$dashboard_host_port" 50 || return 1
            fi
            assert_agents_stable
            assert_no_mnemosyne_provisioning || return 1
            if [[ ! -e "$root_boundary_marker" ]]; then
              check_all_store_isolation || return 1
              touch "$root_boundary_marker"
            fi
            return 0
          fi
          sleep 2
        done
        echo "Timed out waiting for Hermes units to become active" >&2
        return 1
      }

      check_profile() {
        local agent="$1" peer_id="$2" peer_display="$3" unit="hermes@$1.service" pid uid gid groups
        echo "Preparing profile access check: $agent -> $peer_id"
        pid=$(timeout 10s systemctl show --property=MainPID --value "$unit")
        [[ "$pid" =~ ^[1-9][0-9]*$ ]]
        uid=$(awk '/^Uid:/ { print $3; exit }' "/proc/$pid/status")
        gid=$(awk '/^Gid:/ { print $3; exit }' "/proc/$pid/status")
        groups=$(awk '/^Groups:/ { $1 = ""; gsub(/[[:space:]]+/, ","); sub(/^,/, ""); print; exit }' "/proc/$pid/status")
        echo "Checking $agent -> $peer_id profile as pid=$pid uid=$uid gid=$gid groups=$groups"
        # shellcheck disable=SC2016
        timeout --kill-after=5s --signal=TERM 30 "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --mount --root --wd -- "${lib.getExe' pkgs.util-linux "setpriv"}" --no-new-privs --bounding-set=-all --inh-caps=-all --ambient-caps=-all --reuid="$uid" --regid="$gid" --groups="$groups" /bin/bash -euc '
            id
            echo "Expected uid:gid:groups=$4:$5:$6; actual=$(id -u):$(id -g):$(id -G)"
            [[ "$(id -u)" == "$4" && "$(id -g)" == "$5" ]] || { echo "Service identity mismatch" >&2; exit 1; }
            for group in ''${6//,/ }; do
              [[ " $(id -G) " == *" $group "* ]] || { echo "Missing supplementary group $group" >&2; exit 1; }
            done
            cap_eff=$(grep "^CapEff:" /proc/self/status) || { echo "Cannot read process capabilities" >&2; exit 1; }
            echo "$cap_eff"
            [[ "''${cap_eff#*:}" =~ ^[[:space:]]*0+[[:space:]]*$ ]]
            profiles="/var/lib/hermes-$1/.hermes/profiles"
            if [[ ! -r "$profiles" || ! -x "$profiles" ]]; then
              echo "Cannot enumerate profile directory: $profiles" >&2
              for path in "/var/lib/hermes-$1" "/var/lib/hermes-$1/.hermes" "$profiles"; do
                "${lib.getExe' pkgs.coreutils "stat"}" -c "%A %u:%g %n" "$path" >&2 || true
              done
              exit 1
            fi
            expected="$2"
            found=
            for profile in "$profiles"/*; do
              if [[ ! -d "$profile" ]]; then
                echo "Profile entry is not traversable as service identity: $profile" >&2
                "${lib.getExe' pkgs.coreutils "stat"}" -c "%A %u:%g %n" "$profile" >&2 || true
                continue
              fi
              name=''${profile##*/}
              printf "Visible profile from %s: %s\\n" "$3" "$name"
              [[ "$name" == "$expected" ]] && found="$profile"
            done
            [[ -n "$found" ]]
            test -r "$found/config.yaml"
            config=$(<"$found/config.yaml")
            [[ "$config" == *agent_profile_name* && "$config" == *"$7"* ]]
            echo "Read peer profile from service namespace: $expected"
          ' -- "$agent" "$peer_id" "$unit" "$uid" "$gid" "$groups" "$peer_display"
      }

      check_profiles_in_service_namespaces() {
        local vm_pid peer_pid vm_netns peer_netns
        local vm_netns_fd peer_netns_fd
        vm_pid=$(service_pid hermes@vm.service)
        peer_pid=$(service_pid hermes@vm-peer.service)
        vm_netns=$(readlink "/proc/$vm_pid/ns/net")
        peer_netns=$(readlink "/proc/$peer_pid/ns/net")
        exec {vm_netns_fd}<"/proc/$vm_pid/ns/net"
        exec {peer_netns_fd}<"/proc/$peer_pid/ns/net"

        echo "Stopping gateways to run profile-list commands within their captured namespaces with lower peak memory"
        stop_peer_probes
        timeout --kill-after=5s 60 systemctl stop hermes@vm.service hermes@vm-peer.service || { diagnose; return 1; }
        assert_network_resources_clean ha0 hermes_agent_0 "''${agent_vm_subnet4}" "''${agent_vm_subnet6}" || return 1
        assert_network_resources_clean ha1 hermes_agent_1 "''${peer_agent_subnet4}" "''${peer_agent_subnet6}" || return 1
        check_profile_list vm hermes-vm-peer "$vm_netns_fd" "$vm_netns" || return 1
        check_profile_list vm-peer hermes-vm "$peer_netns_fd" "$peer_netns" || return 1
        exec {vm_netns_fd}<&-
        exec {peer_netns_fd}<&-
        assert_namespace_released "$vm_netns" || return 1
        assert_namespace_released "$peer_netns" || return 1

        timeout --kill-after=5s 180 systemctl start hermes@vm.service hermes@vm-peer.service hermes-pf@vm.service hermes-pf@vm-peer.service || { diagnose; return 1; }
        if ! wait_for_active; then diagnose; return 1; fi
        assert_distinct_namespaces || return 1
        start_peer_probes hermes@vm.service "''${agent_vm_ip}" "''${agent_vm_ip6}" || return 1
        start_peer_probes hermes@vm-peer.service "''${peer_agent_ip}" "''${peer_agent_ip6}" || return 1
        check_agent_network hermes@vm.service hb0 "''${host_vm_ip}" "''${agent_vm_ip}" "''${peer_agent_ip}" "''${host_vm_ip6}" "''${agent_vm_ip6}" "''${peer_agent_ip6}" || return 1
        check_agent_network hermes@vm-peer.service hb1 "''${host_peer_ip}" "''${peer_agent_ip}" "''${agent_vm_ip}" "''${host_peer_ip6}" "''${peer_agent_ip6}" "''${agent_vm_ip6}" || return 1
        check_dashboard_mapping || return 1
        check_public_state_network hermes-pf@vm.service || return 1
        check_public_state_network hermes-pf@vm-peer.service || return 1
        check_profile vm hermes-vm-peer "hermes-vm-peer" || return 1
        check_profile vm-peer hermes-vm "hermes-vm" || return 1
      }

      run_as_service() {
        local mode="$1" pid="$2" uid gid groups
        shift 2
        uid=$(awk '/^Uid:/ { print $3; exit }' "/proc/$pid/status")
        gid=$(awk '/^Gid:/ { print $3; exit }' "/proc/$pid/status")
        groups=$(awk '/^Groups:/ { $1 = ""; gsub(/[[:space:]]+/, ","); sub(/^,/, ""); print; exit }' "/proc/$pid/status")
        namespaces=(--net)
        if [[ "$mode" == root ]]; then namespaces+=(--mount --root --wd); fi
        timeout --kill-after=2s 15 "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" "''${namespaces[@]}" -- \
          "${lib.getExe' pkgs.util-linux "setpriv"}" --no-new-privs --bounding-set=-all --inh-caps=-all --ambient-caps=-all \
          --reuid="$uid" --regid="$gid" --groups="$groups" "$@"
      }

      check_default_on_features() {
        local pid child cmdline cap headroom_pid="" peer_pid
        local -a children
        pid=$(service_pid hermes@vm.service) || return 1
        peer_pid=$(service_pid hermes@vm-peer.service) || return 1
        read -r -a children <<<"$(<"/proc/$pid/task/$pid/children")"
        for child in "''${children[@]}"; do
          [[ -r "/proc/$child/cmdline" ]] || continue
          cmdline=$(tr '\0' ' ' <"/proc/$child/cmdline")
          if [[ "$cmdline" == *"headroom proxy --port 18080"* ]]; then headroom_pid="$child"; break; fi
        done
        [[ -n "$headroom_pid" ]] || { echo "Default-on Headroom proxy child is not running" >&2; return 1; }
        cap=$(awk '/^CapEff:/ { print $2; exit }' "/proc/$headroom_pid/status")
        [[ "$cap" =~ ^0+$ ]] || { echo "Headroom child has effective capabilities: $cap" >&2; return 1; }
        for agent in vm vm-peer; do
          agent_pid="$pid"
          if [[ "$agent" == vm-peer ]]; then agent_pid="$peer_pid"; fi
          run_as_service root "$agent_pid" "${lib.getExe' pkgs.python3 "python3"}" -c '
        import pathlib, sys
        root = pathlib.Path("/var/lib") / f"hermes-{sys.argv[1]}" / ".hermes/skills"
        skills = (
            "official/creative/concept-diagrams",
            "official/creative/creative-ideation",
            "official/software-development/ast-grep",
            "official/software-development/code-wiki",
            "official/software-development/subagent-driven-development",
        )
        missing = [skill for skill in skills if not (root / skill / "SKILL.md").is_file()]
        assert not missing, missing
        print(f"DEFAULT_SKILLS_INSTALLED={len(skills)}")
          ' "$agent"
        done
        echo "DEFAULT_ON_FEATURES_PASSED headroom-child=$headroom_pid CapEff=0; default skills installed for both agents"
      }

      run_in_saved_namespace() {
        local netns_fd="$1"
        shift
        timeout --kill-after=5s 60 "${lib.getExe' pkgs.util-linux "nsenter"}" \
          --net="/proc/$$/fd/$netns_fd" -- "$@"
      }

      check_profile_list() {
        local agent="$1" peer_id="$2" netns_fd="$3" netns="$4" profiles
        echo "Running hermes profile list for $agent in captured service network namespace $netns (stopped gateway's HOME)"
        profiles=$(HOME="/var/lib/hermes-$agent" run_in_saved_namespace "$netns_fd" hermes profile list 2>&1) || {
          echo "hermes profile list failed in $agent namespace: $profiles" >&2
          return 1
        }
        printf 'Profile list from hermes@%s.service:\n%s\n' "$agent" "$profiles"
        [[ "$profiles" == *default* && "$profiles" == *"$peer_id"* ]] || {
          echo "hermes@''${agent}.service profile list omitted default or peer profile $peer_id" >&2
          return 1
        }
      }

      tcp_connect_host() {
        "${lib.getExe' pkgs.python3 "python3"}" -c 'import socket,sys;s=socket.socket(socket.AF_INET6 if ":" in sys.argv[1] else socket.AF_INET,socket.SOCK_STREAM);s.settimeout(2);s.connect((sys.argv[1],int(sys.argv[2])));s.sendall(b"GET / HTTP/1.0\r\nHost: probe\r\n\r\n");assert b"200 OK" in s.recv(256);s.close()' "$1" "$2"
      }

      tcp_echo_host() {
        "${lib.getExe' pkgs.python3 "python3"}" -c 'import socket,sys;s=socket.create_connection((sys.argv[1],int(sys.argv[2])),timeout=2);s.settimeout(2);s.sendall(b"network-policy-echo");assert s.recv(128)==b"network-policy-echo";s.close()' "$1" "$2"
      }

      tcp_connect_namespace() {
        local pid="$1" address="$2" port="$3"
        "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- \
          "${lib.getExe' pkgs.python3 "python3"}" -c 'import socket,sys;s=socket.socket(socket.AF_INET6 if ":" in sys.argv[1] else socket.AF_INET,socket.SOCK_STREAM);s.settimeout(1);s.connect((sys.argv[1],int(sys.argv[2])));s.close()' "$address" "$port" 2>/dev/null
      }

      tcp_connect_service() {
        local pid="$1" address="$2" port="$3"
        run_as_service net "$pid" "${lib.getExe' pkgs.python3 "python3"}" \
          -c 'import socket,sys;s=socket.socket(socket.AF_INET6 if ":" in sys.argv[1] else socket.AF_INET,socket.SOCK_STREAM);s.settimeout(1);s.connect((sys.argv[1],int(sys.argv[2])));s.close()' "$address" "$port" 2>/dev/null
      }

      udp_probe() {
        "${lib.getExe' pkgs.python3 "python3"}" -c 'import socket,sys;s=socket.socket(socket.AF_INET6 if ":" in sys.argv[1] else socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(1);s.sendto(b"probe",(sys.argv[1],int(sys.argv[2])));data,_=s.recvfrom(128);assert data==b"hermes-network-policy-udp-ok",data' "$1" "$2"
      }

      check_host_initiated_replies() {
        tcp_connect_host "''${peer_agent_ip}" 18084 || { echo "Host-initiated TCP response to peer agent failed" >&2; return 1; }
        tcp_connect_host "''${peer_agent_ip6}" 18085 || { echo "Host-initiated IPv6 TCP response to peer agent failed" >&2; return 1; }
        udp_probe "''${peer_agent_ip}" 18090 || { echo "Host-initiated UDP response to peer agent failed" >&2; return 1; }
        echo "Host-initiated TCP/UDP connections received agent replies"
      }

      udp_probe_namespace() {
        local pid="$1" address="$2" port="$3"
        "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- \
          "${lib.getExe' pkgs.python3 "python3"}" -c 'import socket,sys;s=socket.socket(socket.AF_INET6 if ":" in sys.argv[1] else socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(1);s.sendto(b"probe",(sys.argv[1],int(sys.argv[2])));data,_=s.recvfrom(128);assert data==b"hermes-network-policy-udp-ok",data' "$address" "$port"
      }

      udp_probe_service() {
        local pid="$1" address="$2" port="$3"
        run_as_service net "$pid" "${lib.getExe' pkgs.python3 "python3"}" \
          -c 'import socket,sys;s=socket.socket(socket.AF_INET6 if ":" in sys.argv[1] else socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(1);s.sendto(b"probe",(sys.argv[1],int(sys.argv[2])));data,_=s.recvfrom(128);assert data==b"hermes-network-policy-udp-ok",data' "$address" "$port" 2>/dev/null
      }

      tcp_echo_probe() {
        "${lib.getExe' pkgs.python3 "python3"}" -c 'import socket,sys;s=socket.create_connection((sys.argv[1],int(sys.argv[2])),timeout=2);s.settimeout(2);s.sendall(b"network-policy-echo");assert s.recv(128)==b"network-policy-echo"' "$1" "$2"
      }

      tcp_echo_probe_namespace() {
        local pid="$1" address="$2" port="$3"
        "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- \
          "${lib.getExe' pkgs.python3 "python3"}" -c 'import socket,sys;s=socket.create_connection((sys.argv[1],int(sys.argv[2])),timeout=2);s.settimeout(2);s.sendall(b"network-policy-echo");assert s.recv(128)==b"network-policy-echo"' "$address" "$port"
      }

      tcp_echo_probe_service() {
        local pid="$1" address="$2" port="$3"
        run_as_service net "$pid" "${lib.getExe' pkgs.python3 "python3"}" \
          -c 'import socket,sys;s=socket.create_connection((sys.argv[1],int(sys.argv[2])),timeout=2);s.settimeout(2);s.sendall(b"network-policy-echo");assert s.recv(128)==b"network-policy-echo"' "$address" "$port" 2>/dev/null
      }

      stop_peer_probes() {
        local pid
        for pid in "''${peer_probe_pids[@]}"; do
          kill "$pid" 2>/dev/null || true
          wait "$pid" 2>/dev/null || true
        done
        peer_probe_pids=()
      }

      start_peer_probes() {
        local unit="$1" address4="$2" address6="$3" pid probe_pid probe_log
        pid=$(service_pid "$unit")
        probe_log="/run/hermes-vm-probes-''${unit//[^a-zA-Z0-9]/_}.log"
        echo "Starting peer probe server for $unit in its live network namespace (target PID=$pid, log=$probe_log)"
        "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- \
          "${lib.getExe' pkgs.python3 "python3"}" ${vmNetworkProbeServer} agent "$address4" "$address6" >"$probe_log" 2>&1 &
        peer_probe_pids+=("$!")
        for attempt in {1..120}; do
          if tcp_connect_namespace "$pid" "$address4" 18084 && tcp_connect_namespace "$pid" "$address6" 18085; then
            if [[ "$unit" == hermes@vm-peer.service ]]; then
              if ! tcp_connect_namespace "$pid" "$address4" 18088; then sleep 0.1; continue; fi
              if ! tcp_connect_namespace "$pid" 127.0.0.1 18087; then sleep 0.1; continue; fi
              if ! tcp_connect_namespace "$pid" 127.0.0.1 18089; then sleep 0.1; continue; fi
              if ! udp_probe_namespace "$pid" "$address4" 18086; then sleep 0.1; continue; fi
              if ! udp_probe_namespace "$pid" "$address4" 18088; then sleep 0.1; continue; fi
              if ! tcp_connect_namespace "$pid" "$address4" 18090; then sleep 0.1; continue; fi
              if ! udp_probe_namespace "$pid" "$address4" 18090; then sleep 0.1; continue; fi
              if ! udp_probe_namespace "$pid" 127.0.0.1 18087; then sleep 0.1; continue; fi
              if ! udp_probe_namespace "$pid" 127.0.0.1 18089; then sleep 0.1; continue; fi
            fi
            echo "Live peer TCP targets ready in $unit at $address4:18084 and [$address6]:18085"
            return 0
          fi
          if (( attempt % 5 == 0 )); then echo "Waiting for live peer targets in $unit (attempt $attempt/120)"; fi
          sleep 0.1
        done
        for probe_pid in "''${peer_probe_pids[@]}"; do
          if [[ -r "/proc/$probe_pid/cmdline" ]]; then
            echo "$unit probe launcher PID=$probe_pid cmdline=$(tr '\0' ' ' <"/proc/$probe_pid/cmdline")" >&2
          else
            echo "$unit probe launcher PID=$probe_pid has exited" >&2
          fi
        done
        echo "$unit probe-server log:" >&2
        cat "$probe_log" >&2 || true
        "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- "${lib.getExe' pkgs.iproute2 "ss"}" -H -lntup >&2 || true
        echo "$unit peer TCP targets failed their positive-connect checks" >&2
        return 1
      }

      service_pid() {
        local pid
        pid=$(timeout 10s systemctl show --property=MainPID --value "$1")
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { echo "$1 has no live main PID: $pid" >&2; return 1; }
        printf '%s\n' "$pid"
      }

      expected_root_directory() {
        local unit="$1" instance="''${1#*@}"
        instance="''${instance%.service}"
        case "$unit" in
          hermes@*) printf '/run/hermes-%s/root\n' "$instance" ;;
          hermes-pf@*) printf '/run/hermes-%s-pf/root\n' "$instance" ;;
          hermes-network@*) printf '/run/hermes-network-%s/root\n' "$instance" ;;
          hermes-netns@*) printf '/run/hermes-netns-%s/root\n' "$instance" ;;
          hermes-host-control@*) printf '/run/hermes-host-control-%s/root\n' "$instance" ;;
          hermes-network-observer@*) printf '/run/hermes-network-observer-%s/root\n' "$instance" ;;
          hermes-dns@*) printf '/run/hermes-dns-%s/root\n' "$instance" ;;
          hermes-host-proxy@*) printf '/run/hermes-host-proxy-%s/root\n' "$instance" ;;
          hermes-agent-relay@*) printf '/run/hermes-agent-relay-%s/root\n' "$instance" ;;
          hermes-network-ready@*) printf '/run/hermes-network-ready-%s/root\n' "$instance" ;;
          hermes-dhcp@*) printf '/run/hermes-dhcp-%s/root\n' "$instance" ;;
          *) echo "$unit has no expected private-root mapping" >&2; return 1 ;;
        esac
      }

      check_root_configuration() {
        local unit actual expected
        for unit in "''${units[@]}"; do
          expected=$(expected_root_directory "$unit") || return 1
          actual=$(timeout 10s systemctl show --property=RootDirectory --value "$unit")
          [[ "$actual" == "$expected" ]] || {
            echo "$unit effective RootDirectory is $actual; expected $expected" >&2
            return 1
          }
        done
        echo "All five Hermes service families use their per-instance effective RootDirectory"
      }

      check_instantiated_security() {
        local unit
        journalctl -b --no-pager -o cat --grep='BOUNDARY_PASSED|NETWORK_RECORD_CONTRACT_PASSED'
        systemd-analyze verify "''${units[@]}"
        for unit in "''${units[@]}"; do
          systemd-analyze security --no-pager --json=short "$unit" | "${lib.getExe' pkgs.python3 "python3"}" -c 'import json,sys; rows=json.load(sys.stdin); print("UNIT_SECURITY",sys.argv[1],json.dumps([row for row in rows if row.get("exposure") not in (None,"0.0",0)]))' "$unit"
        done
        for unit in hermes-network-failure@vm.service hermes-network-failure@vm-peer.service; do
          systemd-analyze verify "$unit"
          systemd-analyze security --no-pager --json=short "$unit" | "${lib.getExe' pkgs.python3 "python3"}" -c 'import json,sys; rows=json.load(sys.stdin); print("UNIT_SECURITY",sys.argv[1],json.dumps([row for row in rows if row.get("exposure") not in (None,"0.0",0)]))' "$unit"
        done
        echo "Instantiated-unit systemd-analyze verify/security completed (scores are not enforcement proof)"
      }

      check_helper_mounts() {
        local setup="hermes-host-control@vm.service" ready="hermes-network-ready@vm.service" setup_binds setup_writes ready_binds ready_writes pid mountinfo
        setup_binds=$(systemctl show --property=BindPaths --value "$setup")
        setup_writes=$(systemctl show --property=ReadWritePaths --value "$setup")
        ready_binds=$(systemctl show --property=BindPaths --value "$ready")
        ready_writes=$(systemctl show --property=ReadWritePaths --value "$ready")
        [[ "$setup_binds" == *"/run/systemd/network"* && "$setup_writes" == *"/run/systemd/network"* ]] || {
          echo "$setup does not have the explicit, narrow networkd write mount: $setup_binds / $setup_writes" >&2
          return 1
        }
        [[ "$setup_binds" != *"/run "* && "$ready_binds" != *"/run "* ]] || {
          echo "A helper binds the complete host /run tree" >&2
          return 1
        }
        [[ "$ready_binds" == *"/run/systemd/network"* ]] && {
          echo "$ready unexpectedly binds networkd's writable runtime directory" >&2
          return 1
        }
        [[ "$ready_writes" != *"/run/systemd/network"* ]] || {
          echo "$ready unexpectedly has write access to networkd's runtime directory" >&2
          return 1
        }
        [[ "$ready_writes" != *"/run/hermes-agent-network-0"* ]] || {
          echo "$ready unexpectedly has producer write access: $ready_writes" >&2
          return 1
        }
        pid=$(service_pid "$ready") || return 1
        mountinfo=$(<"/proc/$pid/mountinfo")
        [[ "$mountinfo" != *" /run/systemd/network "* ]] || {
          echo "$ready has an unexpected host networkd directory mount" >&2
          return 1
        }
        [[ ! -e "/proc/$pid/root/run/systemd/private" && ! -e "/proc/$pid/root/run/hermes-host-resolv.conf" \
          && -r "/proc/$pid/root/run/hermes-agent-network-0/authorization.json" ]] || {
          echo "$ready must read authorization without manager/host-resolver access" >&2
          return 1
        }
        [[ ! -e "/proc/$pid/root/run/systemd/network" ]] || {
          echo "$ready can see the networkd runtime directory without needing it" >&2
          return 1
        }
        echo "Controller owns networkd/publication writes; dynamic readiness sees read-only authorization, no manager/resolver socket"
      }

      discover_network_values() {
        local main_pid peer_pid
        main_pid=$(service_pid hermes@vm.service) || return 1
        peer_pid=$(service_pid hermes@vm-peer.service) || return 1
        host_vm_ip=$(ip -o -4 address show dev ha0 scope global | awk '$4 ~ /\/30$/ { split($4, a, "/"); print a[1]; exit }')
        agent_vm_ip=$(nsenter --target "$main_pid" --net -- ip -o -4 address show dev hb0 scope global | awk '$4 ~ /\/30$/ { split($4, a, "/"); print a[1]; exit }')
        host_peer_ip=$(ip -o -4 address show dev ha1 scope global | awk '$4 ~ /\/30$/ { split($4, a, "/"); print a[1]; exit }')
        peer_agent_ip=$(nsenter --target "$peer_pid" --net -- ip -o -4 address show dev hb1 scope global | awk '$4 ~ /\/30$/ { split($4, a, "/"); print a[1]; exit }')
        host_vm_ip6=$(ip -o -6 address show dev ha0 scope global | awk '$4 ~ /\/64$/ && $0 !~ / tentative|deprecated/ { split($4, a, "/"); print a[1]; exit }')
        agent_vm_ip6=$(nsenter --target "$main_pid" --net -- ip -o -6 address show dev hb0 scope global | awk '$4 ~ /\/64$/ && $0 !~ / tentative|deprecated/ { split($4, a, "/"); print a[1]; exit }')
        host_peer_ip6=$(ip -o -6 address show dev ha1 scope global | awk '$4 ~ /\/64$/ && $0 !~ / tentative|deprecated/ { split($4, a, "/"); print a[1]; exit }')
        peer_agent_ip6=$(nsenter --target "$peer_pid" --net -- ip -o -6 address show dev hb1 scope global | awk '$4 ~ /\/64$/ && $0 !~ / tentative|deprecated/ { split($4, a, "/"); print a[1]; exit }')
        [[ -n "$host_vm_ip" && -n "$agent_vm_ip" && -n "$host_peer_ip" && -n "$peer_agent_ip" \
          && -n "$host_vm_ip6" && -n "$agent_vm_ip6" && -n "$host_peer_ip6" && -n "$peer_agent_ip6" ]] || {
          echo "Could not discover the host and peer DHCP/SLAAC address pairs" >&2
          return 1
        }
        agent_vm_subnet4=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]+"/30").network)' "$host_vm_ip")
        peer_agent_subnet4=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]+"/30").network)' "$host_peer_ip")
        agent_vm_subnet6=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]+"/64").network)' "$host_vm_ip6")
        peer_agent_subnet6=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]+"/64").network)' "$host_peer_ip6")
        echo "Discovered vm network $agent_vm_subnet4/$agent_vm_subnet6 and peer network $peer_agent_subnet4/$peer_agent_subnet6"
      }

      check_all_store_isolation() {
        local unit pid uid gid instance runtime state
        check_root_configuration || return 1
        check_helper_mounts || return 1
        [[ -r "$store_sentinel" ]] || { echo "Positive-control store sentinel is missing: $store_sentinel" >&2; return 1; }
        [[ "$(<"$store_sentinel")" == "$store_sentinel_text" ]] || {
          echo "Positive-control store sentinel has unexpected contents" >&2
          return 1
        }
        "$store_probe" "$store_sentinel" >/dev/null || { echo "Positive-control store probe cannot read sentinel" >&2; return 1; }
        [[ -r "/nix/.ro-store/''${store_sentinel##*/}" ]] || {
          echo "Positive-control 9p store alias cannot read sentinel" >&2
          return 1
        }
        [[ -x /run/current-system/sw/bin/bash && -r /etc/static/os-release ]] || {
          echo "Positive-control NixOS store aliases are unavailable" >&2
          return 1
        }
        for unit in "''${units[@]}"; do
          [[ "$unit" == hermes-dhcp@* ]] || continue
          pid=$(service_pid "$unit") || return 1
          instance="''${unit#hermes-dhcp@}"
          instance="''${instance%.service}"
          runtime="/run/hermes-dhcp-$instance"
          state="/var/lib/hermes-dhcp-$instance"
          [[ $(readlink "/proc/$pid/root/var/run/dhcpcd") == /run/dhcpcd \
            && -L "/proc/$pid/root/var/lib/dhcpcd" ]] || return 1
          uid=$(awk '/^Uid:/ {print $3}' "/proc/$pid/status")
          gid=$(awk '/^Gid:/ {print $3}' "/proc/$pid/status")
          # This checks path access as the client identity, not its cgroup/seccomp enforcement.
          nsenter --target "$pid" --mount --root --wd --setuid "$uid" --setgid "$gid" -- \
            "${lib.getExe pkgs.python3}" -c 'import os,sys; assert os.path.samefile("/var/run/dhcpcd",sys.argv[1]); assert os.path.samefile("/var/lib/dhcpcd",sys.argv[2]); assert os.access("/run/dhcpcd",os.W_OK) and os.access("/var/lib/dhcpcd",os.W_OK)' \
            "$runtime" "$state" || return 1
          echo "$unit fixed runtime/state paths resolve to writable manager-owned directories as UID $uid"
        done
      }

      assert_distinct_namespaces() {
        local host_ns unit pid ns
        declare -A seen=()
        host_ns=$(readlink /proc/1/ns/net)
        seen["$host_ns"]=host
        echo "Host network namespace: $host_ns"
        for unit in "''${agent_units[@]}" "''${public_state_units[@]}"; do
          pid=$(service_pid "$unit")
          [[ $(systemctl show --property=PrivateNetwork --value "$unit") == yes ]] || {
            echo "$unit does not have effective PrivateNetwork=yes" >&2
            return 1
          }
          ns=$(readlink "/proc/$pid/ns/net")
          if [[ -n "''${seen[$ns]:-}" ]]; then
            echo "Network namespace shared unexpectedly: $unit and ''${seen[$ns]} ($ns)" >&2
            return 1
          fi
          seen["$ns"]="$unit"
          echo "$unit network namespace: $ns"
        done
        [[ "''${#seen[@]}" == 5 ]]
      }

      assert_namespace_released() {
        local expected="$1" ignore="''${2:-}" path namespace pid comm cgroup
        for path in /proc/[0-9]*/ns/net /proc/[0-9]*/fd/*; do
          [[ -e "$path" || -L "$path" ]] || continue
          [[ "$path" == "$ignore" ]] && continue
          namespace=$(readlink "$path" 2>/dev/null || true)
          if [[ "$namespace" == "$expected" ]]; then
            pid=''${path#/proc/}; pid=''${pid%%/*}
            comm=$(<"/proc/$pid/comm")
            cgroup=$(tr '\n' ';' <"/proc/$pid/cgroup")
            echo "Stopped service namespace is still referenced by $path (pid=$pid comm=$comm cgroup=$cgroup): $expected" >&2
            return 1
          fi
        done
        echo "No process or open namespace handle retains $expected"
      }

      start_test_endpoint() {
        echo "Creating isolated HTTP endpoint namespace"
        ip netns add hermes-vm-endpoint
        ip link add he0 type veth peer name he1
        ip link set he1 netns hermes-vm-endpoint
        ip address add 198.20.0.1/30 dev he0
        ip address add 10.20.0.1/29 dev he0
        ip -6 address add fd42:198:20::1/64 dev he0 nodad
        ip -6 address add 2001:db9::1/64 dev he0 nodad
        ip link set he0 up
        ip -n hermes-vm-endpoint link set lo up
        ip -n hermes-vm-endpoint address add 198.20.0.2/30 dev he1
        ip -n hermes-vm-endpoint address add 10.20.0.2/29 dev he1
        ip -n hermes-vm-endpoint address add 10.20.0.3/29 dev he1
        ip -n hermes-vm-endpoint -6 address add fd42:198:20::2/64 dev he1 nodad
        ip -n hermes-vm-endpoint -6 address add fd42:198:20::3/64 dev he1 nodad
        ip -n hermes-vm-endpoint -6 address add 2001:db9::2/64 dev he1 nodad
        ip -n hermes-vm-endpoint link set he1 up
        ip -n hermes-vm-endpoint route add default via 198.20.0.1
        ip -n hermes-vm-endpoint -6 route add default via fd42:198:20::1
        ip netns exec hermes-vm-endpoint "${lib.getExe' pkgs.python3 "python3"}" ${vmNetworkProbeServer} endpoint >/run/hermes-vm-endpoint-probes.log 2>&1 &
        endpoint_pid=$!
        for attempt in {1..120}; do
          if tcp_connect_namespace "$endpoint_pid" 198.20.0.2 18082 \
            && tcp_connect_namespace "$endpoint_pid" 10.20.0.2 18082 \
            && tcp_connect_namespace "$endpoint_pid" 10.20.0.3 18082 \
            && tcp_connect_namespace "$endpoint_pid" fd42:198:20::2 18082 \
            && tcp_connect_namespace "$endpoint_pid" fd42:198:20::3 18082 \
            && tcp_connect_namespace "$endpoint_pid" fd42:198:20::2 18086 \
            && tcp_connect_namespace "$endpoint_pid" 2001:db9::2 18082 \
            && tcp_connect_namespace "$endpoint_pid" 10.20.0.2 18083 \
            && tcp_connect_namespace "$endpoint_pid" 10.20.0.2 18086; then
            if ! udp_probe_namespace "$endpoint_pid" 10.20.0.2 18082; then sleep 0.1; continue; fi
            if ! udp_probe_namespace "$endpoint_pid" 10.20.0.2 18083; then sleep 0.1; continue; fi
            if ! udp_probe_namespace "$endpoint_pid" 10.20.0.2 18086; then sleep 0.1; continue; fi
            if ! udp_probe_namespace "$endpoint_pid" 10.20.0.3 18082; then sleep 0.1; continue; fi
            if ! udp_probe_namespace "$endpoint_pid" fd42:198:20::2 18082; then sleep 0.1; continue; fi
            if ! udp_probe_namespace "$endpoint_pid" fd42:198:20::2 18083; then sleep 0.1; continue; fi
            if ! udp_probe_namespace "$endpoint_pid" fd42:198:20::3 18086; then sleep 0.1; continue; fi
            if ! tcp_echo_probe_namespace "$endpoint_pid" 10.20.0.2 18090; then sleep 0.1; continue; fi
            echo "Controlled endpoint ready in hermes-vm-endpoint at 198.20.0.2 and fd42:198:20::2:18082"
            return 0
          fi
          if (( attempt % 5 == 0 )); then echo "Waiting for controlled endpoint listeners (attempt $attempt/120)"; fi
          sleep 0.1
        done
        echo "Endpoint IPv4 listeners:" >&2
        ip netns exec hermes-vm-endpoint "${lib.getExe' pkgs.iproute2 "ss"}" -H -ltunp >&2 || true
        echo "Endpoint IPv6 listeners:" >&2
        ip netns exec hermes-vm-endpoint "${lib.getExe' pkgs.iproute2 "ss"}" -6 -H -ltn 'sport = :18082' >&2 || true
        ip -n hermes-vm-endpoint -6 address show >&2 || true
        if kill -0 "$endpoint_pid" 2>/dev/null; then
          echo "Endpoint probe server process still exists: $endpoint_pid" >&2
        else
          echo "Endpoint probe server exited: $endpoint_pid" >&2
        fi
        cat /run/hermes-vm-endpoint-probes.log >&2 || true
        echo "Controlled endpoint failed to listen" >&2
        return 1
      }

      check_host_only_resolver() (
        local unit="$1" pid="$2" host_if="$3" host_ip="$4" host_ip6="$5" agent_ip="$6" instance resolver_file original test_table output actual expected
        instance="''${unit#*@}"
        instance="''${instance%.service}"
        resolver_file="/run/hermes-agent-network-''${instance/vm/0}/resolv.conf"
        [[ "$instance" == vm-peer ]] && resolver_file=/run/hermes-agent-network-1/resolv.conf
        original=$(<"$resolver_file")
        test_table="hermes-vm-dns-negative-$instance"

        remove_dns_block() {
          if nft list table inet "$test_table" >/dev/null 2>&1; then
            nft delete table inet "$test_table"
          fi
        }
        restore_resolver() {
          printf '%s\n' "$original" >"$resolver_file"
          remove_dns_block
        }
        trap restore_resolver EXIT

        assert_nameservers() {
          expected="$1"
          actual=$(awk '$1 == "nameserver" { if (NF != 2) exit 2; print $2 }' "/proc/$pid/root/etc/resolv.conf")
          [[ "$actual" == "$expected" ]] || {
            echo "$unit resolver nameservers differ: expected [$expected], got [$actual]" >&2
            return 1
          }
        }
        resolve_controlled_record() {
          run_as_service root "$pid" "${lib.getExe' pkgs.python3 "python3"}" -c '
        import socket, sys
        cap = next(line.split()[1] for line in open("/proc/self/status") if line.startswith("CapEff:"))
        assert int(cap, 16) == 0, cap
        family, expected = sys.argv[1:]
        af = socket.AF_INET if family == "A" else socket.AF_INET6
        actual = sorted({row[4][0] for row in socket.getaddrinfo("hermes-vm.test", None, af)})
        assert actual == [expected], actual
        print(f"{family} {actual[0]} CapEff=0")
          ' "$1" "$2"
        }

        output=$("${lib.getExe' pkgs.dnsutils "dig"}" +time=2 +tries=1 +short hermes-vm.test A)
        [[ "$output" == 198.20.0.2 ]] || { echo "Host resolver positive control returned: $output" >&2; return 1; }
        expected=$(printf '%s\n%s' "$host_ip" "$host_ip6")
        assert_nameservers "$expected"
        output=$("${lib.getExe' pkgs.dnsutils "dig"}" +time=2 +tries=1 +short hermes-vm.test AAAA)
        [[ "$output" == fd42:198:20::2 ]] || { echo "Host resolver AAAA positive control returned: $output" >&2; return 1; }
        printf 'nameserver %s\noptions attempts:1 timeout:2\n' "$host_ip" >"$resolver_file"
        assert_nameservers "$host_ip"
        resolve_controlled_record A 198.20.0.2
        resolve_controlled_record AAAA fd42:198:20::2

        nft add table inet "$test_table"
        nft add chain inet "$test_table" input '{ type filter hook input priority -151; policy accept; }'
        nft add rule inet "$test_table" input iifname "$host_if" ip saddr "$agent_ip" udp dport 53 drop
        nft add rule inet "$test_table" input iifname "$host_if" ip saddr "$agent_ip" tcp dport 53 drop
        output=$(run_as_service root "$pid" "${lib.getExe' pkgs.python3 "python3"}" -c '
        import socket, sys
        cap = next(line.split()[1] for line in open("/proc/self/status") if line.startswith("CapEff:"))
        assert int(cap, 16) == 0, cap
        try:
            socket.getaddrinfo("hermes-vm.test", None, socket.AF_INET)
        except socket.gaierror:
            print("gaierror")
        else:
            raise SystemExit("lookup unexpectedly succeeded")
        ')
        [[ "$output" == gaierror ]] || { echo "$unit DNS-unavailable negative control returned: $output" >&2; return 1; }

        restore_resolver
        trap - EXIT
        expected=$(printf '%s\n%s' "$host_ip" "$host_ip6")
        assert_nameservers "$expected"
        resolve_controlled_record A 198.20.0.2
        resolve_controlled_record AAAA fd42:198:20::2
        echo "$unit used exactly one host DNS nameserver successfully and failed closed when that host resolver was blocked"
      )

      check_agent_network() {
        local unit="$1" peer_if="$2" host_ip="$3" agent_ip="$4" blocked_peer="$5" host_ip6="$6" agent_ip6="$7" blocked_peer6="$8" host_if pid output
        pid=$(service_pid "$unit") || return 1
        host_if="ha''${peer_if#hb}"
        echo "Checking isolated networking for $unit pid=$pid"
        "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- "${lib.getExe' pkgs.iproute2 "ip"}" -o -4 address show dev "$peer_if" | grep -F "inet $agent_ip/30" || return 1
        "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- "${lib.getExe' pkgs.iproute2 "ip"}" -o -6 address show dev "$peer_if" | grep -F "inet6 $agent_ip6/64" || return 1
        "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- "${lib.getExe' pkgs.iproute2 "ip"}" route show default | grep -F "via $host_ip" || return 1
        "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- "${lib.getExe' pkgs.iproute2 "ip"}" -6 route show default | grep -F "dev $peer_if" || return 1
        echo "$unit: verifying nftables input/forward rules"
        nft list chain inet hermes-agent-guard hermes_agent_input_guard | grep -F "iifname \"$host_if\" drop" || return 1
        nft list chain inet hermes-agent-guard hermes_agent_input_guard | grep -F "ip saddr @''${host_if}_peer4" || return 1
        nft list chain inet hermes-agent-guard hermes_agent_forward_guard | grep -F "ip6 saddr != @''${host_if}_peer6 drop" || return 1
        nft list chain inet nixos-fw input-allow | grep -F "iifname \"$host_if\" accept" || return 1
        nft list chain inet nixos-fw forward-allow | grep -F "iifname \"$host_if\" accept" || return 1
        echo "$unit: probing host IPv4 UDP DNS"
        output=$("${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- "${lib.getExe' pkgs.dnsutils "dig"}" +time=2 +tries=1 +short @"$host_ip" hermes-vm.test A) || { echo "$unit IPv4 UDP DNS query failed" >&2; return 1; }
        [[ "$output" == 198.20.0.2 ]] || { echo "$unit IPv4 UDP DNS answer was: $output" >&2; return 1; }
        echo "$unit: probing host IPv4 TCP DNS"
        output=$("${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- "${lib.getExe' pkgs.dnsutils "dig"}" +tcp +time=2 +tries=1 +short @"$host_ip" hermes-vm.test A) || { echo "$unit IPv4 TCP DNS query failed" >&2; return 1; }
        [[ "$output" == 198.20.0.2 ]] || { echo "$unit IPv4 TCP DNS answer was: $output" >&2; return 1; }
        output=$("${lib.getExe' pkgs.dnsutils "dig"}" +time=2 +tries=1 +short @"$host_ip6" hermes-vm.test AAAA) || { echo "Host-local IPv6 DNS proxy query failed" >&2; return 1; }
        [[ "$output" == fd42:198:20::2 ]] || { echo "Host-local IPv6 DNS proxy answer was: $output" >&2; return 1; }
        echo "$unit: probing host IPv6 UDP DNS"
        output=$("${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- "${lib.getExe' pkgs.dnsutils "dig"}" +time=2 +tries=1 +short @"$host_ip6" hermes-vm.test AAAA) || { echo "$unit IPv6 UDP DNS query failed" >&2; return 1; }
        [[ "$output" == fd42:198:20::2 ]] || { echo "$unit IPv6 UDP DNS answer was: $output" >&2; return 1; }
        echo "$unit: probing host IPv6 TCP DNS"
        output=$("${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- "${lib.getExe' pkgs.dnsutils "dig"}" +tcp +time=2 +tries=1 +short @"$host_ip6" hermes-vm.test AAAA) || { echo "$unit IPv6 TCP DNS query failed" >&2; return 1; }
        [[ "$output" == fd42:198:20::2 ]] || { echo "$unit IPv6 TCP DNS answer was: $output" >&2; return 1; }
        echo "$unit: service-identity name-resolution probes"
        check_host_only_resolver "$unit" "$pid" "$host_if" "$host_ip" "$host_ip6" "$agent_ip" || return 1
        output=$(run_as_service root "$pid" "${lib.getExe' pkgs.python3 "python3"}" -c 'import socket; print(*sorted({r[4][0] for r in socket.getaddrinfo("hermes-vm.test", None, socket.AF_INET)}), sep="\\n")') || { echo "$unit service-identity A lookup failed" >&2; return 1; }
        [[ "$output" == *198.20.0.2* ]] || { echo "$unit service-identity A lookup was: $output" >&2; return 1; }
        output=$(run_as_service root "$pid" "${lib.getExe' pkgs.python3 "python3"}" -c 'import socket; print(*sorted({r[4][0] for r in socket.getaddrinfo("hermes-vm.test", None, socket.AF_INET6)}), sep="\\n")') || { echo "$unit service-identity AAAA lookup failed" >&2; return 1; }
        [[ "$output" == *fd42:198:20::2* ]] || { echo "$unit service-identity AAAA lookup was: $output" >&2; return 1; }
        run_as_service net "$pid" "${lib.getExe' pkgs.curl "curl"}" --fail --silent --show-error --connect-timeout 2 --max-time 4 http://198.20.0.2:18082/ >/dev/null || return 1
        run_as_service net "$pid" "${lib.getExe' pkgs.curl "curl"}" --ipv6 --fail --silent --show-error --connect-timeout 2 --max-time 4 -g 'http://[2001:db9::2]:18082/' >/dev/null || return 1
        if [[ "$unit" == hermes@vm.service ]]; then
          output=$(run_as_service net "$pid" "${lib.getExe' pkgs.curl "curl"}" --fail --silent --show-error --connect-timeout 2 --max-time 4 http://198.20.0.2:18082/source) || return 1
          [[ "$output" == 198.20.0.1 ]] || { echo "$unit IPv4 source translation was $output, expected 198.20.0.1" >&2; return 1; }
          output=$(run_as_service net "$pid" "${lib.getExe' pkgs.curl "curl"}" --ipv6 --fail --silent --show-error --connect-timeout 2 --max-time 4 -g 'http://[2001:db9::2]:18082/source') || return 1
          [[ "$output" == 2001:db9::1 ]] || { echo "$unit IPv6 source translation was $output, expected 2001:db9::1" >&2; return 1; }
          echo "$unit IPv4 and IPv6 NAT source addresses verified by the controlled endpoint"
          run_as_service net "$pid" "${lib.getExe' pkgs.curl "curl"}" --fail --silent --show-error --connect-timeout 2 --max-time 4 http://10.20.0.2:18082/ >/dev/null || return 1
          run_as_service net "$pid" "${lib.getExe' pkgs.curl "curl"}" --ipv6 --fail --silent --show-error --connect-timeout 2 --max-time 4 -g 'http://[fd42:198:20::2]:18082/' >/dev/null || return 1
          tcp_echo_probe_service "$pid" 10.20.0.2 18090 || { echo "$unit explicit TCP permission failed its response check" >&2; return 1; }
          if tcp_connect_service "$pid" 10.20.0.3 18082 || tcp_connect_service "$pid" fd42:198:20::3 18082 || tcp_connect_service "$pid" 10.20.0.2 18083; then
            echo "$unit reached an adjacent private address/port outside its exact permissions" >&2
            return 1
          fi
          udp_probe_service "$pid" 10.20.0.2 18086 || { echo "$unit UDP-only private permission failed its response check" >&2; return 1; }
          udp_probe_service "$pid" fd42:198:20::2 18086 || { echo "$unit forwarded IPv6 UDP permission failed its response check" >&2; return 1; }
          if udp_probe_service "$pid" fd42:198:20::3 18086 || udp_probe_service "$pid" fd42:198:20::2 18083 || tcp_connect_service "$pid" fd42:198:20::2 18086; then
            echo "$unit crossed the IPv6 UDP address, port, or protocol boundary" >&2
            return 1
          fi
          echo "$unit IPv6 UDP allow and adjacent address/port/protocol denials passed"
          if udp_probe_service "$pid" 10.20.0.2 18082 || udp_probe_service "$pid" fd42:198:20::2 18082 || tcp_connect_service "$pid" 10.20.0.2 18086 || udp_probe_service "$pid" 10.20.0.2 18083 || udp_probe_service "$pid" 10.20.0.3 18082; then
            echo "$unit crossed a TCP-only/UDP-only protocol, adjacent-port, or address boundary" >&2
            return 1
          fi
          for address in "$host_ip" "$host_ip6"; do
            if [[ "$address" == *:* ]]; then
              tcp_connect_service "$pid" "$address" 18083 || { echo "$unit could not use its default host-address permission at [$address]:18083" >&2; return 1; }
              udp_probe_service "$pid" "$address" 18083 || { echo "$unit could not use its default host UDP permission at [$address]:18083" >&2; return 1; }
            else
              tcp_connect_service "$pid" "$address" 18083 || { echo "$unit could not use its default host-address permission at $address:18083" >&2; return 1; }
              udp_probe_service "$pid" "$address" 18083 || { echo "$unit could not use its default host UDP permission at $address:18083" >&2; return 1; }
            fi
          done
          for address in "$host_other_ip" fd42:198:20::1; do
            if tcp_connect_service "$pid" "$address" 18083; then
              echo "$unit unexpectedly reached non-veth host address $address:18083" >&2
              return 1
            fi
            if udp_probe_service "$pid" "$address" 18083; then
              echo "$unit unexpectedly reached non-veth host UDP address $address:18083" >&2
              return 1
            fi
          done
        else
          for endpoint in "10.20.0.2:18082" "10.20.0.2:18090" "10.20.0.3:18082" "$host_ip:18083" "$host_other_ip:18083"; do
            address="''${endpoint%:*}"
            port="''${endpoint##*:}"
            if tcp_connect_service "$pid" "$address" "$port"; then
              echo "$unit unexpectedly reached private/host service at $address:$port" >&2
              return 1
            fi
          done
          for address in fd42:198:20::2 fd42:198:20::3; do
            if tcp_connect_service "$pid" "$address" 18082; then
              echo "$unit unexpectedly reached private IPv6 service [$address]:18082" >&2
              return 1
            fi
          done
          for address in fd42:198:20::1 "$host_ip6" "''${host_peer_ip6}"; do
            if tcp_connect_service "$pid" "$address" 18083; then
              echo "$unit unexpectedly reached host IPv6 service [$address]:18083" >&2
              return 1
            fi
          done
          for endpoint in "10.20.0.2:18082" "10.20.0.3:18082" "fd42:198:20::2:18082" "fd42:198:20::3:18086"; do
            address="''${endpoint%:*}"
            port="''${endpoint##*:}"
            if udp_probe_service "$pid" "$address" "$port"; then
              echo "$unit unexpectedly reached private UDP service $address:$port" >&2
              return 1
            fi
          done
          for address in "$host_ip" "$host_other_ip" fd42:198:20::1 "$host_ip6" "''${host_peer_ip6}"; do
            if udp_probe_service "$pid" "$address" 18083; then
              echo "$unit unexpectedly received UDP from private/host destination $address" >&2
              return 1
            fi
          done
        fi
        if tcp_connect_service "$pid" "$blocked_peer" 18084; then
          echo "$unit unexpectedly reached peer agent service at $blocked_peer:18084" >&2
          return 1
        fi
        echo "Denied $unit -> peer agent $blocked_peer:18084"
        if tcp_connect_service "$pid" "$blocked_peer6" 18085; then
          echo "$unit unexpectedly reached peer agent IPv6 service [$blocked_peer6]:18085" >&2
          return 1
        fi
        echo "Denied $unit -> peer agent IPv6 [$blocked_peer6]:18085"
        # shellcheck disable=SC2016
        run_as_service net "$pid" "${lib.getExe' pkgs.bash "bash"}" -euc 'cap=$(awk "/^CapEff:/ { print \$2 }" /proc/self/status); [[ "$cap" =~ ^0+$ ]]' || return 1
        [[ $(service_pid "$unit") == "$pid" ]] || { echo "$unit restarted during network probes" >&2; return 1; }
        echo "$unit resolved host-configured loopback DNS (UDP/TCP) and reached controlled endpoint with zero capabilities"
      }

      check_public_state_network() {
        local unit="$1" pid links families address
        pid=$(service_pid "$unit")
        links=$("${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- "${lib.getExe' pkgs.iproute2 "ip"}" -o link show | awk -F': ' '{ sub(/@.*/, "", $2); print $2 }')
        [[ "$links" == lo ]] || { echo "$unit has network interfaces other than loopback: $links" >&2; return 1; }
        families=$(systemctl show --property=RestrictAddressFamilies --value "$unit")
        [[ "$families" == "~" ]] || { echo "$unit address-family restriction is not empty: $families" >&2; return 1; }
        for address in "198.20.0.2:18082" "''${host_vm_ip}:18083" "$host_other_ip:18083" "''${peer_agent_ip}:18084"; do
          port="''${address##*:}"
          address="''${address%:*}"
          if tcp_connect_service "$pid" "$address" "$port"; then
            echo "$unit unexpectedly reached network endpoint $address" >&2
            return 1
          fi
        done
        for address in "[fd42:198:20::2]:18082" "[fd42:198:20::1]:18083" "[''${peer_agent_ip6}]:18085"; do
          port="''${address##*:}"
          address="''${address#[}"
          address="''${address%]*}"
          if tcp_connect_service "$pid" "$address" "$port"; then
            echo "$unit unexpectedly reached IPv6 network endpoint $address" >&2
            return 1
          fi
        done
        [[ $(service_pid "$unit") == "$pid" ]] || { echo "$unit restarted during network-denial probes" >&2; return 1; }
        echo "$unit has only loopback and cannot reach external, host, or peer endpoints"
      }

      check_public_internet() {
        local unit pid expected_dns output response dns_ip uplink nm_state nm_devices host_dns_ready
        echo "Real-Internet regression: validating guest host DNS/TLS and QEMU default route"
        ip route show default | grep -q '^default ' || { echo "Guest has no QEMU-provided IPv4 default route" >&2; return 1; }
        if [[ "$HERMES_VM_NM_UPLINK_TEST" == 1 ]]; then
          uplink=$(ip -4 route show default | awk 'NR == 1 { print $5 }')
          nm_devices=$(${lib.getExe' pkgs.networkmanager "nmcli"} -t -f DEVICE,STATE device status)
          nm_state=$(awk -F: -v dev="$uplink" '$1 == dev { print $2 }' <<< "$nm_devices")
          [[ -n "$uplink" && "$nm_state" == connected ]] || {
            echo "NetworkManager does not own the active default-route uplink $uplink: $nm_devices" >&2
            return 1
          }
          if ! grep -Fxq 'ha0:unmanaged' <<< "$nm_devices" || ! grep -Fxq 'ha1:unmanaged' <<< "$nm_devices"; then
            echo "Hermes host veths were not excluded from NetworkManager: $nm_devices" >&2
            return 1
          fi
          echo "NetworkManager retains $uplink and leaves Hermes veths unmanaged"
        fi
        host_dns_ready=0
        for _ in {1..5}; do
          if "${lib.getExe' pkgs.dnsutils "dig"}" +time=3 +tries=1 +short example.com A | grep -Eq '^[0-9]+\.'; then
            host_dns_ready=1
            break
          fi
          sleep 1
        done
        (( host_dns_ready )) || {
          echo "Guest host resolver could not resolve example.com; configured resolver follows" >&2
          cat /etc/resolv.conf >&2
          echo "Guest IPv4 route table and route selection for the public resolver:" >&2
          ip -4 route show table all >&2
          ip -4 route get 1.1.1.1 >&2 || true
          echo "Direct public DNS control via 1.1.1.1:" >&2
          "${lib.getExe' pkgs.dnsutils "dig"}" +time=3 +tries=1 +short @1.1.1.1 example.com A >&2 || true
          echo "Loopback DNS forwarder control via 127.0.0.1:" >&2
          "${lib.getExe' pkgs.dnsutils "dig"}" +time=3 +tries=1 +short @127.0.0.1 example.com A >&2 || true
          return 1
        }
        "${lib.getExe' pkgs.curl "curl"}" --noproxy '*' --fail --silent --show-error --connect-timeout 3 --max-time 10 https://example.com/ | grep -Fq 'Example Domain' || {
          echo "Guest host HTTPS positive control failed (DNS, route, upstream, or CA trust)" >&2
          return 1
        }
        for unit in "''${agent_units[@]}"; do
          pid=$(service_pid "$unit") || return 1
          if [[ "$unit" == hermes@vm.service ]]; then expected_dns=''${host_vm_ip}; else expected_dns=''${host_peer_ip}; fi
          echo "$unit: verify generated resolver, public DNS, TCP/443, HTTPS and CapEff=0 as service identity"
          output=$(run_as_service root "$pid" "${lib.getExe' pkgs.python3 "python3"}" -c 'import socket,sys; expected=sys.argv[1]; resolv=open("/etc/resolv.conf",encoding="ascii").read(); assert "nameserver "+expected in resolv,"unexpected generated resolver: "+resolv; addresses=sorted({answer[4][0] for answer in socket.getaddrinfo("example.com",443,socket.AF_INET,socket.SOCK_STREAM)}); assert addresses,"public DNS returned no IPv4 addresses"; sock=socket.create_connection((addresses[0],443),timeout=4); sock.close(); caps=next(line.split()[1] for line in open("/proc/self/status") if line.startswith("CapEff:")); assert int(caps,16)==0,"effective capabilities are nonzero: "+caps; print("PUBLIC_DNS_IP="+addresses[0]); print("resolver="+expected+" DNS="+",".join(addresses)+" TCP/443=connected CapEff="+caps)' "$expected_dns") || {
            echo "$unit failed public DNS/TCP from its service namespace; resolver/routes follow" >&2
            "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --mount --root -- cat /etc/resolv.conf >&2 || true
            "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- "${lib.getExe' pkgs.iproute2 "ip"}" route show table all >&2 || true
            return 1
          }
          echo "$output"
          dns_ip=$(awk -F= '$1 == "PUBLIC_DNS_IP" { print $2; exit }' <<< "$output")
          [[ "$dns_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "$unit returned no single IPv4 address for the HTTPS probe: $output" >&2; return 1; }
          response=$(run_as_service net "$pid" "${lib.getExe' pkgs.curl "curl"}" --resolve "example.com:443:$dns_ip" --noproxy '*' --fail --silent --show-error --connect-timeout 3 --max-time 10 https://example.com/ -w '%{http_code}') || {
            echo "$unit certificate-verified HTTPS failed; certificate verification is not disabled" >&2
            return 1
          }
          [[ "$response" == *"Example Domain"* && "''${response: -3}" == 200 ]] || {
            echo "$unit HTTPS response was not the expected public Example Domain HTTP 200" >&2
            return 1
          }
          echo "$unit returned verified HTTPS HTTP 200 with the expected public content"
        done
        echo "Public IPv6 Internet reachability remains unverified"
      }

      dashboard_http_ok() {
        local port="$1" retries="$2" attempt code=000 body_file error_file title_seen asset_seen
        body_file=$(mktemp)
        error_file=$(mktemp)
        for ((attempt = 1; attempt <= retries; attempt++)); do
          if code=$("${lib.getExe' pkgs.curl "curl"}" --noproxy '*' --silent --show-error --connect-timeout 1 --max-time 2 -o "$body_file" -w '%{http_code}' "http://127.0.0.1:$port/" 2>"$error_file"); then
            if [[ "$code" == 200 ]] && grep -Fq '<title>Hermes Agent - Dashboard</title>' "$body_file" && grep -Fq 'src="/assets/index-' "$body_file" && grep -Fq '.js"' "$body_file"; then
              rm -f "$body_file" "$error_file"
              echo "Packaged Hermes dashboard UI returned HTTP 200 via 127.0.0.1:$port at guest uptime $(awk '{print $1}' /proc/uptime)s"
              return 0
            fi
          fi
          sleep 0.2
        done
        title_seen=0
        asset_seen=0
        grep -Fq '<title>Hermes Agent - Dashboard</title>' "$body_file" && title_seen=1 || true
        grep -Fq 'src="/assets/index-' "$body_file" && grep -Fq '.js"' "$body_file" && asset_seen=1 || true
        echo "Dashboard UI check rejected 127.0.0.1:$port: HTTP $code, title marker=$title_seen, packaged JS marker=$asset_seen" >&2
        [[ ! -s "$error_file" ]] || cat "$error_file" >&2
        rm -f "$body_file" "$error_file"
        return 1
      }

      check_dashboard_mapping() {
        local pid listener ready=0 response_file code
        for _ in {1..100}; do
          pid=$(service_pid hermes@vm.service) || return 1
          if "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- "${lib.getExe' pkgs.iproute2 "ss"}" -H -ltn 'sport = :9119' | grep -Fq '127.0.0.1:9119' \
            && "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- "${lib.getExe' pkgs.iproute2 "ss"}" -H -ltn 'sport = :9119' | grep -Fq "''${agent_vm_ip}:9119"; then
            ready=1
            break
          fi
          sleep 0.1
        done
        (( ready )) || { echo "The real Hermes dashboard is not listening on its namespace port 9119" >&2; return 1; }
        listener=$(ss -H -ltn "sport = :$dashboard_host_port")
        if [[ "$listener" != *"127.0.0.1:$dashboard_host_port"* ]] || ! awk -v port="$dashboard_host_port" '$4 == "127.0.0.1:" port || $4 == "[::1]:" port { next } { bad=1 } END { exit (NR > 0 && !bad ? 0 : 1) }' <<< "$listener"; then
          echo "Dashboard mapping is missing or not restricted to host loopback: $listener" >&2
          return 1
        fi
        listener=$(ss -H -lun "sport = :$dashboard_host_port")
        if [[ "$listener" != *"127.0.0.1:$dashboard_host_port"* ]] || ! awk -v port="$dashboard_host_port" '$4 == "127.0.0.1:" port || $4 == "[::1]:" port { next } { bad=1 } END { exit (NR > 0 && !bad ? 0 : 1) }' <<< "$listener"; then
          echo "Both-protocol dashboard mapping has no host-loopback UDP proxy: $listener" >&2
          return 1
        fi
        dashboard_http_ok "$dashboard_host_port" 50 || return 1
        echo "Dashboard UI mapping 127.0.0.1:$dashboard_host_port -> agent loopback:9119 is host-loopback-only"
        response_file=$(mktemp)
        if ! code=$("${lib.getExe' pkgs.curl "curl"}" --noproxy '*' --fail --silent --show-error --connect-timeout 1 --max-time 2 -o "$response_file" -w '%{http_code}' http://127.0.0.1:18193/); then
          rm -f "$response_file"
          echo "Explicit loopback mapping 127.0.0.1:18193 did not return its positive-control response" >&2
          return 1
        fi
        if [[ "$code" != 200 || "$(<"$response_file")" != OK ]]; then
          rm -f "$response_file"
          echo "Explicit loopback mapping 127.0.0.1:18193 returned an unexpected HTTP/body response (HTTP $code)" >&2
          return 1
        fi
        rm -f "$response_file"
        if dashboard_http_ok 18193 1; then
          echo "Dashboard HTTP oracle accepted a misdirected HTTP 200 loopback response on port 18193" >&2
          return 1
        fi
        echo "HTTP oracle rejected the explicit loopback positive-control response as a misdirected dashboard (HTTP 200, body OK)"
      }

      check_port_mappings() {
        local code listener port
        for port in 18191 18193 18194 18195 18196 18198; do
          listener=$(ss -H -ltn "sport = :$port")
          if [[ "$listener" != *"127.0.0.1:$port"* ]] || ! awk -v port="$port" '$4 == "127.0.0.1:" port || $4 == "[::1]:" port { next } { bad=1 } END { exit (NR > 0 && !bad ? 0 : 1) }' <<< "$listener"; then
            echo "TCP mapping $port is missing or not loopback-only: $listener" >&2
            return 1
          fi
        done
        for port in 18192 18193 18194 18195 18197; do
          listener=$(ss -H -lun "sport = :$port")
          if [[ "$listener" != *"127.0.0.1:$port"* ]] || ! awk -v port="$port" '$4 == "127.0.0.1:" port || $4 == "[::1]:" port { next } { bad=1 } END { exit (NR > 0 && !bad ? 0 : 1) }' <<< "$listener"; then
            echo "UDP mapping $port is missing or not loopback-only: $listener" >&2
            return 1
          fi
        done
        for port in 18191 18196 18198; do
          if ss -H -lun "sport = :$port" | grep -q .; then echo "TCP-only mapping unexpectedly opened UDP $port" >&2; return 1; fi
        done
        for port in 18192 18197; do
          if ss -H -ltn "sport = :$port" | grep -q .; then echo "UDP-only mapping unexpectedly opened TCP $port" >&2; return 1; fi
        done
        tcp_connect_host 127.0.0.1 18191 || return 1
        for port in 18193 18194 18195 18196; do
          code=$("${lib.getExe' pkgs.curl "curl"}" --noproxy '*' --fail --silent --show-error --connect-timeout 1 --max-time 4 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/") || return 1
          [[ "$code" == 200 ]] || { echo "Mapped HTTP port $port returned HTTP $code instead of 200" >&2; return 1; }
        done
        for port in 18192 18193 18194 18195 18197; do udp_probe 127.0.0.1 "$port" || { echo "Mapped UDP port $port did not return a response" >&2; return 1; }; done
        echo "TCP-only, UDP-only, explicit-both/default-both veth and loopback mappings returned expected positive controls"
      }

      check_permission_revocation() {
        local pid handle client_pid ready_file=/run/hermes-vm-revocation-client.log
        pid=$(service_pid hermes@vm.service) || return 1
        rm -f "$ready_file"
        run_as_service net "$pid" "${lib.getExe' pkgs.python3 "python3"}" -c 'import socket,sys,time;s=socket.create_connection(("10.20.0.2",18090),timeout=2);s.settimeout(2);s.sendall(b"first");assert s.recv(16)==b"first";print("ESTABLISHED",flush=True);time.sleep(4);s.sendall(b"second");assert s.recv(16)==b"second"' >"$ready_file" 2>&1 &
        client_pid=$!
        for _ in {1..50}; do
          if grep -q ESTABLISHED "$ready_file"; then break; fi
          if ! kill -0 "$client_pid" 2>/dev/null; then cat "$ready_file" >&2; echo "Private TCP positive control failed before revocation" >&2; return 1; fi
          sleep 0.1
        done
        grep -q ESTABLISHED "$ready_file" || { echo "Private TCP session did not reach its positive-control state" >&2; return 1; }
        handle=$(nft -a list chain inet hermes-agent-guard hermes_agent_forward_guard | awk '/daddr 10.20.0.2 tcp dport 18090 accept/ { print $NF; exit }')
        [[ "$handle" =~ ^[0-9]+$ ]] || { echo "Could not find the declarative private TCP permission rule" >&2; return 1; }
        nft delete rule inet hermes-agent-guard hermes_agent_forward_guard handle "$handle"
        if wait "$client_pid"; then echo "Established private TCP session continued after its allow rule was revoked" >&2; return 1; fi
        if tcp_echo_probe_service "$pid" 10.20.0.2 18090; then echo "New private TCP connection survived permission revocation" >&2; return 1; fi
        echo "Revoked private permission blocked both an established flow's next packet and a new connection"
        stop_peer_probes
        timeout --kill-after=5s 30 systemctl restart nftables.service || { diagnose; return 1; }
        timeout --kill-after=5s 180 systemctl start hermes@vm.service hermes@vm-peer.service hermes-pf@vm.service hermes-pf@vm-peer.service || { diagnose; return 1; }
        wait_for_active || { diagnose; return 1; }
        assert_distinct_namespaces || return 1
        start_peer_probes hermes@vm.service "''${agent_vm_ip}" "''${agent_vm_ip6}" || return 1
        start_peer_probes hermes@vm-peer.service "''${peer_agent_ip}" "''${peer_agent_ip6}" || return 1
        check_host_initiated_replies || return 1
        pid=$(service_pid hermes@vm.service) || return 1
        tcp_echo_probe_service "$pid" 10.20.0.2 18090 || { echo "Firewall restart did not restore declarative private permission" >&2; return 1; }
        check_agent_network hermes@vm.service hb0 "''${host_vm_ip}" "''${agent_vm_ip}" "''${peer_agent_ip}" "''${host_vm_ip6}" "''${agent_vm_ip6}" "''${peer_agent_ip6}" || return 1
        check_agent_network hermes@vm-peer.service hb1 "''${host_peer_ip}" "''${peer_agent_ip}" "''${agent_vm_ip}" "''${host_peer_ip6}" "''${peer_agent_ip6}" "''${agent_vm_ip6}" || return 1
        check_dashboard_mapping || return 1
        check_port_mappings || return 1
        echo "Firewall restart preserved host/private policy and TCP/UDP port mappings"
      }

      check_host_permission_revocation() {
        local pid client_pid ready_file=/run/hermes-vm-host-revocation-client.log entry family table chain handle
        echo "Testing a mapped-source-port host connection cannot survive permission revocation"
        tcp_echo_host "''${host_peer_ip}" 18084 || { echo "Host echo listener positive control failed" >&2; return 1; }
        pid=$(service_pid hermes@vm-peer.service) || return 1
        for entry in "inet hermes-agent-guard hermes_agent_input_guard" "inet nixos-fw input-allow"; do
          read -r family table chain <<< "$entry"
          nft insert rule "$family" "$table" "$chain" iifname "ha1" ip saddr "''${peer_agent_ip}" ip daddr "''${host_peer_ip}" tcp dport 18084 accept comment "hermes-vm-host-permission-revocation" || return 1
        done
        rm -f "$ready_file"
        run_as_service net "$pid" "${lib.getExe' pkgs.python3 "python3"}" -c 'import socket,sys,time;s=socket.socket();s.settimeout(2);s.bind((sys.argv[2],18198));s.connect((sys.argv[1],18084));s.sendall(b"first");assert s.recv(32)==b"first";print("ESTABLISHED",flush=True);time.sleep(2);s.sendall(b"second");assert s.recv(32)==b"second"' "''${host_peer_ip}" "''${peer_agent_ip}" >"$ready_file" 2>&1 &
        client_pid=$!
        for _ in {1..50}; do
          if grep -q ESTABLISHED "$ready_file"; then break; fi
          if ! kill -0 "$client_pid" 2>/dev/null; then cat "$ready_file" >&2; echo "Mapped-source-port host permission positive control failed" >&2; return 1; fi
          sleep 0.1
        done
        grep -q ESTABLISHED "$ready_file" || { echo "Mapped-source-port host connection did not reach its positive-control state" >&2; return 1; }
        remove_host_revocation_rules
        if wait "$client_pid"; then echo "Mapped-source-port host connection survived permission revocation" >&2; return 1; fi
        echo "Host permission revocation blocked the next ORIGINAL-direction packet despite its mapped source port"
        # The exact-policy monitors fail closed while the deliberately extra rule exists.
        stop_peer_probes
        assert_network_resources_clean ha0 hermes_agent_0 "''${agent_vm_subnet4}" "''${agent_vm_subnet6}" || return 1
        assert_network_resources_clean ha1 hermes_agent_1 "''${peer_agent_subnet4}" "''${peer_agent_subnet6}" || return 1
        timeout 30s systemctl reset-failed
        timeout --kill-after=5s 180 systemctl start hermes@vm.service hermes@vm-peer.service \
          hermes-pf@vm.service hermes-pf@vm-peer.service || { diagnose; return 1; }
        wait_for_active || { diagnose; return 1; }
        assert_distinct_namespaces || return 1
        discover_network_values || return 1
        start_peer_probes hermes@vm.service "$agent_vm_ip" "$agent_vm_ip6" || return 1
        start_peer_probes hermes@vm-peer.service "$peer_agent_ip" "$peer_agent_ip6" || return 1
        echo "Both gateways reacquired after the temporary host permission rule was removed"
      }

      check_mapping_failure_cleanup() {
        local collision_pid port state
        echo "Testing partial TCP/UDP mapping startup cleanup after an occupied UDP host port"
        stop_peer_probes
        timeout --kill-after=5s 60 systemctl stop hermes@vm-peer.service || { diagnose; return 1; }
        for _ in {1..100}; do
          state=$(systemctl show --property=ActiveState --value hermes-network@vm-peer.service)
          [[ "$state" == inactive || "$state" == failed ]] && break
          sleep 0.1
        done
        [[ "$state" == inactive || "$state" == failed ]] || { echo "Peer network helper did not stop before collision test" >&2; return 1; }
        "${lib.getExe' pkgs.python3 "python3"}" -c 'import socket,time;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(("127.0.0.1",18192));time.sleep(600)' >/dev/null 2>&1 &
        collision_pid=$!
        for _ in {1..50}; do
          if ss -H -lun 'sport = :18192' | grep -Fq '127.0.0.1:18192'; then break; fi
          sleep 0.1
        done
        ss -H -lun 'sport = :18192' | grep -Fq '127.0.0.1:18192' || { kill "$collision_pid" 2>/dev/null || true; echo "Could not establish UDP mapping collision positive control" >&2; return 1; }
        timeout 30s systemctl reset-failed hermes@vm-peer.service hermes-network@vm-peer.service
        if timeout --kill-after=5s 60 systemctl start hermes@vm-peer.service; then
          kill "$collision_pid" 2>/dev/null || true
          echo "Peer network helper started despite an occupied UDP mapping host port" >&2
          return 1
        fi
        kill "$collision_pid" 2>/dev/null || true
        wait "$collision_pid" 2>/dev/null || true
        for _ in {1..100}; do
          state=$(systemctl show --property=ActiveState --value hermes-network@vm-peer.service)
          if [[ "$state" == inactive || "$state" == failed ]] && ! ip link show dev ha1 >/dev/null 2>&1; then break; fi
          sleep 0.1
        done
        if ip link show dev ha1 >/dev/null 2>&1; then echo "Failed mapping setup left its peer veth" >&2; return 1; fi
        for port in 18191 18192 18193 18194 18195 18196 18197 18198; do
          if ss -H -ltn "sport = :$port" | grep -q . || ss -H -lun "sport = :$port" | grep -q .; then
            echo "Failed mapping setup left a host proxy on port $port" >&2
            return 1
          fi
        done
        if ip -4 route show table all | grep -Fq "''${peer_agent_subnet4}" || ip -6 route show table all | grep -Fq "''${peer_agent_subnet6}"; then
          echo "Failed mapping setup left a peer route" >&2
          return 1
        fi
        timeout 30s systemctl reset-failed hermes@vm-peer.service hermes-network@vm-peer.service
        timeout --kill-after=5s 180 systemctl start hermes@vm-peer.service hermes-pf@vm-peer.service || { diagnose; return 1; }
        wait_for_active || { diagnose; return 1; }
        start_peer_probes hermes@vm-peer.service "''${peer_agent_ip}" "''${peer_agent_ip6}" || return 1
        check_port_mappings || return 1
        echo "Partial mapping failure cleaned TCP proxies, UDP listeners, veth and routes; retry succeeded"
      }

      check_dhcp_renewal() {
        local main_gateway peer_gateway main_dhcp peer_dhcp old_main4 old_main6 old_peer4 old_peer6
        trigger_dhcp_rebind() {
          local host_if="$1" client_pid="$2" client_if="$3" capture_file="$4" expected_ip="$5" unit="$6" capture_pid started_at lease_log
          started_at=$(date +%s)
          tcpdump -nni "$host_if" -vv -l 'udp port 67 or udp port 68' >"$capture_file" 2>&1 &
          capture_pid=$!
          sleep 0.2
          if ! timeout --kill-after=5s 30 nsenter --target "$client_pid" --mount --root --wd -- \
            "$dhcpcd_exe" --rebind "$client_if"; then
            kill "$capture_pid" 2>/dev/null || true
            wait "$capture_pid" 2>/dev/null || true
            echo "DHCP client rebind command failed on $client_if" >&2
            return 1
          fi
          for _ in {1..100}; do
            grep -Eq 'DHCP-Message.*ACK|DHCPACK' "$capture_file" && break
            sleep 0.1
          done
          kill "$capture_pid" 2>/dev/null || true
          wait "$capture_pid" 2>/dev/null || true
          grep -Eq 'DHCP-Message.*ACK|DHCPACK' "$capture_file" || {
            echo "No DHCP ACK observed on $host_if after rebind; capture follows:" >&2
            cat "$capture_file" >&2
            return 1
          }
          for _ in {1..300}; do
            lease_log=$(journalctl -u "$unit" --since "@$started_at" --no-pager -o cat)
            grep -Fq "leased $expected_ip for" <<< "$lease_log" && break
            sleep 0.1
          done
          grep -Fq "leased $expected_ip for" <<< "$lease_log" || {
            echo "$unit did not log application of the renewed $expected_ip lease; journal follows:" >&2
            printf '%s\n' "$lease_log" >&2
            return 1
          }
          echo "Observed DHCP ACK on $host_if and client-applied lease $expected_ip in $unit"
        }
        echo "Forcing DHCP lease rebind in both isolated client namespaces"
        main_gateway=$(service_pid hermes@vm.service) || return 1
        peer_gateway=$(service_pid hermes@vm-peer.service) || return 1
        main_dhcp=$(service_pid hermes-dhcp@vm.service) || return 1
        peer_dhcp=$(service_pid hermes-dhcp@vm-peer.service) || return 1
        old_main4=$agent_vm_ip; old_main6=$agent_vm_ip6
        old_peer4=$peer_agent_ip; old_peer6=$peer_agent_ip6
        trigger_dhcp_rebind ha0 "$main_dhcp" hb0 /run/hermes-vm-dhcp-main-rebind.log "$old_main4" hermes-dhcp@vm.service || return 1
        trigger_dhcp_rebind ha1 "$peer_dhcp" hb1 /run/hermes-vm-dhcp-peer-rebind.log "$old_peer4" hermes-dhcp@vm-peer.service || return 1
        for _ in {1..100}; do
          [[ "$(systemctl show --property=ActiveState --value hermes-network-ready@vm.service)" == active \
            && "$(systemctl show --property=ActiveState --value hermes-network-ready@vm-peer.service)" == active ]] && break
          sleep 0.1
        done
        discover_network_values || return 1
        [[ "$agent_vm_ip" == "$old_main4" && "$agent_vm_ip6" == "$old_main6" \
          && "$peer_agent_ip" == "$old_peer4" && "$peer_agent_ip6" == "$old_peer6" ]] || {
            echo "DHCP rebind changed a live allocation without a readiness restart" >&2
            return 1
          }
        [[ "$(service_pid hermes@vm.service)" == "$main_gateway" \
          && "$(service_pid hermes@vm-peer.service)" == "$peer_gateway" ]] || {
            echo "Gateway restarted during same-lease DHCP renewal" >&2
            return 1
          }
        check_agent_network hermes@vm.service hb0 "$host_vm_ip" "$agent_vm_ip" "$peer_agent_ip" \
          "$host_vm_ip6" "$agent_vm_ip6" "$peer_agent_ip6" || return 1
        check_agent_network hermes@vm-peer.service hb1 "$host_peer_ip" "$peer_agent_ip" "$agent_vm_ip" \
          "$host_peer_ip6" "$peer_agent_ip6" "$agent_vm_ip6" || return 1
        echo "Both DHCP ACKs were applied by their clients; allocations, routes, firewall and gateway processes remained coherent"
      }

      check_dhcp_failure_gate() {
        local old_start current_start state set_output resolver
        echo "Testing bounded DHCP failure, stale resolver rejection, and lease recovery"
        stop_peer_probes
        timeout --kill-after=5s 60 systemctl stop hermes@vm.service hermes@vm-peer.service || { diagnose; return 1; }
        assert_network_resources_clean ha0 hermes_agent_0 "$agent_vm_subnet4" "$agent_vm_subnet6" || return 1
        assert_network_resources_clean ha1 hermes_agent_1 "$peer_agent_subnet4" "$peer_agent_subnet6" || return 1
        old_start=$(systemctl show --property=ExecMainStartTimestampMonotonic --value hermes@vm.service)
        dhcp_block=1
        nft add table inet hermes-vm-dhcp-block
        nft add chain inet hermes-vm-dhcp-block input '{ type filter hook input priority -151; policy accept; }'
        nft add rule inet hermes-vm-dhcp-block input \
          iifname "ha0" udp sport 68 udp dport 67 drop comment "hermes-vm-dhcp-block"
        install -d -m 0750 /run/hermes-agent-network-0
        printf 'nameserver 203.0.113.53\n' >/run/hermes-agent-network-0/resolv.conf
        if timeout --kill-after=5s 75 systemctl start hermes@vm.service >/run/hermes-vm-dhcp-failure.log 2>&1; then
          echo "Gateway start unexpectedly succeeded without a DHCP lease" >&2
          return 1
        fi
        current_start=$(systemctl show --property=ExecMainStartTimestampMonotonic --value hermes@vm.service)
        [[ "$current_start" == "$old_start" ]] || { echo "Gateway ExecStart ran during DHCP failure" >&2; return 1; }
        state=$(systemctl show --property=ActiveState --value hermes@vm.service)
        [[ "$state" != active ]] || { echo "Gateway remained active without DHCP" >&2; return 1; }
        state=$(systemctl show --property=ActiveState --value hermes-network-ready@vm.service)
        [[ "$state" != active ]] || { echo "Readiness service reported success without DHCP" >&2; return 1; }
        set_output=$(nft -n list set inet hermes-agent-guard ha0_peer4)
        if grep -Eq 'elements[[:space:]]*=[[:space:]]*\{[^}]*[0-9]' <<< "$set_output"; then
          echo "Peer firewall set retained an address after DHCP failure" >&2
          return 1
        fi
        remove_dhcp_block
        timeout --kill-after=5s 180 systemctl stop hermes@vm.service hermes@vm-peer.service \
          hermes-network@vm.service hermes-network@vm-peer.service \
          hermes-dhcp@vm.service hermes-dhcp@vm-peer.service \
          hermes-network-ready@vm.service hermes-network-ready@vm-peer.service || return 1
        assert_network_resources_clean ha0 hermes_agent_0 "$agent_vm_subnet4" "$agent_vm_subnet6" || return 1
        assert_network_resources_clean ha1 hermes_agent_1 "$peer_agent_subnet4" "$peer_agent_subnet6" || return 1
        timeout 30s systemctl reset-failed "''${units[@]}"
        timeout --kill-after=5s 180 systemctl start hermes@vm.service hermes@vm-peer.service \
          hermes-pf@vm.service hermes-pf@vm-peer.service || { diagnose; return 1; }
        wait_for_active || { diagnose; return 1; }
        start_peer_probes hermes@vm.service "$agent_vm_ip" "$agent_vm_ip6" || return 1
        start_peer_probes hermes@vm-peer.service "$peer_agent_ip" "$peer_agent_ip6" || return 1
        resolver=$(< /run/hermes-agent-network-0/resolv.conf)
        [[ "$resolver" == *"nameserver $host_vm_ip"* && "$resolver" == *"nameserver $host_vm_ip6"* ]] \
          && [[ "$resolver" != *203.0.113.53* ]] || {
            echo "Restart used stale resolver state instead of its current DHCP allocation" >&2
            return 1
          }
        echo "DHCP failure kept the gateway stopped with empty peer sets; DHCP recovery replaced stale resolver state"
      }

      check_split_producer_loss() {
        local scenario unit pid started deadline ready gateway set_output revoked elapsed
        stop_peer_probes
        for scenario in normal-slow-stop host-control netns network-observer dns-child host-proxy-child agent-relay-child stale-observer; do
          split_frozen_pid=
          started=$(python3 -c 'import time; print(time.monotonic_ns())')
          case "$scenario" in
            normal-slow-stop)
              install -d -m 0755 "''${split_override%/*}"
              printf '[Service]\nExecStop=${pkgs.coreutils}/bin/sleep 8\n' > "$split_override"
              systemctl daemon-reload
              started=$(python3 -c 'import time; print(time.monotonic_ns())')
              systemctl --no-block stop hermes@vm.service
              ;;
            stale-observer)
              pid=$(service_pid hermes-network-observer@vm.service) || return 1
              split_frozen_pid="$pid"
              kill -STOP "$pid"
              ;;
            *-child)
              unit="hermes-''${scenario%-child}@vm.service"
              pid=$(service_pid "$unit") || return 1
              pid=$(awk '{print $1}' "/proc/$pid/task/$pid/children")
              [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { echo "$scenario has no supervised child" >&2; return 1; }
              kill -KILL "$pid"
              ;;
            *) systemctl kill --signal=KILL --kill-whom=main "hermes-$scenario@vm.service" ;;
          esac
          deadline=$((SECONDS + 10))
          revoked=0
          while (( SECONDS < deadline )); do
            ready=$(systemctl show --property=ActiveState --value hermes-network-ready@vm.service)
            gateway=$(systemctl show --property=ActiveState --value hermes@vm.service)
            if [[ "$ready" != active && "$gateway" != active ]]; then
              set_output=$(nft -j list table inet hermes-agent-guard)
              if python3 -c 'import json,sys; sets=[row["set"] for row in json.load(sys.stdin)["nftables"] if "set" in row and row["set"].get("name") in ("ha0_host4","ha0_peer4","ha0_host6","ha0_peer6")]; sys.exit(0 if len(sets)==4 and all(not value.get("elem") for value in sets) else 1)' <<<"$set_output"; then
                revoked=1
                break
              fi
            fi
            sleep 0.1
          done
          elapsed=$(python3 -c 'import sys,time; print((time.monotonic_ns()-int(sys.argv[1]))//1000000)' "$started")
          [[ "$revoked" == 1 && "$elapsed" -lt 10000 ]] || { echo "$scenario failed the unchanged 10-second revocation bound: ''${elapsed}ms" >&2; return 1; }
          if [[ "$scenario" == normal-slow-stop ]]; then
            [[ "$gateway" == deactivating && "$elapsed" -lt 8000 ]] || { echo "normal revocation waited for slow gateway stop" >&2; return 1; }
            rm -f -- "$split_override"
            systemctl daemon-reload
          fi
          echo "SPLIT_LOSS_REVOKED scenario=$scenario elapsed_ms=$elapsed gateway=$gateway"
          [[ -z "$split_frozen_pid" ]] || kill -CONT "$split_frozen_pid" 2>/dev/null || true
          split_frozen_pid=
          timeout --kill-after=5s 180 systemctl stop hermes@vm.service hermes@vm-peer.service hermes-network@vm.service hermes-network@vm-peer.service || return 1
          assert_network_resources_clean ha0 hermes_agent_0 "$agent_vm_subnet4" "$agent_vm_subnet6" || return 1
          assert_network_resources_clean ha1 hermes_agent_1 "$peer_agent_subnet4" "$peer_agent_subnet6" || return 1
          systemctl reset-failed
          timeout --kill-after=5s 180 systemctl start hermes@vm.service hermes@vm-peer.service hermes-pf@vm.service hermes-pf@vm-peer.service || return 1
          wait_for_active || return 1
          assert_distinct_namespaces || return 1
        done
        start_peer_probes hermes@vm.service "$agent_vm_ip" "$agent_vm_ip6" || return 1
        start_peer_probes hermes@vm-peer.service "$peer_agent_ip" "$peer_agent_ip6" || return 1
      }

      check_ipv6_default_route_loss() {
        local anchor_pid route6 route6_after gateway route4_before route4_after started deadline ready gateway_state set_output revoked elapsed observed_route6 observer_state controller_state
        echo "Testing that live IPv6 default-route loss closes readiness while IPv4 remains routed"
        anchor_pid=$(service_pid hermes-netns@vm.service) || return 1
        route6=$(nsenter --target "$anchor_pid" --net -- ip -6 route show default dev hb0)
        gateway=$(awk '{ for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }' <<< "$route6")
        [[ -n "$gateway" ]] || { echo "No IPv6 default-route gateway was available for the loss probe: $route6" >&2; return 1; }
        route4_before=$(nsenter --target "$anchor_pid" --net -- ip -4 route show default dev hb0)
        [[ -n "$route4_before" ]] || { echo "IPv4 default route was absent before the IPv6 loss probe" >&2; return 1; }
        ipv6_route_pid="$anchor_pid"
        ipv6_route_gateway="$gateway"
        nsenter --target "$anchor_pid" --net -- ${pkgs.bash}/bin/bash -c 'set -e; printf 0 > /proc/sys/net/ipv6/conf/hb0/accept_ra'
        started=$(python3 -c 'import time; print(time.monotonic_ns())')
        disable_test_ipv6_ra ha0
        route6_after=$(nsenter --target "$anchor_pid" --net -- ip -6 route show default dev hb0 2>/dev/null || true)
        if [[ -n "$route6_after" ]]; then
          nsenter --target "$anchor_pid" --net -- ip -6 route del default dev hb0 || true
          route6_after=$(nsenter --target "$anchor_pid" --net -- ip -6 route show default dev hb0 2>/dev/null || true)
        fi
        [[ -z "$route6_after" ]] || { echo "IPv6 default route remains after deletion: $route6_after" >&2; return 1; }
        route4_after=$(nsenter --target "$anchor_pid" --net -- ip -4 route show default dev hb0 2>/dev/null || true)
        [[ -n "$route4_after" && "$route4_after" == "$route4_before" ]] || {
          echo "Removing the IPv6 route changed the independent IPv4 default route: before=$route4_before after=$route4_after" >&2
          return 1
        }
        deadline=$((SECONDS + 10))
        revoked=0
        while (( SECONDS < deadline )); do
          ready=$(systemctl show --property=ActiveState --value hermes-network-ready@vm.service)
          gateway_state=$(systemctl show --property=ActiveState --value hermes@vm.service)
          if [[ "$ready" != active && "$gateway_state" != active ]]; then
            set_output=$(nft -j list table inet hermes-agent-guard)
            if python3 -c 'import json,sys; names={"ha0_host4","ha0_peer4","ha0_host6","ha0_peer6"}; sets=[row["set"] for row in json.load(sys.stdin)["nftables"] if "set" in row and row["set"].get("name") in names]; sys.exit(0 if len(sets)==4 and all(not value.get("elem") for value in sets) else 1)' <<<"$set_output"; then
              revoked=1
              break
            fi
          fi
          sleep 0.1
        done
        elapsed=$(python3 -c 'import sys,time; print((time.monotonic_ns()-int(sys.argv[1]))//1000000)' "$started")
        if [[ "$revoked" != 1 ]]; then
          observed_route6=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["route6"])' /run/hermes-observation-vm/observation.json 2>/dev/null || printf 'unavailable')
          observer_state=$(systemctl show --property=ActiveState --value hermes-network-observer@vm.service)
          controller_state=$(systemctl show --property=ActiveState --value hermes-host-control@vm.service)
          echo "IPv6 route loss diagnostic: kernel_routes=[$route6_after] observer_record_route6=$observed_route6 observer=$observer_state controller=$controller_state readiness=$ready gateway=$gateway_state"
        fi
        [[ "$revoked" == 1 && "$elapsed" -lt 10000 ]] || {
          echo "IPv6 default-route loss did not revoke gateway authorization within the unchanged 10-second bound: ''${elapsed}ms" >&2
          return 1
        }
        echo "HERMES_VM_IPV6_DEFAULT_ROUTE_LOSS_REVOKED elapsed_ms=$elapsed ipv4_route_preserved=1"
        nsenter --target "$anchor_pid" --net -- ${pkgs.bash}/bin/bash -c 'set -e; printf 1 > /proc/sys/net/ipv6/conf/hb0/accept_ra' 2>/dev/null || true
        nsenter --target "$anchor_pid" --net -- ip -6 route replace default via "$gateway" dev hb0 2>/dev/null || true
        unset ipv6_route_pid ipv6_route_gateway
        timeout --kill-after=5s 180 systemctl stop hermes@vm.service hermes@vm-peer.service hermes-network@vm.service hermes-network@vm-peer.service || return 1
        assert_network_resources_clean ha0 hermes_agent_0 "$agent_vm_subnet4" "$agent_vm_subnet6" || return 1
        assert_network_resources_clean ha1 hermes_agent_1 "$peer_agent_subnet4" "$peer_agent_subnet6" || return 1
        restore_test_ipv6_ra || return 1
        systemctl reset-failed
        timeout --kill-after=5s 180 systemctl start hermes@vm.service hermes@vm-peer.service hermes-pf@vm.service hermes-pf@vm-peer.service || return 1
        wait_for_active || return 1
        assert_distinct_namespaces || return 1
        discover_network_values || return 1
        start_peer_probes hermes@vm.service "$agent_vm_ip" "$agent_vm_ip6" || return 1
        start_peer_probes hermes@vm-peer.service "$peer_agent_ip" "$peer_agent_ip6" || return 1
      }

      check_ipv6_default_route_startup_gate() {
        local anchor_pid route4 route6 route6_after gateway substate ready gateway_state started deadline set_output revoked gateway_start gateway_start_before elapsed
        echo "Testing initial startup remains blocked when the IPv6 default route disappears before readiness"
        stop_peer_probes
        timeout --kill-after=5s 180 systemctl stop hermes@vm.service hermes@vm-peer.service hermes-network@vm.service hermes-network@vm-peer.service || return 1
        assert_network_resources_clean ha0 hermes_agent_0 "$agent_vm_subnet4" "$agent_vm_subnet6" || return 1
        assert_network_resources_clean ha1 hermes_agent_1 "$peer_agent_subnet4" "$peer_agent_subnet6" || return 1
        install -d -m 0755 "''${ipv6_readiness_override%/*}"
        printf '[Service]\nBindReadOnlyPaths+=%s\nExecStartPre=%s/bin/sleep 20\n' "${pkgs.coreutils}" "${pkgs.coreutils}" >"$ipv6_readiness_override"
        systemctl daemon-reload
        systemctl reset-failed
        gateway_start_before=$(systemctl show --property=ExecMainStartTimestampMonotonic --value hermes@vm.service)
        systemctl --no-block start hermes@vm.service || return 1
        deadline=$((SECONDS + 180))
        while (( SECONDS < deadline )); do
          substate=$(systemctl show --property=SubState --value hermes-network-ready@vm.service)
          [[ "$substate" == start-pre ]] && break
          gateway_state=$(systemctl show --property=ActiveState --value hermes@vm.service)
          [[ "$gateway_state" != active ]] || { echo "Gateway started before the IPv6 route gate test could remove its route" >&2; return 1; }
          sleep 0.1
        done
        [[ "$substate" == start-pre ]] || { echo "Readiness did not reach the test-only start-pre barrier: $substate" >&2; return 1; }
        anchor_pid=$(service_pid hermes-netns@vm.service) || return 1
        for _ in {1..100}; do
          route4=$(nsenter --target "$anchor_pid" --net -- ip -4 route show default dev hb0)
          route6=$(nsenter --target "$anchor_pid" --net -- ip -6 route show default dev hb0)
          gateway=$(awk '{ for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }' <<< "$route6")
          [[ -n "$route4" && -n "$gateway" ]] && break
          sleep 0.1
        done
        [[ -n "$route4" && -n "$gateway" ]] || { echo "Dual-stack routes were not available before the startup loss: IPv4=[$route4] IPv6=[$route6]" >&2; return 1; }
        ipv6_route_pid="$anchor_pid"
        ipv6_route_gateway="$gateway"
        nsenter --target "$anchor_pid" --net -- ${pkgs.bash}/bin/bash -c 'set -e; printf 0 > /proc/sys/net/ipv6/conf/hb0/accept_ra'
        started=$(python3 -c 'import time; print(time.monotonic_ns())')
        disable_test_ipv6_ra ha0
        route6_after=$(nsenter --target "$anchor_pid" --net -- ip -6 route show default dev hb0 2>/dev/null || true)
        if [[ -n "$route6_after" ]]; then
          nsenter --target "$anchor_pid" --net -- ip -6 route del default dev hb0 || true
          route6_after=$(nsenter --target "$anchor_pid" --net -- ip -6 route show default dev hb0 2>/dev/null || true)
        fi
        [[ -z "$route6_after" ]] || { echo "IPv6 default route remains after the targeted loss: $route6_after" >&2; return 1; }
        [[ -n "$(nsenter --target "$anchor_pid" --net -- ip -4 route show default dev hb0)" ]] || {
          echo "IPv4 default route disappeared with the IPv6-only startup fault" >&2
          return 1
        }
        deadline=$((SECONDS + 10))
        revoked=0
        while (( SECONDS < deadline )); do
          ready=$(systemctl show --property=ActiveState --value hermes-network-ready@vm.service)
          gateway_state=$(systemctl show --property=ActiveState --value hermes@vm.service)
          gateway_start=$(systemctl show --property=ExecMainStartTimestampMonotonic --value hermes@vm.service)
          if [[ "$ready" != active && "$gateway_state" != active && "$gateway_start" == "$gateway_start_before" ]]; then
            set_output=$(nft -j list table inet hermes-agent-guard)
            if python3 -c 'import json,sys; names={"ha0_host4","ha0_peer4","ha0_host6","ha0_peer6"}; sets=[row["set"] for row in json.load(sys.stdin)["nftables"] if "set" in row and row["set"].get("name") in names]; sys.exit(0 if len(sets)==4 and all(not value.get("elem") for value in sets) else 1)' <<<"$set_output"; then
              revoked=1
              break
            fi
          fi
          sleep 0.1
        done
        elapsed=$(python3 -c 'import sys,time; print((time.monotonic_ns()-int(sys.argv[1]))//1000000)' "$started")
        [[ "$revoked" == 1 && "$elapsed" -lt 10000 ]] || {
          echo "Startup without an IPv6 default route was not kept closed within the unchanged 10-second bound: ''${elapsed}ms" >&2
          return 1
        }
        echo "HERMES_VM_IPV6_DEFAULT_ROUTE_STARTUP_BLOCKED elapsed_ms=$elapsed ipv4_route_preserved=1 gateway_start_unchanged=$gateway_start_before"
        timeout --kill-after=5s 180 systemctl stop hermes@vm.service hermes@vm-peer.service hermes-network@vm.service hermes-network@vm-peer.service || return 1
        assert_network_resources_clean ha0 hermes_agent_0 "$agent_vm_subnet4" "$agent_vm_subnet6" || return 1
        assert_network_resources_clean ha1 hermes_agent_1 "$peer_agent_subnet4" "$peer_agent_subnet6" || return 1
        restore_test_ipv6_ra || return 1
        rm -f -- "$ipv6_readiness_override"
        systemctl daemon-reload
        systemctl reset-failed
        unset ipv6_route_pid ipv6_route_gateway
        timeout --kill-after=5s 180 systemctl start hermes@vm.service hermes@vm-peer.service hermes-pf@vm.service hermes-pf@vm-peer.service || return 1
        wait_for_active || return 1
        assert_distinct_namespaces || return 1
        discover_network_values || return 1
        start_peer_probes hermes@vm.service "$agent_vm_ip" "$agent_vm_ip6" || return 1
        start_peer_probes hermes@vm-peer.service "$peer_agent_ip" "$peer_agent_ip6" || return 1
      }

      check_guard_policy_loss() {
        local set_output main_ready peer_ready main_gateway peer_gateway scenario chain
        echo "Testing per-chain missing/stale guard-policy rejection with live allocation sets"
        for scenario in input-missing forward-stale; do
          stop_peer_probes
          for entry in "ha0_peer4 $agent_vm_ip" "ha1_peer4 $peer_agent_ip"; do
            read -r set address <<< "$entry"
            set_output=$(nft -n list set inet hermes-agent-guard "$set")
            grep -Fq "$address" <<< "$set_output" || {
              echo "$set lacked its expected live address before $scenario" >&2
              return 1
            }
          done
          case "$scenario" in
            input-missing)
              chain=hermes_agent_input_guard
              nft flush chain inet hermes-agent-guard "$chain"
              ;;
            forward-stale)
              chain=hermes_agent_forward_guard
              printf 'add rule inet hermes-agent-guard %s ip saddr 203.0.113.0/24 accept comment "vm-stale-policy"\n' "$chain" | nft -f -
              ;;
          esac
          for _ in {1..100}; do
            main_ready=$(systemctl show --property=ActiveState --value hermes-network-ready@vm.service)
            peer_ready=$(systemctl show --property=ActiveState --value hermes-network-ready@vm-peer.service)
            main_gateway=$(systemctl show --property=ActiveState --value hermes@vm.service)
            peer_gateway=$(systemctl show --property=ActiveState --value hermes@vm-peer.service)
            if [[ "$main_ready" != active && "$peer_ready" != active \
              && "$main_gateway" != active && "$peer_gateway" != active ]]; then break; fi
            sleep 0.1
          done
          [[ "$main_ready" != active && "$peer_ready" != active \
            && "$main_gateway" != active && "$peer_gateway" != active ]] || {
              echo "Readiness or gateway remained active after $scenario" >&2
              return 1
            }
          assert_network_resources_clean ha0 hermes_agent_0 "$agent_vm_subnet4" "$agent_vm_subnet6" || return 1
          assert_network_resources_clean ha1 hermes_agent_1 "$peer_agent_subnet4" "$peer_agent_subnet6" || return 1
          for set in ha0_peer4 ha1_peer4; do
            set_output=$(nft -n list set inet hermes-agent-guard "$set")
            if grep -Eq 'elements[[:space:]]*=\s*\{[^}]*[0-9]' <<< "$set_output"; then
              echo "$set retained an address after $scenario" >&2
              return 1
            fi
          done
          timeout --kill-after=5s 30 systemctl restart nftables.service || { diagnose; return 1; }
          timeout --kill-after=5s 180 systemctl start hermes@vm.service hermes@vm-peer.service \
            hermes-pf@vm.service hermes-pf@vm-peer.service || { diagnose; return 1; }
          wait_for_active || { diagnose; return 1; }
          assert_distinct_namespaces || return 1
          echo "Both agents revoked and reacquired after $scenario with current policy"
        done
        start_peer_probes hermes@vm.service "$agent_vm_ip" "$agent_vm_ip6" || return 1
        start_peer_probes hermes@vm-peer.service "$peer_agent_ip" "$peer_agent_ip6" || return 1
        check_agent_network hermes@vm.service hb0 "$host_vm_ip" "$agent_vm_ip" "$peer_agent_ip" \
          "$host_vm_ip6" "$agent_vm_ip6" "$peer_agent_ip6" || return 1
        check_agent_network hermes@vm-peer.service hb1 "$host_peer_ip" "$peer_agent_ip" "$agent_vm_ip" \
          "$host_peer_ip6" "$peer_agent_ip6" "$agent_vm_ip6" || return 1
        echo "Missing input rules and stale forward policy with unchanged allocation sets revoked both agents; nftables reload restored verified policy"
      }

      check_address_dad_states() {
        local duplicate=fdde:ffff::1 usable=fdde:ffff::2 addr_json state filtered failed_json
        echo "Testing live IPv6 tentative and failed DAD, usable address and retirement filtering"
        ip link add hda0 type veth peer name hda1
        ip netns add dad-peer
        ip link set hda1 netns dad-peer
        ip link set hda0 up
        ip -n dad-peer link set lo up
        ip -n dad-peer link set dev hda1 up
        printf '1\n' >/proc/sys/net/ipv6/conf/hda0/accept_dad
        ip netns exec dad-peer ${pkgs.runtimeShell} -c 'printf 1 > /proc/sys/net/ipv6/conf/hda1/accept_dad'
        dad_setting=$(ip netns exec dad-peer cat /proc/sys/net/ipv6/conf/hda1/accept_dad)
        [[ "$dad_setting" == 1 ]] || { echo "Could not enable DAD on the namespace veth" >&2; return 1; }
        ip -6 address add "$duplicate/64" dev hda0
        for _ in {1..20}; do
          addr_json=$(ip -j -6 address show dev hda0)
          state=$(python3 -c 'import json,sys; print(any(a.get("tentative", False) for l in json.load(sys.stdin) for a in l.get("addr_info", [])))' <<<"$addr_json")
          [[ "$state" == True ]] && break
          sleep 0.01
        done
        [[ "$state" == True ]] || { echo "IPv6 duplicate-address probe never exposed tentative state" >&2; return 1; }
        filtered=$(python3 ${agentAddressFilter} inet6 64 <<<"$addr_json")
        [[ -z "$filtered" ]] || { echo "Tentative IPv6 address passed the readiness filter: $filtered" >&2; return 1; }
        for _ in {1..30}; do
          addr_json=$(ip -j -6 address show dev hda0)
          state=$(python3 -c 'import json,sys; print(any(a.get("tentative", False) for l in json.load(sys.stdin) for a in l.get("addr_info", [])))' <<<"$addr_json")
          [[ "$state" == False ]] && break
          sleep 0.1
        done
        filtered=$(python3 ${agentAddressFilter} inet6 64 <<<"$addr_json")
        [[ "$filtered" == "$duplicate" ]] || { echo "Usable DAD control was filtered: $filtered" >&2; return 1; }
        ip -n dad-peer -6 address add "$duplicate/64" dev hda1
        state=False
        for _ in {1..100}; do
          failed_json=$(ip netns exec dad-peer ip -j -6 address show dev hda1)
          state=$(python3 -c 'import json,sys; print(any(a.get("dadfailed", False) for l in json.load(sys.stdin) for a in l.get("addr_info", [])))' <<<"$failed_json")
          [[ "$state" == True ]] && break
          sleep 0.1
        done
        [[ "$state" == True ]] || {
          echo "Duplicate IPv6 address across isolated veth namespaces never reached dadfailed; JSON follows:" >&2
          printf '%s\n' "$failed_json" >&2
          return 1
        }
        filtered=$(ip netns exec dad-peer python3 ${agentAddressFilter} inet6 64 <<<"$failed_json")
        [[ -z "$filtered" ]] || { echo "dadfailed IPv6 address passed the readiness filter: $filtered" >&2; return 1; }
        ip -n dad-peer -6 address del "$duplicate/64" dev hda1
        ip -6 address del "$duplicate/64" dev hda0
        ip -6 address add "$usable/64" dev hda0
        for _ in {1..30}; do
          addr_json=$(ip -j -6 address show dev hda0)
          state=$(python3 -c 'import json,sys; print(any(a.get("tentative", False) for l in json.load(sys.stdin) for a in l.get("addr_info", [])))' <<<"$addr_json")
          [[ "$state" == False ]] && break
          sleep 0.1
        done
        filtered=$(python3 ${agentAddressFilter} inet6 64 <<<"$addr_json")
        [[ "$filtered" == "$usable" ]] || { echo "Ordinary usable SLAAC control was filtered: $filtered" >&2; return 1; }
        ip -6 address del "$usable/64" dev hda0
        filtered=$(ip -j -6 address show dev hda0 | python3 ${agentAddressFilter} inet6 64)
        [[ -z "$filtered" ]] || { echo "Retired IPv6 address remained published: $filtered" >&2; return 1; }
        ip link delete dev hda0
        ip netns del dad-peer
        echo "Tentative and live dadfailed IPv6 addresses were excluded; usable control passed and retirement cleared"
      }

      check_dad_readiness_gate() {
        local agent host_if peer_if gateway ready network dhcp client_pid peer6 host_link_local client_json failed start_before start_after ready_log recovery_units publication before_controller before_observer current_controller start_result index subnet4 subnet6
        echo "Testing main and peer readiness rejection for live dadfailed required IPv6 addresses"
        inject_dadfailed_peer_address() {
          local client_pid="$1" peer_if="$2" host_if="$3" host_link_local="$4" peer6="$5" mode="''${6:-startup}" client_json failed filtered agent observer_log
          agent=vm
          [[ "$peer_if" == hb1 ]] && agent=vm-peer
          dad_event_observed=0
          dad_namespace_revoked=0
          exec {dad_netns_fd}<"/proc/$client_pid/ns/net" || return 1
          dad_netns_path="/proc/$$/fd/$dad_netns_fd" dad_peer_if="$peer_if" dad_test_address="$peer6" dad_sender_log="/run/hermes-vm-dad-$agent.log"
          python3 ${vmDadInjector} "$host_if" "$host_link_local" "$peer6" >"$dad_sender_log" 2>&1 &
          dad_sender_pid=$!
          nsenter --net="$dad_netns_path" -- ip -6 address del "$peer6/64" dev "$peer_if" || return 1
          nsenter --net="$dad_netns_path" -- ip -6 address add "$peer6/64" dev "$peer_if" || return 1
          failed=
          for _ in {1..100}; do
            if ! client_json=$(nsenter --net="$dad_netns_path" -- ip -j -6 address show dev "$peer_if" 2>/dev/null); then
              if [[ "$mode" == active ]]; then
                dad_namespace_revoked=1
                echo "$peer_if namespace was revoked before DAD status could be re-read"
                return 0
              fi
              grep -Fq 'VM_DAD_NA_SENT first=1' "$dad_sender_log" || {
                cat "$dad_sender_log" >&2
                echo "$peer_if namespace stopped before a controlled DAD advertisement was sent" >&2
                return 1
              }
              observer_log=$(journalctl -u "hermes-network-observer@$agent.service" -b --no-pager -o cat)
              if grep -Fq "SLAAC DAD failed on $peer_if" <<< "$observer_log"; then
                dad_event_observed=1
                echo "$peer_if observer confirmed DAD failure before its dependent namespace was revoked"
              else
                dad_namespace_revoked=1
                echo "$peer_if dependent namespace was revoked after the controlled DAD advertisement"
              fi
              return 0
            fi
            failed=$(python3 -c 'import json,sys; print(any(a.get("dadfailed", False) and a.get("local") == sys.argv[1] for l in json.load(sys.stdin) for a in l.get("addr_info", [])))' "$peer6" <<<"$client_json")
            if [[ "$failed" == True ]]; then dad_event_observed=1; break; fi
            sleep 0.1
          done
          [[ "$failed" == True ]] || {
            cat "$dad_sender_log" >&2 || true
            echo "No live dadfailed required address $peer6 on $peer_if; address JSON follows:" >&2
            printf '%s\n' "$client_json" >&2
            return 1
          }
          filtered=$(python3 ${agentAddressFilter} inet6 64 <<<"$client_json")
          if grep -Fxq "$peer6" <<<"$filtered"; then
            echo "$peer_if address filter published its dadfailed IPv6 identity" >&2
            return 1
          fi
          grep -Fq 'VM_DAD_NA_SENT first=1' "$dad_sender_log" || {
            cat "$dad_sender_log" >&2
            echo "$peer_if did not receive the controlled DAD neighbor advertisement" >&2
            return 1
          }
        }
        wait_gateway_ready() {
          local gateway="$1" ready="$2"
          for _ in {1..900}; do
            if [[ $(systemctl show --property=ActiveState --value "$gateway") == active \
              && $(systemctl show --property=ActiveState --value "$ready") == active ]]; then return 0; fi
            sleep 0.1
          done
          echo "$gateway did not recover with its network readiness barrier within 90s" >&2
          return 1
        }
        stop_peer_probes
        timeout --kill-after=5s 60 systemctl stop hermes@vm.service hermes@vm-peer.service || { diagnose; return 1; }
        assert_network_resources_clean ha0 hermes_agent_0 "$agent_vm_subnet4" "$agent_vm_subnet6" || return 1
        assert_network_resources_clean ha1 hermes_agent_1 "$peer_agent_subnet4" "$peer_agent_subnet6" || return 1
        for agent in vm vm-peer; do
          if [[ "$agent" == vm ]]; then
            host_if=ha0; peer_if=hb0; subnet4="$agent_vm_subnet4"; subnet6="$agent_vm_subnet6"
          else
            host_if=ha1; peer_if=hb1; subnet4="$peer_agent_subnet4"; subnet6="$peer_agent_subnet6"
          fi
          gateway="hermes@$agent.service"
          ready="hermes-network-ready@$agent.service"
          network="hermes-network@$agent.service"
          dhcp="hermes-dhcp@$agent.service"
          timeout --kill-after=5s 90 systemctl start "$ready" || { diagnose; return 1; }
          [[ $(systemctl show --property=ActiveState --value "$ready") == active ]] || {
            echo "$ready did not establish a valid pre-DAD readiness baseline" >&2
            diagnose
            return 1
          }
          client_pid=$(service_pid "$dhcp") || return 1
          peer6=$(nsenter --target "$client_pid" --net -- ip -j -6 address show dev "$peer_if" | python3 ${agentAddressFilter} inet6 64 | awk 'NR == 1 { print; exit }')
          [[ -n "$peer6" ]] || { echo "$peer_if has no usable peer IPv6 allocation after readiness" >&2; return 1; }
          host_link_local=$(ip -j -6 address show dev "$host_if" | python3 -c 'import json,sys; print(next((a["local"] for link in json.load(sys.stdin) for a in link.get("addr_info", []) if a.get("family") == "inet6" and a.get("scope") == "link"), ""))')
          [[ -n "$host_link_local" ]] || { echo "$host_if has no host link-local IPv6 source" >&2; return 1; }
          index=0
          [[ "$agent" == vm-peer ]] && index=1
          publication="/run/hermes-agent-network-$index"
          before_controller=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["controller"])' "$publication/authorization.json")
          before_observer=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["invocation"])' "/run/hermes-observation-$agent/observation.json")
          inject_dadfailed_peer_address "$client_pid" "$peer_if" "$host_if" "$host_link_local" "$peer6" || return 1
          start_before=$(systemctl show --property=ExecMainStartTimestampMonotonic --value "$gateway")
          if timeout --kill-after=5s 60 systemctl start "$gateway"; then start_result=0; else start_result=$?; fi
          start_after=$(systemctl show --property=ExecMainStartTimestampMonotonic --value "$gateway")
          if [[ "$start_after" != "$start_before" ]]; then
            wait_gateway_ready "$gateway" "$ready" || { diagnose; return 1; }
            current_controller=$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); a=json.load(open(sys.argv[2])); o=json.load(open(sys.argv[3])); assert a["authorized"] is True and a["generation"] == c["generation"]; assert a["controller"] != sys.argv[4]; assert o["generation"] == c["generation"] and o["invocation"] == a["observer"]; assert o["peer4"] and o["peer6"] and o["route4"] and o["route6"] and not o["dadfailed"]; assert o["invocation"] != sys.argv[5]; print(a["controller"])' "$publication/config.json" "$publication/authorization.json" "/run/hermes-observation-$agent/observation.json" "$before_controller" "$before_observer") || { echo "$gateway started without a new authorized observer generation" >&2; return 1; }
            echo "$agent gateway ExecStart followed fresh controller authorization $current_controller after DAD revocation"
            cleanup_dad_fault
            if [[ "$agent" == vm-peer ]]; then discover_network_values || return 1; fi
            continue
          fi
          [[ "$start_result" != 0 ]] || { echo "$gateway start returned success without a fresh ExecStart" >&2; return 1; }
          [[ "$start_after" == "$start_before" ]] || { echo "$gateway ExecStart ran without a new network generation" >&2; return 1; }
          for _ in {1..50}; do
            [[ $(systemctl show --property=ActiveState --value "$ready") == failed ]] && break
            sleep 0.1
          done
          [[ $(systemctl show --property=ActiveState --value "$ready") != active ]] || {
            echo "$ready remained active after its required IPv6 address failed DAD" >&2
            return 1
          }
          if (( dad_event_observed )); then
            ready_log=$(journalctl -u "hermes-network-observer@$agent.service" -b --no-pager -o cat)
            grep -Fq "SLAAC DAD failed on $peer_if" <<< "$ready_log" || {
              echo "$peer_if observer did not report its required DAD failure" >&2
              return 1
            }
            echo "$agent kept ExecStart blocked for dadfailed required address $peer6"
          else
            [[ $dad_namespace_revoked == 1 ]] || { echo "$agent DAD failure was neither observed nor revoked" >&2; return 1; }
            assert_network_resources_clean "$host_if" "hermes_agent_''${host_if#ha}" "$subnet4" "$subnet6" || return 1
            echo "$agent startup stayed closed after DAD and dependent namespace teardown"
          fi
          cleanup_dad_fault
          timeout 30s systemctl reset-failed "$gateway" "$network" "$dhcp" "$ready"
          timeout --kill-after=5s 180 systemctl start "$gateway" || { diagnose; return 1; }
          wait_gateway_ready "$gateway" "$ready" || { diagnose; return 1; }
          if [[ "$agent" == vm-peer ]]; then discover_network_values || return 1; fi
        done
        for agent in vm vm-peer; do
          if [[ "$agent" == vm ]]; then
            host_if=ha0; peer_if=hb0; subnet4="$agent_vm_subnet4"; subnet6="$agent_vm_subnet6"
          else
            host_if=ha1; peer_if=hb1; subnet4="$peer_agent_subnet4"; subnet6="$peer_agent_subnet6"
          fi
          gateway="hermes@$agent.service"
          ready="hermes-network-ready@$agent.service"
          dhcp="hermes-dhcp@$agent.service"
          client_pid=$(service_pid "$dhcp") || return 1
          peer6=$(nsenter --target "$client_pid" --net -- ip -j -6 address show dev "$peer_if" | python3 ${agentAddressFilter} inet6 64 | awk 'NR == 1 { print; exit }')
          [[ -n "$peer6" ]] || { echo "$peer_if has no usable IPv6 allocation for address-loss test" >&2; return 1; }
          host_link_local=$(ip -j -6 address show dev "$host_if" | python3 -c 'import json,sys; print(next((a["local"] for link in json.load(sys.stdin) for a in link.get("addr_info", []) if a.get("family") == "inet6" and a.get("scope") == "link"), ""))')
          [[ -n "$host_link_local" ]] || { echo "$host_if has no host link-local IPv6 source for address-loss test" >&2; return 1; }
          inject_dadfailed_peer_address "$client_pid" "$peer_if" "$host_if" "$host_link_local" "$peer6" active || return 1
          for _ in {1..100}; do
            if [[ $(systemctl show --property=ActiveState --value "$ready") != active \
              && $(systemctl show --property=ActiveState --value "$gateway") != active ]]; then break; fi
            sleep 0.1
          done
          [[ $(systemctl show --property=ActiveState --value "$ready") != active \
            && $(systemctl show --property=ActiveState --value "$gateway") != active ]] || {
            echo "$agent retained readiness/application after its IPv6 identity entered dadfailed" >&2
            return 1
          }
          ready_log=$(journalctl -u "hermes-network-observer@$agent.service" -b --no-pager -o cat)
          if (( dad_event_observed )); then
            grep -Fq "SLAAC DAD failed on $peer_if" <<< "$ready_log" || {
              echo "$agent observer did not report live DAD failure" >&2
              return 1
            }
          fi
          echo "$agent revoked its active firewall generation and stopped after IPv6 DAD failure"
          assert_network_resources_clean "$host_if" "hermes_agent_''${host_if#ha}" "$subnet4" "$subnet6" || return 1
          [[ ! -e "/run/hermes-agent-network-''${host_if#ha}/authorization.json" ]] || {
            echo "$agent retained stale network authorization after active DAD failure" >&2
            return 1
          }
          cleanup_dad_fault
          timeout 30s systemctl reset-failed "$gateway" "hermes-network@$agent.service" "$dhcp" "$ready"
          recovery_units=("$gateway")
          if [[ "$agent" == vm ]]; then recovery_units+=(hermes@vm-peer.service); fi
          timeout --kill-after=5s 180 systemctl start "''${recovery_units[@]}" || { diagnose; return 1; }
          wait_gateway_ready "$gateway" "$ready" || { diagnose; return 1; }
          discover_network_values || return 1
        done
        timeout --kill-after=5s 180 systemctl start hermes-pf@vm.service hermes-pf@vm-peer.service || { diagnose; return 1; }
        wait_for_active || { diagnose; return 1; }
        echo "Main and peer gateways recovered only after DHCP/SLAAC and verified firewall readiness were restored"
      }

      check_nft_startup_failure_gate() {
        local main_start peer_start
        echo "Testing bounded startup failure when nftables allocation/policy publication is unavailable"
        stop_peer_probes
        timeout --kill-after=5s 60 systemctl stop hermes@vm.service hermes@vm-peer.service || { diagnose; return 1; }
        assert_network_resources_clean ha0 hermes_agent_0 "$agent_vm_subnet4" "$agent_vm_subnet6" || return 1
        assert_network_resources_clean ha1 hermes_agent_1 "$peer_agent_subnet4" "$peer_agent_subnet6" || return 1
        main_start=$(systemctl show --property=ExecMainStartTimestampMonotonic --value hermes@vm.service)
        peer_start=$(systemctl show --property=ExecMainStartTimestampMonotonic --value hermes@vm-peer.service)
        nft flush table inet hermes-agent-guard
        for unit in hermes@vm.service hermes@vm-peer.service; do
          if timeout --kill-after=5s 60 systemctl start "$unit"; then
            echo "$unit unexpectedly started without its declarative nftables guard table" >&2
            return 1
          fi
        done
        [[ "$(systemctl show --property=ExecMainStartTimestampMonotonic --value hermes@vm.service)" == "$main_start" \
          && "$(systemctl show --property=ExecMainStartTimestampMonotonic --value hermes@vm-peer.service)" == "$peer_start" ]] || {
            echo "Gateway ExecStart ran while nftables publication was unavailable" >&2
            return 1
          }
        for unit in hermes-network-ready@vm.service hermes-network-ready@vm-peer.service; do
          [[ "$(systemctl show --property=ActiveState --value "$unit")" != active ]] || {
            echo "$unit reported ready without the nftables guard table" >&2
            return 1
          }
        done
        timeout --kill-after=5s 30 systemctl restart nftables.service || { diagnose; return 1; }
        timeout 30s systemctl reset-failed hermes@vm.service hermes@vm-peer.service hermes-network@vm.service \
          hermes-network@vm-peer.service hermes-dhcp@vm.service hermes-dhcp@vm-peer.service \
          hermes-network-ready@vm.service hermes-network-ready@vm-peer.service
        timeout --kill-after=5s 180 systemctl start hermes@vm.service hermes@vm-peer.service \
          hermes-pf@vm.service hermes-pf@vm-peer.service || { diagnose; return 1; }
        wait_for_active || { diagnose; return 1; }
        start_peer_probes hermes@vm.service "$agent_vm_ip" "$agent_vm_ip6" || return 1
        start_peer_probes hermes@vm-peer.service "$peer_agent_ip" "$peer_agent_ip6" || return 1
        echo "Both gateways remained blocked during nftables publication failure and recovered after declarative reload"
      }

      check_nft_readback_exit_status() {
        "${pkgs.python3}/bin/python3" -I -B ${vmNetworkRecordTests} ${networkRecordPath} \
          ${../modules/services/agent/hermes-network/setup.py} ${hostRecordPath} ${vmNetworkObserver}
      }

      check_nft_policy_startup_gate() {
        local scenario chain other_chain other_before start_before start_after ready_log controller_unit controller_log
        prime_dhcp_clients() {
          local main_dhcp peer_dhcp main4 peer4 main6 peer6
          timeout --kill-after=5s 90 systemctl start hermes-network@vm.service hermes-dhcp@vm.service \
            hermes-network@vm-peer.service hermes-dhcp@vm-peer.service || return 1
          for _ in {1..300}; do
            main_dhcp=$(systemctl show --property=MainPID --value hermes-dhcp@vm.service)
            peer_dhcp=$(systemctl show --property=MainPID --value hermes-dhcp@vm-peer.service)
            if [[ "$main_dhcp" =~ ^[1-9][0-9]*$ && "$peer_dhcp" =~ ^[1-9][0-9]*$ ]]; then
              main4=$(nsenter --target "$main_dhcp" --net -- ip -o -4 address show dev hb0 scope global)
              peer4=$(nsenter --target "$peer_dhcp" --net -- ip -o -4 address show dev hb1 scope global)
              main6=$(nsenter --target "$main_dhcp" --net -- ip -o -6 address show dev hb0 scope global | grep -vE ' tentative|deprecated' || true)
              peer6=$(nsenter --target "$peer_dhcp" --net -- ip -o -6 address show dev hb1 scope global | grep -vE ' tentative|deprecated' || true)
              if [[ "$main4" == *"inet "* && "$peer4" == *"inet "* \
                && -n "$main6" && -n "$peer6" \
                && $(nsenter --target "$main_dhcp" --net -- ip -4 route show default) == *"default "* \
                && $(nsenter --target "$peer_dhcp" --net -- ip -4 route show default) == *"default "* \
                && $(nsenter --target "$main_dhcp" --net -- ip -6 route show default) == *"default "* \
                && $(nsenter --target "$peer_dhcp" --net -- ip -6 route show default) == *"default "* ]]; then
                echo "Both DHCP/SLAAC client namespaces acquired addresses and routes before policy mutation"
                return 0
              fi
            fi
            sleep 0.1
          done
          echo "Could not prime both DHCP/SLAAC clients before startup policy mutation" >&2
          return 1
        }
        echo "Testing main and peer startup rejection for independently missing/stale nftables policy"
        stop_peer_probes
        for scenario in input-missing forward-stale; do
          case "$scenario" in
            input-missing) chain=hermes_agent_input_guard; other_chain=hermes_agent_forward_guard ;;
            forward-stale) chain=hermes_agent_forward_guard; other_chain=hermes_agent_input_guard ;;
          esac
          other_before=$(nft -n list chain inet hermes-agent-guard "$other_chain") || return 1
          timeout --kill-after=5s 60 systemctl stop hermes@vm.service hermes@vm-peer.service || { diagnose; return 1; }
          assert_network_resources_clean ha0 hermes_agent_0 "$agent_vm_subnet4" "$agent_vm_subnet6" || return 1
          assert_network_resources_clean ha1 hermes_agent_1 "$peer_agent_subnet4" "$peer_agent_subnet6" || return 1
          prime_dhcp_clients || { diagnose; return 1; }
          case "$scenario" in
            input-missing) nft flush chain inet hermes-agent-guard "$chain" ;;
            forward-stale)
              printf 'add rule inet hermes-agent-guard %s ip saddr 203.0.113.0/24 accept comment "vm-startup-stale-policy"\n' "$chain" | nft -f -
              ;;
          esac
          for unit in hermes@vm.service hermes@vm-peer.service; do
            start_before=$(systemctl show --property=ExecMainStartTimestampMonotonic --value "$unit")
            if timeout --kill-after=5s 60 systemctl start "$unit"; then
              echo "$unit unexpectedly started with $scenario" >&2
              return 1
            fi
            start_after=$(systemctl show --property=ExecMainStartTimestampMonotonic --value "$unit")
            [[ "$start_after" == "$start_before" ]] || {
              echo "$unit ExecStart ran before policy readback rejected $scenario" >&2
              return 1
            }
            [[ "$(systemctl show --property=ActiveState --value "hermes-network-ready@''${unit#hermes@}")" != active ]] || {
              echo "$unit reported readiness with $scenario" >&2
              return 1
            }
            controller_unit="hermes-host-control@''${unit#hermes@}"
            controller_log=$(journalctl -u "$controller_unit" -b --no-pager -o cat)
            grep -Fq 'current nftables guard policy readback failed' <<< "$controller_log" || {
              echo "$controller_unit did not report policy readback rejection for $unit/$scenario" >&2
              return 1
            }
            if grep -Fq 'firewall set readback did not match allocation' <<< "$controller_log"; then
              echo "$unit failed allocation publication/readback instead of policy readback for $scenario" >&2
              return 1
            fi
            assert_network_resources_clean ha0 hermes_agent_0 "$agent_vm_subnet4" "$agent_vm_subnet6" || return 1
            assert_network_resources_clean ha1 hermes_agent_1 "$peer_agent_subnet4" "$peer_agent_subnet6" || return 1
            timeout 30s systemctl reset-failed "''${units[@]}" hermes-network-failure@vm.service hermes-network-failure@vm-peer.service
          done
          [[ "$(nft -n list chain inet hermes-agent-guard "$other_chain")" == "$other_before" ]] || {
            echo "$scenario unexpectedly changed the other nftables guard chain" >&2
            return 1
          }
          timeout --kill-after=5s 60 systemctl stop hermes@vm.service hermes@vm-peer.service || return 1
          assert_network_resources_clean ha0 hermes_agent_0 "$agent_vm_subnet4" "$agent_vm_subnet6" || return 1
          assert_network_resources_clean ha1 hermes_agent_1 "$peer_agent_subnet4" "$peer_agent_subnet6" || return 1
          timeout --kill-after=5s 30 systemctl restart nftables.service || { diagnose; return 1; }
          timeout 30s systemctl reset-failed "''${units[@]}"
          timeout --kill-after=5s 180 systemctl start hermes@vm.service hermes@vm-peer.service \
            hermes-pf@vm.service hermes-pf@vm-peer.service || { diagnose; return 1; }
          wait_for_active || { diagnose; return 1; }
          assert_distinct_namespaces || return 1
          echo "Main and peer gateway ExecStart stayed blocked until nftables restored $scenario policy"
        done
        start_peer_probes hermes@vm.service "$agent_vm_ip" "$agent_vm_ip6" || return 1
        start_peer_probes hermes@vm-peer.service "$peer_agent_ip" "$peer_agent_ip6" || return 1
      }

      check_networkd_restart_recovery() {
        local old_pid old_netns old_netns_fd old_netns_fd_path old_mac new_pid new_mac ready_main ready_peer
        echo "Testing networkd restart recovery and namespace replacement"
        stop_peer_probes
        old_pid=$(service_pid hermes@vm.service) || return 1
        exec {old_netns_fd}<"/proc/$old_pid/ns/net" || { echo "Could not pin the old network namespace" >&2; return 1; }
        old_netns_fd_path="/proc/$$/fd/$old_netns_fd"
        old_netns=$(readlink "$old_netns_fd_path")
        old_mac=$(nsenter --target "$old_pid" --net -- ip -o link show dev hb0 | awk '{ for (i = 1; i <= NF; i++) if ($i == "link/ether") print $(i + 1) }')
        [[ "$old_mac" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || { echo "Could not read the pre-restart DHCP client MAC" >&2; return 1; }
        timeout --kill-after=5s 120 systemctl restart systemd-networkd.service || { diagnose; return 1; }
        for _ in {1..600}; do
          ready_main=$(systemctl show --property=ActiveState --value hermes-network-ready@vm.service)
          ready_peer=$(systemctl show --property=ActiveState --value hermes-network-ready@vm-peer.service)
          [[ "$ready_main" == active && "$ready_peer" == active ]] && break
          sleep 0.2
        done
        [[ "$ready_main" == active && "$ready_peer" == active ]] || { echo "DHCP/SLAAC/firewall readiness did not recover after networkd restart" >&2; diagnose; return 1; }
        new_pid=$(service_pid hermes-dhcp@vm.service) || return 1
        new_mac=$(nsenter --target "$new_pid" --net -- ip -o link show dev hb0 | awk '{ for (i = 1; i <= NF; i++) if ($i == "link/ether") print $(i + 1) }')
        [[ "$new_mac" == "$old_mac" ]] || { echo "DHCP client MAC changed across namespace replacement: $old_mac -> $new_mac" >&2; return 1; }
        assert_namespace_released "$old_netns" "$old_netns_fd_path" || { exec {old_netns_fd}<&-; return 1; }
        exec {old_netns_fd}<&-
        echo "networkd restart reacquired DHCP/SLAAC and verified firewall/DNS readiness with stable DHCP client identity ($new_mac)"
        wait_for_active || { diagnose; return 1; }
        new_pid=$(service_pid hermes@vm.service) || return 1
        [[ "$new_pid" != "$old_pid" ]] || { echo "Gateway did not restart after networkd restart" >&2; return 1; }
        start_peer_probes hermes@vm.service "$agent_vm_ip" "$agent_vm_ip6" || return 1
        start_peer_probes hermes@vm-peer.service "$peer_agent_ip" "$peer_agent_ip6" || return 1
        check_agent_network hermes@vm.service hb0 "$host_vm_ip" "$agent_vm_ip" "$peer_agent_ip" "$host_vm_ip6" "$agent_vm_ip6" "$peer_agent_ip6" || return 1
        echo "networkd restart rebuilt DHCP/SLAAC, firewall and DNS in fresh namespaces with stable DHCP client identity ($new_mac)"
      }

      assert_network_resources_clean() {
        local iface="$1" table="$2" subnet="$3" subnet6="$4" network_unit state job route4 route6 port agent unit
        local deadline=$((SECONDS + 30))
        local -a mapped_host_ports=()
        network_unit=hermes-network@''${iface#ha}.service
        agent=vm
        if [[ "$iface" == ha0 ]]; then network_unit=hermes-network@vm.service; fi
        if [[ "$iface" == ha1 ]]; then network_unit=hermes-network@vm-peer.service; agent=vm-peer; fi
        # One bounded cleanup budget covers the 15s networkd lock and unit stop timeout.
        for unit in "$network_unit" "hermes-host-control@$agent.service" "hermes-network-failure@$agent.service" "hermes-network-observer@$agent.service" "hermes-dhcp@$agent.service" "hermes-network-ready@$agent.service" "hermes-netns@$agent.service"; do
          state=active
          while (( SECONDS < deadline )); do
            state=$(systemctl show --property=ActiveState --value "$unit")
            job=$(systemctl show --property=Job --value "$unit")
            [[ ( "$state" == inactive || "$state" == failed ) && ( "$job" == 0 || -z "$job" ) ]] && break
            sleep 0.1
          done
          [[ ( "$state" == inactive || "$state" == failed ) && ( "$job" == 0 || -z "$job" ) ]] || { echo "$unit did not finish teardown: state=$state job=$job" >&2; return 1; }
        done
        if ip link show dev "$iface" >/dev/null 2>&1; then
          echo "Stale host veth remains after stopping agent: $iface" >&2
          return 1
        fi
        if nft list table inet "$table" >/dev/null 2>&1; then
          echo "Stale per-agent runtime nftables table remains after stopping agent: $table" >&2
          return 1
        fi
        host_dns_ip=''${host_vm_ip}
        host_dns_ip6=''${host_vm_ip6}
        if [[ "$iface" == ha1 ]]; then
          host_dns_ip=''${host_peer_ip}
          host_dns_ip6=''${host_peer_ip6}
        fi
        if ss -H -lunpt 'sport = :53' | grep -Fq "$host_dns_ip:53"; then
          echo "Stale Hermes DNS listener remains after stopping agent $iface: $host_dns_ip:53" >&2
          return 1
        fi
        if ss -H -lunpt 'sport = :53' | grep -Fq "[$host_dns_ip6]:53"; then
          echo "Stale Hermes IPv6 DNS listener remains after stopping agent $iface: [$host_dns_ip6]:53" >&2
          return 1
        fi
        nft list table inet hermes-agent-guard >/dev/null || { echo "Declarative Hermes firewall guard is missing" >&2; return 1; }
        route4=$(ip -4 route show table all | grep -F "$subnet" || true)
        if [[ -n "$route4" ]]; then
          echo "Stale Hermes IPv4 route remains after stopping agent $iface: $route4" >&2
          return 1
        fi
        route6=$(ip -6 route show table all | grep -F "$subnet6" || true)
        if [[ -n "$route6" ]]; then
          echo "Stale Hermes IPv6 route remains after stopping agent $iface: $route6" >&2
          return 1
        fi
        if [[ "$iface" == ha0 ]]; then mapped_host_ports=("$dashboard_host_port"); else mapped_host_ports=("''${peer_host_ports[@]}"); fi
        for port in "''${mapped_host_ports[@]}"; do
          if ss -H -ltn "sport = :$port" | grep -q . || ss -H -lun "sport = :$port" | grep -q .; then
            echo "Stale host port mapping remains after stopping agent $iface: $port" >&2
            return 1
          fi
        done
        echo "No stale veth, route, or nftables table for $iface"
      }

      start_fail_closed_probe() {
        local main_pid main_netns state invocation_id invocation_log failure_unit failure_before failure_after failure_status failure_log controller controller_before proxy_unit
        local -a proxy_units=(hermes-dns@vm.service hermes-host-proxy@vm.service hermes-agent-relay@vm.service)
        echo "Testing fail-closed startup with a conflicting reserved interface"
        failure_unit=hermes-network-failure@vm.service
        main_pid=$(service_pid hermes@vm.service)
        main_netns=$(readlink "/proc/$main_pid/ns/net")
        timeout --kill-after=5s 60 systemctl stop hermes@vm.service || { diagnose; return 1; }
        assert_network_resources_clean ha0 hermes_agent_0 "''${agent_vm_subnet4}" "''${agent_vm_subnet6}" || return 1
        assert_namespace_released "$main_netns" || return 1
        ip link add ha0 type dummy
        failure_before=$(systemctl show --property=InvocationID --value "$failure_unit")
        timeout --kill-after=5s 30 systemctl start hermes@vm.service || true
        sleep 2
        if [[ $(systemctl show --property=ActiveState --value hermes@vm.service) == active \
          || $(systemctl show --property=ActiveState --value hermes-network@vm.service) == active ]]; then
          echo "Agent/network helper became active despite its reserved veth name being occupied" >&2
          return 1
        fi
        ip -d link show dev ha0 | grep -q 'alias hermes-agent-vm' && { echo "Failure cleanup deleted/claimed the conflicting link" >&2; return 1; }
        ip link delete dev ha0
        assert_network_resources_clean ha0 hermes_agent_0 "''${agent_vm_subnet4}" "''${agent_vm_subnet6}" || return 1
        failure_after=$(systemctl show --property=InvocationID --value "$failure_unit")
        failure_status=$(systemctl show --property=ExecMainStatus --value "$failure_unit")
        [[ -n "$failure_after" && "$failure_after" != "$failure_before" && "$failure_status" == 0 ]] || {
          echo "Host-control failure did not run the successful namespace reaper: invocation=$failure_after status=$failure_status" >&2
          return 1
        }
        failure_log=$(journalctl -b "_SYSTEMD_UNIT=$failure_unit" "_SYSTEMD_INVOCATION_ID=$failure_after" --no-pager -o cat)
        if ! grep -Fq "PAYLOAD_BOUNDARY_PASSED role=network-failure" <<< "$failure_log" \
          || ! grep -Fq "NETWORK_FAILURE_REAPER_QUEUED unit=hermes-netns@vm.service" <<< "$failure_log"; then
          echo "$failure_unit did not prove its confined asynchronous anchor-stop request" >&2
          return 1
        fi
        timeout 30s systemctl reset-failed hermes@vm.service hermes-network@vm.service
        timeout --kill-after=5s 180 systemctl start hermes@vm.service || { diagnose; return 1; }
        timeout --kill-after=5s 180 systemctl start hermes@vm-peer.service hermes-pf@vm.service hermes-pf@vm-peer.service || { diagnose; return 1; }
        wait_for_active || { diagnose; return 1; }
        echo "Interface-collision failure preserved unrelated interface ha0"
        main_pid=$(service_pid hermes@vm.service)
        main_netns=$(readlink "/proc/$main_pid/ns/net")
        timeout --kill-after=5s 60 systemctl stop hermes@vm.service || { diagnose; return 1; }
        assert_network_resources_clean ha0 hermes_agent_0 "''${agent_vm_subnet4}" "''${agent_vm_subnet6}" || return 1
        assert_namespace_released "$main_netns" || return 1
        ip link add hvm-overlap type dummy || return 1
        ip link set hvm-overlap up || return 1
        ip route add "''${agent_vm_subnet4}" dev hvm-overlap || return 1
        controller=hermes-host-control@vm.service
        controller_before=$(systemctl show --property=InvocationID --value "$controller")
        timeout --kill-after=5s 60 systemctl start hermes@vm.service || true
        for _ in {1..100}; do
          state=$(systemctl show --property=ActiveState --value "$controller")
          [[ "$state" == failed || "$state" == inactive ]] && break
          sleep 0.1
        done
        [[ "$state" == failed ]] || { echo "Host controller did not fail on an overlapping host route: $state" >&2; return 1; }
        [[ $(systemctl show --property=ActiveState --value hermes@vm.service) != active ]] || { echo "Gateway started despite the rejected overlapping route" >&2; return 1; }
        invocation_id=$(systemctl show --property=InvocationID --value "$controller")
        [[ -n "$invocation_id" && "$invocation_id" != "$controller_before" ]] || { echo "Host controller did not run for the overlapping route" >&2; return 1; }
        invocation_log=$(journalctl -b "_SYSTEMD_UNIT=$controller" "_SYSTEMD_INVOCATION_ID=$invocation_id" --no-pager -o cat)
        grep -Fq "overlaps host route" <<< "$invocation_log" || { echo "Host controller did not report its route-overlap failure" >&2; return 1; }
        for proxy_unit in "''${proxy_units[@]}"; do
          [[ $(systemctl show --property=ActiveState --value "$proxy_unit") != active ]] || {
            echo "$proxy_unit remained active despite host route-overlap rejection" >&2
            return 1
          }
        done
        [[ ! -e /run/hermes-agent-network-0/authorization.json ]] || { echo "Route-overlap failure published network authorization" >&2; return 1; }
        if ip link show dev ha0 >/dev/null 2>&1; then echo "Route-overlap failure left its Hermes veth" >&2; return 1; fi
        ip route del "''${agent_vm_subnet4}" dev hvm-overlap || return 1
        ip link delete dev hvm-overlap || return 1
        assert_network_resources_clean ha0 hermes_agent_0 "''${agent_vm_subnet4}" "''${agent_vm_subnet6}" || return 1
        timeout 30s systemctl reset-failed hermes@vm.service hermes-network@vm.service
        timeout --kill-after=5s 180 systemctl start hermes@vm.service hermes@vm-peer.service hermes-pf@vm.service hermes-pf@vm-peer.service || { diagnose; return 1; }
        wait_for_active || { diagnose; return 1; }
        echo "Route-overlap failure exited before gateway/proxy startup and cleaned owned resources"
      }

      if ! wait_for_active; then diagnose; exit 1; fi
      if [[ "''${HERMES_VM_DEFAULT_ON_TEST:-0}" == 1 ]]; then
        check_default_on_features || { diagnose; exit 1; }
      fi
      if [[ "$HERMES_VM_DAD_PROBE_ONLY" == 1 ]]; then
        check_address_dad_states || { diagnose; exit 1; }
        echo "Hermes live DAD probe passed"
        exit 0
      fi
      check_nft_readback_exit_status || { diagnose; exit 1; }
      host_other_ip=$(ip -o -4 address show scope global | awk '$2 != "ha0" && $2 != "ha1" { split($4, a, "/"); print a[1]; exit }')
      [[ -n "$host_other_ip" ]] || { echo "No non-veth host interface address is available for the isolation probe" >&2; diagnose; exit 1; }
      if [[ "$HERMES_VM_INTERNET_TEST" == 1 ]]; then
        if ! grep -Fxq 'nameserver 127.0.0.1' /etc/resolv.conf || grep -Fq 'nameserver 1.1.1.1' /etc/resolv.conf; then
          echo "Internet fixture host resolver must use its local stub; host dnsmasq owns the public upstream" >&2
          cat /etc/resolv.conf >&2
          exit 1
        fi
      else
        [[ "$(awk '$1 == "nameserver" { if (NF != 2) exit 2; print $2 }' /etc/resolv.conf)" == 127.0.0.1 ]] || { echo "Offline fixture must have exactly one host-only DNS nameserver" >&2; cat /etc/resolv.conf >&2; exit 1; }
      fi
      [[ -e /run/hermes-vm-resolver-ready ]] || { echo "Late resolver fixture did not finish before agent startup" >&2; exit 1; }
      echo "Agent network setup waited for the late host resolver fixture"
      echo "Host UDP/TCP DNS listeners:"
      ss -H -lunpt 'sport = :53'
      echo "Starting positive-control host TCP/UDP listeners"
      "${lib.getExe' pkgs.python3 "python3"}" ${vmNetworkProbeServer} host >/run/hermes-vm-host-probes.log 2>&1 &
      host_probe_pid=$!
      for _ in {1..30}; do
        if ss -H -ltn 'sport = :18083' | grep -q . && ss -H -lun 'sport = :18083' | grep -q .; then break; fi
        sleep 0.1
      done
      ss -H -ltn 'sport = :18083' || { cat /run/hermes-vm-host-probes.log >&2; diagnose; exit 1; }
      ss -H -lun 'sport = :18083' || { cat /run/hermes-vm-host-probes.log >&2; diagnose; exit 1; }
      udp_probe 127.0.0.1 18083 || { echo "Host UDP echo positive control failed on loopback" >&2; cat /run/hermes-vm-host-probes.log >&2; diagnose; exit 1; }
      echo "Host TCP/UDP listeners passed loopback positive controls"
      echo "Starting peer TCP/UDP listeners"
      start_peer_probes hermes@vm.service "''${agent_vm_ip}" "''${agent_vm_ip6}" || { diagnose; exit 1; }
      start_peer_probes hermes@vm-peer.service "''${peer_agent_ip}" "''${peer_agent_ip6}" || { diagnose; exit 1; }
      start_test_endpoint || { diagnose; exit 1; }
      for address in "''${host_vm_ip}" "''${host_peer_ip}" "$host_other_ip"; do
        tcp_connect_host "$address" 18083 || { echo "Host TCP target is not live at $address:18083" >&2; diagnose; exit 1; }
      done
      for address in "''${host_vm_ip6}" "''${host_peer_ip6}" fd42:198:20::1; do
        tcp_connect_host "$address" 18083 || { echo "Host IPv6 TCP target is not live at [$address]:18083" >&2; diagnose; exit 1; }
      done
      for address in "''${host_vm_ip}" "''${host_peer_ip}" "$host_other_ip" "''${host_vm_ip6}" "''${host_peer_ip6}" fd42:198:20::1; do
        udp_probe "$address" 18083 || { echo "Host UDP target is not live at $address:18083" >&2; diagnose; exit 1; }
      done
      echo "Host IPv4/IPv6 denial targets accepted positive-control TCP connections"
      check_host_initiated_replies || { diagnose; exit 1; }
      assert_distinct_namespaces || { diagnose; exit 1; }
      check_address_dad_states || { diagnose; exit 1; }
      check_dad_readiness_gate || { diagnose; exit 1; }
      check_agent_network hermes@vm.service hb0 "''${host_vm_ip}" "''${agent_vm_ip}" "''${peer_agent_ip}" "''${host_vm_ip6}" "''${agent_vm_ip6}" "''${peer_agent_ip6}" || { diagnose; exit 1; }
      check_agent_network hermes@vm-peer.service hb1 "''${host_peer_ip}" "''${peer_agent_ip}" "''${agent_vm_ip}" "''${host_peer_ip6}" "''${peer_agent_ip6}" "''${agent_vm_ip6}" || { diagnose; exit 1; }
      check_ipv6_default_route_startup_gate || { diagnose; exit 1; }
      check_ipv6_default_route_loss || { diagnose; exit 1; }
      if [[ "$HERMES_VM_INTERNET_RECOVERY_ONLY" == 1 ]]; then
        echo "Focused Internet recovery run: public DNS and verified HTTPS after nftables/networkd recovery"
        check_public_internet || { diagnose; exit 1; }
        stop_peer_probes
        timeout --kill-after=5s 30 systemctl restart nftables.service || { diagnose; exit 1; }
        timeout 30s systemctl reset-failed hermes@vm.service hermes@vm-peer.service hermes-network@vm.service \
          hermes-network@vm-peer.service hermes-dhcp@vm.service hermes-dhcp@vm-peer.service \
          hermes-network-ready@vm.service hermes-network-ready@vm-peer.service
        timeout --kill-after=5s 180 systemctl start hermes@vm.service hermes@vm-peer.service \
          hermes-pf@vm.service hermes-pf@vm-peer.service || { diagnose; exit 1; }
        wait_for_active || { diagnose; exit 1; }
        check_public_internet || { diagnose; exit 1; }
        check_networkd_restart_recovery || { diagnose; exit 1; }
        check_public_internet || { diagnose; exit 1; }
        echo "Hermes focused Internet recovery checks passed"
        exit 0
      fi
      check_guard_policy_loss || { diagnose; exit 1; }
      check_split_producer_loss || { diagnose; exit 1; }
      if [[ "$HERMES_VM_INTERNET_TEST" == 1 ]]; then check_public_internet || { diagnose; exit 1; }; fi
      check_host_permission_revocation || { diagnose; exit 1; }
      check_dashboard_mapping || { diagnose; exit 1; }
      check_port_mappings || { diagnose; exit 1; }
      check_permission_revocation || { diagnose; exit 1; }
      check_dhcp_renewal || { diagnose; exit 1; }
      check_dhcp_failure_gate || { diagnose; exit 1; }
      check_nft_startup_failure_gate || { diagnose; exit 1; }
      check_nft_policy_startup_gate || { diagnose; exit 1; }
      check_networkd_restart_recovery || { diagnose; exit 1; }
      check_mapping_failure_cleanup || { diagnose; exit 1; }
      check_public_state_network hermes-pf@vm.service || { diagnose; exit 1; }
      check_public_state_network hermes-pf@vm-peer.service || { diagnose; exit 1; }
      stop_peer_probes
      start_fail_closed_probe || { diagnose; exit 1; }
      start_peer_probes hermes@vm.service "''${agent_vm_ip}" "''${agent_vm_ip6}" || { diagnose; exit 1; }
      start_peer_probes hermes@vm-peer.service "''${peer_agent_ip}" "''${peer_agent_ip6}" || { diagnose; exit 1; }
      check_agent_network hermes@vm.service hb0 "''${host_vm_ip}" "''${agent_vm_ip}" "''${peer_agent_ip}" "''${host_vm_ip6}" "''${agent_vm_ip6}" "''${peer_agent_ip6}" || { diagnose; exit 1; }
      check_dashboard_mapping || { diagnose; exit 1; }

      echo "Restarting public-state services"
      pf_vm_netns=$(readlink "/proc/$(service_pid hermes-pf@vm.service)/ns/net")
      pf_peer_netns=$(readlink "/proc/$(service_pid hermes-pf@vm-peer.service)/ns/net")
      timeout --kill-after=5s 60 systemctl stop hermes-pf@vm.service hermes-pf@vm-peer.service || { diagnose; exit 1; }
      assert_namespace_released "$pf_vm_netns" || { diagnose; exit 1; }
      assert_namespace_released "$pf_peer_netns" || { diagnose; exit 1; }
      timeout --kill-after=5s 60 systemctl start hermes-pf@vm.service hermes-pf@vm-peer.service || { diagnose; exit 1; }
      if ! wait_for_active; then diagnose; exit 1; fi
      assert_distinct_namespaces || { diagnose; exit 1; }
      check_public_state_network hermes-pf@vm.service || { diagnose; exit 1; }
      check_public_state_network hermes-pf@vm-peer.service || { diagnose; exit 1; }
      echo "Restarting vm-peer agent"
      stop_peer_probes
      timeout --kill-after=5s 180 systemctl restart hermes@vm-peer.service || { diagnose; exit 1; }
      timeout --kill-after=5s 60 systemctl start hermes-pf@vm-peer.service || { diagnose; exit 1; }
      if ! wait_for_active; then diagnose; exit 1; fi
      assert_distinct_namespaces || { diagnose; exit 1; }
      start_peer_probes hermes@vm.service "''${agent_vm_ip}" "''${agent_vm_ip6}" || { diagnose; exit 1; }
      start_peer_probes hermes@vm-peer.service "''${peer_agent_ip}" "''${peer_agent_ip6}" || { diagnose; exit 1; }
      check_agent_network hermes@vm-peer.service hb1 "''${host_peer_ip}" "''${peer_agent_ip}" "''${agent_vm_ip}" "''${host_peer_ip6}" "''${peer_agent_ip6}" "''${agent_vm_ip6}" || { diagnose; exit 1; }
      check_port_mappings || { diagnose; exit 1; }
      check_public_state_network hermes-pf@vm-peer.service || { diagnose; exit 1; }
      echo "Restarting vm agent"
      stop_peer_probes
      peer_pid_before=$(service_pid hermes@vm-peer.service)
      restart_request_usec=$(awk '{ printf "%.0f", $1 * 1000000 }' /proc/uptime)
      timeout --kill-after=5s 180 systemctl restart hermes@vm.service || { diagnose; exit 1; }
      check_dashboard_startup restart "$restart_request_usec" || { diagnose; exit 1; }
      echo "Requiring peer restart after main restart"
      timeout --kill-after=5s 180 systemctl start hermes@vm-peer.service || { diagnose; exit 1; }
      peer_pid_after=$(service_pid hermes@vm-peer.service)
      [[ "$peer_pid_after" != "$peer_pid_before" ]] || { echo "Peer did not restart after the main agent restart" >&2; diagnose; exit 1; }
      timeout --kill-after=5s 60 systemctl restart hermes-pf@vm.service hermes-pf@vm-peer.service || { diagnose; exit 1; }
      if ! wait_for_active; then diagnose; exit 1; fi
      assert_distinct_namespaces || { diagnose; exit 1; }
      start_peer_probes hermes@vm.service "''${agent_vm_ip}" "''${agent_vm_ip6}" || { diagnose; exit 1; }
      start_peer_probes hermes@vm-peer.service "''${peer_agent_ip}" "''${peer_agent_ip6}" || { diagnose; exit 1; }
      check_agent_network hermes@vm.service hb0 "''${host_vm_ip}" "''${agent_vm_ip}" "''${peer_agent_ip}" "''${host_vm_ip6}" "''${agent_vm_ip6}" "''${peer_agent_ip6}" || { diagnose; exit 1; }
      check_agent_network hermes@vm-peer.service hb1 "''${host_peer_ip}" "''${peer_agent_ip}" "''${agent_vm_ip}" "''${host_peer_ip6}" "''${peer_agent_ip6}" "''${agent_vm_ip6}" || { diagnose; exit 1; }
      if [[ "$HERMES_VM_INTERNET_TEST" == 1 ]]; then check_public_internet || { diagnose; exit 1; }; fi
      check_host_initiated_replies || { diagnose; exit 1; }
      check_dashboard_mapping || { diagnose; exit 1; }
      check_port_mappings || { diagnose; exit 1; }
      check_public_state_network hermes-pf@vm.service || { diagnose; exit 1; }
      check_public_state_network hermes-pf@vm-peer.service || { diagnose; exit 1; }

      for unit in "''${units[@]}"; do
        state=$(timeout 5s systemctl show --property=ActiveState --value "$unit")
        substate=$(timeout 5s systemctl show --property=SubState --value "$unit")
        service_type=$(timeout 5s systemctl show --property=Type --value "$unit")
        echo "Verified $unit: $state/$substate ($service_type)"
      done

      check_profiles_in_service_namespaces || { diagnose; exit 1; }
      if ! wait_for_active; then diagnose; exit 1; fi
      stop_peer_probes
      timeout --kill-after=5s 180 systemctl stop "''${units[@]}" || { diagnose; exit 1; }
      cleanup_test_network
      check_instantiated_security || { diagnose; exit 1; }
      echo "Hermes VM runtime checks passed"
    '';
  };
in
{
  imports = import ../modules/module-list.nix;

  # This isolated, network-restricted test VM needs Hermes' current Matrix dependency.
  nixpkgs.config.permittedInsecurePackages = [ "olm-3.2.16" ];

  networking.useNetworkd = true;
  networking.resolvconf.enable = false;
  networking.nameservers = [ ];
  environment.etc."resolv.conf".source = lib.mkForce "/run/hermes-vm-resolv.conf";
  services.dnsmasq = {
    enable = true;
    settings = {
      address = [
        "/hermes-vm.test/198.20.0.2"
        "/hermes-vm.test/fd42:198:20::2"
      ];
      bind-interfaces = true;
      interface = [ "lo" ];
      no-hosts = true;
      no-resolv = true;
    };
  };

  systemd.services."hermes@" = {
    after = [ "dnsmasq.service" ];
    requires = [ "dnsmasq.service" ];
  };

  systemd.services.hermes-vm-network-record-tests = {
    before = [ "hermes-network@vm.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 -I -B ${vmNetworkRecordTests} ${networkRecordPath} ${../modules/services/agent/hermes-network/setup.py} ${hostRecordPath} ${vmNetworkObserver}";
      ExecStartPost = "${pkgs.python3}/bin/python3 -I -B ${./tests/hermes-runtime/contracts.py} ${../modules/services/agent/hermes-runtime} ${pkgs.coreutils}/bin/chown";
      Type = "oneshot";
      DynamicUser = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      StandardOutput = "journal+console";
    };
  };
  systemd.services.hermes-vm-before-proxies = {
    after = [
      "hermes-network@vm.service"
      "hermes-dhcp@vm.service"
      "hermes-network-observer@vm.service"
    ];
    requires = [
      "hermes-network@vm.service"
      "hermes-dhcp@vm.service"
    ];
    before = [
      "hermes-dns@vm.service"
      "hermes-host-proxy@vm.service"
      "hermes-agent-relay@vm.service"
    ];
    partOf = [ "hermes-network@vm.service" ];
    serviceConfig = {
      ExecStart = lib.getExe vmNetworkReadinessBarrierProbe;
      RootDirectory = "/run/hermes-vm-before-proxies/root";
      RuntimeDirectory = [ "hermes-vm-before-proxies/root" ];
      RuntimeDirectoryMode = "0700";
      NetworkNamespacePath = "/proc/1/ns/net";
      PrivateNetwork = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      NoNewPrivileges = true;
      CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
      RestrictNamespaces = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_NETLINK"
      ];
      BindReadOnlyPaths = vmNetworkReadinessBarrierClosure ++ [
        "/run/hermes-observation-vm"
        "/run/systemd/private"
        "${pkgs.writeTextDir ".keep" ""}:/run/systemd/system"
      ];
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };
  systemd.services."hermes-dns@vm".requires = [ "hermes-vm-before-proxies.service" ];
  systemd.services."hermes-host-proxy@vm".requires = [ "hermes-vm-before-proxies.service" ];
  systemd.services."hermes-agent-relay@vm".requires = [ "hermes-vm-before-proxies.service" ];

  systemd.services."hermes-netns@" = vmPayloadHook "netns";
  systemd.services."hermes-host-control@" = vmPayloadHook "host-control";
  systemd.services."hermes-network-observer@" = vmPayloadHook "network-observer";
  systemd.services."hermes-dns@" = vmPayloadHook "dns";
  systemd.services."hermes-host-proxy@" = vmPayloadHook "host-proxy";
  systemd.services."hermes-agent-relay@" = vmPayloadHook "agent-relay";
  systemd.services."hermes-network-ready@" = vmPayloadHook "network-ready";
  systemd.services."hermes-network-failure@" = vmPayloadHook "network-failure";
  systemd.services."hermes-dhcp@" = vmPayloadHook "dhcp";
  systemd.services."hermes-pf@" = vmPayloadHook "pf";
  systemd.services."hermes@".serviceConfig.ExecStartPost = [
    "${pkgs.python3}/bin/python3 ${vmPayloadBoundaryProbe} gateway"
  ];
  systemd.services."hermes-network@".serviceConfig.ExecStartPost =
    lib.mkDefault "${lib.getExe pkgs.python3} ${vmNetworkLocalBoundaryProbe}";

  systemd.services.hermes-vm-late-resolver = {
    before = [ "network-online.target" ];
    wantedBy = [ "network-online.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      sleep 5
      printf 'nameserver 127.0.0.1\n' > /run/hermes-vm-resolv.conf
      touch /run/hermes-vm-resolver-ready
    '';
  };

  services.hermes-specialised-agent = {
    enable = true;
    mainAgent = "vm";
    agents.vm = {
      enable = true;
      fullName = "hermes-vm";
      headroomEnable = false;
      headroomPort = 18080;
      networkAllow = [
        {
          address = "10.20.0.2";
          port = 18082;
          protocol = "tcp";
        }
        {
          address = "fd42:198:20::2";
          port = 18082;
          protocol = "tcp";
        }
        {
          address = "fd42:198:20::2";
          port = 18086;
          protocol = "udp";
        }
        {
          address = "10.20.0.2";
          port = 18090;
          protocol = "tcp";
        }
        {
          address = "10.20.0.2";
          port = 18086;
          protocol = "udp";
        }
        { }
      ];
      settings.kanban.default_assignee = "hermes-vm";
    };
    agents.vm-peer = {
      enable = true;
      fullName = "hermes-vm-peer";
      headroomEnable = false;
      headroomPort = 18081;
      portMappings = [
        {
          hostPort = 18191;
          agentPort = 18084;
          protocol = "tcp";
        }
        {
          hostPort = 18192;
          agentPort = 18086;
          protocol = "udp";
        }
        {
          hostPort = 18193;
          agentPort = 18087;
          target = "loopback";
        }
        {
          hostPort = 18195;
          agentPort = 18088;
          protocol = "both";
        }
        {
          hostPort = 18194;
          agentPort = 18090;
          protocol = "tcp";
        }
        {
          hostPort = 18194;
          agentPort = 18090;
          protocol = "udp";
        }
        {
          hostPort = 18196;
          agentPort = 18089;
          protocol = "tcp";
          target = "loopback";
        }
        {
          hostPort = 18197;
          agentPort = 18089;
          protocol = "udp";
          target = "loopback";
        }
        # Gives the revocation test a mapped source port with no local listener.
        {
          hostPort = 18198;
          agentPort = 18198;
          protocol = "tcp";
        }
      ];
    };
    installDefaultSkills = false;
  };

  system.stateVersion = "26.05";

  virtualisation = {
    diskImage = "./hermes-module-vm.qcow2";
    diskSize = 1024;
    graphics = false;
    memorySize = 2048;
    mountHostNixStore = false;
    restrictNetwork = true;
    useNixStoreImage = false;
    writableStore = false;
    sharedDirectories = lib.mkForce { };
    qemu.options = [
      "-virtfs local,path=/nix/store,security_model=none,mount_tag=nix-store,readonly=on"
    ];
    fileSystems = {
      "/nix/.ro-store" = {
        device = "nix-store";
        fsType = "9p";
        neededForBoot = true;
        options = [
          "trans=virtio"
          "version=9p2000.L"
          "ro"
        ];
      };
      "/nix/store" = {
        device = "/nix/.ro-store";
        fsType = "none";
        options = [ "bind" ];
      };
    };
  };

  boot.initrd.availableKernelModules = [
    "9p"
    "9pnet_virtio"
  ];

  systemd.services.hermes-module-vm-smoke = {
    description = "Check the Hermes VM resource and read-only 9p store limits";
    after = [ "local-fs.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [
      pkgs.gawk
      pkgs.util-linux
    ];
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "tty";
      StandardError = "tty";
      TTYPath = "/dev/ttyS0";
    };
    script = ''
      set -eu
      store_fs=$(findmnt --target /nix/.ro-store --noheadings --output FSTYPE | sort -u)
      store_options=$(findmnt --target /nix/.ro-store --noheadings --output OPTIONS | sort -u)
      test "$store_fs" = 9p
      case ",$store_options," in *,ro,*) ;; *) echo "/nix/.ro-store is not read-only" >&2; exit 1 ;; esac
      memory_kib=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
      test "$memory_kib" -le 2097152
      findmnt --target /nix/.ro-store
      findmnt --target /nix/store
      printf 'Guest MemTotal: %s kB (limit: 2097152 kB)\n' "$memory_kib"
      df -h /
      echo "Hermes VM smoke checks passed"
    '';
  };

  systemd.services.hermes-vm-generation-rollback-launcher = {
    description = "Launch the disposable Hermes generation rollback probe when explicitly enabled";
    after = [
      "hermes@vm.service"
      "hermes@vm-peer.service"
      "hermes-network-ready@vm.service"
      "hermes-network-ready@vm-peer.service"
    ];
    environment.HERMES_VM_PREVIOUS_SYSTEM = "";
    serviceConfig = {
      ExecStart = lib.getExe vmGenerationRollbackLaunch;
      StandardError = "journal+console";
      StandardOutput = "journal+console";
      Type = "oneshot";
    };
  };
  systemd.services.hermes-module-vm-agent-smoke = {
    description = "Verify real Hermes agent and public-state services in their runtime namespaces";
    unitConfig = {
      # This disposable guest must stop when the smoke result is known.
      FailureAction = "poweroff";
      SuccessAction = "poweroff";
    };
    after = [
      "hermes@vm.service"
      "hermes@vm-peer.service"
      "hermes-pf@vm.service"
      "hermes-pf@vm-peer.service"
    ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      HERMES_VM_DASHBOARD_HOST_PORT = toString dashboardHostPort;
      HERMES_VM_PEER_HOST_PORTS = lib.concatStringsSep " " peerHostPorts;
      HERMES_VM_INTERNET_TEST = "0";
      HERMES_VM_INTERNET_RECOVERY_ONLY = "0";
      HERMES_VM_NM_UPLINK_TEST = "0";
      HERMES_VM_DAD_PROBE_ONLY = "0";
    };
    serviceConfig = {
      ExecStart = lib.getExe vmAgentRuntimeSmoke;
      StandardError = "journal+console";
      StandardOutput = "journal+console";
      # The complete 2-GiB fault and lifecycle matrix can exceed one hour; production limits are unchanged.
      TimeoutStartSec = "5400s";
      Type = "oneshot";
    };
  };
}
