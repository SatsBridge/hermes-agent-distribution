import fcntl
import ipaddress
import json
import os
import pathlib
import subprocess
import time

from network_record import atomic, config, identity, notify_ready, usable


def command(settings, tool, *args, input=None, timeout=15, pass_fds=()):
    return subprocess.run(
        [settings["tools"][tool], *args], input=input, text=True,
        stdout=subprocess.PIPE, check=True, timeout=timeout, pass_fds=pass_fds,
    ).stdout


def owned_link(settings):
    result = subprocess.run(
        [settings["tools"]["ip"], "-j", "link", "show", "dev", settings["host_interface"]],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=2,
    )
    if result.returncode:
        return None
    link, = json.loads(result.stdout)
    return link if link.get("ifalias") == "hermes-agent-" + settings["name"] else None


def flush_sets(settings):
    batch = "".join("flush set inet hermes-agent-guard " + name + "\n" for name in settings["set_names"])
    command(settings, "nft", "-f", "-", input=batch, timeout=2)


def networkd(settings, reconfigure=False):
    lock = pathlib.Path("/run/systemd/network/.hermes-networkd.lock")
    with lock.open("a") as stream:
        deadline = time.monotonic() + 15
        while True:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("networkd reload lock timed out")
                time.sleep(0.05)
        command(settings, "networkctl", "reload")
        if reconfigure:
            command(settings, "networkctl", "reconfigure", settings["host_interface"])


def cleanup(settings):
    os.environ["SYSTEMD_OFFLINE"] = "0"
    publication = pathlib.Path(settings["publication"])
    for name in ("authorization.json", "config.json", "resolv.conf", "resolv.conf.tmp"):
        (publication / name).unlink(missing_ok=True)
    failed = False
    try:
        flush_sets(settings)
    except (OSError, subprocess.SubprocessError) as error:
        failed = True
        print(f"{settings['name']}: firewall revocation failed: {error}", flush=True)
        if owned_link(settings):
            try:
                command(settings, "ip", "link", "set", "dev", settings["host_interface"], "down", timeout=2)
            except (OSError, subprocess.SubprocessError) as error:
                failed = True
                print(f"{settings['name']}: FAILED to block owned link: {error}", flush=True)
    # Link removal must precede a potentially blocking networkd lock/reload.
    if owned_link(settings):
        try:
            command(settings, "ip", "link", "delete", "dev", settings["host_interface"], timeout=2)
        except (OSError, subprocess.SubprocessError) as error:
            failed = True
            print(f"{settings['name']}: FAILED to delete owned link: {error}", flush=True)
    dropin = pathlib.Path(settings["ra_dropin"])
    if dropin.exists():
        try:
            dropin.unlink()
        except (OSError, subprocess.SubprocessError, TimeoutError) as error:
            failed = True
            print(f"{settings['name']}: failed to remove RA drop-in: {error}", flush=True)
        else:
            try:
                networkd(settings)
            except (OSError, subprocess.SubprocessError, TimeoutError) as error:
                failed = True
                print(f"{settings['name']}: cleanup networkd reload failed: {error}", flush=True)
    if failed:
        raise RuntimeError(f"{settings['name']}: network cleanup incomplete")


def validate_anchor(settings, manager, expected):
    manager.deadline = time.monotonic() + 2
    actual = manager.unit_info("hermes-netns@" + settings["name"] + ".service", with_pid=True)
    process = pathlib.Path("/proc") / str(expected["pid"])
    if (actual["ActiveState"] != "active" or actual["MainPID"] != expected["pid"]
            or actual["InvocationID"] != expected["generation"]
            or int((process / "stat").read_text().rpartition(")")[2].split()[19]) != expected["start"]
            or (process / "ns/net").stat().st_ino != expected["namespace"]):
        raise RuntimeError("namespace anchor generation changed")


def check_overlap(settings, host4, host6):
    links = json.loads(command(settings, "ip", "-j", "address", "show"))
    for family, address, prefix in ((4, host4, 30), (6, host6, 64)):
        subnet = ipaddress.ip_network(address + "/" + str(prefix), strict=False)
        routes = json.loads(command(settings, "ip", "-j", "-" + str(family), "route", "show", "table", "all"))
        for route in routes:
            if route.get("dev") == settings["host_interface"] or route.get("dst", "default") == "default":
                continue
            other = ipaddress.ip_network(route["dst"], strict=False)
            if other.prefixlen and subnet.overlaps(other):
                raise ValueError(f"Hermes subnet {subnet} overlaps host route {other}")
        for link in links:
            if link["ifname"] == settings["host_interface"]:
                continue
            for item in link.get("addr_info", []):
                if item.get("family") != ("inet" if family == 4 else "inet6"):
                    continue
                other = ipaddress.ip_network(item["local"] + "/" + str(item["prefixlen"]), strict=False)
                if subnet.overlaps(other):
                    raise ValueError(f"Hermes subnet {subnet} overlaps host address {other}")


def initialize(settings, manager, verify_policy):
    os.environ["SYSTEMD_OFFLINE"] = "0"
    flush_sets(settings)
    verify_policy()
    links = json.loads(command(settings, "ip", "-j", "link", "show"))
    if any(link["ifname"] in (settings["host_interface"], settings["interface"]) for link in links):
        raise FileExistsError("Refusing to replace an existing Hermes network interface")
    dropin = pathlib.Path(settings["ra_dropin"])
    if dropin.exists():
        dropin.unlink()
        networkd(settings)
    manager.deadline = time.monotonic() + 2
    anchor = manager.unit_info("hermes-netns@" + settings["name"] + ".service", with_pid=True)
    identity(anchor["InvocationID"])
    if anchor["MainPID"] <= 1:
        raise ValueError("invalid namespace anchor PID")
    process = pathlib.Path("/proc") / str(anchor["MainPID"])
    expected = dict(
        version=1, generation=anchor["InvocationID"], controller=os.environ["INVOCATION_ID"],
        pid=anchor["MainPID"], start=int((process / "stat").read_text().rpartition(")")[2].split()[19]),
        namespace=(process / "ns/net").stat().st_ino, policy=settings["policy"],
    )
    descriptor = os.open(process / "ns/net", os.O_RDONLY | os.O_CLOEXEC)
    try:
        if os.fstat(descriptor).st_ino != expected["namespace"]:
            raise RuntimeError("held namespace FD differs from the anchor generation")
        validate_anchor(settings, manager, expected)
        # Install the cleanup alias and peer MAC before moving the peer.
        command(settings, "ip", "link", "add", settings["host_interface"], "alias", "hermes-agent-" + settings["name"],
            "type", "veth", "peer", "name", settings["interface"], "address", settings["mac"])
        command(settings, "ip", "link", "set", "dev", settings["host_interface"], "alias", "hermes-agent-" + settings["name"])
        if not owned_link(settings):
            raise RuntimeError("new veth does not carry its Hermes ownership alias")
        command(settings, "ip", "link", "set", "dev", settings["interface"], "netns", f"/proc/self/fd/{descriptor}", pass_fds=(descriptor,))
        validate_anchor(settings, manager, expected)
        command(settings, "ip", "link", "set", "dev", settings["host_interface"], "up")
        notify_ready(settings["name"] + ": peer moved; awaiting carrier/allocation")
        deadline = time.monotonic() + 30
        while True:
            link, = json.loads(command(settings, "ip", "-j", "address", "show", "dev", settings["host_interface"]))
            expected["host4"] = sorted(item["local"] for item in link["addr_info"] if usable(item, "inet", 30))
            expected["host6"] = sorted(item["local"] for item in link["addr_info"] if usable(item, "inet6", 64))
            if len(expected["host4"]) == 1 and expected["host6"]:
                break
            if time.monotonic() >= deadline:
                raise TimeoutError("networkd did not allocate host veth addresses within 30s")
            time.sleep(0.1)
        check_overlap(settings, expected["host4"][0], expected["host6"][0])
        prefix = ipaddress.ip_network(expected["host6"][0] + "/64", strict=False)
        dropin.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        dropin.parent.chmod(0o755)
        dropin.write_text(f"[IPv6Prefix]\nPrefix={prefix}\nAddressAutoconfiguration=yes\nOnLink=yes\n")
        dropin.chmod(0o644)
        networkd(settings, reconfigure=True)
        publication = pathlib.Path(settings["publication"])
        publication.chmod(0o755)
        atomic(publication / "config.json", expected)
        config(publication / "config.json")
        return expected, descriptor
    except BaseException:
        os.close(descriptor)
        raise
