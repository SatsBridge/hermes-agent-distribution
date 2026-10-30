import ipaddress
import json
import os
import pathlib
import subprocess
import sys
import time

sys.path.insert(0, sys.argv.pop(1))
from network_record import atomic, config, dad_pending, dad_waiting, now, observation, usable

settings = json.loads(pathlib.Path(sys.argv.pop(1)).read_text())
publication = pathlib.Path(settings['publication'])
observation_path = settings['observation_path']
interface = settings['interface']
mac = settings['mac']
pathlib.Path(observation_path).parent.chmod(493)
notified = False
while True:
    dad_probe = False
    try:
        expected = config(publication / 'config.json')

        def ip(*args):
            return json.loads(subprocess.check_output([settings['tools']['ip'], '-j', *args], timeout=2))
        link, = ip('address', 'show', 'dev', interface)
        peer4 = sorted((item['local'] for item in link['addr_info'] if usable(item, 'inet', 30)))
        prefix = ipaddress.ip_network(expected['host6'][0] + '/64', strict=False)
        peer6 = sorted((item['local'] for item in link['addr_info'] if usable(item, 'inet6', 64) and ipaddress.ip_address(item['local']) in prefix))
        dadfailed = any((item.get('dadfailed') or 'dadfailed' in item.get('flags', []) for item in link['addr_info']))
        dad_probe = dad_pending(link['addr_info'])
        if dadfailed:
            raise RuntimeError('SLAAC DAD failed on ' + interface)
        if not peer4 or not peer6:
            time.sleep(0.1)
            continue
        listeners = []
        for protocol, flags in (('tcp', '-ltn'), ('udp', '-lun')):
            output = subprocess.check_output([settings['tools']['ss'], '-H', flags], text=True, timeout=2)
            for line in output.splitlines():
                endpoint = line.split()[3]
                if any((endpoint.startswith(address + ':') for address in peer4)):
                    listeners.append(protocol + ':' + endpoint.rsplit(':', 1)[1])
        if dad_waiting(link['addr_info'], peer6, dadfailed):
            time.sleep(0.1)
            continue
        routes = ip('route', 'show')
        record = dict(version=1, generation=expected['generation'], invocation=os.environ['INVOCATION_ID'], namespace=os.stat('/proc/self/ns/net').st_ino, timestamp=now(), interface=interface, index=link['ifindex'], mac=link['address'], peer4=peer4, peer6=peer6, route4=any((route.get('dst') == 'default' and route.get('dev') == interface and (route.get('gateway') == expected['host4'][0]) for route in routes)), route6=any((route.get('dst') == 'default' and route.get('dev') == interface for route in routes)), dadfailed=dadfailed, listeners=sorted(set(listeners)))
        atomic(observation_path, record)
        observation(observation_path, expected, interface, mac)
        if not notified:
            notified = True
    except (OSError, ValueError, subprocess.SubprocessError):
        if notified:
            raise
    time.sleep(0.1 if dad_probe else 0.5)
