#!/usr/bin/env python3
"""Sign KeyWoo with its pinned local identity; never fall back to ad-hoc."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import sys
from signing_support import ROOT, load_profile, run, unlock, signing_search_path

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", nargs="?", type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--previous", type=Path)
    parser.add_argument("--allow-identity-migration", action="store_true")
    args = parser.parse_args()
    data = load_profile()
    unlock(data)
    fingerprint = data["identity_sha1"]
    if args.check:
        print(json.dumps({"stable_identity_ready": True, "identity_sha1": fingerprint})); return
    if args.app is None:
        parser.error("app is required unless --check is used")
    app = args.app.resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "app.keydance.mac":
        raise RuntimeError("This signing profile is restricted to the KeyWoo bundle identifier.")
    previous = None
    if args.previous is not None:
        previous = args.previous.resolve()
        if not previous.is_dir() or not (previous / "Contents/Info.plist").is_file():
            raise RuntimeError("The explicitly supplied previous bundle does not exist or is not an application.")
        if previous == app or previous.samefile(app):
            raise RuntimeError("The new and previous bundles must be different copies; refusing to sign the previous bundle in place.")
        if not args.allow_identity_migration:
            # Validate the previous identity before any mutation, then verify
            # the update in both directions after signing the new copy.
            run([sys.executable, ROOT / "scripts/verify-signing.py", previous, fingerprint])
    requirement = f'=designated => identifier "app.keydance.mac" and certificate leaf = H"{fingerprint}"'
    with signing_search_path(data):
        run(["/usr/bin/codesign", "--force", "--sign", fingerprint, "--keychain", data["keychain_path"],
             "--timestamp=none", "--identifier", "app.keydance.mac", "--requirements", requirement, app])
    verify = [sys.executable, ROOT / "scripts/verify-signing.py", app, fingerprint]
    if previous is not None:
        if args.allow_identity_migration:
            # Explicit one-time migration cannot preserve the old ad-hoc TCC
            # authorization. Normal later builds require cross-DR validation.
            print("Explicit signing identity migration: macOS privacy approval must be renewed once.")
        else:
            verify += ["--previous", previous]
    run(verify)
    print(json.dumps({"signed": True, "stable_identity": True, "identity_sha1": fingerprint,
                      "identity_migration": bool(args.allow_identity_migration and args.previous)}))

if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Stable signing failed: {error}", file=sys.stderr); sys.exit(1)
