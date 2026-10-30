import concurrent.futures
import os
import pathlib
import stat
import subprocess
import sys


def grant(skills_dir, jobs, scope, setfacl):
    if jobs <= 0:
        raise ValueError("ACL worker count must be positive")
    base = pathlib.Path(skills_dir).resolve()
    if not base.is_dir():
        return
    search = pathlib.Path(scope).resolve() if scope else base
    if not search.is_relative_to(base):
        raise ValueError(f"grant-skills-acl: refusing scope outside skills_dir: {scope}")
    files = []
    if search.is_file():
        if search.name != "SKILL.md":
            return
        files.append(search)
    elif search.is_dir():
        for directory, _, names in os.walk(search, followlinks=False):
            if "SKILL.md" in names:
                path = pathlib.Path(directory) / "SKILL.md"
                if stat.S_ISREG(path.lstat().st_mode):
                    files.append(path)
    else:
        return
    directories = {base}
    for path in files:
        directory = path.parent
        while directory != base and directory != directory.parent:
            directories.add(directory)
            directory = directory.parent
    tasks = []
    for paths, permissions in ((files, "r--"), (sorted(directories), "r-x")):
        for offset in range(0, len(paths), 50):
            tasks.append([setfacl, "-m", f"g:{os.getgid()}:{permissions}", "--", *map(str, paths[offset:offset + 50])])
    if jobs == 1:
        for command in tasks:
            subprocess.run(command, check=True)
    else:
        with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as executor:
            futures = [executor.submit(subprocess.run, command, check=True) for command in tasks]
            for future in futures:
                future.result()


def main(setfacl):
    grant(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else os.cpu_count() or 1,
        sys.argv[3] if len(sys.argv) > 3 else None, setfacl)
