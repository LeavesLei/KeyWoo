#!/usr/bin/env python3
"""Validate the shared release version and stamp an already generated Info.plist."""
import argparse
import json
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]


def load_version():
    value = json.loads((ROOT / "release-version.json").read_text())
    if not isinstance(value.get("version"), str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value["version"]):
        raise ValueError("Release version must be a three-part numeric version")
    if type(value.get("build")) is not int or value["build"] < 23 or value["build"] > 65535:
        raise ValueError("Build must increase from the previous preview (22), and fit Windows metadata")
    return value


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--plist", type=Path)
    args = parser.parse_args()
    value = load_version()
    if args.plist:
        content = plistlib.loads(args.plist.read_bytes())
        content["CFBundleShortVersionString"] = value["version"]
        content["CFBundleVersion"] = str(value["build"])
        args.plist.write_bytes(plistlib.dumps(content, sort_keys=False))
    print(json.dumps(value))
