#!/usr/bin/env python3
"""Install the already signed KeyWoo bundle atomically, preserving its identity."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import uuid
from signing_support import ROOT, load_profile, run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "dist/KeyWoo.app")
    parser.add_argument("--destination", type=Path, default=Path("/Applications/KeyWoo.app"))
    args = parser.parse_args()
    source, destination = args.source.resolve(), args.destination
    if not destination.is_absolute() or destination.name != "KeyWoo.app" or destination.is_symlink():
        raise RuntimeError("The destination must be an absolute, non-symlink KeyWoo.app path.")
    if source == destination:
        raise RuntimeError("The source and destination must be separate bundles.")
    fingerprint = load_profile()["identity_sha1"]
    verify = [sys.executable, ROOT / "scripts/verify-signing.py"]
    run([*verify, source, fingerprint])
    if destination.exists():
        info = plistlib.loads((destination / "Contents/Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != "app.keydance.mac":
            raise RuntimeError("Refusing to replace another application's bundle.")
        run([*verify, source, fingerprint, "--previous", destination])
    processes = run(["ps", "-axo", "pid=,command="])
    paths = [str(p / "Contents/MacOS/KeyDance") for p in (source, destination)]
    for line in processes.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and any(fields[1] == p or fields[1].startswith(p + " ") for p in paths):
            raise RuntimeError("Quit the running KeyWoo normally before installing it.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    lock_path = ROOT / ".build/keywoo-packaging.lock"
    lock_path.parent.mkdir(exist_ok=True)
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with tempfile.TemporaryDirectory(prefix=".KeyWoo-install-", dir=destination.parent) as temporary:
            candidate = Path(temporary) / "KeyWoo.app"
            run(["ditto", source, candidate])
            run([*verify, candidate, fingerprint, "--previous", source])
            backup = destination.parent / (".KeyWoo-previous-" + uuid.uuid4().hex[:10] + ".app.backup")
            previous_exists = destination.exists()
            if previous_exists:
                destination.rename(backup)
            try:
                candidate.rename(destination)
            except Exception:
                if previous_exists:
                    backup.rename(destination)
                raise
    # Keep the complete signed bundle intact. No re-signing, trust changes,
    # permission resets, or Launchpad database edits are part of installation.
    run([*verify, destination, fingerprint, "--previous", source])
    register = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    run([register, "-f", destination])
    run([register, "-u", source])
    print(json.dumps({"installed": str(destination), "certificate_sha1": fingerprint,
                      "registered": True, "previous_bundle": str(backup) if previous_exists else None}))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        sys.exit(f"KeyWoo installation failed: {error}")
