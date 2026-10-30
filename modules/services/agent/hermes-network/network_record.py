import ipaddress
import hashlib
import json
import os
import pathlib
import re
import socket
import time

def now():
    return time.clock_gettime_ns(time.CLOCK_BOOTTIME)


def notify_ready(status=None):
    address = os.environ["NOTIFY_SOCKET"]
    if address.startswith("@"):
        address = "\0" + address[1:]
    message = "READY=1" + ("\nSTATUS=" + status if status else "")
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as notifier:
        notifier.sendto(message.encode(), address)

def usable(item, family, prefix):
    if item.get("family") != family or item.get("prefixlen") != prefix or item.get("scope") != "global":
        return False
    if set(item.get("flags", [])) & {"tentative", "dadfailed", "deprecated"}:
        return False
    if any(item.get(flag) for flag in ("tentative", "dadfailed", "deprecated")):
        return False
    return not any(
        value is not None and value != "forever" and int(value) <= 0
        for value in (item.get("valid_life_time"), item.get("preferred_life_time"))
    )

def dad_pending(items):
    return any(
        item.get("tentative")
        or item.get("dadfailed")
        or bool(set(item.get("flags", [])) & {"tentative", "dadfailed"})
        for item in items
    )

def dad_waiting(items, peer6, dadfailed):
    return dad_pending(items) and not peer6 and not dadfailed

def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result

def load(path, fields, limit=65536):
    with open(path, "rb") as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError("oversized network record")
    record = json.loads(data, object_pairs_hook=unique)
    if type(record) is not dict or set(record) != set(fields):
        raise ValueError("unexpected network record fields")
    return record

def atomic(path, record):
    path = pathlib.Path(path)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(record, sort_keys=True), encoding="ascii")
    temporary.chmod(0o644)
    temporary.replace(path)

def identity(value):
    if type(value) is not str or re.fullmatch("[0-9a-f]{32}", value) is None:
        raise ValueError("invalid invocation identity")

def positive(value):
    if type(value) is not int or value <= 0:
        raise ValueError("invalid positive integer")

def fresh(value):
    positive(value)
    if not 0 <= now() - value <= 2_000_000_000:
        raise ValueError("stale or future network record")

config_fields = "version generation controller pid start namespace host4 host6 policy".split()
observation_fields = "version generation invocation namespace timestamp interface index mac peer4 peer6 route4 route6 dadfailed listeners".split()
authorization_fields = "version generation controller observer pid start namespace allocation policy timestamp authorized".split()

def config(path):
    record = load(path, config_fields, 4096)
    if type(record["version"]) is not int or record["version"] != 1:
        raise ValueError("unknown config version")
    for key in ("generation", "controller"):
        identity(record[key])
    for key in ("pid", "start", "namespace"):
        positive(record[key])
    for key, version in (("host4", 4), ("host6", 6)):
        addresses(record[key], version)
    digest(record["policy"])
    return record

def digest(value):
    if type(value) is not str or re.fullmatch("[0-9a-f]{64}", value) is None:
        raise ValueError("invalid digest")

def addresses(values, version):
    if type(values) is not list or not 1 <= len(values) <= 32:
        raise ValueError(f"invalid IPv{version} address count")
    if any(type(value) is not str for value in values) or len(set(values)) != len(values):
        raise ValueError("duplicate or non-string address")
    for value in values:
        address = ipaddress.ip_address(value)
        if address.version != version or str(address) != value:
            raise ValueError("noncanonical address")

def observation(path, expected, interface, mac):
    record = load(path, observation_fields)
    if type(record["version"]) is not int or record["version"] != 1:
        raise ValueError("unknown observation version")
    identity(record["invocation"])
    fresh(record["timestamp"])
    positive(record["index"])
    positive(record["namespace"])
    if (record["generation"] != expected["generation"] or record["namespace"] != expected["namespace"]
            or record["interface"] != interface or record["mac"] != mac):
        raise ValueError("wrong observer generation/interface/namespace")
    for key in ("route4", "route6", "dadfailed"):
        if type(record[key]) is not bool:
            raise ValueError("invalid observer boolean")
    for key, version in (("peer4", 4), ("peer6", 6)):
        addresses(record[key], version)
    if len(record["peer4"]) != 1 or not record["route4"] or not record["route6"] or record["dadfailed"]:
        raise ValueError("DHCP/SLAAC/routes not ready")
    for key, host, prefix in (("peer4", "host4", 30), ("peer6", "host6", 64)):
        subnet = ipaddress.ip_network(expected[host][0] + "/" + str(prefix), strict=False)
        if any(ipaddress.ip_address(address) not in subnet or address in expected[host] for address in record[key]):
            raise ValueError("peer outside allocated subnet or equal to host")
    listeners = record["listeners"]
    if type(listeners) is not list or len(listeners) > 128 or any(type(value) is not str or re.fullmatch(r"(?:tcp|udp):[1-9][0-9]{0,4}", value) is None or int(value.split(":")[1]) > 65535 for value in listeners) or len(set(listeners)) != len(listeners):
        raise ValueError("invalid listener list")
    return record

def allocation(expected, observed):
    return hashlib.sha256(json.dumps([expected, observed["peer4"], observed["peer6"]], sort_keys=True).encode()).hexdigest()

def authorization(path, expected, observed):
    record = load(path, authorization_fields, 4096)
    if type(record["version"]) is not int or record["version"] != 1 or record["authorized"] is not True:
        raise ValueError("invalid authorization")
    for key in ("generation", "controller", "observer"):
        identity(record[key])
    for key in ("pid", "start", "namespace"):
        positive(record[key])
    for key in ("allocation", "policy"):
        digest(record[key])
    fresh(record["timestamp"])
    if any(record[key] != expected[key] for key in ("generation", "controller", "pid", "start", "namespace", "policy")):
        raise ValueError("authorization generation mismatch")
    if record["observer"] != observed["invocation"] or record["allocation"] != allocation(expected, observed):
        raise ValueError("authorization does not cover current observer data")
    return record

def verify_sets(actual, expected):
    if any(sorted(actual.get(key, [])) != sorted(values) for key, values in expected.items()):
        raise ValueError("firewall set readback did not match allocation")
