import os
import pathlib
import sys

runtime = pathlib.Path(os.environ["RUNTIME_DIRECTORY"].split(":", 1)[0]).stat()
home = os.environ["HOME"]
state = os.environ["STATE_DIRECTORY"].split(":", 1)[0]
if not os.path.isabs(home) or os.path.normpath(home) != os.path.normpath(state) or home == "/":
    raise ValueError("ownership initialization is restricted to the managed StateDirectory")
# Preserve GNU chown's recursive/symlink semantics and systemd's idmapped state.
os.execv(sys.argv[1], [sys.argv[1], "-R", f"{runtime.st_uid}:{runtime.st_gid}", "--", home])
