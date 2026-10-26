{
  config,
  lib,
  pkgs,
  ...
}:
let
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
  vmNetworkProbeServer = pkgs.writeText "hermes-vm-network-probe-server.py" ''
    import http.server
    import select
    import socket
    import socketserver
    import sys
    import threading

    class HttpHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"OK")

        def log_message(self, *_args):
            pass

    class EchoHandler(socketserver.BaseRequestHandler):
        def handle(self):
            while True:
                data = self.request.recv(128)
                if not data:
                    break
                self.request.sendall(data)

    class UdpEchoServer:
        def __init__(self, addresses):
            self.sockets = []
            for family, address, port in addresses:
                sock = socket.socket(family, socket.SOCK_DGRAM)
                if family == socket.AF_INET6:
                    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                sock.bind((address, port))
                self.sockets.append(sock)

        def serve_forever(self):
            while True:
                for sock in select.select(self.sockets, [], [])[0]:
                    data, peer = sock.recvfrom(4096)
                    sock.sendto(b"hermes-network-policy-udp-ok", peer)

    class TcpServer6(http.server.ThreadingHTTPServer):
        address_family = socket.AF_INET6

        def server_bind(self):
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            super().server_bind()

    class EchoServer4(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True

    mode = sys.argv[1]
    if mode == "host":
        tcp_servers = [
            http.server.ThreadingHTTPServer(("0.0.0.0", 18083), HttpHandler),
            TcpServer6(("::", 18083), HttpHandler),
            EchoServer4(("0.0.0.0", 18084), EchoHandler),
        ]
        udp_addresses = [
            (socket.AF_INET, "0.0.0.0", 18083),
            (socket.AF_INET6, "::", 18083),
        ]
    elif mode == "endpoint":
        tcp_servers = [
            http.server.ThreadingHTTPServer(("0.0.0.0", 18082), HttpHandler),
            TcpServer6(("::", 18082), HttpHandler),
            http.server.ThreadingHTTPServer(("10.20.0.2", 18083), HttpHandler),
            http.server.ThreadingHTTPServer(("10.20.0.2", 18086), HttpHandler),
            TcpServer6(("fd42:198:20::2", 18086), HttpHandler),
            EchoServer4(("10.20.0.2", 18090), EchoHandler),
        ]
        udp_addresses = [
            (socket.AF_INET, "10.20.0.2", 18082),
            (socket.AF_INET, "10.20.0.2", 18083),
            (socket.AF_INET, "10.20.0.2", 18086),
            (socket.AF_INET, "10.20.0.3", 18082),
            (socket.AF_INET6, "fd42:198:20::2", 18082),
            (socket.AF_INET6, "fd42:198:20::2", 18083),
            (socket.AF_INET6, "fd42:198:20::2", 18086),
            (socket.AF_INET6, "fd42:198:20::3", 18086),
        ]
    else:
        ipv4, ipv6 = sys.argv[2:4]
        tcp_servers = [
            http.server.ThreadingHTTPServer((ipv4, 18084), HttpHandler),
            TcpServer6((ipv6, 18085), HttpHandler),
            http.server.ThreadingHTTPServer((ipv4, 18088), HttpHandler),
            http.server.ThreadingHTTPServer((ipv4, 18090), HttpHandler),
            http.server.ThreadingHTTPServer(("127.0.0.1", 18087), HttpHandler),
            http.server.ThreadingHTTPServer(("127.0.0.1", 18089), HttpHandler),
        ]
        udp_addresses = [
            (socket.AF_INET, ipv4, 18086),
            (socket.AF_INET, ipv4, 18088),
            (socket.AF_INET, ipv4, 18090),
            (socket.AF_INET, "127.0.0.1", 18087),
            (socket.AF_INET, "127.0.0.1", 18089),
        ]

    for server in tcp_servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    UdpEchoServer(udp_addresses).serve_forever()
  '';
  vmNetworkReadinessBarrierProbe = pkgs.writeShellApplication {
    name = "hermes-vm-network-readiness-barrier-probe";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.iproute2
      pkgs.nftables
      pkgs.systemd
      pkgs.util-linux
    ];
    text = ''
      gateway_start=$(systemctl show --property=ExecMainStartTimestampMonotonic --value hermes@vm.service)
      [[ "$gateway_start" == 0 ]] || exit 0
      for _ in {1..300}; do
        if ip -o -4 address show dev hb0 scope global | grep -q '/30' \
          && ip -o -6 address show dev hb0 scope global | grep -q '/64' \
          && ip -4 route show default | grep -q 'dev hb0' \
          && ip -6 route show default | grep -q 'dev hb0'; then
          break
        fi
        sleep 0.1
      done
      if ! ip -o -4 address show dev hb0 scope global | grep -q '/30' \
        || ! ip -o -6 address show dev hb0 scope global | grep -q '/64' \
        || ! ip -4 route show default | grep -q 'dev hb0' \
        || ! ip -6 route show default | grep -q 'dev hb0'; then
        echo "DHCP/SLAAC were not ready before the test firewall delay" >&2
        exit 1
      fi
      for set in ha0_peer4 ha0_peer6; do
        host_set=$(nsenter --net=/proc/1/ns/net -- nft -n list set inet hermes-agent-guard "$set")
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
      pkgs.util-linux
    ];
    text = ''
      store_sentinel=${vmStoreSentinel}
      store_sentinel_text='Hermes VM unrelated store sentinel'
      store_probe=${lib.getExe' pkgs.coreutils "stat"}
      dhcpcd_exe=${lib.getExe pkgs.dhcpcd}
      store_bash=${pkgs.runtimeShell}

      units=(
        hermes@vm.service
        hermes@vm-peer.service
        hermes-pf@vm.service
        hermes-pf@vm-peer.service
        hermes-network@vm.service
        hermes-network@vm-peer.service
        hermes-dhcp@vm.service
        hermes-dhcp@vm-peer.service
        hermes-network-ready@vm.service
        hermes-network-ready@vm-peer.service
      )
      agent_units=(hermes@vm.service hermes@vm-peer.service)
      public_state_units=(hermes-pf@vm.service hermes-pf@vm-peer.service)
      host_probe_pid=
      peer_probe_pids=()
      endpoint_pid=
      permissive_control=0
      dhcp_block=0
      startup_phases_reported=0
      host_vm_ip="" agent_vm_ip="" host_peer_ip="" peer_agent_ip=""
      host_vm_ip6="" agent_vm_ip6="" host_peer_ip6="" peer_agent_ip6=""
      agent_vm_subnet4="" peer_agent_subnet4="" agent_vm_subnet6="" peer_agent_subnet6=""
      dashboard_host_port="$HERMES_VM_DASHBOARD_HOST_PORT"

      cleanup_test_network() {
        remove_permissive_control
        remove_host_revocation_rules
        remove_dhcp_block
        [[ -z "$endpoint_pid" ]] || kill "$endpoint_pid" 2>/dev/null || true
        stop_peer_probes
        [[ -z "$host_probe_pid" ]] || kill "$host_probe_pid" 2>/dev/null || true
        ip netns del hermes-vm-endpoint 2>/dev/null || true
        ip link delete dev he0 2>/dev/null || true
        [[ -z "$agent_vm_subnet4" ]] || ip route del "$agent_vm_subnet4" dev hvm-overlap 2>/dev/null || true
        ip link delete dev hvm-overlap 2>/dev/null || true
      }
      trap cleanup_test_network EXIT

      remove_dhcp_block() {
        (( dhcp_block )) || return 0
        local handle
        handle=$(nft -a list chain inet hermes-agent-guard hermes_agent_input_guard 2>/dev/null | awk '/comment "hermes-vm-dhcp-block"/ { print $NF; exit }')
        [[ -z "$handle" ]] || nft delete rule inet hermes-agent-guard hermes_agent_input_guard handle "$handle" 2>/dev/null || true
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
        log=$(journalctl -b -u hermes-network-ready@vm.service --no-pager -o cat)
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
          record=$(timeout 5s journalctl -b -u hermes@vm.service -u hermes-network@vm.service --no-pager -o json | "${lib.getExe' pkgs.python3 "python3"}" -c 'import json,sys; mode=sys.argv[1]; boundary=int(sys.argv[2]); rows=[json.loads(line) for line in sys.stdin if line.strip()]; ready_rows=sorted((row for row in rows if row.get("MESSAGE")=="HERMES_DASHBOARD_READY port=9119"),key=lambda row:int(row["__MONOTONIC_TIMESTAMP"])); ready=ready_rows[0] if mode=="boot" else next(row for row in ready_rows if int(row["__MONOTONIC_TIMESTAMP"])>=boundary); ready_usec=int(ready["__MONOTONIC_TIMESTAMP"]); boundary=min(int(row["__MONOTONIC_TIMESTAMP"]) for row in rows if row.get("MESSAGE","").startswith("Starting Configure isolated network for Hermes agent vm") and int(row["__MONOTONIC_TIMESTAMP"])<=ready_usec) if mode=="boot" else boundary; pid=ready["_PID"]; first=min((row for row in rows if row.get("_PID")==pid and int(row["__MONOTONIC_TIMESTAMP"])>=boundary),key=lambda row:int(row["__MONOTONIC_TIMESTAMP"])); print(boundary,pid,first["__MONOTONIC_TIMESTAMP"],ready["__MONOTONIC_TIMESTAMP"])' "$mode" "$boundary" 2>/dev/null) && break
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
        local deadline=$((SECONDS + 120)) next_report=$SECONDS ready state unit
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
            check_all_store_isolation
            return $?
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

        echo "Stopping gateways to run profile-list commands within their captured namespaces without exceeding the 1-GiB VM limit"
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

      remove_permissive_control() {
        local entry family table chain handle
        (( permissive_control )) || return 0
        for entry in "inet hermes-agent-guard hermes_agent_input_guard" "inet nixos-fw input-allow"; do
          read -r family table chain <<< "$entry"
          while handle=$(nft -a list chain "$family" "$table" "$chain" | awk '/comment "hermes-vm-permissive-control"/ { print $NF; exit }') && [[ -n "$handle" ]]; do
            nft delete rule "$family" "$table" "$chain" handle "$handle"
          done
        done
        permissive_control=0
      }

      check_permissive_control() {
        local pid address
        pid=$(service_pid hermes@vm.service)
        permissive_control=1
        for address in "''${host_peer_ip}" "$host_other_ip" "''${host_peer_ip6}" fd42:198:20::1; do
          if [[ "$address" == *:* ]]; then
            nft insert rule inet hermes-agent-guard hermes_agent_input_guard iifname "ha0" ip6 saddr "''${agent_vm_ip6}" ip6 daddr "$address" tcp dport 18083 accept comment "hermes-vm-permissive-control" || return 1
            nft insert rule inet nixos-fw input-allow iifname "ha0" ip6 saddr "''${agent_vm_ip6}" ip6 daddr "$address" tcp dport 18083 accept comment "hermes-vm-permissive-control" || return 1
            nft insert rule inet hermes-agent-guard hermes_agent_input_guard iifname "ha0" ip6 saddr "''${agent_vm_ip6}" ip6 daddr "$address" udp dport 18083 accept comment "hermes-vm-permissive-control" || return 1
            nft insert rule inet nixos-fw input-allow iifname "ha0" ip6 saddr "''${agent_vm_ip6}" ip6 daddr "$address" udp dport 18083 accept comment "hermes-vm-permissive-control" || return 1
          else
            nft insert rule inet hermes-agent-guard hermes_agent_input_guard iifname "ha0" ip saddr "''${agent_vm_ip}" ip daddr "$address" tcp dport 18083 accept comment "hermes-vm-permissive-control" || return 1
            nft insert rule inet nixos-fw input-allow iifname "ha0" ip saddr "''${agent_vm_ip}" ip daddr "$address" tcp dport 18083 accept comment "hermes-vm-permissive-control" || return 1
            nft insert rule inet hermes-agent-guard hermes_agent_input_guard iifname "ha0" ip saddr "''${agent_vm_ip}" ip daddr "$address" udp dport 18083 accept comment "hermes-vm-permissive-control" || return 1
            nft insert rule inet nixos-fw input-allow iifname "ha0" ip saddr "''${agent_vm_ip}" ip daddr "$address" udp dport 18083 accept comment "hermes-vm-permissive-control" || return 1
          fi
        done
        tcp_connect_service "$pid" "''${host_vm_ip}" 18083 || { echo "Permissive control failed to connect to live host listener" >&2; return 1; }
        for address in "''${host_peer_ip}" "$host_other_ip" "''${host_peer_ip6}" fd42:198:20::1; do
          tcp_connect_service "$pid" "$address" 18083 || { echo "Permissive control failed to connect to host address $address" >&2; return 1; }
          udp_probe_service "$pid" "$address" 18083 || { echo "Permissive control failed to get a UDP response from $address" >&2; return 1; }
        done
        echo "Permissive-control TCP/UDP probes succeeded for non-veth and peer host addresses"
        remove_permissive_control
        for address in "''${host_peer_ip}" "$host_other_ip" "''${host_peer_ip6}" fd42:198:20::1; do
          if tcp_connect_service "$pid" "$address" 18083 || udp_probe_service "$pid" "$address" 18083; then
            echo "Host-service denial oracle still succeeds after removing temporary allow rules for $address" >&2
            return 1
          fi
        done
        echo "Denial oracle detected the restored host-service block"
      }

      service_pid() {
        local pid
        pid=$(timeout 10s systemctl show --property=MainPID --value "$1")
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { echo "$1 has no live main PID: $pid" >&2; return 1; }
        printf '%s\n' "$pid"
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

      check_store_isolation() {
        local unit="$1" pid="$2" bind_paths temporary_filesystem inaccessible_paths root_directory alias uid gid root_probe
        echo "Checking store closure and host-store denial in $unit (pid=$pid)"
        bind_paths=$(timeout 10s systemctl show --property=BindReadOnlyPaths --value "$unit")
        temporary_filesystem=$(timeout 10s systemctl show --property=TemporaryFileSystem --value "$unit")
        inaccessible_paths=$(timeout 10s systemctl show --property=InaccessiblePaths --value "$unit")
        root_directory=$(timeout 10s systemctl show --property=RootDirectory --value "$unit")
        [[ "$bind_paths" == *"/nix/store/"* ]] || {
          echo "$unit has no effective individual store-path binds" >&2
          return 1
        }
        case " $bind_paths " in
          *" /nix "*) echo "$unit still binds the entire /nix tree" >&2; return 1 ;;
        esac
        [[ "$temporary_filesystem" == *"/nix:ro"* ]] || {
          echo "$unit does not mask the host /nix tree with a read-only temporary filesystem: $temporary_filesystem" >&2
          return 1
        }
        if [[ -n "$root_directory" ]]; then
          [[ "$root_directory" == */root ]] || { echo "$unit has an unexpected private root: $root_directory" >&2; return 1; }
        else
          for alias in /run/current-system /run/booted-system /run/wrappers /etc/static /etc/profiles /etc/systemd; do
            [[ "$inaccessible_paths" == *"$alias"* ]] || {
              echo "$unit does not mask Nix store alias $alias: $inaccessible_paths" >&2
              return 1
            }
          done
        fi
        uid=$(awk '/^Uid:/ { print $3; exit }' "/proc/$pid/status")
        gid=$(awk '/^Gid:/ { print $3; exit }' "/proc/$pid/status")
        if [[ -n "$root_directory" ]]; then
          root_probe="$store_bash"
          [[ "$unit" != hermes-dhcp@* ]] || root_probe="$dhcpcd_exe"
          # shellcheck disable=SC2016
          if ! "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --mount --root --wd --setuid "$uid" --setgid "$gid" -- \
            "$store_bash" -euc '
              test -x "$1" && test ! -e "$2"
              for path in /etc/systemd/system/multi-user.target /run/current-system/sw/bin/bash /run/wrappers/bin/sudo; do
                [[ ! -e "$path" ]] || { echo "Host store alias remains in private DHCP root: $path" >&2; exit 1; }
              done
            ' -- "$root_probe" "$store_sentinel"
          then
            return 1
          fi
          echo "$unit private root exposes its service binary and hides host store aliases"
          return 0
        fi
        # shellcheck disable=SC2016
        "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --mount --root --wd --setuid "$uid" --setgid "$gid" -- \
          "$store_bash" -euc '
          sentinel="$1"
          expected="$2"
          probe="$3"
          test -r "$probe" && test -x "$probe"
          "$probe" --version >/dev/null
          if [[ -r "$sentinel" ]]; then
            echo "Unrelated host store sentinel is readable: $sentinel" >&2
            exit 1
          fi
          for path in \
            "/nix/.ro-store/''${sentinel##*/}" \
            /etc/profiles/per-user/root/bin/bash \
            /etc/static/os-release \
            /etc/systemd/system/multi-user.target \
            /nix/var/nix/profiles/system \
            /root/.nix-defexpr \
            /root/.nix-profile/bin/bash \
            /run/booted-system/sw/bin/bash \
            /run/current-system/sw/bin/bash \
            /run/wrappers/bin/sudo; do
            if [[ -e "$path" ]]; then
              echo "Host Nix store alias remains reachable: $path" >&2
              exit 1
            fi
          done
          [[ "$expected" == "Hermes VM unrelated store sentinel" ]]
          echo "Allowed store probe is executable; unrelated host store paths are hidden"
        ' -- "$store_sentinel" "$store_sentinel_text" "$store_probe"
      }

      check_all_store_isolation() {
        local unit pid
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
        for unit in "''${agent_units[@]}" "''${public_state_units[@]}"; do
          pid=$(service_pid "$unit") || return 1
          check_store_isolation "$unit" "$pid" || return 1
        done
        for unit in hermes-network-ready@vm.service hermes-network-ready@vm-peer.service hermes-dhcp@vm.service hermes-dhcp@vm-peer.service; do
          pid=$(service_pid "$unit") || return 1
          check_store_isolation "$unit" "$pid" || return 1
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
        local expected="$1" path namespace
        for path in /proc/[0-9]*/ns/net /proc/[0-9]*/fd/*; do
          [[ -e "$path" || -L "$path" ]] || continue
          namespace=$(readlink "$path" 2>/dev/null || true)
          if [[ "$namespace" == "$expected" ]]; then
            echo "Stopped service namespace is still referenced by $path: $expected" >&2
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
        output=$(run_as_service root "$pid" "${lib.getExe' pkgs.python3 "python3"}" -c 'import socket; print(*sorted({r[4][0] for r in socket.getaddrinfo("hermes-vm.test", None, socket.AF_INET)}), sep="\\n")') || { echo "$unit service-identity A lookup failed" >&2; return 1; }
        [[ "$output" == *198.20.0.2* ]] || { echo "$unit service-identity A lookup was: $output" >&2; return 1; }
        output=$(run_as_service root "$pid" "${lib.getExe' pkgs.python3 "python3"}" -c 'import socket; print(*sorted({r[4][0] for r in socket.getaddrinfo("hermes-vm.test", None, socket.AF_INET6)}), sep="\\n")') || { echo "$unit service-identity AAAA lookup failed" >&2; return 1; }
        [[ "$output" == *fd42:198:20::2* ]] || { echo "$unit service-identity AAAA lookup was: $output" >&2; return 1; }
        run_as_service net "$pid" "${lib.getExe' pkgs.curl "curl"}" --fail --silent --show-error --connect-timeout 2 --max-time 4 http://198.20.0.2:18082/ >/dev/null || return 1
        run_as_service net "$pid" "${lib.getExe' pkgs.curl "curl"}" --ipv6 --fail --silent --show-error --connect-timeout 2 --max-time 4 -g 'http://[2001:db9::2]:18082/' >/dev/null || return 1
        if [[ "$unit" == hermes@vm.service ]]; then
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
        [[ "$families" == AF_UNIX ]] || { echo "$unit address-family restriction is not AF_UNIX: $families" >&2; return 1; }
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
        local unit pid expected_dns output response dns_ip
        echo "Real-Internet regression: validating guest host DNS/TLS and QEMU default route"
        ip route show default | grep -q '^default ' || { echo "Guest has no QEMU-provided IPv4 default route" >&2; return 1; }
        "${lib.getExe' pkgs.dnsutils "dig"}" +time=3 +tries=1 +short example.com A | grep -Eq '^[0-9]+\.' || {
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

      check_dhcp_failure_gate() {
        local old_start current_start state set_output resolver
        echo "Testing bounded DHCP failure, stale resolver rejection, and lease recovery"
        stop_peer_probes
        timeout --kill-after=5s 60 systemctl stop hermes@vm.service hermes@vm-peer.service || { diagnose; return 1; }
        assert_network_resources_clean ha0 hermes_agent_0 "$agent_vm_subnet4" "$agent_vm_subnet6" || return 1
        assert_network_resources_clean ha1 hermes_agent_1 "$peer_agent_subnet4" "$peer_agent_subnet6" || return 1
        old_start=$(systemctl show --property=ExecMainStartTimestampMonotonic --value hermes@vm.service)
        nft insert rule inet hermes-agent-guard hermes_agent_input_guard \
          iifname "ha0" udp sport 68 udp dport 67 drop comment "hermes-vm-dhcp-block"
        dhcp_block=1
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
        timeout --kill-after=5s 60 systemctl stop hermes-network-ready@vm.service hermes-dhcp@vm.service hermes-network@vm.service || true
        timeout 30s systemctl reset-failed hermes@vm.service hermes@vm-peer.service hermes-network@vm.service \
          hermes-network@vm-peer.service hermes-dhcp@vm.service hermes-dhcp@vm-peer.service \
          hermes-network-ready@vm.service hermes-network-ready@vm-peer.service
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

      check_networkd_restart_recovery() {
        local old_pid old_netns old_mac new_pid new_mac ready_main ready_peer
        echo "Testing networkd restart recovery and namespace replacement"
        stop_peer_probes
        old_pid=$(service_pid hermes@vm.service) || return 1
        old_netns=$(readlink "/proc/$old_pid/ns/net")
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
        assert_namespace_released "$old_netns" || return 1
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
        local iface="$1" table="$2" subnet="$3" subnet6="$4" network_unit state
        network_unit=hermes-network@''${iface#ha}.service
        if [[ "$iface" == ha0 ]]; then network_unit=hermes-network@vm.service; fi
        if [[ "$iface" == ha1 ]]; then network_unit=hermes-network@vm-peer.service; fi
        for _ in {1..100}; do
          state=$(systemctl show --property=ActiveState --value "$network_unit")
          [[ "$state" == inactive || "$state" == failed ]] && break
          sleep 0.1
        done
        [[ "$state" == inactive || "$state" == failed ]] || { echo "$network_unit did not finish teardown" >&2; return 1; }
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
        if ip -4 route show table all | grep -Fq "$subnet"; then
          echo "Stale Hermes route remains after stopping agent $iface" >&2
          return 1
        fi
        if ip -6 route show table all | grep -Fq "$subnet6"; then
          echo "Stale Hermes IPv6 route remains after stopping agent $iface" >&2
          return 1
        fi
        if ss -H -ltn "sport = :$dashboard_host_port" | grep -q .; then
          echo "Stale host dashboard mapping remains after stopping agent $iface" >&2
          return 1
        fi
        if ss -H -lun "sport = :$dashboard_host_port" | grep -q .; then
          echo "Stale host dashboard UDP mapping remains after stopping agent $iface" >&2
          return 1
        fi
        echo "No stale veth, route, or nftables table for $iface"
      }

      start_fail_closed_probe() {
        local main_pid main_netns state invocation_id invocation_log
        echo "Testing fail-closed startup with a conflicting reserved interface"
        main_pid=$(service_pid hermes@vm.service)
        main_netns=$(readlink "/proc/$main_pid/ns/net")
        timeout --kill-after=5s 60 systemctl stop hermes@vm.service || { diagnose; return 1; }
        assert_network_resources_clean ha0 hermes_agent_0 "''${agent_vm_subnet4}" "''${agent_vm_subnet6}" || return 1
        assert_namespace_released "$main_netns" || return 1
        ip link add ha0 type dummy
        timeout --kill-after=5s 30 systemctl start hermes@vm.service || true
        sleep 2
        if [[ $(systemctl show --property=ActiveState --value hermes@vm.service) == active \
          || $(systemctl show --property=ActiveState --value hermes-network@vm.service) == active ]]; then
          echo "Agent/network helper became active despite its reserved veth name being occupied" >&2
          return 1
        fi
        ip -d link show dev ha0 | grep -q 'alias hermes-agent-vm' && { echo "Failure cleanup deleted/claimed the conflicting link" >&2; return 1; }
        assert_network_resources_clean hb0 hermes_agent_0 "''${agent_vm_subnet4}" "''${agent_vm_subnet6}" || return 1
        ip link delete dev ha0
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
        timeout --kill-after=5s 60 systemctl start hermes@vm.service || true
        for _ in {1..100}; do
          state=$(systemctl show --property=ActiveState --value hermes-network@vm.service)
          [[ "$state" == failed || "$state" == inactive ]] && break
          sleep 0.1
        done
        [[ "$state" == failed || "$state" == inactive ]] || { echo "Network helper did not fail on an overlapping host route" >&2; return 1; }
        [[ $(systemctl show --property=ActiveState --value hermes@vm.service) != active ]] || { echo "Gateway started despite the rejected overlapping route" >&2; return 1; }
        invocation_id=$(systemctl show --property=InvocationID --value hermes-network@vm.service)
        invocation_log=$(journalctl -b _SYSTEMD_UNIT=hermes-network@vm.service _SYSTEMD_INVOCATION_ID="$invocation_id" --no-pager -o cat)
        grep -Fq "overlaps host route" <<< "$invocation_log" || { echo "Network helper did not report its route-overlap failure" >&2; return 1; }
        if grep -Fq "Forwarding host 127.0.0.1:" <<< "$invocation_log"; then
          echo "Network setup continued to mapping startup after its route-overlap failure" >&2
          return 1
        fi
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
      host_other_ip=$(ip -o -4 address show scope global | awk '$2 != "ha0" && $2 != "ha1" { split($4, a, "/"); print a[1]; exit }')
      [[ -n "$host_other_ip" ]] || { echo "No non-veth host interface address is available for the isolation probe" >&2; diagnose; exit 1; }
      if [[ "$HERMES_VM_INTERNET_TEST" == 1 ]]; then
        if ! grep -Fq 'nameserver 127.0.0.1' /etc/resolv.conf || ! grep -Fq 'nameserver 1.1.1.1' /etc/resolv.conf; then
          echo "Internet fixture host resolver must retain the local test stub and include the explicit public resolver" >&2
          cat /etc/resolv.conf >&2
          exit 1
        fi
      else
        grep -Fq 'nameserver 127.0.0.1' /etc/resolv.conf || { echo "Offline fixture host resolver does not use the loopback stub" >&2; cat /etc/resolv.conf >&2; exit 1; }
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
      check_permissive_control || { diagnose; exit 1; }
      check_agent_network hermes@vm.service hb0 "''${host_vm_ip}" "''${agent_vm_ip}" "''${peer_agent_ip}" "''${host_vm_ip6}" "''${agent_vm_ip6}" "''${peer_agent_ip6}" || { diagnose; exit 1; }
      check_agent_network hermes@vm-peer.service hb1 "''${host_peer_ip}" "''${peer_agent_ip}" "''${agent_vm_ip}" "''${host_peer_ip6}" "''${peer_agent_ip6}" "''${agent_vm_ip6}" || { diagnose; exit 1; }
      if [[ "$HERMES_VM_INTERNET_TEST" == 1 ]]; then check_public_internet || { diagnose; exit 1; }; fi
      check_host_permission_revocation || { diagnose; exit 1; }
      check_dashboard_mapping || { diagnose; exit 1; }
      check_port_mappings || { diagnose; exit 1; }
      check_permission_revocation || { diagnose; exit 1; }
      check_dhcp_failure_gate || { diagnose; exit 1; }
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
      timeout --kill-after=5s 60 systemctl start hermes@vm-peer.service || { diagnose; exit 1; }
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
      echo "Hermes VM runtime checks passed"
    '';
  };
in
{
  imports = import ../modules/module-list.nix;

  # This isolated, network-restricted test VM needs Hermes' current Matrix dependency.
  nixpkgs.config.permittedInsecurePackages = [ "olm-3.2.16" ];

  networking.resolvconf.enable = false;
  networking.nameservers = [ ];
  environment.etc."resolv.conf".source = "/run/hermes-vm-resolv.conf";
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

  systemd.services."hermes-network-ready@vm".serviceConfig = {
    ExecStartPre = [ (lib.getExe vmNetworkReadinessBarrierProbe) ];
    BindReadOnlyPaths = lib.mkAfter vmNetworkReadinessBarrierClosure;
  };

  systemd.services.hermes-vm-late-resolver = {
    before = [ "network-online.target" ];
    wantedBy = [ "network-online.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      sleep 5
      printf 'nameserver 127.0.0.1\nnameserver ::1\n' > /run/hermes-vm-resolv.conf
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
    memorySize = 1024;
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
      test "$memory_kib" -le 1048576
      findmnt --target /nix/.ro-store
      findmnt --target /nix/store
      printf 'Guest MemTotal: %s kB (limit: 1048576 kB)\n' "$memory_kib"
      df -h /
      echo "Hermes VM smoke checks passed"
    '';
  };

  systemd.services.hermes-module-vm-agent-smoke = {
    description = "Verify real Hermes agent and public-state services in their runtime namespaces";
    after = [
      "hermes@vm.service"
      "hermes@vm-peer.service"
      "hermes-pf@vm.service"
      "hermes-pf@vm-peer.service"
    ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      HERMES_VM_DASHBOARD_HOST_PORT = toString dashboardHostPort;
      HERMES_VM_INTERNET_TEST = "0";
    };
    serviceConfig = {
      ExecStart = lib.getExe vmAgentRuntimeSmoke;
      StandardError = "journal+console";
      StandardOutput = "journal+console";
      # Gateway restarts recreate one mount per closure path in the 1-GiB guest.
      TimeoutStartSec = "1200s";
      Type = "oneshot";
    };
  };
}
