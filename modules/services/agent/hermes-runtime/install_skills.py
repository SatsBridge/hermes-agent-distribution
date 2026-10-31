import json
import pathlib
import subprocess
import sys
import time

settings = json.loads(pathlib.Path(sys.argv[1]).read_text())
for skill in ("official/creative/concept-diagrams", "official/creative/creative-ideation",
        "official/software-development/ast-grep", "official/software-development/code-wiki",
        "official/software-development/subagent-driven-development"):
    started = time.monotonic()
    print(f"Default skill install started: {skill}", flush=True)
    try:
        subprocess.run([settings["hermes"], "skills", "install", "-y", skill], check=True)
    except subprocess.CalledProcessError as error:
        print(f"Default skill install failed: {skill} exit={error.returncode} elapsed={time.monotonic() - started:.3f}s", flush=True)
        raise
    print(f"Default skill install completed: {skill} elapsed={time.monotonic() - started:.3f}s", flush=True)
