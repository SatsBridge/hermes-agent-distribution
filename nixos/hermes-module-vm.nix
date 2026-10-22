{ lib, pkgs, ... }:
let
  vmIpv6HttpServer = pkgs.writeText "hermes-vm-ipv6-http-server.py" ''
    import http.server
    import socket
    import sys


    class ThreadingHTTPServerV6(http.server.ThreadingHTTPServer):
        address_family = socket.AF_INET6

        def server_bind(self):
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            super().server_bind()


    ThreadingHTTPServerV6((sys.argv[1], int(sys.argv[2])), http.server.SimpleHTTPRequestHandler).serve_forever()
  '';
  vmStoreSentinel = pkgs.writeText "hermes-vm-unrelated-store-sentinel" "Hermes VM unrelated store sentinel\n";
  vmAgentRuntimeSmoke = pkgs.writeShellApplication {
    name = "hermes-module-vm-agent-smoke";
    runtimeInputs = [
      pkgs.gawk
      pkgs.acl
      pkgs.coreutils
      pkgs.curl
      pkgs.dnsutils
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
      store_bash=${pkgs.runtimeShell}
      dnsmasq_exe=${lib.getExe pkgs.dnsmasq}
      units=(
        hermes@vm.service
        hermes@vm-peer.service
        hermes-pf@vm.service
        hermes-pf@vm-peer.service
        hermes-network@vm.service
        hermes-network@vm-peer.service
      )
      agent_units=(hermes@vm.service hermes@vm-peer.service)
      public_state_units=(hermes-pf@vm.service hermes-pf@vm-peer.service)
      host_probe_pid=
      host_probe6_pid=
      peer_probe_pids=()
      endpoint_pid=
      endpoint6_pid=
      permissive_control=0

      cleanup_test_network() {
        remove_permissive_control
        [[ -z "$endpoint_pid" ]] || kill "$endpoint_pid" 2>/dev/null || true
        [[ -z "$endpoint6_pid" ]] || kill "$endpoint6_pid" 2>/dev/null || true
        stop_peer_probes
        [[ -z "$host_probe_pid" ]] || kill "$host_probe_pid" 2>/dev/null || true
        [[ -z "$host_probe6_pid" ]] || kill "$host_probe6_pid" 2>/dev/null || true
        ip netns del hermes-vm-endpoint 2>/dev/null || true
        ip link delete dev he0 2>/dev/null || true
      }
      trap cleanup_test_network EXIT

      diagnose() {
        echo "Hermes VM runtime check failed; unit status follows:" >&2
        timeout 15s systemctl status --no-pager --full "''${units[@]}" >&2 || true
        for unit in "''${units[@]}"; do
          timeout 15s journalctl -b -u "$unit" --no-pager -n 80 >&2 || true
        done
        getfacl -p -- /var/lib/hermes-vm /var/lib/hermes-vm/.hermes /var/lib/hermes-vm-peer /var/lib/hermes-vm-peer/.hermes >&2 || true
        ip -o link show >&2 || true
        ip -4 route show table all >&2 || true
        nft list ruleset >&2 || true
        ss -H -lunpt 'sport = :53' >&2 || true
        cat /etc/resolv.conf >&2 || true
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
            assert_agents_stable
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
        assert_network_resources_clean ha0 hermes_agent_0 198.18.0.0/30 fd42:198:18::/80 || return 1
        assert_network_resources_clean ha1 hermes_agent_1 198.18.0.4/30 fd42:198:18:0:1::/80 || return 1
        check_profile_list vm hermes-vm-peer "$vm_netns_fd" "$vm_netns" || return 1
        check_profile_list vm-peer hermes-vm "$peer_netns_fd" "$peer_netns" || return 1
        exec {vm_netns_fd}<&-
        exec {peer_netns_fd}<&-
        assert_namespace_released "$vm_netns" || return 1
        assert_namespace_released "$peer_netns" || return 1

        timeout --kill-after=5s 180 systemctl start hermes@vm.service hermes@vm-peer.service hermes-pf@vm.service hermes-pf@vm-peer.service || { diagnose; return 1; }
        if ! wait_for_active; then diagnose; return 1; fi
        assert_distinct_namespaces || return 1
        start_peer_probes hermes@vm.service 198.18.0.2 fd42:198:18::2 || return 1
        start_peer_probes hermes@vm-peer.service 198.18.0.6 fd42:198:18:0:1::2 || return 1
        check_agent_network hermes@vm.service hb0 198.18.0.1 198.18.0.2 198.18.0.6 fd42:198:18::1 fd42:198:18::2 fd42:198:18:0:1::2 || return 1
        check_agent_network hermes@vm-peer.service hb1 198.18.0.5 198.18.0.6 198.18.0.2 fd42:198:18:0:1::1 fd42:198:18:0:1::2 fd42:198:18::2 || return 1
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
        "${lib.getExe' pkgs.python3 "python3"}" -c 'import socket,sys;s=socket.socket(socket.AF_INET6 if ":" in sys.argv[1] else socket.AF_INET,socket.SOCK_STREAM);s.settimeout(2);s.connect((sys.argv[1],int(sys.argv[2])));s.close()' "$1" "$2"
      }

      tcp_connect_namespace() {
        local pid="$1" address="$2" port="$3"
        "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- \
          "${lib.getExe' pkgs.python3 "python3"}" -c 'import socket,sys;s=socket.socket(socket.AF_INET6 if ":" in sys.argv[1] else socket.AF_INET,socket.SOCK_STREAM);s.settimeout(2);s.connect((sys.argv[1],int(sys.argv[2])));s.close()' "$address" "$port" 2>/dev/null
      }

      tcp_connect_service() {
        local pid="$1" address="$2" port="$3"
        run_as_service net "$pid" "${lib.getExe' pkgs.python3 "python3"}" \
          -c 'import socket,sys;s=socket.socket(socket.AF_INET6 if ":" in sys.argv[1] else socket.AF_INET,socket.SOCK_STREAM);s.settimeout(2);s.connect((sys.argv[1],int(sys.argv[2])));s.close()' "$address" "$port" 2>/dev/null
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
        local unit="$1" address4="$2" address6="$3" pid
        pid=$(service_pid "$unit")
        "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- \
          "${lib.getExe' pkgs.python3 "python3"}" -c 'import socket,sys,time;s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind((sys.argv[1],18084));s.listen(8);time.sleep(600)' "$address4" >/dev/null 2>&1 &
        peer_probe_pids+=("$!")
        "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- \
          "${lib.getExe' pkgs.python3 "python3"}" -c 'import socket,sys,time;s=socket.socket(socket.AF_INET6);s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1);s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind((sys.argv[1],18085));s.listen(8);time.sleep(600)' "$address6" >/dev/null 2>&1 &
        peer_probe_pids+=("$!")
        for _ in {1..30}; do
          if tcp_connect_namespace "$pid" "$address4" 18084 && tcp_connect_namespace "$pid" "$address6" 18085; then
            echo "Live peer TCP targets ready in $unit at $address4:18084 and [$address6]:18085"
            return 0
          fi
          sleep 0.1
        done
        echo "$unit peer TCP targets failed their positive-connect checks" >&2
        return 1
      }

      remove_permissive_control() {
        local entry family table chain handle
        (( permissive_control )) || return 0
        for entry in "inet hermes-agent-guard hermes_agent_input_guard" "inet nixos-fw input-allow"; do
          read -r family table chain <<< "$entry"
          handle=$(nft -a list chain "$family" "$table" "$chain" | awk '/comment "hermes-vm-permissive-control"/ { print $NF; exit }')
          [[ -z "$handle" ]] || nft delete rule "$family" "$table" "$chain" handle "$handle"
        done
        permissive_control=0
      }

      check_permissive_control() {
        local pid
        pid=$(service_pid hermes@vm.service)
        permissive_control=1
        nft insert rule inet hermes-agent-guard hermes_agent_input_guard iifname "ha0" ip daddr 198.18.0.1 tcp dport 18083 accept comment "hermes-vm-permissive-control" || return 1
        nft insert rule inet nixos-fw input-allow iifname "ha0" ip daddr 198.18.0.1 tcp dport 18083 accept comment "hermes-vm-permissive-control" || return 1
        tcp_connect_service "$pid" 198.18.0.1 18083 || { echo "Permissive control failed to connect to live host listener" >&2; return 1; }
        echo "Permissive-control TCP connect succeeded with temporary allow rules"
        remove_permissive_control
        if tcp_connect_service "$pid" 198.18.0.1 18083; then
          echo "TCP denial oracle still connects after removing temporary allow rules" >&2
          return 1
        fi
        echo "Denial oracle detected the restored host-service block"
      }

      service_pid() {
        local pid
        pid=$(timeout 10s systemctl show --property=MainPID --value "$1")
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { echo "$1 has no live main PID: $pid" >&2; return 1; }
        printf '%s\n' "$pid"
      }

      network_helper_pid() {
        local unit="$1" cgroup candidate executable
        cgroup=$(timeout 10s systemctl show --property=ControlGroup --value "$unit")
        [[ "$cgroup" == /* ]] || { echo "$unit has no service cgroup: $cgroup" >&2; return 1; }
        while IFS= read -r candidate; do
          [[ "$candidate" =~ ^[1-9][0-9]*$ ]] || continue
          executable=$(readlink "/proc/$candidate/exe" 2>/dev/null || true)
          if [[ "$executable" == "$dnsmasq_exe" ]]; then
            printf '%s\n' "$candidate"
            return 0
          fi
        done < "/sys/fs/cgroup$cgroup/cgroup.procs"
        echo "$unit has no surviving dnsmasq process in its service cgroup" >&2
        return 1
      }

      check_store_isolation() {
        local unit="$1" pid="$2" bind_paths temporary_filesystem inaccessible_paths alias uid gid
        echo "Checking store closure and host-store denial in $unit (pid=$pid)"
        bind_paths=$(timeout 10s systemctl show --property=BindReadOnlyPaths --value "$unit")
        temporary_filesystem=$(timeout 10s systemctl show --property=TemporaryFileSystem --value "$unit")
        inaccessible_paths=$(timeout 10s systemctl show --property=InaccessiblePaths --value "$unit")
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
        for alias in /run/current-system /run/booted-system /run/wrappers /etc/static /etc/profiles /etc/systemd; do
          [[ "$inaccessible_paths" == *"$alias"* ]] || {
            echo "$unit does not mask Nix store alias $alias: $inaccessible_paths" >&2
            return 1
          }
        done
        uid=$(awk '/^Uid:/ { print $3; exit }' "/proc/$pid/status")
        gid=$(awk '/^Gid:/ { print $3; exit }' "/proc/$pid/status")
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
        for unit in hermes-network@vm.service hermes-network@vm-peer.service; do
          pid=$(network_helper_pid "$unit") || return 1
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
        ip -6 address add fd42:198:20::1/64 dev he0 nodad
        ip link set he0 up
        ip -n hermes-vm-endpoint link set lo up
        ip -n hermes-vm-endpoint address add 198.20.0.2/30 dev he1
        ip -n hermes-vm-endpoint -6 address add fd42:198:20::2/64 dev he1 nodad
        ip -n hermes-vm-endpoint link set he1 up
        ip -n hermes-vm-endpoint route add default via 198.20.0.1
        ip -n hermes-vm-endpoint -6 route add default via fd42:198:20::1
        ip netns exec hermes-vm-endpoint "${lib.getExe' pkgs.python3 "python3"}" -m http.server 18082 --bind 198.20.0.2 >/dev/null 2>&1 &
        endpoint_pid=$!
        ip netns exec hermes-vm-endpoint "${lib.getExe' pkgs.python3 "python3"}" ${vmIpv6HttpServer} fd42:198:20::2 18082 >/dev/null &
        endpoint6_pid=$!
        for _ in {1..30}; do
          if tcp_connect_namespace "$endpoint_pid" 198.20.0.2 18082 \
            && tcp_connect_namespace "$endpoint6_pid" fd42:198:20::2 18082; then
            echo "Controlled endpoint ready in hermes-vm-endpoint at 198.20.0.2 and fd42:198:20::2:18082"
            return 0
          fi
          sleep 0.1
        done
        echo "Endpoint IPv4 listeners:" >&2
        ip netns exec hermes-vm-endpoint "${lib.getExe' pkgs.iproute2 "ss"}" -H -ltn 'sport = :18082' >&2 || true
        echo "Endpoint IPv6 listeners:" >&2
        ip netns exec hermes-vm-endpoint "${lib.getExe' pkgs.iproute2 "ss"}" -6 -H -ltn 'sport = :18082' >&2 || true
        echo "Controlled endpoint failed to listen" >&2
        return 1
      }

      check_agent_network() {
        local unit="$1" peer_if="$2" host_ip="$3" agent_ip="$4" blocked_peer="$5" host_ip6="$6" agent_ip6="$7" blocked_peer6="$8" host_if pid output
        pid=$(service_pid "$unit") || return 1
        host_if="ha''${peer_if#hb}"
        echo "Checking isolated networking for $unit pid=$pid"
        "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- "${lib.getExe' pkgs.iproute2 "ip"}" -o -4 address show dev "$peer_if" | grep -F "inet $agent_ip/30" || return 1
        "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- "${lib.getExe' pkgs.iproute2 "ip"}" -o -6 address show dev "$peer_if" | grep -F "inet6 $agent_ip6/80" || return 1
        "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- "${lib.getExe' pkgs.iproute2 "ip"}" route show default | grep -F "via $host_ip" || return 1
        "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- "${lib.getExe' pkgs.iproute2 "ip"}" -6 route show default | grep -F "via $host_ip6" || return 1
        echo "$unit: verifying nftables input/forward rules"
        nft list chain inet hermes-agent-guard hermes_agent_input_guard | grep -F "iifname \"$host_if\" drop" || return 1
        nft list chain inet nixos-fw input-allow | grep -F "iifname \"$host_if\" ip saddr $agent_ip ip daddr $host_ip udp dport 53 accept" || return 1
        nft list chain inet nixos-fw forward-allow | grep -F "iifname \"$host_if\" ip saddr $agent_ip accept" || return 1
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
        run_as_service net "$pid" "${lib.getExe' pkgs.curl "curl"}" --ipv6 --fail --silent --show-error --connect-timeout 2 --max-time 4 -g 'http://[fd42:198:20::2]:18082/' >/dev/null || return 1
        for address in "$host_ip" "$host_other_ip"; do
          if tcp_connect_service "$pid" "$address" 18083; then
            echo "$unit unexpectedly reached host service at $address:18083" >&2
            return 1
          fi
          echo "Denied $unit -> $address:18083"
        done
        for address in "$host_ip6" fd42:198:20::1; do
          if tcp_connect_service "$pid" "$address" 18083; then
            echo "$unit unexpectedly reached host IPv6 service at [$address]:18083" >&2
            return 1
          fi
          echo "Denied $unit -> [$address]:18083"
        done
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
        for address in "198.20.0.2:18082" "198.18.0.1:18083" "$host_other_ip:18083" "198.18.0.6:18084"; do
          port="''${address##*:}"
          address="''${address%:*}"
          if tcp_connect_service "$pid" "$address" "$port"; then
            echo "$unit unexpectedly reached network endpoint $address" >&2
            return 1
          fi
        done
        for address in "[fd42:198:20::2]:18082" "[fd42:198:20::1]:18083" "[fd42:198:18:0:1::2]:18085"; do
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

      check_dashboard_mapping() {
        local pid listener code ready=0
        for _ in {1..100}; do
          pid=$(service_pid hermes@vm.service) || return 1
          if "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- "${lib.getExe' pkgs.iproute2 "ss"}" -H -ltn 'sport = :9119' | grep -Fq '127.0.0.1:9119' \
            && "${lib.getExe' pkgs.util-linux "nsenter"}" --target "$pid" --net -- "${lib.getExe' pkgs.iproute2 "ss"}" -H -ltn 'sport = :9119' | grep -Fq '198.18.0.2:9119'; then
            ready=1
            break
          fi
          sleep 0.1
        done
        (( ready )) || { echo "The real Hermes dashboard is not listening on its namespace port 9119" >&2; return 1; }
        listener=$(ss -H -ltn 'sport = :9119')
        [[ "$listener" == *127.0.0.1:9119* && "$listener" != *0.0.0.0:9119* ]] || {
          echo "Dashboard mapping is missing or not restricted to host loopback: $listener" >&2
          return 1
        }
        code=$("${lib.getExe' pkgs.curl "curl"}" --noproxy '*' --silent --show-error --max-time 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:9119/)
        [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] || { echo "Dashboard mapping returned no HTTP response: $code" >&2; return 1; }
        echo "Dashboard responds through configured loopback mapping 127.0.0.1:9119 -> agent port 9119 (HTTP $code)"
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
        host_dns_ip=198.18.0.1
        host_dns_ip6=fd42:198:18::1
        if [[ "$iface" == ha1 ]]; then
          host_dns_ip=198.18.0.5
          host_dns_ip6=fd42:198:18:0:1::1
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
        if ss -H -ltn 'sport = :9119' | grep -q .; then
          echo "Stale host dashboard mapping remains after stopping agent $iface" >&2
          return 1
        fi
        echo "No stale veth, route, or nftables table for $iface"
      }

      start_fail_closed_probe() {
        local main_pid main_netns
        echo "Testing fail-closed startup with a conflicting reserved interface"
        main_pid=$(service_pid hermes@vm.service)
        main_netns=$(readlink "/proc/$main_pid/ns/net")
        timeout --kill-after=5s 60 systemctl stop hermes@vm.service || { diagnose; return 1; }
        assert_network_resources_clean ha0 hermes_agent_0 198.18.0.0/30 fd42:198:18::/80 || return 1
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
        assert_network_resources_clean hb0 hermes_agent_0 198.18.0.0/30 fd42:198:18::/80 || return 1
        ip link delete dev ha0
        timeout 30s systemctl reset-failed hermes@vm.service hermes-network@vm.service
        timeout --kill-after=5s 180 systemctl start hermes@vm.service || { diagnose; return 1; }
        timeout --kill-after=5s 180 systemctl start hermes@vm-peer.service hermes-pf@vm.service hermes-pf@vm-peer.service || { diagnose; return 1; }
        wait_for_active || { diagnose; return 1; }
        echo "Setup failure stopped the service and preserved unrelated interface ha0"
      }

      if ! wait_for_active; then diagnose; exit 1; fi
      host_other_ip=$(ip -o -4 address show scope global | awk '$2 != "ha0" && $2 != "ha1" { split($4, a, "/"); print a[1]; exit }')
      [[ -n "$host_other_ip" ]] || { echo "No non-veth host interface address is available for the isolation probe" >&2; diagnose; exit 1; }
      grep -Fq 'nameserver 127.0.0.1' /etc/resolv.conf || { echo "VM host resolver does not use the loopback stub fixture" >&2; cat /etc/resolv.conf >&2; exit 1; }
      [[ -e /run/hermes-vm-resolver-ready ]] || { echo "Late resolver fixture did not finish before agent startup" >&2; exit 1; }
      echo "Agent network setup waited for the late host resolver fixture"
      echo "Host UDP/TCP DNS listeners:"
      ss -H -lunpt 'sport = :53'
      "${lib.getExe' pkgs.python3 "python3"}" -c 'import socket,time;s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(("0.0.0.0",18083));s.listen(8);time.sleep(600)' >/dev/null 2>&1 &
      host_probe_pid=$!
      "${lib.getExe' pkgs.python3 "python3"}" -c 'import socket,time;s=socket.socket(socket.AF_INET6);s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1);s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(("::",18083));s.listen(8);time.sleep(600)' >/dev/null 2>&1 &
      host_probe6_pid=$!
      start_peer_probes hermes@vm.service 198.18.0.2 fd42:198:18::2 || { diagnose; exit 1; }
      start_peer_probes hermes@vm-peer.service 198.18.0.6 fd42:198:18:0:1::2 || { diagnose; exit 1; }
      for address in 198.18.0.1 198.18.0.5 "$host_other_ip"; do
        tcp_connect_host "$address" 18083 || { echo "Host TCP target is not live at $address:18083" >&2; diagnose; exit 1; }
      done
      for address in fd42:198:18::1 fd42:198:18:0:1::1; do
        tcp_connect_host "$address" 18083 || { echo "Host IPv6 TCP target is not live at [$address]:18083" >&2; diagnose; exit 1; }
      done
      echo "Host IPv4/IPv6 denial targets accepted positive-control TCP connections"
      start_test_endpoint || { diagnose; exit 1; }
      assert_distinct_namespaces || { diagnose; exit 1; }
      check_permissive_control || { diagnose; exit 1; }
      check_agent_network hermes@vm.service hb0 198.18.0.1 198.18.0.2 198.18.0.6 fd42:198:18::1 fd42:198:18::2 fd42:198:18:0:1::2 || { diagnose; exit 1; }
      check_agent_network hermes@vm-peer.service hb1 198.18.0.5 198.18.0.6 198.18.0.2 fd42:198:18:0:1::1 fd42:198:18:0:1::2 fd42:198:18::2 || { diagnose; exit 1; }
      check_dashboard_mapping || { diagnose; exit 1; }
      check_public_state_network hermes-pf@vm.service || { diagnose; exit 1; }
      check_public_state_network hermes-pf@vm-peer.service || { diagnose; exit 1; }
      stop_peer_probes
      start_fail_closed_probe || { diagnose; exit 1; }
      start_peer_probes hermes@vm.service 198.18.0.2 fd42:198:18::2 || { diagnose; exit 1; }
      start_peer_probes hermes@vm-peer.service 198.18.0.6 fd42:198:18:0:1::2 || { diagnose; exit 1; }
      check_agent_network hermes@vm.service hb0 198.18.0.1 198.18.0.2 198.18.0.6 fd42:198:18::1 fd42:198:18::2 fd42:198:18:0:1::2 || { diagnose; exit 1; }
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
      start_peer_probes hermes@vm.service 198.18.0.2 fd42:198:18::2 || { diagnose; exit 1; }
      start_peer_probes hermes@vm-peer.service 198.18.0.6 fd42:198:18:0:1::2 || { diagnose; exit 1; }
      check_agent_network hermes@vm-peer.service hb1 198.18.0.5 198.18.0.6 198.18.0.2 fd42:198:18:0:1::1 fd42:198:18:0:1::2 fd42:198:18::2 || { diagnose; exit 1; }
      check_public_state_network hermes-pf@vm-peer.service || { diagnose; exit 1; }
      echo "Restarting vm agent"
      stop_peer_probes
      timeout --kill-after=5s 180 systemctl restart hermes@vm.service || { diagnose; exit 1; }
      echo "Requiring peer restart after main restart"
      timeout --kill-after=5s 60 systemctl start hermes@vm-peer.service || { diagnose; exit 1; }
      timeout --kill-after=5s 60 systemctl restart hermes-pf@vm.service hermes-pf@vm-peer.service || { diagnose; exit 1; }
      if ! wait_for_active; then diagnose; exit 1; fi
      assert_distinct_namespaces || { diagnose; exit 1; }
      start_peer_probes hermes@vm.service 198.18.0.2 fd42:198:18::2 || { diagnose; exit 1; }
      start_peer_probes hermes@vm-peer.service 198.18.0.6 fd42:198:18:0:1::2 || { diagnose; exit 1; }
      check_agent_network hermes@vm.service hb0 198.18.0.1 198.18.0.2 198.18.0.6 fd42:198:18::1 fd42:198:18::2 fd42:198:18:0:1::2 || { diagnose; exit 1; }
      check_agent_network hermes@vm-peer.service hb1 198.18.0.5 198.18.0.6 198.18.0.2 fd42:198:18:0:1::1 fd42:198:18:0:1::2 fd42:198:18::2 || { diagnose; exit 1; }
      check_dashboard_mapping || { diagnose; exit 1; }
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
      settings.kanban.default_assignee = "hermes-vm";
    };
    agents.vm-peer = {
      enable = true;
      fullName = "hermes-vm-peer";
      headroomEnable = false;
      headroomPort = 18081;
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
    serviceConfig = {
      ExecStart = lib.getExe vmAgentRuntimeSmoke;
      StandardError = "journal+console";
      StandardOutput = "journal+console";
      # Gateway restarts recreate one mount per closure path in the 1-GiB guest.
      TimeoutStartSec = "900s";
      Type = "oneshot";
    };
  };
}
