import json
import os
import pathlib
import sys

settings = json.loads(pathlib.Path(sys.argv[1]).read_text())
os.symlink(settings["state"], "/var/lib/dhcpcd")
os.execv(settings["dhcpcd"], [settings["dhcpcd"], "--nobackground", "--waitip=4", "--timeout=25",
    "--nohook=resolv.conf,hostname,ntp.conf", "--config=/dev/null", settings["interface"]])
