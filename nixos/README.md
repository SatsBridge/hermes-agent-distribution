# Hermes NixOS module VM

From the repository root, build a local x86_64-linux NixOS VM from the real
`modules/services/agent/hermes.nix` module with two real Hermes agents (`vm`
and `vm-peer`) and their public-state services. QEMU networking is restricted;
no host Hermes state or credentials are supplied, and the check does not make
model requests. Default skill downloads are disabled only for this offline
fixture; the real ownership initialization pre-step remains enabled. The
VM-only Nixpkgs configuration explicitly permits the
known-insecure `olm-3.2.16` Matrix dependency without clearing its vulnerability
metadata; this exception is not applied to other outputs. The real gateway
`ExecStart` and ownership initialization are tested.

The guest is configured with 1024 MiB RAM and a 1024 MiB root disk. The QEMU
command explicitly shares the host `/nix/store` read-only via 9p; the guest
does not copy the store into its root disk. This bypasses NixOS's Linux-host
virtiofs default because this fixture specifically tests the 9p guest mount.
The guest disk limit does not limit host-side Nix builds, the Nix store, or
qcow2 metadata/physical allocation.

```sh
nix --extra-experimental-features 'nix-command flakes' build .#hermes-module-vm-config-check
nixos-rebuild build-vm --flake .#hermes-module-vm
```

If `nixos-rebuild` is not installed, its equivalent VM build is:

```sh
nix --extra-experimental-features 'nix-command flakes' build .#nixosConfigurations.hermes-module-vm.config.system.build.vm
```

Run `./result/bin/run-nixos-vm` from a directory where the guest disk
may be created. To inspect the module without booting, run:

```sh
nix --extra-experimental-features 'nix-command flakes' eval --json \
  .#nixosConfigurations.hermes-module-vm.config.services.hermes-\
specialised-agent \
  --apply 'c: {
    inherit (c) enable mainAgent;
    agents = builtins.mapAttrs (_: a: {
      inherit (a) enable fullName headroomPort;
    }) c.agents;
  }'
```

At boot, the `hermes-module-vm-smoke` one-shot prints the guest store mounts,
guest `MemTotal`, and root filesystem usage to the serial console. It fails if
`/nix/.ro-store` is not a read-only 9p mount or guest RAM exceeds 1024 MiB.
`/nix/store` is a bind of that read-only mount. The
`hermes-module-vm-agent-smoke` one-shot then checks both agent and public-state
units are active, restarts both public-state units and both agent instances,
and reads each peer's generated profile from the other agent's live mount
namespace using that service's UID/GID and supplementary groups. Each wait is
bounded at 120 seconds, and both agents must retain the same live PID and
restart count with `active/running` state for 10 seconds after startup and
restarts, including after profile reads. A failure prints unit status and the
last 80 journal lines per unit. Successful boots print
`Hermes VM runtime checks passed` on the serial console.

Start the VM from a directory where its qcow2 disk may be created, then wait
for the runtime-check message on the serial console:

```sh
./result/bin/run-nixos-vm
```

On the host, verify the configured virtual disk capacity (1024 MiB / 1 GiB)
with the QEMU package selected by the VM:

```sh
qemu_img="$(nix --extra-experimental-features 'nix-command flakes' eval --raw \
  .#nixosConfigurations.hermes-module-vm.config.virtualisation.qemu.package)/bin/qemu-img"
"$qemu_img" info --output=json hermes-module-vm.qcow2
du -h hermes-module-vm.qcow2
nix --extra-experimental-features 'nix-command flakes' path-info -Sh .#nixosConfigurations.hermes-module-vm.config.system.build.vm
```

`du` reports sparse host allocation; `path-info` reports host store closure
size. Neither is bounded by the guest disk size.

No guest login credential is configured. Stop QEMU from the host (the QEMU
monitor is available with `Ctrl-A c`; use `quit` there), and wait for it to exit
before deleting the disk. In this sandbox, ACPI powerdown stalled while
unmounting `/nix/store`, so do not rely on guest `poweroff` completing. To reset
guest state, remove `hermes-module-vm.qcow2` before the next launch; never
delete it while QEMU is running.
