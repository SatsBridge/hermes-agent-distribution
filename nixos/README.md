# Hermes NixOS module VM

From the repository root, build a local x86_64-linux NixOS VM from the real
`modules/services/agent/hermes.nix` module with two real Hermes agents (`vm`
and `vm-peer`) and their public-state services. QEMU networking is restricted;
no host Hermes state or credentials are supplied, and the check does not make
model requests. Default skill downloads are disabled only for this offline
fixture. The optional Headroom proxy is disabled to stay within the 1024 MiB
guest limit; real Hermes gateways, the dashboard, and ownership initialization
remain enabled. Production Headroom defaults are unchanged. The
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

## Per-agent network isolation

Each enabled `hermes@NAME.service` keeps effective `PrivateNetwork=yes` and joins
the namespace of its `hermes-network@NAME.service` companion via
`JoinsNamespaceOf=`. The companion owns the otherwise isolated namespace, creates
one veth pair and starts the DNS/localhost port proxies. The nftables input and
forward rules are declared through `networking.firewall.extraInputRules`,
`networking.firewall.extraForwardRules`, and an early input guard table; the
firewall fails closed before a veth is brought up. It fails the agent start if
veth or DNS setup fails. `hermes-pf@NAME` remains in its own `PrivateNetwork=yes`
namespace with `RestrictAddressFamilies=AF_UNIX`.
The short-lived companion setup process is trusted host-networking code and is
granted `CAP_NET_ADMIN`, `CAP_SYS_ADMIN`, and `CAP_SYS_PTRACE` to move the veth
and configure the host namespace; its DNS and TCP proxy children drop to
`nobody` before serving requests.

Agent veths use `haN`/`hbN` interfaces, IPv4 subnets from `198.18.0.0/15`, and
per-agent ULA IPv6 `/80`s under `fd42:198:18::/48`. Startup fails on overlapping
host addresses/routes. The host resolver is proxied on each veth's host-side
addresses; TCP/UDP port 53 to those addresses, required IPv6 neighbor/error control,
and established replies to loopback dashboard proxies are the only accepted
agent-to-host traffic. New connections to all other host services are dropped.
Traffic to another Hermes agent subnet is blocked. Outbound IPv4/IPv6 routing
and NAT use NixOS `networking.nat` with nftables;
`networking.firewall.filterForward`
is enabled so forwarding is limited to configured NAT internal interfaces.
`networking.nat.externalInterface` remains `null`; NixOS therefore masquerades
agent traffic on any outgoing interface. Set that existing option when egress
must be restricted to a particular host interface.

This changes host-wide NixOS firewall/NAT behavior: the firewall backend becomes
nftables, forwarding is enabled for IPv4 and IPv6, and unconfigured forwarded
traffic is filtered. Existing routed networks must be represented by the
NixOS firewall/NAT configuration (or explicit nftables forward rules). Existing
`networking.firewall.extraCommands` or `networking.nat.extraCommands` are
incompatible with the nftables backends and cause configuration evaluation to
fail. The host must have no pre-existing routes/addresses overlapping the
reserved Hermes ranges. IPv6 egress depends on host IPv6 connectivity.

The main agent's dashboard stays bound to namespace loopback and defaults to a
host mapping `127.0.0.1:9119 -> agent namespace loopback:9119`. The companion
runs an unprivileged namespace relay and a second unprivileged host proxy; only
the latter listens on host loopback. Other mappings are declared per agent, for
example:

```nix
services.hermes-specialised-agent.agents.vm.portMappings = [
  { hostPort = 9119; agentPort = 9119; target = "loopback"; }
];
```

`portMappings = []` disables the localhost proxy. Host ports must be unique and
greater than 1024. `target = "veth"` (the default) connects directly to a service
bound on the namespace interface; `target = "loopback"` relays to a loopback-
bound service such as the dashboard. Mappings are not exposed on the host's non-loopback
interfaces; this preserves host-only dashboard access without opening a host
port to the LAN. The host administrator can still connect directly to the
agent's veth address. NixOS `networking.nat.forwardPorts` is intentionally not
used for the dashboard: it forwards from a configured external interface,
whereas this mapping is a host-loopback-only proxy.
Host-local application services/webhooks remain unreachable from agents except
for DNS. The public-state fixer has no network access.

For diagnostics, inspect `systemctl status hermes-network@NAME.service`,
`readlink /proc/$(systemctl show -p MainPID --value hermes@NAME.service)/ns/net`,
`ip link show haN`, `nft list table inet hermes-agent-guard`,
`nft list chain inet nixos-fw input-allow`, `nft list chain inet nixos-fw forward-allow`,
and `ss -ltnp 'sport = :9119'`. Stop/restart of an agent removes and recreates
its veth, routes, DNS forwarder, and configured localhost proxies. Firewall
rules are declarative in the NixOS ruleset, not inserted per invocation. Rollback
by reverting the module change and rebuilding the NixOS configuration.

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
