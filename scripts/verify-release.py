#!/usr/bin/env python3
"""Verify the four release artifacts and write checksums for invited downloaders.

Requires macOS package read-back checks and Windows installation/upgrade/uninstall
checks. These are build gates, not a claim of physical Windows audio/keyboard QA.
"""
import argparse
import hashlib
import json
from pathlib import Path


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def verify(folder, version):
    prefix = "KeyWoo-" + version
    mac = json.loads((folder / (prefix + "-mac-arm64-manifest.json")).read_text())
    win = json.loads((folder / (prefix + "-win-x64-manifest.json")).read_text(encoding="utf-8-sig"))
    if mac["version"] != version or win["version"] != version or mac["build"] != win["build"]:
        raise ValueError("Platform version/build mismatch")
    if not mac.get("sourceCommit") or mac["sourceCommit"] != win.get("sourceCommit") or mac.get("sourceDirty") is not False:
        raise ValueError("Both platform packages must come from the same clean committed source")
    if not (mac["archiveContentsVerified"] and mac["diskImageContentsVerified"] and
            win["archiveContentsVerified"] and win["installerTested"] and win["packagedPresetCount"] == 24):
        raise ValueError("Package verification gates have not passed")
    expected = {item["file"]: item["sha256"] for item in mac["artifacts"]}
    expected.update({win["archive"]: win["sha256"], win["installer"]: win["installerSha256"]})
    required = {prefix + suffix for suffix in ("-mac-arm64.dmg", "-mac-arm64.zip", "-win-x64.zip", "-win-x64-setup.exe")}
    if set(expected) != required:
        raise ValueError("Release must contain exactly the expected four platform packages")
    for name, sha in expected.items():
        if digest(folder / name) != sha:
            raise ValueError("Release artifact checksum mismatch: " + name)
    for suffix in ("-mac-arm64-manifest.json", "-win-x64-manifest.json"):
        name = prefix + suffix
        expected[name] = digest(folder / name)
    (folder / "SHA256SUMS.txt").write_text("".join(sha + "  " + name + "\n" for name, sha in sorted(expected.items())))
    print(json.dumps({"version": version, "build": mac["build"], "verifiedArtifacts": 4,
                      "windowsHardwareKeyboardTested": win["hardwareKeyboardTested"],
                      "windowsDevicePlaybackTested": win["devicePlaybackTested"]}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--version", default="1.0.0")
    args = parser.parse_args()
    verify(args.directory, args.version)
