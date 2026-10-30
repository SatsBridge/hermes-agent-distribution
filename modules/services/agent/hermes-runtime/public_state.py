import json
import os
import pathlib
import selectors
import signal
import stat
import subprocess
import sys
import time

def nul_paths(buffer, chunk):
    parts = (buffer + chunk).split(b"\0")
    return parts[-1], [os.fsdecode(path) for path in parts[:-1]]


def main():
    sys.path.insert(0, sys.argv.pop(1))
    from skills_acl import grant

    settings = json.loads(pathlib.Path(sys.argv[1]).read_text())
    home = pathlib.Path(os.environ["HOME"])
    hermes = pathlib.Path(os.environ["HERMES_HOME"])
    skills = hermes / "skills"
    gid = os.getgid()

    def acl(path, permissions):
        subprocess.run([settings["setfacl"], "-m", f"g:{gid}:{permissions}", "--", str(path)], check=True)

    # StateDirectoryMode=2700 can leave the ACL mask at ---.
    acl(home, "r-x,m::r-x")
    acl(hermes, "r-x,m::r-x")
    acl(hermes / "cron", "r-x")
    acl(hermes / "cron/output", "r--")

    def scan():
        grant(skills, 1, skills, settings["setfacl"])
        for name in ("gateway.pid", "gateway_state.json"):
            path = hermes / name
            if path.exists() and stat.S_ISREG(path.lstat().st_mode):
                acl(path, "r--")
        for name in ("logs", "logs/curator"):
            path = hermes / name
            if path.exists() and stat.S_ISDIR(path.lstat().st_mode):
                for directory, _, _ in os.walk(path, followlinks=False):
                    acl(directory, "r--")

    def stop(*_):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    scan()
    watcher = subprocess.Popen([settings["inotifywait"], "-mrqe", "create,moved_to", "--format", "%w%f%0",
        "--no-newline", "--", str(skills)], stdout=subprocess.PIPE)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(watcher.stdout, selectors.EVENT_READ)
            repeat_at = time.monotonic() + 5
            buffer = b""
            while True:
                timeout = max(0, repeat_at - time.monotonic()) if repeat_at is not None else None
                for key, _ in selector.select(timeout):
                    chunk = os.read(key.fileobj.fileno(), 4096)
                    if not chunk:
                        raise RuntimeError("public-state inotify watcher exited")
                    buffer, paths = nul_paths(buffer, chunk)
                    for path in paths:
                        grant(skills, 1, path, settings["setfacl"])
                if repeat_at is not None and time.monotonic() >= repeat_at:
                    scan()
                    repeat_at = None
    finally:
        watcher.terminate()
        try:
            watcher.wait(timeout=2)
        except subprocess.TimeoutExpired:
            watcher.kill()
            watcher.wait()


if __name__ == "__main__":
    main()
