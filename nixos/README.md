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

agent veths use `haN`/`hbN` interfaces, IPv4 subnets from `198.18.0.0/15`, and
per-agent ULA IPv6 `/80`s under `fd42:198:18::/48`. Startup fails on overlapping
host addresses/routes. The host resolver is proxied on each veth's host-side
addresses; TCP/UDP port 53 to those addresses and required IPv6 neighbor/error
control, plus established replies on configured mapping ports, remain narrow
exceptions. Explicit `networkAllow` rules permit only
their declared host/private tuples; all other new host connections are dropped.
Each agent also drops forwarded destinations in IPv4 private/shared/link-local,
loopback, documentation, benchmarking, multicast and reserved ranges, and IPv6
ULA, link-local, loopback, documentation, multicast and special-purpose ranges.
This includes RFC1918, 100.64.0.0/10, 169.254.0.0/16, 198.18.0.0/15,
233.252.0.0/24 (within the denied IPv4 multicast range), 2001::/32 (Teredo),
2001:2::/48 (benchmarking), 2001:db8::/32 and 2002::/16 (6to4), plus 3fff::/20.
Other non-global IANA ranges listed in the policy are blocked too. Unlisted
addresses are treated as public-like, but may be unrouted or special-use.
This policy does not prove Internet reachability. Add an exact per-agent
permission for a private/special destination:

```nix
services.hermes-specialised-agent.agents.vm.networkAllow = [
  { address = "10.20.0.2"; port = 443; protocol = "tcp"; }
  { address = "fd42:1234::2"; protocol = "both"; }
  { } # The agent's two veth host addresses, either TCP or UDP, any port.
];
```

`protocol` is `tcp`, `udp`, or `both` (default); `address` is one literal IPv4
or IPv6 address (default: that agent's host-side v4 and v6 veth addresses), and
`port` is 1–65535 (default: any). CIDRs and DNS names are not accepted. Each
rule is scoped to that agent's interface and source address; peer-agent
subnets remain denied even if explicitly named. The resolver proxy remains a
deliberate exception: each agent can query its host-side resolver on TCP/UDP
53 even without a `networkAllow` entry.
The network helper waits for `network-online.target` before taking its upstream
resolver snapshot. Resolver changes after startup are not watched; restart the
agent service (`systemctl restart hermes@NAME.service`) to rebuild its network
and refresh the DNS upstreams. If host network readiness never completes, the
agent stays stopped rather than using an early or empty resolver configuration.
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
  { hostPort = 9119; agentPort = 9119; target = "loopback"; protocol = "both"; }
];
```

`portMappings = []` disables the localhost proxy. The `protocol` field accepts
`tcp`, `udp`, or `both` (default), so existing mappings now also reserve and
forward UDP unless marked `protocol = "tcp"`. Host ports must be greater than
1024; the same numeric host port may be used once for TCP and once for UDP,
but never twice for one transport. The default `target = "veth"` connects
directly to a service bound on the namespace interface; `target = "loopback"`
relays to a loopback-bound service such as the dashboard. Mappings are not
exposed on the host's non-loopback interfaces; this preserves host-only dashboard
access without opening a host port to the LAN. The host administrator can still
connect directly to the agent's veth address. NixOS `networking.nat.forwardPorts`
is intentionally not
used for the dashboard: it forwards from a configured external interface,
whereas this mapping is a host-loopback-only proxy.
Host-local application services/webhooks are unreachable by default except for
DNS; explicitly permitted tuples are the only additional access. The
public-state fixer has no network access.

## Per-service Nix store visibility

Each enabled `hermes@NAME`, `hermes-pf@NAME`, and `hermes-network@NAME` service
gets a separate read-only `/nix` view containing only its evaluated runtime
closure. The gateway closure follows its effective PATH, agent package
override, all template and instance lifecycle commands (including
NixOS-generated hooks), resolver/config files, CA bundle, configured plugins,
and peer profile configs/plugins. The public-state fixer and network helper
receive their own closures, including their lifecycle commands. Other host
store paths and NixOS profile and system aliases are hidden; package contents
are not stripped.

This is an intentional compatibility boundary: service processes can no longer
run arbitrary host `/nix/store` paths or discover packages through NixOS profile
aliases. Add runtime tools through the service PATH/package configuration,
plugins through `extraPlugins`, or reference store-backed resources in the
declared agent configuration. The offline VM fixture disables Headroom and
default skill downloads, so their default-on closure coverage is evaluated and
built separately; the VM does not exercise their runtime startup.

Each store path is a separate bind mount. The current VM fixture renders about
1.1k gateway binds per agent, 116 network-helper binds, and 19 public-state
fixer binds; package-set updates can change these counts and service start time.
The longer start/restart bounds apply only to the VM smoke test, not production
systemd timeouts.

For diagnostics, inspect `systemctl status hermes-network@NAME.service`,
`readlink /proc/$(systemctl show -p MainPID --value hermes@NAME.service)/ns/net`,
`ip link show haN`, `nft list table inet hermes-agent-guard`,
`nft list chain inet hermes-agent-guard hermes_agent_input_guard`,
`nft list chain inet hermes-agent-guard hermes_agent_forward_guard`,
`nft list chain inet nixos-fw input-allow`, `nft list chain inet nixos-fw forward-allow`,
`ss -ltnup 'sport = :9119'`, and the configured `hostPort`s. Stop/restart of an
agent removes and recreates its veth, routes, DNS forwarder, namespace relays,
and host-loopback proxies. Firewall rules are declarative in the NixOS ruleset,
not inserted per invocation. Removing a permission blocks subsequent packets
to that private/host tuple, but does not forcibly close the agent's userspace
socket; existing connections can remain open and time out. Public egress and
already-established public flows remain host-uplink dependent. Rollback by
reverting the module/configuration change and rebuilding or switching to the
previous NixOS generation; verify the effective guard rules and listeners after
the rollback.

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
checks that each service sees its store closure but not a known unrelated host
store sentinel (including the guest's read-only 9p alias),
and reads each peer's generated profile from the other agent's live mount
namespace using that service's UID/GID and supplementary groups. Each wait is
bounded at 120 seconds, and both agents must retain the same live PID and
restart count with `active/running` state for 10 seconds after startup and
restarts, including after profile reads. A failure prints unit status and the
last 80 journal lines per unit. Successful boots print
`Hermes VM runtime checks passed` on the serial console.
Gateway start/restart commands are bounded at 180 seconds and the smoke unit
at 1200 seconds to allow per-store-path mount setup and the expanded live
network-policy probes in the 1-GiB guest; the VM's
RAM and disk limits are unchanged.
For each real agent, the smoke check also runs `hermes profile list` from that
agent's captured network namespace with its own `HOME` and verifies its default
profile and the other agent's profile are visible. It stops the gateways while
running the CLI to stay within the 1-GiB VM memory limit, then restarts them and
repeats network checks. A separate peer-profile read runs as the service identity.
Shared profile IDs must follow Hermes'
profile-ID grammar (lowercase letters, numbers, `-`, `_`); the VM fixture uses
`hermes-vm` and `hermes-vm-peer` and sets
`kanban.default_assignee = "hermes-vm"`.
The VM delays creation of its loopback-stub resolver until the
`network-online.target` prerequisite, and the smoke check verifies the resolver
was present before agent network startup. Host/peer TCP denial probes first
prove their listeners accept connections from a control context; a temporary
firewall allow rule also proves the denial oracle detects a reachable host
service before the rule is removed. Peer listeners are recreated in both live
agent namespaces after restarts.

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
