{ lib, pkgs, ... }:
let
  vmAgentRuntimeSmoke = pkgs.writeShellApplication {
    name = "hermes-module-vm-agent-smoke";
    runtimeInputs = [
      pkgs.gawk
      pkgs.acl
      pkgs.coreutils
      pkgs.systemd
      pkgs.util-linux
    ];
    text = ''
      units=(
        hermes@vm.service
        hermes@vm-peer.service
        hermes-pf@vm.service
        hermes-pf@vm-peer.service
      )

      diagnose() {
        echo "Hermes VM runtime check failed; unit status follows:" >&2
        timeout 15s systemctl status --no-pager --full "''${units[@]}" >&2 || true
        for unit in "''${units[@]}"; do
          timeout 15s journalctl -b -u "$unit" --no-pager -n 80 >&2 || true
        done
        getfacl -p -- /var/lib/hermes-vm /var/lib/hermes-vm/.hermes /var/lib/hermes-vm-peer /var/lib/hermes-vm-peer/.hermes >&2 || true
      }

      assert_agents_stable() {
        local deadline=$((SECONDS + 10)) unit state substate pid restarts current expected=
        echo "Checking agent stability for 10 seconds"
        while (( SECONDS < deadline )); do
          current=
          for unit in hermes@vm.service hermes@vm-peer.service; do
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
            return $?
          fi
          sleep 2
        done
        echo "Timed out waiting for Hermes units to become active" >&2
        return 1
      }

      check_profile() {
        local agent="$1" peer="$2" unit="hermes@$1.service" pid uid gid groups
        echo "Preparing profile access check: $agent -> $peer"
        pid=$(timeout 10s systemctl show --property=MainPID --value "$unit")
        [[ "$pid" =~ ^[1-9][0-9]*$ ]]
        uid=$(awk '/^Uid:/ { print $3; exit }' "/proc/$pid/status")
        gid=$(awk '/^Gid:/ { print $3; exit }' "/proc/$pid/status")
        groups=$(awk '/^Groups:/ { $1 = ""; gsub(/[[:space:]]+/, ","); sub(/^,/, ""); print; exit }' "/proc/$pid/status")
        echo "Checking $agent -> $peer profile as pid=$pid uid=$uid gid=$gid groups=$groups"
        # shellcheck disable=SC2016
        timeout --kill-after=5s --signal=TERM 30 "${pkgs.util-linux}/bin/nsenter" --target "$pid" --mount --root --wd -- "${pkgs.util-linux}/bin/setpriv" --no-new-privs --bounding-set=-all --inh-caps=-all --ambient-caps=-all --reuid="$uid" --regid="$gid" --groups="$groups" /bin/bash -euc '
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
                "${pkgs.coreutils}/bin/stat" -c "%A %u:%g %n" "$path" >&2 || true
              done
              exit 1
            fi
            expected="$2"
            found=
            for profile in "$profiles"/*; do
              if [[ ! -d "$profile" ]]; then
                echo "Profile entry is not traversable as service identity: $profile" >&2
                "${pkgs.coreutils}/bin/stat" -c "%A %u:%g %n" "$profile" >&2 || true
                continue
              fi
              name=''${profile##*/}
              printf "Visible profile from %s: %s\\n" "$3" "$name"
              [[ "$name" == "$expected" ]] && found="$profile"
            done
            [[ -n "$found" ]]
            test -r "$found/config.yaml"
            config=$(<"$found/config.yaml")
            [[ "$config" == *agent_profile_name* && "$config" == *"$expected"* ]]
            echo "Read peer profile from service namespace: $expected"
          ' -- "$agent" "$peer" "$unit" "$uid" "$gid" "$groups"
      }

      if ! wait_for_active; then diagnose; exit 1; fi
      echo "Restarting public-state services"
      timeout --kill-after=5s 60 systemctl restart hermes-pf@vm.service hermes-pf@vm-peer.service || { diagnose; exit 1; }
      if ! wait_for_active; then diagnose; exit 1; fi
      echo "Restarting vm-peer agent"
      timeout --kill-after=5s 60 systemctl restart hermes@vm-peer.service || { diagnose; exit 1; }
      timeout --kill-after=5s 60 systemctl start hermes-pf@vm-peer.service || { diagnose; exit 1; }
      if ! wait_for_active; then diagnose; exit 1; fi
      echo "Restarting vm agent"
      timeout --kill-after=5s 60 systemctl restart hermes@vm.service || { diagnose; exit 1; }
      echo "Requiring peer restart after main restart"
      timeout --kill-after=5s 60 systemctl start hermes@vm-peer.service || { diagnose; exit 1; }
      timeout --kill-after=5s 60 systemctl restart hermes-pf@vm.service hermes-pf@vm-peer.service || { diagnose; exit 1; }
      if ! wait_for_active; then diagnose; exit 1; fi

      for unit in "''${units[@]}"; do
        state=$(timeout 5s systemctl show --property=ActiveState --value "$unit")
        substate=$(timeout 5s systemctl show --property=SubState --value "$unit")
        service_type=$(timeout 5s systemctl show --property=Type --value "$unit")
        echo "Verified $unit: $state/$substate ($service_type)"
      done

      check_profile vm "Hermes module VM peer" || { diagnose; exit 1; }
      check_profile vm-peer "Hermes module VM" || { diagnose; exit 1; }
      if ! wait_for_active; then diagnose; exit 1; fi
      echo "Hermes VM runtime checks passed"
    '';
  };
in
{
  imports = import ../modules/module-list.nix;

  # This isolated, network-restricted test VM needs Hermes' current Matrix dependency.
  nixpkgs.config.permittedInsecurePackages = [ "olm-3.2.16" ];

  services.hermes-specialised-agent = {
    enable = true;
    mainAgent = "vm";
    agents.vm = {
      enable = true;
      fullName = "Hermes module VM";
      headroomPort = 18080;
    };
    agents.vm-peer = {
      enable = true;
      fullName = "Hermes module VM peer";
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
      TimeoutStartSec = "600s";
      Type = "oneshot";
    };
  };
}
