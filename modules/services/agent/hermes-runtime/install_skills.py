import json
import pathlib
import subprocess
import sys

settings = json.loads(pathlib.Path(sys.argv[1]).read_text())
for skill in ("official/creative/concept-diagrams", "official/creative/creative-ideation",
        "official/software-development/ast-grep", "official/software-development/code-wiki",
        "official/software-development/subagent-driven-development"):
    subprocess.run([settings["hermes"], "skills", "install", "-y", skill], check=True)
