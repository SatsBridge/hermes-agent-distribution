import json
import sys

def usable(item, family, prefix):
    if item.get("family") != family or item.get("prefixlen") != prefix or item.get("scope") != "global":
        return False
    if set(item.get("flags", [])) & {"tentative", "dadfailed", "deprecated"} or any(item.get(flag) for flag in ("tentative", "dadfailed", "deprecated")):
        return False
    return not any(value is not None and value != "forever" and int(value) <= 0 for value in (item.get("valid_life_time"), item.get("preferred_life_time")))

if sys.argv[1:] == ["--self-test"]:
    fixture = [
        {"family": "inet6", "prefixlen": 64, "scope": "global", "local": "2001:db8::1"},
        {"family": "inet6", "prefixlen": 64, "scope": "global", "local": "2001:db8::2", "tentative": True},
        {"family": "inet6", "prefixlen": 64, "scope": "global", "local": "2001:db8::3", "dadfailed": True},
        {"family": "inet6", "prefixlen": 64, "scope": "global", "local": "2001:db8::4", "deprecated": True},
        {"family": "inet6", "prefixlen": 64, "scope": "global", "local": "2001:db8::5", "flags": ["tentative"]},
        {"family": "inet6", "prefixlen": 64, "scope": "global", "local": "2001:db8::6", "preferred_life_time": 0},
        {"family": "inet6", "prefixlen": 64, "scope": "global", "local": "2001:db8::7", "valid_life_time": 0},
    ]
    assert [item["local"] for item in fixture if usable(item, "inet6", 64)] == ["2001:db8::1"]
    sys.exit(0)

expected_family, expected_prefix = sys.argv[1], int(sys.argv[2])
data = json.load(sys.stdin)
for link in data:
    for item in link.get("addr_info", []):
        if usable(item, expected_family, expected_prefix):
            print(item["local"])
