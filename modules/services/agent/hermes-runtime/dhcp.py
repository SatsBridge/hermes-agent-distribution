import json
import os
import pathlib
import sys

settings = json.loads(pathlib.Path(sys.argv[1]).read_text())
# The tmpfs is per-command: initialize it in the process that execs the client.
os.symlink("/run/dhcpcd", "/var/run/dhcpcd")
os.execv(settings["dhcpcd"], [settings["dhcpcd"], "--nobackground", "--waitip=4", "--timeout=25",
    "--nohook=resolv.conf,hostname,ntp.conf", "--config=/dev/null", settings["interface"]])
