# Hermes NixOS module VM

From the repository root, build a local x86_64-linux NixOS VM from the real
`modules/services/agent/hermes.nix` module. The fixture enables the module but
disables its test agent, so no Hermes gateway or public-state service starts.
QEMU networking is restricted; no host Hermes state or credentials are
supplied.

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
    agentEnabled = c.agents.vm.enable;
  }'
```

At boot, the `hermes-module-vm-smoke` one-shot prints the guest store mounts,
guest `MemTotal`, and root filesystem usage to the serial console. It fails if
`/nix/.ro-store` is not a read-only 9p mount or guest RAM exceeds 1024 MiB.
`/nix/store` is a bind of that read-only mount. The `hermes@.service` template
is present, but no agent instance is enabled.

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
