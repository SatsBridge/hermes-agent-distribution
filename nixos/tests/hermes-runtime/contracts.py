import importlib.util
import json
import os
import pathlib
import runpy
import subprocess
import sys
import tempfile
import unittest.mock

source = pathlib.Path(sys.argv[1])
chown = sys.argv[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, source / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


with tempfile.TemporaryDirectory() as directory:
    temporary = pathlib.Path(directory)
    skills = temporary / "skills"
    nested = skills / "group" / "one\nmore"
    nested.mkdir(parents=True)
    skill = nested / "SKILL.md"
    skill.write_text("fixture")
    (nested / "ignored.txt").write_text("fixture")
    module = load("skills_acl")
    for jobs in (1, 2):
        with unittest.mock.patch.object(module.subprocess, "run") as invoked:
            module.grant(skills, jobs, nested, "setfacl")
            calls = [call.args[0] for call in invoked.call_args_list]
            assert any(command[2].endswith(":r--") and str(skill) in command for command in calls)
            assert any(command[2].endswith(":r-x") and str(skills) in command for command in calls)
            assert not any(str(nested / "ignored.txt") in command for command in calls)
    for scope in (temporary, skills / ".."):
        try:
            module.grant(skills, 1, scope, "setfacl")
        except ValueError:
            pass
        else:
            raise AssertionError("outside-scope ACL accepted")
    try:
        module.grant(skills, 0, skills, "setfacl")
    except ValueError:
        pass
    else:
        raise AssertionError("zero ACL worker count accepted")
    with unittest.mock.patch.object(module.subprocess, "run", side_effect=subprocess.CalledProcessError(1, ["setfacl"])):
        try:
            module.grant(skills, 1, skills, "setfacl")
        except subprocess.CalledProcessError:
            pass
        else:
            raise AssertionError("ACL command failure suppressed")
    monitor = load("public_state")
    buffer, paths = monitor.nul_paths(b"", b"first\npath\0sec")
    assert paths == ["first\npath"] and buffer == b"sec"
    buffer, paths = monitor.nul_paths(buffer, b"ond\0third\0")
    assert paths == ["second", "third"] and buffer == b""

    state = temporary / "state"
    runtime = temporary / "runtime"
    state.mkdir()
    runtime.mkdir()
    (state / "sentinel").write_text("keep")
    environment = dict(os.environ, HOME=str(state), STATE_DIRECTORY=str(state), RUNTIME_DIRECTORY=str(runtime))
    with unittest.mock.patch.dict(os.environ, environment), unittest.mock.patch.object(sys, "argv", [str(source / "ownership.py"), chown]):
        with unittest.mock.patch.object(os, "execv") as invoked:
            runpy.run_path(str(source / "ownership.py"))
            owner = runtime.stat()
            invoked.assert_called_once_with(chown, [chown, "-R", f"{owner.st_uid}:{owner.st_gid}", "--", str(state)])
    assert (state / "sentinel").read_text() == "keep"
    rejected = subprocess.run([sys.executable, "-I", "-B", str(source / "ownership.py"), chown],
        env={**environment, "HOME": str(temporary)}, capture_output=True, text=True)
    assert rejected.returncode != 0 and "restricted to the managed StateDirectory" in rejected.stderr

    pid_file = temporary / "child.pid"
    settings = temporary / "gateway.json"
    waiter = "import pathlib,os,time; pathlib.Path(" + repr(str(pid_file)) + ").write_text(str(os.getpid())); time.sleep(30)"
    finisher = "import pathlib,time; p=pathlib.Path(" + repr(str(pid_file)) + "); deadline=time.monotonic()+5\nwhile not p.exists() and time.monotonic()<deadline: time.sleep(.01)\nraise SystemExit(7)"
    settings.write_text(json.dumps({"headroom": [sys.executable, "-c", waiter],
        "gateway": [sys.executable, "-c", finisher], "dashboard": None}))
    result = subprocess.run([sys.executable, "-I", "-B", str(source / "gateway.py"), str(settings)],
        env=environment, capture_output=True, text=True, timeout=10)
    assert result.returncode == 7 and "Hermes gateway" in result.stderr and "status 7" in result.stderr, result
    try:
        os.kill(int(pid_file.read_text()), 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError("supervisor left its other child running")

print("RUNTIME_PYTHON_CONTRACT_PASSED ACL/scope/worker-errors/NUL-events/ownership-argv-and-scope/supervision", flush=True)
