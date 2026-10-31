import ctypes
import errno
import fcntl
import os
import pathlib
import socket
import stat
import sys
role = sys.argv[1]
sentinel_name = sys.argv[2]
expected_caps = {"gateway": 0, "pf": (1 << 2) | (1 << 3), "dhcp": (1 << 10) | (1 << 12) | (1 << 13),
    "host-control": 1 << 12, "network-failure": 0, "netns": 0, "network-observer": 0, "dns": 1 << 10,
    "host-proxy": 0, "agent-relay": 0, "network-ready": 0}[role]
status = dict(line.split(":", 1) for line in pathlib.Path("/proc/self/status").read_text().splitlines())
assert int(status["CapEff"], 16) == expected_caps, (role, status)
assert int(status["CapBnd"], 16) == expected_caps, (role, status)
assert int(status["CapPrm"], 16) == expected_caps, (role, status)
assert int(status["CapAmb"], 16) == (0 if role in ("host-control", "netns") else expected_caps), (role, status)
assert int(status["NoNewPrivs"]) == 1 and int(status["Seccomp"]) == 2
libc = ctypes.CDLL(None, use_errno=True)
assert libc.setns(-1, 0) == -1 and ctypes.get_errno() == errno.EPERM
assert libc.unshare(0x40000000) == -1 and ctypes.get_errno() == errno.EPERM
families = (socket.AF_UNIX, socket.AF_INET, socket.AF_INET6, socket.AF_NETLINK, socket.AF_PACKET)
allowed = {"gateway": (socket.AF_UNIX, socket.AF_INET, socket.AF_INET6), "pf": (), "dhcp": families,
    "host-control": (socket.AF_NETLINK, socket.AF_UNIX), "network-failure": (socket.AF_UNIX,),
    "netns": (), "network-observer": (socket.AF_NETLINK,),
    "dns": (socket.AF_INET, socket.AF_INET6, socket.AF_NETLINK), "host-proxy": (socket.AF_INET,),
    "agent-relay": (socket.AF_INET,), "network-ready": (socket.AF_UNIX,)}[role]
for family in families + (socket.AF_VSOCK,):
    if family in allowed:
        continue
    try:
        descriptor = socket.socket(family, socket.SOCK_DGRAM)
    except OSError as error:
        assert error.errno in (errno.EPERM, errno.EAFNOSUPPORT), (role, family, error)
    else:
        descriptor.close()
        raise AssertionError((role, "forbidden family succeeded", family))
assert stat.S_IMODE(os.stat("/").st_mode) == 0o700, (role, os.stat("/"))
mounts = [line.split() for line in pathlib.Path("/proc/self/mountinfo").read_text().splitlines()]
nix_root = next((fields for fields in mounts if fields[4].endswith("/nix")), None)
store_mounts = [fields for fields in mounts if "/nix/store/" in fields[4]]
assert nix_root is not None and "ro" in nix_root[5].split(","), (role, nix_root)
assert store_mounts and all("ro" in fields[5].split(",") for fields in store_mounts), (role, store_mounts)
assert pathlib.Path(sys.executable).is_file() and os.access(sys.executable, os.R_OK | os.X_OK), role
for store_root in ("/nix/store", "/nix/.ro-store"):
    assert not (pathlib.Path(store_root) / sentinel_name).exists(), (role, store_root)
for alias in ("/run/current-system", "/run/booted-system", "/run/wrappers", "/etc/static", "/etc/profiles",
    "/etc/profiles/per-user/root/bin/bash", "/etc/systemd/system", "/nix/var/nix/profiles/system",
    "/root/.nix-defexpr", "/root/.nix-profile/bin/bash", "/run/wrappers/bin/sudo"):
    assert not pathlib.Path(alias).exists(), (role, alias)
print(f"STORE_BOUNDARY_PASSED role={role} read-only-mounts={len(store_mounts)} sentinel=denied", flush=True)
for root in os.environ.get("RUNTIME_DIRECTORY", "").split(":"):
    if not root.endswith("/root") or not pathlib.Path(root).exists():
        continue
    try:
        os.rename(root, root + ".boundary-probe")
    except OSError as error:
        assert error.errno in (errno.EPERM, errno.EACCES, errno.EROFS, errno.EBUSY), (role, error)
    else:
        os.rename(root + ".boundary-probe", root)
        raise AssertionError((role, "payload can replace manager RootDirectory through its runtime bind"))
if role not in ("gateway",):
    assert not pathlib.Path("/etc/group").exists(), role
if role not in ("host-control", "network-failure"):
    assert not pathlib.Path("/run/systemd/private").exists(), role
    assert not pathlib.Path("/run/dbus/system_bus_socket").exists(), role
    assert not pathlib.Path("/run/systemd/network").exists(), role
    for directory in pathlib.Path("/run").glob("hermes-agent-network-*"):
        try:
            descriptor = os.open(directory / ".forbidden-writer", os.O_CREAT | os.O_WRONLY, 0o600)
        except OSError as error:
            assert error.errno in (errno.EACCES, errno.EROFS), (role, error)
        else:
            os.close(descriptor)
            raise AssertionError((role, "producer write succeeded"))
else:
    assert pathlib.Path("/run/dbus/system_bus_socket").is_socket(), role
    assert not pathlib.Path("/run/systemd/private").exists(), role
    if role == "network-failure":
        assert not pathlib.Path("/run/systemd/network").exists(), role
observation_directories = list(pathlib.Path("/run").glob("hermes-observation-*"))
if role == "network-observer":
    assert len(observation_directories) == 1, (role, observation_directories)
    probe = observation_directories[0] / ".boundary-probe"
    probe.touch()
    probe.unlink()
elif role in ("host-control", "network-ready", "host-proxy", "agent-relay"):
    assert len(observation_directories) == 1, (role, observation_directories)
    directory = observation_directories[0]
    assert directory.is_dir()
    mounts = [line.split() for line in pathlib.Path("/proc/self/mountinfo").read_text().splitlines()]
    mount = next((fields for fields in mounts if fields[4].endswith(str(directory))), None)
    assert mount is not None and "ro" in mount[5].split(","), (role, directory, mount)
    try:
        descriptor = os.open(directory / ".boundary-probe", os.O_CREAT | os.O_WRONLY, 0o600)
    except OSError as error:
        assert error.errno in (errno.EACCES, errno.EROFS), (role, error)
    else:
        os.close(descriptor)
        os.unlink(directory / ".boundary-probe")
        raise AssertionError((role, "observer record write succeeded"))
if role == "gateway":
    with open("/dev/kvm", "r+b", buffering=0) as device:
        assert fcntl.ioctl(device, 0xAE00, 0) == 12
elif role not in ("netns",):
    try:
        descriptor = os.open("/dev/kvm", os.O_RDWR)
    except OSError as error:
        assert error.errno in (errno.EPERM, errno.EACCES), (role, error)
    else:
        os.close(descriptor)
        raise AssertionError((role, "device cgroup allowed KVM"))
device_result = "not-exposed" if role == "netns" else "KVM-positive" if role == "gateway" else "cgroup-denied"
print(f"PAYLOAD_BOUNDARY_PASSED role={role} uid={os.getuid()} gid={os.getgid()} caps={expected_caps:x} ambient={status['CapAmb'].strip()} root=0700 seccomp=2 namespace/family=denied device={device_result}", flush=True)
