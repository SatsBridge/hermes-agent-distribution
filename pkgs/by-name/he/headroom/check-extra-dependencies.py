"""Assert that every platform-applicable non-dev Headroom extra is packaged."""

import platform
import sys
import tomllib
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path

from packaging.requirements import Requirement

project = tomllib.loads(Path("pyproject.toml").read_text())["project"]
missing = []
wrong_version = []
for extra, requirements in project["optional-dependencies"].items():
    if extra == "dev":
        continue
    for raw in requirements:
        requirement = Requirement(raw)
        if requirement.name.lower().replace("_", "-") == project["name"].lower().replace("_", "-"):
            continue
        if requirement.marker and not requirement.marker.evaluate({"extra": extra}):
            continue
        if (
            requirement.name == "fastembed"
            and sys.platform == "linux"
            and platform.machine() == "aarch64"
        ):
            continue
        try:
            installed = version(requirement.name)
        except PackageNotFoundError:
            missing.append(raw)
        else:
            if requirement.specifier and installed not in requirement.specifier:
                wrong_version.append(f"{raw} (installed {installed})")

if missing or wrong_version:
    raise SystemExit(
        "Headroom optional dependency coverage failed:\n"
        + "\n".join(f"missing: {item}" for item in missing)
        + "\n".join(f"incompatible: {item}" for item in wrong_version)
    )

print("All applicable non-dev optional dependencies are installed.")
