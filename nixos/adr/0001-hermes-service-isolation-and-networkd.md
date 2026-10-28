# ADR 0001: Hermes service roots, networkd ownership, and resolver proof

Status: proposed; the owner authorized internal privilege separation, but
implementation is partial and independent acceptance review remains pending.
This is not a risk exception or release authorization.
Date: 2026-10-28

The owner authorized splitting internal roles to avoid workload `CAP_SYS_ADMIN`
(task thread, followed by design review t_b1ae7c4b). Preserve the public
families and existing DNS/NAT owners; let the manager enter namespaces, separate
host administration from unprivileged proxies, and validate generation-scoped
agent observations before authorization. The legacy-role table below describes
the pre-split checkpoint; the first implemented split boundary is recorded
separately below. Neither is an accepted final topology. No further topology
permission is needed within those boundaries. PID1 still needs privileges to
construct roots/namespaces; the service payload is not a nested container
manager, so the systemd Container Interface's cgroup-delegation and
manager-capability advice does not justify granting those privileges to
payloads.

## Context and boundaries

The NixOS module operates five production service families: `hermes@` (gateway),
`hermes-pf@` (public-state fixer), `hermes-network@` (host/veth setup),
`hermes-dhcp@` (DHCP client), and `hermes-network-ready@` (readiness
coordinator). This ADR records design decisions for the existing service and
network contracts. No formal SDD was present in the repository; this record does
not claim an upstream or owner-approved SDD.

Preserved contracts: dynamic host IPv4 `/30` + IPv6 `/64`/SLAAC,
protocol/port-specific nftables policy and fail-closed readiness, host-loopback
mappings, host DNS proxy ownership, peer profiles/ACLs, existing user/shared
state, KVM, hook closure overrides, default-on Headroom/skills, NixOS NAT
`externalInterface`, and unrelated uplink ownership. No package/pin update, new
DNS/NAT owner, user-state migration, quota, or unrelated host-daemon re-rooting
is authorized here.

Decision: use per-instance `RootDirectory=` trees and individually-bound Nix
closures; use NixOS `systemd.network.networks` for the generated `.network`
files; strengthen the existing DNS regression without changing resolver
architecture.

## Service and data boundaries

The following table is the historical pre-split checkpoint, not the effective
settings of the new setup/anchor/controller units.

`G` = gateway; `PF` = public-state fixer; `N` = network setup; `D` = DHCP; `R` =
readiness.

| Boundary | G | PF | N | D | R |
|---|---|---|---|---|---|
| Identity | `DynamicUser`; no capabilities | `DynamicUser`; `DAC_READ_SEARCH`, `FOWNER` | root; host network and manager operations | `DynamicUser`; `NET_ADMIN`, `NET_BIND_SERVICE`, `NET_RAW` ambient + bounded | root; host firewall, DNS and manager operations |
| Root | `%t/hermes-%i/root` | `%t/hermes-%i-pf/root` | `%t/hermes-network-%i/root` | `%t/hermes-dhcp-%i/root` | `%t/hermes-network-ready-%i/root` |
| Runtime root creation | base runtime dir + `root` + `root/etc` | base + `root` | base + `root` | base + `root`; native aliases plus one ExecStart link | base + `root`, plus separate resolver-publication dir |
| Persistent state | existing gateway `StateDirectory`; preserve ownership | none; bind the existing gateway state tree read/write to perform ACL maintenance | none | per-instance `StateDirectory`; owner-authorized lease/DUID persistence | none; resolver output is separate volatile runtime state |
| Store | own evaluated closure only; existing profile/plugins/CA/shell/env/KVM bindings | own template + instance closure and effective hooks | own template + instance closure and effective hooks | dhcpcd/wrapper and all template + instance hooks | own template + instance closure and effective hooks |

The fixer needs `BindPaths=%S/hermes-%i`: `ReadWritePaths=` alone does not
expose the host gateway state tree inside `RootDirectory=`. It deliberately does
not declare that tree as a fixer-owned `StateDirectory`, which could recursively
change ownership. The gateway's nested `root` is intentional: `%t/hermes-%i`
also contains its SSH runtime socket. The filesystem root must not alias that
runtime directory. The other service roots likewise use a distinct `root` child
to avoid mixing the chroot filesystem with the service's host runtime directory.

The packaged dhcpcd 10.3.2 uses `/var/run/dhcpcd` for PID/control files and
`/var/lib/dhcpcd` for lease/DUID state, with no runtime/state override flag. The
owner subsequently authorized persistent per-instance client state, superseding
the original ephemeral-client-state constraint; server `PersistLeases=runtime`
is unchanged. Use the owner's two-entry
`RuntimeDirectory=[hermes-dhcp-%i:dhcpcd, hermes-dhcp-%i/root]`; the alias
creates `/run/dhcpcd`. `StateDirectory=hermes-dhcp-%i:dhcpcd` natively creates
the private-root state alias. A single static link in the existing ExecStart
wrapper points `/var/run/dhcpcd` to `/run/dhcpcd`. No directory creation or
environment-path parsing is needed. Its parent is one private `/var/run` tmpfs
with sticky mode 1777, allowing the dynamic identity to create the link without
root, chown, extra capabilities, or unmanaged directory trees. Only this
service's mount namespace sees that tmpfs; it contains a link, while actual
PID/control files live in the manager-owned 0700 runtime directory. Creating
that link in ExecStartPre would populate a different per-command tmpfs.
`User=hermes-dhcp-%i` avoids the default template-wide DynamicUser identity.
Runtime parents/root disappear on stop; lease state persists and is isolated per
instance. The root is writable through its runtime alias, not an immutable-root
boundary.

The previous absolute native-alias proposal was invalid: systemd v261
`load-fragment.c` `config_parse_exec_directories()` requires both source and
destination to be relative and ignores the whole assignment on failure. A
relative runtime alias under `hermes-dhcp-%i/root/var/run/dhcpcd` is also wrong:
the manager emits `../../..`, which resolves to `/` after chroot rather than the
runtime parent. Live guest readlink/mountinfo proved this; do not relax
protection of `/` to accommodate it. The state alias does not cross that root
boundary and works. An earlier `$root` mkdir wrapper failed on root-owned parent
permissions and was removed, not given a privilege bypass. The final proposed
layout adds no host `/run` or `/var` import. `ReadWritePaths` does not import
host paths or override DAC ownership, but the tested `/var/lib` and `/var/run`
exceptions were redundant: managed directories and the explicit tmpfs are
already writable. They were removed after the operator-requested removal matrix
passed without them. Store paths stay read-only.

Host-write exposure is narrow and role-specific:

- `N`: bind only host `/run/systemd/network` read/write, with `ReadWritePaths=`
  for that path; bind `/run/systemd/private` and the D-Bus system socket
  read-only for `systemctl`/`networkctl` control. No whole-host `/run` or `/etc`
  bind.
- `R`: read-only bind of the host resolver snapshot to
  `/run/hermes-host-resolv.conf`, read-only `/run/systemd/private` for
  fail-closed `systemctl stop`, and write access only to its instance
  resolver-publication directory. It does not bind the host networkd directory
  or D-Bus socket.
- `D`: no `ReadWritePaths` declarations. Actual host write exposure is only the
  automatic per-instance runtime/state binds; `/var/run` is private tmpfs. No
  explicit `BindPaths` or host parent-tree bind.
- `PF`: only the existing gateway state tree is writable; store closure mounts
  remain read-only.
- `G`: existing state/shared-state/KVM bindings only; no broad host filesystem
  access.

`RootDirectory=` does not constrain host namespace operations performed by a
`CAP_SYS_ADMIN` process or actions authorized through the system-manager socket.
Setup/readiness remain trusted host-mutating code, not an adversarial-helper
containment boundary.

## Per-role execution hardening

### First implemented split boundary (not whole-task acceptance)

`hermes-netns@` is a root-identity, zero-capability `sleep` lifetime anchor.
Its explicit `CapabilityBoundingSet=""` is important: the Nix unit renderer
omits an empty list rather than emitting an empty directive. A root process
with the omitted directive retains capabilities. The failed prerequisite guest
exposed this, and the corrected guest demonstrated zero effective/permitted/
bounding/ambient capabilities. No dumpability override, SYS_PTRACE or privileged
initializer is necessary for the corrected zero-capability anchor.

`hermes-host-control@` is now the only setup role that creates/deletes the host
veth and RA files. PID1 selects `/proc/1/ns/net` using NetworkNamespacePath;
this unit never joins the anchor and its payload has only NET_ADMIN. The public
`hermes-network@` remains the private-namespace join point. It is ordered after
and bound to both anchor and host controller, joins only the anchor, and brings
up `lo`/the moved peer with NET_ADMIN. Both setup payloads deny setns, namespace
creation and privileged/credential-change syscall groups. Neither starts proxy
children or has SETUID/SETGID/SYS_ADMIN/SYS_PTRACE. Local setup has only
AF_NETLINK/AF_UNIX and no manager socket or networkd runtime bind. The anchor has
only AF_UNIX, no host socket and no persistent state. All three have their own
root/runtime directories, closure/hook discovery, private devices/mounts/tmp/
IPC, strict system/kernel/cgroup protection, closed device policy and MDWE.
PrivateUsers remains off: controller/local NET_ADMIN must apply to the network
namespace's owning user namespace; the anchor's root UID is the tested proc-FD
access contract, not general privilege. PrivatePIDs remains off to preserve the
host PID/namespace identity checks. No BPF/network policy is substituted.

Host-controller setup notification has these exact postconditions: anchor
InvocationID is 32 lowercase hexadecimal characters, PID is greater than one,
process start time and namespace inode are captured, a namespace FD is held,
the owned/aliased veth exists, peer MAC is configured, the peer was moved using
that FD, the anchor identity was rechecked, and the host link is up. This does
NOT mean the host has an address, RA prefix, DHCP, SLAAC or traffic authorization.
Only after this acknowledgement does public local setup bring the peer up.
The controller continues the existing bounded host allocation/overlap checks
and RA publication/reconfigure, avoiding a carrier-before-ack deadlock. It keeps
checking the anchor identity afterward. The existing privileged readiness code
still performs the DHCP/SLAAC/routes/exact-policy barrier; replacing that code
and splitting proxies/telemetry remains outstanding, not implicitly accepted.

The namespace FD is opened only after manager PID/generation validation; process
start time, PID, InvocationID and namespace inode are checked immediately before
and after movement, then while the controller runs. PID reuse cannot retarget
the held FD. Any mismatch fails the owner and runs cleanup. Host-control
ExecStopPost also attempts cleanup after SIGKILL/failed start. Failed nft set
flushing is now reported and attempts to block the owned host link before
deletion; no silent flush success is claimed. This does not yet prove the final
cross-role loss budget. A targeted production-controller SIGKILL test flushed a
populated allocation set and deleted its link in 601.18274 ms while a synthetic
dependent was still in its eight-second ExecStop. This covers that failure edge,
not normal ordered stops, a slow gateway, observer/proxy loss or nft failure.
Controller normal
TERM exits successfully after cleanup; unexpected exits still invalidate
BindsTo consumers. Anchor and controller are PartOf the public network lifetime.

Manager-client contract: SYSTEMD_OFFLINE=0 handles verb-level chroot/offline
detection, but does not override sd_booted(). A read-only store-backed empty
directory at `/run/systemd/system` supplies that boot marker without importing
the host directory. Controller binds only the system-manager private socket
and networkd's varlink socket, plus writable `/run/systemd/network`. The
prerequisite guest exercised real in-unit show/stop, reload/reconfigure and a
failing start for a missing unit without a host D-Bus socket. `systemctl show`
alone can return success/MainPID=0 for a nonexistent unit, hence the explicit
PID/generation validation. A read-only socket mount does NOT constrain API
authority: the root controller remains trusted host control. The legacy
readiness role temporarily also receives the private boot marker; the final
unprivileged readiness/proxy roles must lose manager access.

The maintained VM ExecStartPost runs a Python assertion under the actual local
setup cgroup/seccomp/mount controls, not a root nsenter approximation. It checks
NET_ADMIN-only effective/bounding caps, zero ambient, NNP and seccomp, and denied
INET/INET6/PACKET creation, setns and unshare. The detached prerequisite guest
proved FD movement with denied setns; actual production-role/DHCP regression
and broader lifecycle evidence are tracked separately. Image builds or this
limited probe are not whole-system enforcement proof.

### Proposed split contract (not yet implemented)

The following concrete graph implements the direction reviewed in t_b1ae7c4b.
Review its lifetime/data contracts before replacing the pre-split helper.
This is not a second request for owner permission to split internal roles.

- `hermes-netns@`: a root-identity, zero-capability lifetime anchor. PID1
  creates its private network namespace. A per-instance runtime record binds
  its InvocationID, MainPID, process start time and namespace inode. No
  proxies, manager socket, host network operations or persistent state.
  Root identity is proposed only to let host control open the namespace FD
  without SYS_PTRACE; prove ptrace/DAC checks under final controls.
- `hermes-host-control@`: host namespace selected by PID1 through
  `NetworkNamespacePath=/proc/1/ns/net`; never joins the anchor. Root with
  NET_ADMIN only. Owns veth creation/removal, RA lock/drop-in, host resolver
  snapshot, allocation/config/resolver publication, nftables verification
  and revocation. Opens and validates the anchor reference before moving
  the peer with rtnetlink, without workload setns. Holds the namespace FD
  through movement and rechecks the manager's anchor generation afterward.
  Its Type=notify acknowledgement means HOST SETUP ONLY, not authorization.
  The same process then monitors host policy, observer data and listeners.
- Public `hermes-network@` remains the agent namespace join point and
  local-link setup oneshot. Joins the anchor after host setup; NET_ADMIN
  only, no workload setns, child credential changes or packet proxies.
- `hermes-dhcp@` joins that namespace after local-link setup. Keep the
  tested dynamic identity and bounded NET_ADMIN/NET_BIND_SERVICE/NET_RAW.
- `hermes-network-observer@` joins the agent namespace after DHCP starts.
  Unique DynamicUser, zero capabilities. Reads addresses/routes and
  atomically publishes non-executable telemetry from its own runtime dir.
  It notifies only after producing a usable current-generation observation.
- `hermes-dns@` runs the existing per-agent host-veth DNS proxy directly as
  a unique DynamicUser, with NET_BIND_SERVICE only. No credential-drop
  wrapper, NET_ADMIN, manager socket or host resolver watcher. Reads the
  immutable host-resolver snapshot/config for this generation.
- `hermes-host-proxy@` groups only the configured host-loopback mappings:
  host namespace, unique DynamicUser, zero capabilities, bind 127.0.0.1.
- `hermes-agent-relay@` groups only agent loopback relays: joins the anchor,
  unique DynamicUser. Grant NET_BIND_SERVICE only when a configured relay
  port requires it under the actual namespace threshold; do not reject
  existing low-port mappings or change that threshold globally.
- Public readiness becomes an unprivileged observer of the host control's
  generation-scoped authorization, with mandatory loss dependencies on
  all required roles. The gateway and fixer retain their existing roles.
  Empty proxy/relay groups need no unit. Every internal service still gets
  its own root, necessary closure, restrictions and directory ownership.

Startup order, with arrows meaning Requires/BindsTo plus After:

1. anchor -> host control's HOST SETUP notification -> public local setup;
2. local setup -> DHCP -> usable observer notification;
3. observer -> required DNS, host mappings and agent relays;
4. host control validates telemetry, its own host addresses/routes, exact
   policy and current required listeners; publishes/verifies sets, then
   atomically publishes final authorization;
5. public readiness checks matching authorization and required units,
   notifies final READY -> gateway hooks and ExecStart.

Host control must not be ordered After or synchronously wait for public
readiness/observer before acknowledging host setup. Its monitor may wait
after that acknowledgement. The anchor has PartOf public network for
explicit stop/restart propagation, but does not Require public network.
Host control BindsTo+After anchor; local setup BindsTo+After both. All
agent consumers bind to the anchor as well as their functional producers.
Namespace joining is only private-consumer-to-anchor, never reciprocal
with host control. PartOf is not treated as health monitoring.

Only host control writes/removes the veth, RA files and allocation/DNS
publication directory. Only the observer owns its telemetry directory.
Consumers bind producer directories read-only, without redeclaring their
RuntimeDirectory. No gateway/proxy can forge either producer's record.
Both producers use atomic replacement; no record is sourced as shell.

Planned DAC/mount contract: the anchor publication directory is root-owned
0755 with 0644 non-secret generation records, separate from its 0700 root/runtime
tree. Host-control publication uses the existing per-index
`/run/hermes-agent-network-N` directory, root-owned 0755 with 0644 allocation,
resolver/config and authorization records. The unique per-instance observer UID
owns `/run/hermes-network-observer-N`, mode 0755, with 0644 telemetry records.
These contain network metadata, never credentials or resolver authentication
material. Consumers get same-path read-only DIRECTORY binds to survive atomic
replacement, not writable managed-directory declarations or file-bind snapshots.
Only the gateway resolv.conf intentionally remains a per-start file snapshot.
Public readiness reads controller publication; host control reads observer
publication; proxies read only controller config; gateway reads only resolv.conf.
No consumer can traverse producer private roots. Prove DAC reads with each real
dynamic identity and deny producer writes, including from gateway/proxy UIDs.
Producer runtime removal ends record lifetime; recovery must use a new anchor
and invocation generation, never adopt a stale file left by a failed start.

Telemetry DbC, version 1: a bounded JSON object containing the anchor
generation, namespace inode, interface name/index/MAC, boottime timestamp,
usable IPv4/IPv6 addresses with prefix lengths, and required default
routes. Accept exactly the known fields/types, bounded arrays and input
size (64 KiB), valid canonical addresses, matching interface/MAC/generation and
non-future fresh timestamps; reject duplicate JSON object keys as well as
duplicate array entries, invalid address states,
missing routes, stale/malformed records or dead producer. Keep the current
address-set equality, overlap checks, exact policy hash and nft readback.
The freshness/detection budget must fit existing runtime loss assertions;
do not silently extend their timeouts to make this split pass.

Planned authorization DbC, version 1: at most 4 KiB, exactly version,
anchor InvocationID/PID/start-time/namespace-inode, controller InvocationID,
observer InvocationID, allocation/config digest, policy digest, observed
boottime-nanoseconds, and `authorized=true`. Digests are lowercase SHA256 and
InvocationIDs are lowercase 32-hex strings; PIDs/start-times/inodes/timestamps
are positive integers, not booleans or floats. Reject unknown/missing fields,
duplicate keys, unsupported versions, malformed bounds/types, wrong generation,
changed producer identity, stale/future timestamps and a dead/non-active producer.
No permissive parser or shell evaluation is allowed. Observer publishes every
0.5 seconds; host validation ticks at most once per second and accepts telemetry
only within two seconds of CLOCK_BOOTTIME. Authorization is refreshed only after
a complete successful validation tick; readiness revalidates at most every
0.1 seconds and rejects authorization older than two seconds. These are proposed
validation budgets, not a measured loss guarantee or permission to raise the
existing ten-second runtime loss assertions. Parser negative cases and real
end-to-end revocation timing must pass before this contract is accepted.

Any required process/child loss invalidates authorization. Proxy group
supervisors fail if any required child exits. Host control ExecStopPost
must revoke even after SIGKILL/failed start: if set flushing fails, bring
the owned host link down before deletion and report the failure. It stops
all consumers and the anchor before recovery; no old namespace reference
or record may survive into a new generation. Explicit public recovery
remains required; do not add automatic restart semantics.

Required review/tests: namespace FD access with NET_ADMIN but no
SYS_ADMIN/SYS_PTRACE; graph ordering and every stop/failure path; observer
parser negative tests; every internal main/child kill and stale generation;
private mounts/closure/hooks per role; zero-capability DNS/proxy startup
except demonstrated bind privilege; existing firewall/DAD/DHCP/DNS/state
matrix and ordinary activation/rollback. No final topology acceptance,
enforcement proof or startup-NFR waiver is claimed by this proposal.

### Current pre-split candidate settings

All five services keep `NoNewPrivileges=yes`, `ProtectSystem=strict`,
`ProtectHome=yes`, `ProtectProc=invisible`, private temporary files, private
devices/network/mount namespaces, private keyring, `RemoveIPC=yes`, native
syscall architecture, `SystemCallErrorNumber=EPERM`, and the syscall
allowlist/denylist below. `ProtectClock`, `ProtectHostname=private`,
`ProtectKernelLogs`, `ProtectKernelModules`, `ProtectKernelTunables`, and
`ProtectControlGroups=strict` are enabled per role. `MountAPIVFS=yes` is
retained for the private roots. `MemoryKSM=true` was removed from all roles:
these services are separate security domains, and cross-domain page merging is
not accepted as an implicit optimization.

| Control | G | PF | N | D | R |
|---|---|---|---|---|---|
| `PrivateTmp`, `PrivateDevices`, `PrivateNetwork`, `PrivateIPC`, `PrivateMounts` | enabled | enabled | enabled | enabled | enabled |
| `PrivatePIDs` | off: gateway child lifecycle and process visibility compatibility are unproven | off: no tested need; avoid changing monitor semantics | off: `/proc/1/ns/net` and host PID targeting are required | off: preserve packaged client lifecycle; no test justifies a PID namespace | off: host PID namespace operations are required |
| `PrivateUsers` | `identity`: preserve existing dynamic identity boundary | `identity`: preserve existing dynamic identity boundary | off: host network namespace and host capabilities must remain effective | off: ambient network capabilities must apply to the joined network namespace | off: same host namespace/capability requirement as setup |
| `PrivateBPF` | off: no bpffs use; not a packet firewall | same | same | same | same |
| `ProtectSystem`, `ProtectHome`, `ProtectProc` | strict / yes / invisible | strict / yes / invisible | strict / yes / invisible | strict / yes / invisible | strict / yes / invisible |
| `ProtectClock`, `ProtectHostname`, kernel logs/modules/tunables, control groups | enabled | enabled | enabled | enabled | enabled |
| `ProcSubset` | not set: gateway/ONNX compatibility; `/proc/cpuinfo` remains read-only | `pid` | `pid` while retaining `/proc/1/ns/net` | `pid`; DHCP renewal is the runtime compatibility check | `pid` while retaining `/proc/1/ns/net` |
| Address families | `INET`, `INET6`, `UNIX` | `UNIX` only | `INET`, `INET6`, `NETLINK`, `UNIX` | `INET`, `INET6`, `NETLINK`, `PACKET`, `UNIX` | `INET`, `INET6`, `NETLINK`, `UNIX` |
| `RestrictNamespaces` | true (deny all) | true (deny all) | `net` only; setup must join host netns | true (deny all) | `net` only; it enters the host netns |
| `RestrictRealtime` | true | true | true | true | true |
| `RestrictSUIDSGID` | true | true | true | true | true |
| `SystemCallFilter` | `@system-service`, deny `@resources` and `@privileged` | same | same plus explicit `setns`, `setuid`, `setgid`, `setgroups`, `setresuid`, `setresgid` | `@system-service`, deny `@resources` and `@privileged` | same explicit namespace/credential-drop exceptions as setup |
| Device cgroup | `DevicePolicy=closed`, only `/dev/kvm rw` allowed | `DevicePolicy=closed` | `DevicePolicy=closed` | `DevicePolicy=closed` | `DevicePolicy=closed` |
| Capabilities | bounding and ambient sets empty | bounding/ambient `DAC_READ_SEARCH`, `FOWNER` | `NET_ADMIN`, `SETGID`, `SETUID`, `SYS_ADMIN`, `SYS_PTRACE`; ambient empty | `NET_ADMIN`, `NET_BIND_SERVICE`, `NET_RAW`; ambient equals bounding set | setup set plus `NET_BIND_SERVICE`; ambient empty |
| `MemoryDenyWriteExecute` | off: Hermes/Headroom JIT/FFI/ONNX compatibility not established | on | on | on | on |
| Keyring, `RemoveIPC`, umask | private / yes / `0007` | private / yes / `0077` | private / yes / `0077` | private / yes / `0077` | private / yes / `0077` |

The pre-split helpers still use `setns()` and credential-drop syscalls; removing
these remains required by the approved split. `RestrictSUIDSGID` prevents
setting filesystem SUID/SGID bits, NOT credential transitions. Earlier
task-thread rationale claiming the opposite was incorrect; no role has a
demonstrated filesystem-mode exception. Capability and syscall controls govern
credential transitions separately. Final generated syscall ordering/enforcement
still requires proof; the partial candidate is not accepted because it lists
exceptions.

`ProtectProc=invisible` is defense in depth, not a claim that root or
`CAP_SYS_PTRACE` cannot inspect host processes. Root-directory + narrow
bind/socket access and operation tests are the boundary evidence. Dynamic users
are used for gateway, public-state fixer, and DHCP; setup/readiness remain root
because they mutate host networking/firewall and control host systemd/networkd
through privileged interfaces.

## Reviewed but not enabled / resource controls

These are deliberately not omitted by accident. Reasons apply to all five roles
unless a role-specific distinction is stated.

| Option family | Decision and reason |
|---|---|
| `RestrictFileSystems` | not enabled: depends on BPF-LSM availability; a fixed filesystem allowlist would reject the VM's required 9p Nix store. No filesystem-control proof is claimed. |
| `IPAddressAllow` / `IPAddressDeny` | not enabled: address-only cgroup filters do not encode current nftables protocol/port rules, can be ineffective on unsupported kernels, and must not replace authoritative nftables. |
| `SocketBindAllow` / `SocketBindDeny` | not enabled: not a substitute for destination/protocol/port nftables policy; setup/readiness create dynamic sockets and DHCP needs raw/packet sockets. |
| `RestrictNetworkInterfaces` | not enabled: setup/readiness cross host and agent network namespaces and move a veth peer; an interface-name list could silently break that lifecycle. |
| `PrivateBPF`, custom BPF programs/delegation | no custom BPF. `DevicePolicy`/`DeviceAllow` provide supported device filtering; `PrivateBPF` only isolates bpffs and is not network filtering. No BPF delegation. |
| `SystemCallLog` | not configured: denied calls return `EPERM`; logging all denied syscall attempts is noisy and has no bounded diagnostic consumer. |
| `RootImage`, `RootEphemeral`, root-image verification/integrity/encryption | not selected: individual store-path bindings plus ephemeral runtime roots meet the contract without building and maintaining images. These are alternatives, not requirements. |
| LSM labels/profiles | not added: no per-service AppArmor/SELinux profile exists in the repository; introducing host policy is a separate deployment/compatibility decision. |
| CPU weights/quotas/affinity, memory high/max/swap/zswap limits, OOM score/policy, task limits, IO weights/limits | no explicit hard limits: no workload measurements or owner-approved availability envelope. Arbitrary limits can make gateway startup, DHCP renewal, ACL maintenance, or recovery fail. |
| CPU/memory/IO/IP accounting and PSI thresholds | not enabled: no monitoring consumer or operational threshold is defined. No accounting/pressure claim is made. |
| cgroup delegation/subgroup | disabled/default false; no service manages child cgroups. `DelegateNamespaces=false` remains explicit for gateway/fixer. |
| `MemoryKSM` | disabled for every role due isolated security domains. |

Device filtering is separate from protocol/port network filtering. No custom BPF
program or optional kernel feature is treated as authoritative. The host
nftables guard and verified address sets remain the source of network policy.

## NixOS networkd and DNS decisions

The handwritten `environment.etc` `.network` file and manual networkd/socket
activation are replaced by `systemd.network.networks."40-hermes-agent-N"`. The
key, match (`Name=haN`, `Kind=veth`), `RequiredForOnline=no`, `/30` and `/64`
addresses, DHCP server, IPv4/IPv6 forwarding, RA, runtime lease, pool
offset/size, and router semantics remain the same. The pinned NixOS
`networkd.nix` emits generated `.network` sources into
`systemd-networkd.reloadTriggers`; its service is wanted by `multi-user.target`
and has `stopIfChanged=false`. Runtime RA drop-ins are generated under `/run`
and are still explicitly reloaded/reconfigured by the trusted helper because
they are not Nix-generated sources.

`systemd.network.enable` is set only when the module has active agents. The
networkd wait-online integration is disabled with a weak default only when this
module activates networkd while `networking.useNetworkd=false`; explicit host
policy wins, and hosts using networkd retain their explicit wait-online policy.
On hosts not managed by networkd, the Hermes `ha*` interfaces are the only added
networkd matches; host `networking.useDHCP`, dhcpcd, NetworkManager, and
unrelated uplinks remain host-owned. `networking.dhcpcd.denyInterfaces` and
NetworkManager's `interface-name:ha*` exclusion prevent overlap on Hermes veths.
Nixpkgs emits a generic `systemd.network.enable` + `networking.useDHCP` warning
in this coexistence case; do not silence it by changing host uplink ownership.

NixOS networkd can default-enable systemd-resolved. When Hermes alone enables
networkd on a host with `networking.useNetworkd=false`, the module weakly
preserves the prior no-resolved default; explicit host
`services.resolved.enable` decisions take precedence. No new DNS owner is
introduced.

The DNS design is unchanged: the agent gets only allocated host-veth proxy
nameservers; the host resolver remains the upstream owner. The VM regression
inspects the complete `nameserver` list from `/proc/$PID/root/etc/resolv.conf`,
verifies host-controlled A and AAAA lookups through normal `getaddrinfo()` as
the agent UID/GID with `CapEff=0`, then repeats with one host resolver only. It
blocks both UDP/TCP DNS to that host endpoint and requires lookup failure,
restoring the resolver file and nft rules via an exit trap. This runs for both
agents and is repeated at existing post-restart probes. Existing UDP/TCP proxy
checks and the separate real-Internet DNS + certificate-verified HTTPS test
remain required. Public DNS/TLS failures remain failures; controlled `.test`
endpoints do not prove Internet reachability.

## Quality scenarios, rollout, and rollback

- Startup: each gateway remains blocked until DHCP, SLAAC, firewall readback,
  resolver publication, and DNS listeners are ready; loss still revokes the sets
  and stops the gateway.
- Compatibility: all five families and both VM instances must retain their root,
  individual Nix closure, effective hooks, identities, device policy,
  capabilities, and lifecycle behavior. Existing user/shared state and gateway
  state are not migrated or deleted.
- Network activation: first enable, changed `.network`, removal, and rollback
  must use ordinary NixOS activation with networkd already running, no operator
  manual reload, and unrelated uplink unchanged. Static source/reload-trigger
  evaluation is necessary but not runtime-switch proof.
- Rollback: switch to the previous NixOS generation; verify dynamic
  addresses/routes, runtime RA drop-ins, DNS listeners, service roots, and state
  sentinels. Runtime directories are service-owned ephemeral state; persistent
  gateway state remains unchanged.
- NFR: the existing startup timing target is still not met and remains
  informational; this ADR does not create a waiver. Bootloader updates, reboot
  behavior, and public IPv6 reachability remain unproven unless separately
  tested.

## Traceability and evidence

Trace: task `t_6010650d` and parent investigation comment 234 → this ADR →
`modules/services/agent/hermes.nix` templates/closures and `systemd.network`
declarations → `flake.nix` evaluation assertions → `nixos/hermes-module-vm.nix`
runtime scenarios. No formal SDD is claimed. Sources: systemd 261
`systemd.exec(5)` and `systemd.resource-control(5)`; pinned Nixpkgs
`nixos/modules/system/boot/networkd.nix` (network emission and reload trigger
logic); packaged dhcpcd 10.3.2 binary/source runtime paths.

Evidence status: this remains an incomplete pre-split candidate. Config
evaluation and offline/Internet VM builds succeeded; image construction is not
runtime or Internet evidence. Earlier full guest runs failed on missing
manager/NSS inputs and DHCP paths. The chroot-aware manager
override/socket/group fixes are present; no final whole-matrix success is
claimed.

The DHCP layout was exercised with actual production template controls in fresh
disposable guests. The targeted fixture suppresses gateway/fixer autostart to
isolate this boundary, uses the real network setup and both DHCP instances, and
replaces only the outer smoke runner. It checks symlink target identity,
actual-client-UID write access, `/30` acquisition, matching PID file, rebind,
stop/start, runtime removal and persistent sentinel retention. These
namespace-entered filesystem/control checks do not prove the client's
cgroup/seccomp enforcement; `/proc` capability evidence is from the actual
client.

The removal matrix ran three guests: no ReadWritePaths + private mode-1777 tmpfs
passed all four instance/round checks with guest exit 0 and QEMU exit 0.
Removing tmpfs failed both links with ENOENT. Keeping tmpfs at default 0755
failed both links with EACCES. Both negative guest probes exited 2 while QEMU
exited 0; QEMU status alone is not acceptance. Distinct actual client UIDs were
61470/63371 and effective capabilities were 0x3400 (NET_BIND_SERVICE, NET_ADMIN,
NET_RAW). State was a writable per-instance idmapped mount; `/var/run` was a
separate private tmpfs. The native runtime alias alone was also tested with
direct dhcpcd and no diagnostic pre-start: `/var/run/dhcpcd` was missing for
both clients. The host `/var/run` alias is not inherited.

The latest full pre-split offline run still failed before either gateway
started, although both DHCP clients acquired leases and the readiness
delay hook passed. Its journal reports dnsmasq startup failure, a loopback
relay bind failure on port 9119, and in-root systemctl rejecting the system
manager connection as "System has not been booted with systemd as init
system (PID 1)". A socket bind alone does not make manager clients work in
this root. Those proxy/manager contracts must be resolved and tested in the
split; this run is a failure, not whole-task acceptance. Shutdown stalled
unmounting `/nix/store`; the runner was terminated after retaining output.

Outstanding: implement and independently review the concrete privilege split;
prove namespace FD access and telemetry/loss contracts, final roots/closures and
enforcement, full offline/Internet regressions, default-on features, ordinary
networkd generation switching/rollback, and startup timing. The broad
config-check conjunction still needs named diagnostics before expanding split
assertions. No final acceptance, risk waiver, deployment or release
authorization. The host execution sandbox has no usable system manager;
host-side security scoring is not runtime evidence.
