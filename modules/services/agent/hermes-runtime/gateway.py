import json
import os
import pathlib
import signal
import subprocess
import sys


def main():
    settings = json.loads(pathlib.Path(sys.argv[1]).read_text())
    os.chdir(os.environ["HOME"])
    children = {}

    def stop(*_):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        for key, label in (("headroom", "Headroom proxy"), ("gateway", "Hermes gateway"), ("dashboard", "Hermes dashboard")):
            if settings[key] is not None:
                process = subprocess.Popen(settings[key])
                children[process.pid] = (process, label)
        pid, status = os.wait()
        process, label = children[pid]
        process.returncode = os.waitstatus_to_exitcode(status)
        code = process.returncode if process.returncode >= 0 else 128 - process.returncode
        print(f"{label} (pid {pid}) exited with status {code}", file=sys.stderr, flush=True)
        return code
    finally:
        for process, _ in children.values():
            if process.poll() is None:
                process.terminate()
        for process, _ in children.values():
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    sys.exit(main())
