import json
import os
import pathlib
import socket
import sys
import time

sys.path.insert(0, sys.argv.pop(1))
from network_record import authorization, config, now, observation

settings = json.loads(pathlib.Path(sys.argv.pop(1)).read_text())
publication = pathlib.Path(settings['publication'])
deadline = time.monotonic() + 55
started_at = now()
notified = False
expected = None
while True:
    try:
        current = config(publication / 'config.json')
        if expected is not None and current != expected:
            raise RuntimeError('network generation changed')
        expected = current
        observed = observation(settings['observation_path'], expected, settings['interface'], settings['mac'])
        if observed['timestamp'] < started_at:
            time.sleep(0.1)
            continue
        authorization(publication / 'authorization.json', expected, observed)
        if not notified:
            address = os.environ['NOTIFY_SOCKET']
            if address.startswith('@'):
                address = '\x00' + address[1:]
            with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as notifier:
                notifier.sendto(b'READY=1', address)
            notified = True
    except (OSError, ValueError):
        if notified or (publication / 'authorization.json').exists() or time.monotonic() >= deadline:
            raise
    time.sleep(0.1)
