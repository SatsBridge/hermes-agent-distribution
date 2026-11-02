# ADR 0001: Hermes service roots, privilege separation and networkd

Status: proposed implementation; independent acceptance and owner release decisions
remain pending. This is not an approved exception or release authorization.
Date: 2026-10-28

## Context and decision

Task t_6010650d implements parent investigation t_86a163bd/comment 234. The owner
subsequently authorized internal service separation to remove workload
CAP_SYS_ADMIN, and persistent per-instance DHCP client state. Design review
 t_b1ae7c4b and implementation reviews require executable lifecycle/data contracts
and real guest evidence. No formal SDD exists; this ADR does not invent one.

Keep the five public families: gateway `hermes@`, fixer `hermes-pf@`, local setup
`hermes-network@`, client `hermes-dhcp@`, readiness `hermes-network-ready@`.
Add internal roles only at actual namespace, privilege or producer boundaries.
PID1 constructs/joins namespaces and roots. Payloads do not call setns or change
identity. This is not a claim that the host manager is CAP_SYS_ADMIN-free, nor a
nested container manager requiring the systemd Container Interface's privileges.

Preserve dynamic DHCPv4 /30 and SLAAC /64, exact protocol/port nft policy,
fail-closed startup/loss, host-loopback mappings, host DNS ownership and snapshot
semantics, peer ACL/profiles, existing user/shared state, KVM, hook closures,
default-on Headroom/skills, NAT externalInterface and unrelated uplink ownership.
No pins, packages, public options, NAT/DNS owners, quotas or state migrations are
added. Per-role RootDirectory trees expose only their evaluated runtime closures
and explicit data/device/socket mounts, not /nix or host profiles wholesale.

## Execution and ownership boundaries

| Role | Identity / effective privilege | Namespace and responsibility |
|---|---|---|
| anchor `hermes-netns@` | root UID, empty bounding/ambient caps | Own private netns lifetime; no manager API or network configuration. Root UID is the tested namespace-FD DAC/proc access contract, not general privilege. |
| controller `hermes-host-control@` | root UID, NET_ADMIN only; no ambient caps | PID1 joins host netns via NetworkNamespacePath. Creates/moves/deletes owned veth, networkd RA files, host allocation/resolver/config/authorization, exact nft readback and revocation. Never JoinsNamespaceOf the anchor. |
| failure reaper `hermes-network-failure@` | root UID, empty caps | OnFailure-only D-Bus client stops the private anchor after host-control ExecStopPost has completed; this prevents a failed host setup from stranding its waiting observer. No networking or host filesystem access beyond its own root and D-Bus socket. |
| local setup `hermes-network@` | distinct DynamicUser, NET_ADMIN bounded+ambient | Joins ordered anchor; brings up lo and moved peer. No manager API, DNS/proxy children or host runtime import. Ambient NET_ADMIN carries the one required privilege through exec as non-root. |
| DHCP `hermes-dhcp@` | distinct per-instance DynamicUser; NET_ADMIN, NET_BIND_SERVICE, NET_RAW bounded+ambient | Joins local namespace; packaged dhcpcd configures client addresses/routes, raw DHCP/ARP and client sockets. |
| observer `hermes-network-observer@` | distinct DynamicUser; zero caps | Joins ordered anchor, observes addresses/routes/listeners and publishes telemetry. No manager API or host mutation. |
| DNS `hermes-dns@` | distinct DynamicUser; NET_BIND_SERVICE bounded+ambient | Manager-selected host netns. Existing dnsmasq listens only on allocated host-veth addresses, reads one startup host-resolver snapshot. No setuid/setgid or manager access. |
| host proxy `hermes-host-proxy@` | distinct DynamicUser; NET_BIND_SERVICE only for configured ports below 1024, otherwise zero caps | Host netns; existing socat processes bind only 127.0.0.1. Group supervisor fails on any required child exit. |
| agent relay `hermes-agent-relay@` | distinct DynamicUser; NET_BIND_SERVICE only for configured low relay ports, otherwise zero caps | Anchor netns; existing socat relays veth listeners to namespace loopback, including supported low ports. Required child exit fails supervisor. |
| readiness `hermes-network-ready@` | distinct DynamicUser; zero caps | Anchor netns; checks controller authorization. No manager, host resolver, networkd, nft, writable producer bind or host capabilities. Sends its own READY=1 with NotifyAccess=main. |
| fixer `hermes-pf@` | DynamicUser, primary group hermes-shared; DAC_READ_SEARCH/FOWNER bounded+ambient | Private netns; changes only existing gateway-state ACLs. Numeric `id -g` supplies ACL GID; no host /etc/group bind or NSS group-name query. RestrictAddressFamilies=[] per owner direction; socket() denied explicitly by seccomp, under runtime test. |
| gateway `hermes@` | DynamicUser, zero caps | Joins local namespace only after final readiness. Existing state, peer-profile/shared-state and KVM behavior retained. |

Every added role has its own root and template+instance lifecycle-command closure
discovery. Shell interpreter/env and command dependencies are store references;
Python roles include their interpreter/stdlib and only the binaries their
selected role actually executes. No host shell/profile tree is imported.
Journald output uses inherited descriptors. DNS logs to stderr, avoiding an
otherwise required AF_UNIX syslog socket. Only gateway needs the existing CA
bundle. DHCP suppresses external exit hooks with /dev/null.

The controller alone receives a writable /run/systemd/network bind (RA lock and
drop-ins), the system D-Bus socket for documented system-manager API calls, and
the networkd Varlink socket. It does not bind /run/systemd/private. A store-backed
empty /run/systemd/system boot marker separately satisfies sd_booted();
SYSTEMD_OFFLINE=0 overrides verb-level chroot detection. A read-only mount of the
D-Bus socket does NOT limit API authority: this root controller remains trusted
host control, not a contained NET_ADMIN-only adversary. No whole /run, /etc or
/proc/1/root bind. All payload roles lack manager access.

The fixer binds the gateway state tree read/write deliberately. ReadWritePaths
is not an import into RootDirectory. It does not declare a competing
StateDirectory that would recursively transfer gateway ownership. Its primary
shared group allows numeric ACL operations without leaking all host groups.
The gateway's privileged `+` ownership pre-start remains a separate exception
requiring independent verification; its bypass is not attributed to the main
zero-capability process. Cgroup device controls still apply to that path.

DynamicUser exceptions are per-role, not a shared helper default:

- Anchor retains root UID but zero capabilities. Controller has no SYS_PTRACE;
  access to the anchor's namespace FD relies on matching root UID under proc/
  ptrace checks. A different dynamic anchor UID breaks this proven FD contract.
  Sharing a dynamic identity or adding SYS_PTRACE is not a least-privilege fix.
- Host controller retains root UID and NET_ADMIN. Its private system-manager
  connection is authorized by root peer credentials, RA directory access is
  root-owned, and it must open the root anchor namespace FD. NET_ADMIN alone on
  a dynamic UID grants none of those filesystem/API rights. A new broker/polkit
  authorization interface is not part of this implementation.
- Failure reaper retains root UID only for the same system-manager D-Bus peer
  authorization; it has zero capabilities and can request only the single
  instance anchor stop in its executable operation.
- Local setup has no such requirement after the split. It now uses a distinct
  DynamicUser with NET_ADMIN bounded+ambient, remains in the initial owning
  user namespace and joins the manager-selected anchor netns. Its current
  operation/enforcement proof must be rerun after this identity change.

CapabilityBoundingSet is an upper bound, not a non-root privilege grant.
DynamicUser payloads need AmbientCapabilities for the same required bits to
survive ordinary interpreter/tool exec without setuid or file capabilities.
This applies to local ip (NET_ADMIN), dhcpcd (network configuration/raw DHCP/
privileged client sockets), DNS or configured low-port socat (NET_BIND_SERVICE),
and fixer setfacl (DAC_READ_SEARCH/FOWNER). The root controller uses only the
bounding NET_ADMIN set and an empty ambient set. Gateway, observer and readiness
have no capabilities in either set. Maintained actual-unit probes check
permitted, effective, bounding and ambient sets; listing unit directives alone
is not proof that a child actually received or lacked a bit.

### Directory and record DbC

Root/runtime directories default to 0700. The anchor creates the separate,
root-owned `/run/hermes-agent-network-N` publication directory for its lifetime;
only the controller writes it and sets mode 0755. The observer separately
manages `/run/hermes-observation-NAME`, setting mode 0755 and writing telemetry
with mode 0644. Its root remains 0700. These records contain network metadata,
not secrets. Producers
atomically replace 0644 files; consumers get read-only DIRECTORY binds so
replacement is visible. Consumers never redeclare/chown producer directories.
Gateway resolv.conf deliberately remains a per-start FILE snapshot.

Anchor lifetime owns the host-publication directory so it exists before the
observer's mount namespace is constructed. Observer starts Type=exec after the
anchor but before controller; its active state alone is NOT usable telemetry.
This breaks the mount/bootstrap dependency cycle: observer waits for config and
DHCP/SLAAC; controller validates the actual record, rather than treating exec
success as readiness. Missing/invalid telemetry cannot authorize traffic.
Controller starts after observer exec, hence its read-only telemetry mount
exists. Proxies start after DHCP/local setup and wait for valid config/data.
Neither producer private root is shared. Stop/recovery removes records with
their namespace generation. Recovery is explicit, not an automatic restart.

Internal dynamic user names use distinct `hn-XX-%i` prefixes, no longer than
the existing public gateway identity prefix. Long role names must not introduce
an earlier systemd username-length limit or fall back to a template-wide UID.
Service/runtime/state names remain unchanged; persistent StateDirectory data
is managed/idmapped by systemd, not migrated or deleted by these programs.

Version-1 config (4 KiB) has exact fields: version, anchor generation/PID/start/
namespace inode, controller InvocationID, canonical host4/host6 arrays, policy
digest. Observation (64 KiB) has version, matching generation/netns, observer
InvocationID, CLOCK_BOOTTIME timestamp, interface/index/MAC, usable peer4/peer6,
required default-route booleans, DAD failure and bounded protocol:port listeners.
Reject duplicate object keys/array members, unsupported versions, unknown or
missing fields, bool-as-int, malformed types/addresses/IDs, oversized, stale,
future and wrong-generation records. Observer filters tentative, DAD-failed,
deprecated and expired addresses and constrains IPv6 to the advertised prefix.
It does not refresh telemetry while either usable peer family is absent, so the
controller's two-second freshness limit revokes an authorized generation instead
of accepting an empty allocation. DAD failure is reported immediately.
Controller checks exact current address sets, host overlap and nft policy.

Authorization (4 KiB) has exact fields: version, anchor generation/PID/start/
namespace inode, controller and observer InvocationIDs, allocation and policy
SHA256, boottime timestamp and authorized=true. The unprivileged readiness
parser requires matching immutable config and bounded freshness; no shell
source/eval. Controller checks producer manager state and observer InvocationID
before refreshing authorization. Required proxies are supervised and readiness
has BindsTo/After on every required producer. Empty mapping groups have no
instance. No gateway/proxy can write controller or observer records.

Observer attempts publication every 0.5 seconds; observation and authorization
records are accepted only when at most 2 seconds old. Readiness polls every
0.1 seconds. The first implementation's repeated manager queries missed the
2-second authorization bound; the current validator batches producer queries
and removes redundant per-address calls without increasing that freshness
limit. A prior combined Headroom/network-failure diagnostic exceeded the
controller's cycle budget and correctly failed closed; this establishes an
availability issue under that test load, not a freshness/revocation waiver or
proof that supported production load is affected. Final-candidate timing and
loss evidence is still required.

### Startup, stop and recovery

1. Anchor creates private namespace and publication lifetime.
2. Observer exec establishes its private root/telemetry directory/mounts.
3. Host controller validates live anchor PID, InvocationID, process start time
   and namespace inode, holds a namespace FD, moves peer via rtnetlink and
   rechecks identity. NET_ADMIN is checked in the owning user namespace; no
   payload setns/SYS_PTRACE. It notifies HOST SETUP after peer move/host-link up,
   before carrier-dependent allocation/RA.
4. Public local setup brings peer/lo up; DHCP starts. Controller continues
   networkd allocation, host overlap checks and RA publication. It publishes
   config; observer supplies validated usable address/route telemetry.
5. Proxy groups start as final dynamic identities. Controller waits for required
   producer states and actual DNS/mapping listeners before publishing address
   sets, verifies complete sets and exact guard rules, then authorizes.
6. Readiness validates authorization, sends READY and continuously revalidates;
   only then can gateway hooks/ExecStart execute.

Controller is ordered before consumers; therefore its normal ExecStopPost is
NOT an early-revocation guarantee. The running monitor checks pending stop/
restart jobs for its public gateway/network/readiness and its own controller,
then invalidates authorization and revokes without waiting for reversed stop
ordering or a slow gateway ExecStop. Manager stop requests are --no-block to
avoid waiting on the controller's own transaction. Unexpected observer/proxy/
namespace/policy/data loss also exits/invalidate readiness and stops consumers.
The running controller monitors pending stop jobs and performs fail-close
cleanup in its main process before exiting, ahead of reversed dependency stop
ordering. ExecStopPost repeats the idempotent cleanup as the SIGKILL/failed-start
fallback. OnFailure starts the separate zero-capability D-Bus helper after that
cleanup; it asynchronously asks PID1 to stop the namespace anchor so a failed
controller start cannot strand the otherwise-waiting observer. Anchor BindsTo
edges stop consumers. The helper does not wait on that job. Remove
authorization first;
failed nft flush is reported and attempts link-down. Delete the owned/aliased
link before potentially blocking RA lock/reload. Flush/down/delete/reload failure
injection and measurement are required; logging a failed action is not a
successful fail-closed claim. A held FD prevents PID reuse retargeting the move;
controller rechecks live anchor identity during monitoring.

The existing peer gateway BindsTo/After main gateway remains. Thus stopping main
can also stop peer's dependent network stack. Preserve the intended baseline
transaction, rather than claiming independent peer lifetime from a detached
DHCP-only fixture. Maintained real-gateway comparison remains required.

### DHCP paths and lifetime

Packaged dhcpcd 10.3.2 fixes PID/control files at /var/run/dhcpcd and lease/DUID
files at /var/lib/dhcpcd; no CLI runtime/state override exists. Owner authorized
persistent per-instance client StateDirectory, superseding the initial
volatile-client-state requirement. Server PersistLeases=runtime is unchanged.

RuntimeDirectory aliases create host-level links to their source directory;
they do not create the fixed `/run/dhcpcd` and `/var/lib/dhcpcd` paths inside
each distinct RootDirectory. The final implementation therefore uses distinct
per-instance `hermes-dhcp-%i/dhcpcd` runtime storage and a persistent
`StateDirectory=hermes-dhcp-%i`. `/run/dhcpcd` and `/var/run/dhcpcd` expose the
same per-instance volatile directory; `/var/lib/dhcpcd` is a symlink to that
instance's automatically mounted persistent state. `StateDirectory` remains
automatically idmapped for the DynamicUser. The existing ExecStart helper
creates `/var/lib/dhcpcd` as a symlink to that per-instance in-root directory
before exec. `/var/lib` is a
private directory under this service's managed RootDirectory runtime tree, not
the host's `/var/lib`; `ReadWritePaths=+/var/lib` makes only that in-root
directory writable so the DynamicUser can create the link. This avoids an
additional BindPaths that would lose the
manager's DynamicUser ownership mapping. No host `/run` or `/var` is exposed.
The actual
client start, renewal, restart, path identity and state-sentinel checks on the
final candidate are required before treating this boundary as proven; earlier
results from the alias or non-idmapped bind layouts do not transfer.

## Hardening inventory

All roles use private roots, closure mounts, NNP, strict system/home/kernel/
clock/hostname/control-group protection, private devices/mounts/tmp/IPC,
ProtectProc=invisible, private keyring, RemoveIPC, native ABI and EPERM syscall
errors. All deny namespace creation/entry and @privileged/@resources within
@system-service; no setns or credential-drop syscall exception remains.

The common controls below are applied to each service template and its
instances; role-specific exceptions are explicit rather than inherited as a
larger shared privilege set:

| Role | Namespace / identity controls | Capabilities, syscall and address-family boundary | Data/device exception and reason |
|---|---|---|---|
| Anchor | Root UID; PrivateNetwork creates the namespace; no PrivateUsers/PIDs | Empty caps; AF_UNIX only; deny namespace syscalls | Owns only its runtime root/publication directory; no manager or host network mounts. Root UID is needed for validated proc namespace-FD access, not to retain capabilities. |
| Host controller | Root UID; NetworkNamespacePath selects host netns; no PrivateUsers/PIDs | NET_ADMIN bounding only, no ambient caps; AF_NETLINK/AF_UNIX; no SYS_ADMIN/SYS_PTRACE | Writable `/run/systemd/network`, RO D-Bus and networkd Varlink sockets, instance publication. This is trusted host control because manager API authority cannot be made read-only. |
| Failure reaper | Root UID for manager authorization; no capabilities | Empty caps; AF_UNIX only; no network namespace control | Own root/closure and RO system D-Bus socket only; systemd unit OnFailure schedules it after the controller cleanup. It requests an asynchronous anchor stop and does not wait on its own job. |
| Local setup | Per-instance DynamicUser; joins anchor netns; no PrivateUsers/PIDs | NET_ADMIN bounding+ambient for local `ip` link/loopback configuration; AF_NETLINK/AF_UNIX | Private root and own process only; no manager, resolver, host filesystem or device exception. |
| DHCP | Per-instance DynamicUser; joins local namespace; no PrivateUsers/PIDs | NET_ADMIN/NET_BIND_SERVICE/NET_RAW bounding+ambient for packaged dhcpcd client operations; AF_INET/AF_INET6/AF_NETLINK/AF_PACKET/AF_UNIX | Private runtime plus the owner-approved per-instance persistent client state; no host `/run` or `/var` bind. DHCP server leases remain runtime-only. |
| Network observer | Per-instance DynamicUser; joins anchor netns; no PrivateUsers/PIDs | Empty caps; AF_NETLINK only | Writes its own generation-scoped telemetry; no manager, networkd write, gateway or proxy write path. |
| DNS | Per-instance DynamicUser; NetworkNamespacePath selects host netns; no PrivateUsers/PIDs | NET_BIND_SERVICE bounding+ambient only; AF_INET/AF_INET6/AF_NETLINK | Reads the single host-resolver snapshot and binds only allocated host-veth addresses; no manager or host-network administration. |
| Host proxy | Per-instance DynamicUser; NetworkNamespacePath selects host netns; no PrivateUsers/PIDs | Empty caps unless a configured low host port requires NET_BIND_SERVICE; AF_INET | Existing mappings bind only host `127.0.0.1`; child supervisor owns only its required children. No manager or host runtime write path. |
| Agent relay | Per-instance DynamicUser; joins anchor netns; no PrivateUsers/PIDs | Empty caps unless a configured low agent port requires NET_BIND_SERVICE; AF_INET | Existing relay targets the same agent namespace's loopback. No manager, resolver or host runtime write path. |
| Readiness | Per-instance DynamicUser; joins anchor netns; no PrivateUsers/PIDs | Empty caps; AF_UNIX only for its own notify socket | Reads generation-scoped authorization; no manager, nftables, resolver, networkd or producer write access. |
| Public-state fixer | DynamicUser with only the existing `hermes-shared` group; PrivateUsers=identity | DAC_READ_SEARCH/FOWNER bounding+ambient for ACL repair; no usable socket family (explicit socket syscall denial) | Only existing gateway-state bind; no StateDirectory ownership of gateway state. This preserves ACL behavior without importing host `/etc/group`. |
| Gateway | DynamicUser; joins its agent namespace; PrivateUsers=identity | Empty caps; AF_INET/AF_INET6/AF_UNIX | Existing gateway state, CA bundle and explicit `/dev/kvm` exception only; MDWE is not imposed because JIT/FFI/ONNX/Headroom compatibility is unproven. |

| Control | Enabled/retained/rejected rationale |
|---|---|
| PrivateTmp, PrivateDevices, PrivateNetwork, PrivateIPC, PrivateMounts | Enabled per role. Host roles still have PrivateNetwork but NetworkNamespacePath selects host; only private consumers join anchor. No host role reciprocally joins private anchor. |
| PrivatePIDs | Not enabled: anchor PID/start/namespace-FD validation uses host PID identity; no final compatibility proof for isolated PID trees in other roles. |
| PrivateUsers | Retain identity for gateway/fixer. Off for anchor/controller/local/DHCP: proc access and capabilities must apply in the network namespace's owning userns. New dynamic payloads have no host-admin capability; no extra userns claim is made. |
| PrivateBPF | Off: bpffs isolation is not packet filtering; no role needs bpffs/custom BPF or delegation. |
| ProtectSystem/Home/Proc | strict/yes/invisible. Explicit state/device/runtime binds are exceptions. Root and manager access are not sandboxed adversarially by these switches. |
| ProtectClock/Hostname/KernelTunables/KernelModules/KernelLogs/ControlGroups | Enabled; hostname private, cgroups strict; no writer/delegation needed. |
| MountAPIVFS/ProcSubset | APIVFS enabled. pid subset for helpers; gateway keeps CPU/ONNX proc data for compatibility. |
| RestrictAddressFamilies | Gateway INET/INET6/UNIX; fixer [] plus explicit ~socket syscall denial; anchor UNIX; local NETLINK/UNIX; controller INET/INET6/NETLINK/UNIX; DHCP INET/INET6/NETLINK/PACKET/UNIX; observer NETLINK; DNS INET/INET6/NETLINK; host proxy and agent relay INET; readiness UNIX for its own notify. Payload default [] is overridden explicitly for every concrete role, not treated as deny-all. |
| RestrictNamespaces/Realtime/SUIDSGID | Enabled. SUIDSGID denies filesystem mode creation, NOT setuid/setgid; earlier thread rationale was wrong. Manager constructs namespaces before payload restrictions. |
| SystemCallFilter/Architectures/ErrorNumber/Log | @system-service minus @resources/@privileged; native ABI; EPERM. No universal syscall logging without a bounded consumer. Actual-unit probes, not nsenter, must verify enforcement. |
| Capabilities/ambient | Per-role table above. Explicit empty strings are required where empty Nix lists omit the systemd directive. Never infer zero root capabilities from a missing directive. |
| NNP/personality/MDWE | NNP and locked personality everywhere. MDWE on simple helpers; not imposed on gateway because Headroom/JIT/FFI/ONNX compatibility is unproven. |
| KSM/keyring/IPC/umask | Cross-domain MemoryKSM removed. Private keyring, RemoveIPC, helper umask0077, gateway0007 retained. |
| DevicePolicy/DeviceAllow | closed cgroup policy; gateway alone allows /dev/kvm rw. Representative real-unit device denial and KVM positive control required. |
| RestrictFileSystems | Not enabled: BPF-LSM support/effectiveness not proven; hard-coded ext4 would break required 9p VM store. |
| IPAddressAllow/Deny, bind/interface filters | Not authoritative: cannot encode existing protocol/port destination policy, optional kernel support and moved interfaces need operational proof. nftables remains authoritative. No silently optional BPF replacement. |
| CPU/affinity, memory/swap/zswap/OOM, tasks, IO limits | No arbitrary quota/affinity/OOM changes without measured workload/availability requirements. Defaults remain; not an isolation guarantee. |
| CPU/memory/IO/IP accounting, PSI/pressure | No new thresholds/consumer specified; no new effectiveness claim. |
| cgroup/namespace/BPF delegation | No delegated child cgroups, namespaces or BPF. Gateway/fixer explicit DelegateNamespaces=false retained. |
| RootImage/RootEphemeral/image integrity/encryption/LSM | Alternatives, not new infrastructure requirements. No maintained per-service AppArmor/SELinux policy or image pipeline exists. Individual roots/closures are the selected mechanism. |

## Declarative networkd and DNS

Replace handwritten environment.etc network files/manual upstream activation
with systemd.network.networks using identical `40-hermes-agent-N` keys:
Name=haN, Kind=veth, RequiredForOnline=no, Address=[0.0.0.0/30,::/64], DHCPServer,
IPv4Forwarding, IPv6Forwarding, IPv6SendRA, runtime server leases, PoolOffset=2,
PoolSize=1. `Router=` is omitted: systemd 261 rejects the legacy
`_server_address` token and uses the DHCP server interface address by default.
Pinned NixOS emits .network sources into
reloadTriggers and sets stopIfChanged=false. Enable systemd.network for active
agents, but do not disable it when the host independently owns networkd. In the
pinned switch-to-configuration-ng implementation, removing the last
`X-Reload-Triggers` key is ignored by its unit comparator. Keep one
content-addressed membership trigger while Hermes is enabled and systemd.network
is enabled, including the zero-agent case on a host-owned networkd. The trigger
content is the exact generated Hermes source list (empty after last-agent
removal); addition, content change, and last-agent removal change the retained
trigger without enabling networkd on a host with no active agent. Runtime RA
drop-ins remain outside NixOS and still require the helper's explicit
reload/reconfigure.

Active Hermes agents enable `systemd.network` for their generated veths but do
not change `networking.useNetworkd`; dhcpcd or NetworkManager may continue to own
the host uplink. If the host does not use networkd for its uplink, a `mkDefault`
disables the extra networkd wait-online gate. This preserves an explicit
`systemd.network.wait-online.enable` policy and leaves networkd users' existing
wait-online setting intact. Hermes veths remain excluded from NetworkManager and
dhcpcd, without changing unrelated uplink ownership. First/change/last-agent-removal/rollback
with networkd already running must be exercised using ordinary activation, not
manual reload or trigger evaluation alone.

Agents still get only allocated host-veth proxy resolvers, never public/LAN
fallbacks. Test the COMPLETE nameserver list in the actual gateway root/mount/
network context. Controlled A/AAAA getaddrinfo as real UID/GID with CapEff=0,
normal resolver path, single host-resolver case, host positive and unavailable-
host negative controls, restoration on every exit and both-agent post-restart
repetition are required. Preserve UDP/TCP DNS and separate real Internet DNS/
certificate-verified HTTPS. A legitimate host external upstream is not an agent
fallback. No resolver watcher or new DNS architecture is introduced.

## Evidence, rollout and rollback

Trace: owner/task contracts -> ADR boundaries/DbC -> hermes.nix service and
record contracts -> flake config/syntax/negative-parser checks -> maintained
VM startup, DNS, state, failure, enforcement and activation scenarios. Sources:
systemd 261 systemd.exec and systemd.resource-control; systemd v261
load-fragment/verbs/bus-util/sd_booted sources; pinned Nixpkgs networkd module;
iproute2 and Linux rtnetlink namespace-FD path; packaged dhcpcd 10.3.2 paths.

`hermes-module-vm-config-check` passed after adding the gateway start bound and
its assertion. Every VM smoke run must record the immutable launcher identity,
guest `/run/current-system`, command and both test/wrapper exit statuses.

The earlier evidence attachments 19/24/25 are historical only and are not
accepted as candidate identity evidence: their recorded system closure hashes
conflict with the `init=` paths in the immutable launchers. The launchers used
`/nix/store/vv8g35yrqsk933ga7y2ldzjk1whhjzn7-nixos-system-nixos-26.11.20261014.55bfb4d`,
`/nix/store/if6zd9wmh6zl9h7ii9gm4bib8va6qqk2-nixos-system-nixos-26.11.20261014.55bfb4d`,
and `/nix/store/1sywn75lix5c0fm6f6c1lhfndm2j60rg-nixos-system-nixos-26.11.20261014.55bfb4d`
for the security, Internet, and activation launchers, respectively. Those
launch records do not establish the guest's `/run/current-system`; without that
readback, those runs cannot support final-candidate claims. The current VM
fixtures now print `/run/current-system` before their checks.

Default-on diagnostic evidence explains the earlier `hermes@vm-peer.service`
dependency failure. The pinned package ships all five requested official skills
locally. In a real guest service identity, `hermes skills install -y` fetched
those `official/` bundles from the bundled tree, ran the local security scan,
and installed them; no network/DNS fetch was involved. Cold invocations took
about 14–23 seconds each, and a cold gateway became active about 157 seconds
after its service start. The prior 90-second manager default timed out the main
gateway during its fifth install; systemd then rejected the peer start with
`dependency`. The owner permitted a bounded service/test budget increase after
diagnosing normal initialization rather than a broken DNS/dependency. The
gateway template now explicitly uses `TimeoutStartSec=180s`; this does not alter
the fail-closed record freshness or two-second controller validation budget.

The corrected default-on probe reported `DEFAULT_ON_FEATURES_PASSED` and
`HERMES_VM_SECURITY_ONLY_PASSED`: both agents had all five skills, the Headroom
child was present with `CapEff=0`, and peer profile/ACL checks denied opening
`.env` without reading contents. A previous false negative searched for
`headroom proxy`, while the actual Nix executable is `.headroom-wrapped`; the
probe now matches that observed command line. Guest shutdown still reported
`[FAILED] Failed unmounting /nix/store`, so bounded teardown is not proven.

The current candidate's full offline/failure/lifecycle VM (`/run/current-system`
`/nix/store/4q4ixzxvgkwpzq15a1xj5zslb0qg3ah7-nixos-system-nixos-26.11.20261014.55bfb4d`)
ran with Headroom and default-skill installation disabled, as configured by the
offline fixture. It reached `Hermes VM runtime checks passed` after DAD and
route-loss startup/revocation, all eight bounded producer/child-loss cases,
host-only DNS, DHCP ACK/rebind and blocked/stale-resolver recovery, nftables
publication/readback failure and reload, mappings, interface collision, route
overlap, peer `.env` denial, cleanup/recovery, and instantiated `systemd-analyze
verify/security` plus payload-boundary probes for both agents and internal
roles. Full-log search found no host-control validation-budget-expired diagnostic
in this Headroom-disabled run. Verbatim excerpts, launcher command, closure
identity, test marker, mount inventory, and shutdown failure are in attachment 33.

The same guest's final pre-unmount inventory recorded 17 store references, zero
namespace references, 644 store mappings, and ten private mount namespaces from
host services including PID 1/systemd, networkd, resolved, udev, D-Bus, nsncd,
logind, and dnsmasq. It did not identify the exact mount-busy holder. Shutdown
then reported `[FAILED] Failed unmounting /nix/store`; the 5700-second outer
timeout terminated QEMU, which printed `wrapper_exit=0` after handling SIGTERM.
The guest test marker is a pass, but this is not natural clean shutdown and does
not prove a baseline-only fixture limitation. Do not claim one until compared
with an equivalent baseline shutdown.

The focused current-candidate Internet guest independently passed both agents'
exact-one-host-resolver A/AAAA positive and blocked-resolver negative checks
before/after networkd restart, UDP/TCP DNS, public DNS, TCP/443 and
certificate-verified HTTPS 200 with zero effective capabilities. Its focused
Internet recovery marker passed; shutdown again failed to unmount `/nix/store`,
and the wrapper was manually terminated. The activation guest passed
module-disabled -> add -> source change -> last-agent removal -> re-add ->
rollback through ordinary `switch-to-configuration test`; it sampled networkd's
reload timestamp immediately after each switch and before helper startup, kept
MainPID 515, and preserved uplink/gateway/DHCP sentinels and residue checks. Its
guest marker passed; shutdown again failed the store unmount. Attachments 31 and
32 contain bounded verbatim evidence. Neither focused guest proves a natural
QEMU shutdown; bootloader/reboot/public IPv6 remain untested.

The combined default-on/full-network run on the current candidate, using the
same 2-GiB guest, OOM-killed the Headroom wrapper at guest uptime 553s (about
1.0-GiB anonymous RSS); the peer gateway then failed with `Result=signal`, and
the full test could not start. The later observer `config.json` error occurred
during stop/cleanup, not the initiating failure. No validation-budget-expired
message occurred in that serial run. A prior combined default-on/code-graph
run did report `network validation cycle exceeded its budget` and correctly
revoked authorization; the current OOM run neither reproduces nor clears that
separate under-load validation finding. No tolerance/freshness rule was changed.
The human has been asked whether 2 GiB is a supported minimum that must sustain
two default-on Headroom instances, or whether a separate higher-memory full-test
guest is permitted; until answered, do not increase test memory, relax
validation/revocation, or disable features. Attachment 30 has the current OOM
excerpt. The focused default-on security/profile probe is not a substitute for
the combined full matrix.

The owner cancelled the 15-second startup requirement and directed that startup
remain as-is, prioritizing security (task comment 135). Startup latency remains
diagnostic and is not an acceptance criterion. The 180-second service bound is
an operational budget supported by measured local skill-installation time; it
does not relax the two-second authorization/revocation bound. The offline full
matrix, focused Internet/DNS recovery, activation/rollback, and effective unit
enforcement have current-candidate guest success markers, but clean shutdown,
the combined default-on resource decision, and the separate prior under-load
validation-budget finding remain open. This ADR does not infer software
acceptance, a risk exception, or release authorization.

Rollout is local-only and requires independent review. Ordinary generation
activation/rollback must preserve both state sentinels, persistent DHCP state,
unrelated uplink and host firewall ownership while removing new runtime residue.
Do not delete state to make rollback tests pass. Bootloader/reboot/public-IPv6
and startup-NFR limitations remain explicit, not waived by this ADR. The host
agent sandbox has no usable PID1/system bus; instantiated security/verify and
actual cgroup/seccomp/device proofs belong in disposable guests. QEMU exit0
after forced termination or a /nix/store unmount stall is not clean shutdown.
