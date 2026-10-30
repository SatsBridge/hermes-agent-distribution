import ast
import importlib.util
import json
import ipaddress
import re
import pathlib
import subprocess
import sys
import tempfile
import time
from contextlib import redirect_stdout
from io import StringIO
from unittest.mock import patch

sys.path.insert(0, sys.argv.pop(1))
from network_record import allocation, atomic, authorization, config, dad_pending, dad_waiting, now, observation, verify_sets
setup_spec = importlib.util.spec_from_file_location("hermes_network_setup", sys.argv.pop(1))
network_setup = importlib.util.module_from_spec(setup_spec)
setup_spec.loader.exec_module(network_setup)

with tempfile.TemporaryDirectory() as directory:
    path = pathlib.Path(directory) / 'record.json'
    expected = dict(version=1, generation='a' * 32, controller='b' * 32, pid=123, start=1, namespace=456, host4=['192.0.2.1'], host6=['2001:db8::1'], policy='c' * 64)
    atomic(path, expected)
    assert config(path) == expected
    observed = dict(version=1, generation=expected['generation'], invocation='d' * 32, namespace=456, timestamp=now(), interface='hb0', index=2, mac='02:00:00:00:00:01', peer4=['192.0.2.2'], peer6=['2001:db8::2'], route4=True, route6=True, dadfailed=False, listeners=['tcp:53'])
    assert not dad_pending([{'flags': ['deprecated']}])
    assert dad_pending([{'tentative': True}]) and dad_pending([{'flags': ['dadfailed']}])
    assert dad_waiting([{'tentative': True}], [], False)
    assert not dad_waiting([{'tentative': True}], ['2001:db8::1'], False)
    assert not dad_waiting([{'dadfailed': True}], [], True)
    authorized = dict(version=1, generation=expected['generation'], controller=expected['controller'], observer=observed['invocation'], pid=123, start=1, namespace=456, allocation=allocation(expected, observed), policy=expected['policy'], timestamp=now(), authorized=True)
    rejected = 0

    def reject(reader, data):
        global rejected
        path.write_text(data if type(data) is str else json.dumps(data))
        try:
            reader(path)
        except (ValueError, TypeError):
            rejected += 1
        else:
            raise AssertionError('accepted invalid record: ' + str(data)[:200])
    for fixture, reader in ((expected, config), (observed, lambda p: observation(p, expected, 'hb0', '02:00:00:00:00:01')), (authorized, lambda p: authorization(p, expected, observed))):
        atomic(path, fixture)
        assert reader(path) == fixture
        reject(reader, '{')
        reject(reader, json.dumps(fixture)[:-1] + ',"version":1}')
        reject(reader, {**fixture, 'unexpected': 1})
        reject(reader, {**fixture, 'version': True})
        reject(reader, {**fixture, 'generation': 'f' * 32} if fixture is not expected else {**fixture, 'generation': 'invalid'})
        reject(reader, ' ' * 65537)
    read_observation = lambda p: observation(p, expected, 'hb0', '02:00:00:00:00:01')
    for change in ({'timestamp': now() - 3000000000}, {'timestamp': now() + 10000000000}, {'timestamp': True}, {'index': True}, {'namespace': 1}, {'route4': 1}, {'route6': False}, {'dadfailed': True}, {'interface': 'other'}, {'mac': '02:00:00:00:00:02'}, {'peer4': ['192.0.2.2', '192.0.2.2']}, {'peer6': ['2001:0db8::2']}, {'listeners': ['tcp:53', 'tcp:53']}, {'listeners': ['udp:65536']}):
        reject(read_observation, {**observed, **change})
    for change in ({'timestamp': now() - 5000000000}, {'timestamp': now() + 10000000000}, {'pid': True}, {'start': 0}, {'namespace': 1}, {'allocation': 'x' * 64}, {'observer': 'not-an-id'}, {'authorized': 1}, {'policy': 'f' * 64}):
        reject(lambda p: authorization(p, expected, observed), {**authorized, **change})
    reject(lambda p: authorization(p, expected, observed), {**authorized, 'observer': 'f' * 32})
    reject(lambda p: authorization(p, expected, observed), {**authorized, 'allocation': 'f' * 64})
    print(f'NETWORK_RECORD_CONTRACT_PASSED valid=3 rejected={rejected}', flush=True)
tree = ast.parse(pathlib.Path(sys.argv[1]).read_text())
actual_functions = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in ("run", "rules", "verify_policy")]
assert len(actual_functions) == 3
exec(compile(ast.Module(body=actual_functions, type_ignores=[]), "actual-host-verifiers", "exec"))
cycle_deadline = time.monotonic() + 2
assert run(sys.executable, '-c', "print('matching output')").strip() == 'matching output'
try:
    cycle_deadline = time.monotonic() + 2
    run(sys.executable, '-c', "print('matching output'); raise SystemExit(1)")
except subprocess.CalledProcessError as error:
    assert error.returncode == 1 and error.stdout.strip() == 'matching output'
else:
    raise AssertionError('accepted matching stdout with failed readback command')
expected_sets = dict(host4=['192.0.2.1'], peer4=['192.0.2.2'], host6=['2001:db8::1'], peer6=['2001:db8::2'])
verify_sets(expected_sets, expected_sets)
for bad in ({}, {**expected_sets, 'peer4': []}, {**expected_sets, 'peer4': ['192.0.2.3']}, {**expected_sets, 'peer6': ['2001:db8::2', '2001:db8::3']}):
    try:
        verify_sets(bad, expected_sets)
    except ValueError:
        pass
    else:
        raise AssertionError('accepted mismatching/empty set readback')
print('NETWORK_NFT_READBACK_CONTRACT_PASSED matching/nonzero/mismatch/empty', flush=True)

# Pure verifier fixtures are separate from the live guest nftables fault tests.
actual_run = run
policy_rules = [("input", "")]
nft = "fixture-nft"
good_guard = "table inet hermes-agent-guard {\n chain hermes_agent_input_guard {\n  type filter hook input priority -150; policy drop;\n }\n}\n"
try:
    run = lambda *args: good_guard
    verify_policy()
    for output in ("", good_guard + " ip saddr 203.0.113.0/24 drop\n", good_guard.replace("priority -150", "priority 0")):
        run = lambda *args: output
        try:
            verify_policy()
        except RuntimeError:
            pass
        else:
            raise AssertionError("accepted empty/stale/wrong-priority guard readback")
    def failed_read(*args):
        raise subprocess.CalledProcessError(1, args, output=good_guard)
    run = failed_read
    try:
        verify_policy()
    except subprocess.CalledProcessError:
        pass
    else:
        raise AssertionError("guard caller suppressed matching-output/nonzero failure")
finally:
    run = actual_run
print("NETWORK_GUARD_FIXTURES_PASSED matching/stale/empty/priority/nonzero", flush=True)

def cleanup_case(failures):
    calls = []
    with tempfile.TemporaryDirectory() as directory:
        publication = pathlib.Path(directory) / "publication"
        publication.mkdir()
        dropin = pathlib.Path(directory) / "network" / "ra.conf"
        dropin.parent.mkdir()
        dropin.touch()
        settings = {"name": "vm", "publication": str(publication), "ra_dropin": str(dropin), "host_interface": "ha0"}

        def command(_settings, _tool, *args, **_kwargs):
            action = "down" if args[-1] == "down" else "delete"
            calls.append(action)
            if action in failures:
                raise OSError(action)

        def networkd(_settings):
            calls.append("reload")
            if "reload" in failures:
                raise OSError("reload")

        def flush(_settings):
            calls.append("flush")
            if "flush" in failures:
                raise OSError("flush")

        output = StringIO()
        with patch.object(network_setup, "flush_sets", side_effect=flush), \
            patch.object(network_setup, "owned_link", return_value=True), \
            patch.object(network_setup, "command", side_effect=command), \
            patch.object(network_setup, "networkd", side_effect=networkd), redirect_stdout(output):
            try:
                network_setup.cleanup(settings)
            except RuntimeError:
                return calls, True, output.getvalue()
            return calls, False, output.getvalue()

assert cleanup_case(set())[:2] == (["flush", "delete", "reload"], False)
failed_cleanup = cleanup_case({"flush", "down", "delete", "reload"})
assert failed_cleanup[:2] == (["flush", "down", "delete", "reload"], True)
assert all(message in failed_cleanup[2] for message in ("firewall revocation failed", "FAILED to block", "FAILED to delete", "cleanup networkd reload failed"))
assert cleanup_case({"delete"})[:2] == (["flush", "delete", "reload"], True)
assert cleanup_case({"reload"})[:2] == (["flush", "delete", "reload"], True)
print("NETWORK_CLEANUP_CONTRACT_PASSED flush/down/delete/reload", flush=True)
