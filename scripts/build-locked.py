#!/usr/bin/env python3
"""Serialize KeyWoo packaging so two installers cannot race their renames."""
import fcntl
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
directory = root / ".build"
directory.mkdir(exist_ok=True)
with (directory / "keywoo-packaging.lock").open("a") as lock:
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.exit("Another KeyWoo build/install is active. Wait for it to finish and retry.")
    environment = {**os.environ, "_KEYWOO_BUILD_LOCK_ROOT": str(root)}
    sys.exit(subprocess.run(["/bin/bash", str(root / "scripts/build-app.sh"), *sys.argv[1:]],
                            env=environment).returncode)
