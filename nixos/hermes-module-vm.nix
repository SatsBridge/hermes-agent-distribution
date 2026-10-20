{ lib, pkgs, ... }: {
  imports = import ../modules/module-list.nix;

  services.hermes-specialised-agent = {
    enable = true;
    mainAgent = "vm";
    agents.vm = {
      enable = false;
      fullName = "Hermes module VM";
      headroomPort = 18080;
    };
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
}
