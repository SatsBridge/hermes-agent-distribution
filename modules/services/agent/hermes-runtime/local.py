import json
import pathlib
import subprocess
import sys

settings = json.loads(pathlib.Path(sys.argv[1]).read_text())
for interface in ("lo", settings["interface"]):
    subprocess.run([settings["ip"], "link", "set", "dev", interface, "up"], check=True)
