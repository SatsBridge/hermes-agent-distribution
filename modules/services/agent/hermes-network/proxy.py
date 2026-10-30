import ipaddress
import json
import pathlib
import signal
import subprocess
import sys
import time

sys.path.insert(0, sys.argv.pop(1))
from network_record import addresses, config, observation

settings = json.loads(pathlib.Path(sys.argv.pop(1)).read_text())
publication = pathlib.Path(settings['publication'])
observation_path = settings['observation_path']
interface = settings['interface']
mac = settings['mac']
role = settings['role']
deadline = time.monotonic() + 30
while True:
    try:
        expected = config(publication / 'config.json')
        if role != 'dns':
            observation_record = observation(observation_path, expected, interface, mac)
        break
    except (OSError, ValueError):
        if time.monotonic() >= deadline:
            raise
        time.sleep(0.1)
children = []

def stop(*_):
    raise SystemExit(0)
signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
try:
    if role == 'dns':
        upstreams = [line.split()[1] for line in pathlib.Path('/run/hermes-host-resolv.conf').read_text().splitlines() if len(line.split()) >= 2 and line.split()[0] == 'nameserver']
        if not upstreams:
            raise ValueError('No host nameservers in /etc/resolv.conf')
        args = [settings['tools']['dnsmasq'], '--no-daemon', '--no-resolv', '--no-hosts', '--bind-interfaces', '--user=', '--group=', '--port=53', '--pid-file=', '--log-facility=-']
        args += ['--listen-address=' + address for address in expected['host4'] + expected['host6']]
        args += ['--server=' + str(ipaddress.ip_address(address)) for address in upstreams]
        children.append(subprocess.Popen(args))
    else:
        agent_ip, = observation_record['peer4']
        addresses([agent_ip], 4)
        mappings = settings['mappings']
        for mapping in mappings:
            protocol, port = (mapping['protocol'], mapping['agentPort'])
            source = '127.0.0.1' if role == 'host-proxy' else agent_ip
            source_port = mapping.get('hostPort', port)
            target = agent_ip if role == 'host-proxy' else '127.0.0.1'
            listener = f'TCP4-LISTEN:{source_port},bind={source},reuseaddr,fork' if protocol == 'tcp' else f'UDP4-RECVFROM:{source_port},bind={source},fork'
            destination = f'TCP4:{target}:{port}' if protocol == 'tcp' else f'UDP4-SENDTO:{target}:{port}'
            children.append(subprocess.Popen([settings['tools']['socat'], listener, destination]))
    while True:
        if any((child.poll() is not None for child in children)):
            raise RuntimeError('required proxy child exited')
        time.sleep(0.1)
finally:
    for child in children:
        if child.poll() is None:
            child.terminate()
    for child in children:
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            child.kill()
