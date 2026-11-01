import ipaddress
import json
import os
import pathlib
import re
import subprocess
import signal
import sys
import time

sys.path.insert(0, sys.argv.pop(1))
from network_record import allocation, atomic, config, fresh, now, observation, usable, verify_sets

settings = json.loads(pathlib.Path(sys.argv.pop(1)).read_text())
name = settings["name"]
publication = pathlib.Path(settings['publication'])
observation_path = settings['observation_path']
interface = settings['interface']
mac = settings['mac']
sys.path.insert(0, settings["controller_library"])
from setup import cleanup, initialize
from systemd_manager import SystemdManager

operation = sys.argv[1]
host_interface = settings['host_interface']
roles = settings['proxy_roles'] + ['netns', 'dhcp', 'network-observer', 'host-control', 'network', 'network-ready']
mappings = settings['mappings']
set_names = settings['set_names']
ip = settings['tools']['ip']
nft = settings['tools']['nft']
ss = settings['tools']['ss']
startup_deadline = None
authorized = False
cycle_started = time.monotonic()
last_command = None
slow_commands = []

def run(*args, input=None):
    global last_command
    started = time.monotonic()
    command = ' '.join(args)
    remaining = cycle_deadline - time.monotonic()
    if remaining <= 0:
        print(f'{name}: validation budget expired before {command}; elapsed={started - cycle_started:.3f}s previous={last_command} slow_commands={slow_commands} slow_systemd={manager.slow_calls}', flush=True)
        raise RuntimeError('network validation cycle exceeded its budget')
    last_command = command
    try:
        result = subprocess.run(args, input=input, text=True, stdout=subprocess.PIPE, check=True, timeout=remaining)
    except subprocess.TimeoutExpired:
        elapsed = time.monotonic() - started
        if elapsed >= 0.2:
            slow_commands.append((round(elapsed, 3), command))
        print(f'{name}: validation command exceeded remaining budget; command={command} elapsed={elapsed:.3f}s cycle={time.monotonic() - cycle_started:.3f}s prior_slow={slow_commands} slow_systemd={manager.slow_calls}', flush=True)
        raise
    elapsed = time.monotonic() - started
    if elapsed >= 0.2:
        slow_commands.append((round(elapsed, 3), command))
    return result.stdout

def rules(text, live=False):
    result = []
    for line in text.splitlines():
        line = line.strip()
        if not line or (live and line.startswith(('table ', 'chain ', 'type ', '}'))):
            continue
        marker = line.find('hermes-policy-')
        if marker >= 0:
            line = line[:line.rfind('comment', 0, marker)].rstrip()
        line = line.replace('meta l4proto tcp', 'meta l4proto 6').replace('meta l4proto udp', 'meta l4proto 17').replace('meta l4proto ipv6-icmp', 'meta l4proto 58')

        def canonicalize(match):
            keyword, values = match.groups()
            networks = [ipaddress.ip_network(value.strip(), strict=False) for value in values.split(',')]
            return keyword + '{ ' + ', '.join(map(str, ipaddress.collapse_addresses(networks))) + ' }'
        line = re.sub('(ip6? (?:saddr|daddr) )[{]([^}]*)[}]', canonicalize, line)
        result.append(' '.join(line.split()))
    return result
policy_rules = settings['policy_rules']

def verify_policy():
    for hook, text in policy_rules:
        actual = run(nft, 'list', 'chain', 'inet', 'hermes-agent-guard', 'hermes_agent_' + hook + '_guard')
        if not re.search(f'type filter hook {hook} priority (?:-150|mangle); policy drop;', actual) or rules(actual, live=True) != rules(text):
            raise RuntimeError('current nftables guard policy readback failed: ' + hook)
def stop(*_):
    raise SystemExit(0)

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
if operation == "host-cleanup":
    cleanup(settings)
    sys.exit(0)
if operation != "host-setup":
    raise ValueError("unknown host operation")

frozen = None
bootstrap_restarts = None
descriptor = None
try:
    manager = SystemdManager()
    cycle_deadline = time.monotonic() + 30
    cycle_started = time.monotonic()
    expected, descriptor = initialize(settings, manager, verify_policy)
    while True:
        cycle_started = time.monotonic()
        last_command = None
        slow_commands = []
        cycle_deadline = time.monotonic() + 2
        manager.deadline = cycle_deadline
        manager.slow_calls = []
        watched = (f"hermes@{name}.service", f"hermes-host-control@{name}.service", f"hermes-network@{name}.service", f"hermes-network-ready@{name}.service")
        all_jobs = manager.jobs()
        jobs = [job for job in all_jobs if job[1] in watched]
        restarts = {(job, unit) for job, unit, operation in jobs if operation == 'restart'}
        bootstrap_restarts = restarts if bootstrap_restarts is None else bootstrap_restarts & restarts
        for job, unit, operation in jobs:
            if operation == 'stop' or (operation == 'restart' and (job, unit) not in bootstrap_restarts):
                related = ','.join(
                    f'{pending_operation}:{pending_unit}'
                    for _, pending_unit, pending_operation in all_jobs
                    if pending_unit in watched or pending_unit in ('nftables.service', 'systemd-networkd.service')
                )
                print(f'{name}: {operation} transaction job={job} unit={unit} related_jobs=[{related}]; authorization revoked', flush=True)
                sys.exit(0)
        unit_names = [f"hermes-{role}@{name}.service" for role in roles]
        units = manager.snapshot(unit_names, f"hermes-netns@{name}.service", f"hermes-network-observer@{name}.service")
        anchor = units[f'hermes-netns@{name}.service']
        process = pathlib.Path('/proc') / str(expected['pid'])
        if anchor['InvocationID'] != expected['generation'] or int(anchor['MainPID']) != expected['pid'] or int((process / 'stat').read_text().rpartition(')')[2].split()[19]) != expected['start'] or ((process / 'ns/net').stat().st_ino != expected['namespace']):
            raise RuntimeError('namespace anchor generation lost')
        verify_policy()
        link, = json.loads(run(ip, '-j', 'address', 'show', 'dev', host_interface))
        for key, family, prefix in (('host4', 'inet', 30), ('host6', 'inet6', 64)):
            current = sorted((item['local'] for item in link['addr_info'] if usable(item, family, prefix)))
            if current != sorted(expected[key]):
                raise RuntimeError('host allocation generation lost')
        ready_state = units[f'hermes-network-ready@{name}.service']['ActiveState']
        ready_job = any((unit == f'hermes-network-ready@{name}.service' and operation in ('start', 'restart') for _, unit, operation in jobs))
        if startup_deadline is None and (ready_job or ready_state in ('active', 'activating')):
            startup_deadline = time.monotonic() + 30
        if startup_deadline is None:
            time.sleep(0.5)
            continue
        try:
            record = observation(observation_path, expected, interface, mac)
        except (OSError, ValueError):
            if authorized or time.monotonic() >= startup_deadline:
                raise
            time.sleep(0.1)
            continue
        pending = False
        for role in roles:
            properties = units['hermes-' + role + f'@{name}.service']
            allowed = ('active', 'activating') if role in ('network-ready', 'host-control') else ('active',)
            if properties['ActiveState'] not in allowed:
                if authorized or properties['ActiveState'] == 'failed' or time.monotonic() >= startup_deadline:
                    raise RuntimeError('required producer lost: ' + role)
                pending = True
            if role == 'network-observer' and properties['InvocationID'] != record['invocation']:
                raise RuntimeError('observer process changed')
        if pending:
            time.sleep(0.1)
            continue
        if frozen is not None and frozen != (record['peer4'], record['peer6'], record['index']):
            raise RuntimeError('peer address/interface generation lost')
        required = {(protocol, address, 53) for protocol in ('tcp', 'udp') for address in expected['host4'] + expected['host6']}
        required.update(((mapping['protocol'], '127.0.0.1', mapping['hostPort']) for mapping in mappings))
        listeners = set()
        for line in run(ss, '-H', '-lnut').splitlines():
            fields = line.split()
            address, port = fields[4].rsplit(':', 1)
            if port.isdecimal():
                listeners.add((fields[0], address.strip('[]'), int(port)))
        relays = {mapping['protocol'] + ':' + str(mapping['agentPort']) for mapping in mappings if mapping['target'] == 'loopback'}
        if not required <= listeners or not relays <= set(record['listeners']):
            if authorized or time.monotonic() >= startup_deadline:
                raise RuntimeError(f'required DNS/proxy/relay listener lost: sockets={sorted(required - listeners)} relays={sorted(relays - set(record["listeners"]))}')
            time.sleep(0.1)
            continue
        expected_sets = dict(zip(set_names, (expected['host4'], record['peer4'], expected['host6'], record['peer6'])))
        if not authorized:
            batch = []
            for set_name, values in expected_sets.items():
                batch.append('flush set inet hermes-agent-guard ' + set_name)
                batch.append('add element inet hermes-agent-guard ' + set_name + ' { ' + ', '.join(values) + ' }')
            run(nft, '-f', '-', input='\n'.join(batch) + '\n')
        table = json.loads(run(nft, '-j', 'list', 'table', 'inet', 'hermes-agent-guard'))
        actual_sets = {entry['set']['name']: entry['set'].get('elem', []) for entry in table['nftables'] if 'set' in entry}
        verify_sets(actual_sets, expected_sets)
        if not authorized:
            verify_policy()
        fresh(record['timestamp'])
        frozen = (record['peer4'], record['peer6'], record['index'])
        allocation_hash = allocation(expected, record)
        if not authorized:
            resolver = publication / 'resolv.conf.tmp'
            resolver.write_text(''.join(('nameserver ' + address + '\n' for address in (expected['host4'][0], expected['host6'][0]))) + 'options attempts:1 timeout:2\n')
            resolver.chmod(0o644)
            resolver.replace(publication / 'resolv.conf')
            print(f'{name}: network generation ' + expected['generation'] + ' ready; DHCPv4, SLAAC, DNS and nftables verified', flush=True)
        atomic(publication / 'authorization.json', dict(version=1, generation=expected['generation'], controller=expected['controller'], observer=record['invocation'], pid=expected['pid'], start=expected['start'], namespace=expected['namespace'], allocation=allocation_hash, policy=expected['policy'], timestamp=now(), authorized=True))
        authorized = True
        time.sleep(0.1)
finally:
    if descriptor is not None:
        os.close(descriptor)
    # Revoke before dependents finish stopping; ExecStopPost is the hard-kill fallback.
    cleanup(settings)
