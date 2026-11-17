#!/usr/bin/env python3
"""Turn python-floors.txt into pip requirements + constraints for the romm venv.

Runs with the venv's own interpreter, inside the image build. For each floor whose
installed version is below the minimum, emits `name>=minimum,<cap`. Every other installed
distribution is frozen at its current version in constraints.txt, so only the floored
packages (and anything they strictly require) can change.

Usage: python-floors.py <python-floors.txt> <out-dir>
"""
import sys
from importlib import metadata
from pathlib import Path

from packaging.utils import canonicalize_name
from packaging.version import Version


def main(floors_file: str, out_dir: str) -> None:
    installed = {
        canonicalize_name(d.metadata["Name"]): d.version for d in metadata.distributions()
    }

    requirements, floored = [], set()
    for raw in Path(floors_file).read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        name, minimum, cap = line.split()
        key = canonicalize_name(name)
        current = installed.get(key)
        if current is None:
            sys.exit(f"python-floors: {name} is not installed in the venv; remove the floor")
        if Version(current) >= Version(minimum):
            print(f"python-floors: {name} {current} >= {minimum}, no-op (remove this floor)")
            continue
        if Version(minimum) >= Version(cap):
            sys.exit(f"python-floors: {name}: minimum {minimum} is not below cap {cap}")
        print(f"python-floors: {name} {current} -> >={minimum},<{cap}")
        requirements.append(f"{name}>={minimum},<{cap}")
        floored.add(key)

    constraints = sorted(
        f"{name}=={version}" for name, version in installed.items() if name not in floored
    )
    out = Path(out_dir)
    (out / "requirements.txt").write_text("".join(r + "\n" for r in requirements))
    (out / "constraints.txt").write_text("".join(c + "\n" for c in constraints))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
