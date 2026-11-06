#!/usr/bin/env python3
"""Verify the four release artifacts and write download checksums.

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


def sound_hashes(files, prefix):
    catalogues = {"manifest.json", "synthetic-manifest.json", "hifi-manifest.json", "street-beat-manifest.json"}
    hashes = {}
    for item in files:
        if item["path"].startswith(prefix):
            relative = item["path"][len(prefix):]
            if relative.endswith(".wav") or relative in catalogues:
                hashes[relative] = item["sha256"]
    return hashes


def verify(folder, version):
    prefix = "KeyWoo-" + version
    mac = json.loads((folder / (prefix + "-mac-arm64-manifest.json")).read_text())
    win = json.loads((folder / (prefix + "-win-x64-manifest.json")).read_text(encoding="utf-8-sig"))
    if mac["version"] != version or win["version"] != version or mac["build"] != win["build"]:
        raise ValueError("Platform version/build mismatch")
    if not mac.get("sourceCommit") or mac["sourceCommit"] != win.get("sourceCommit") or mac.get("sourceDirty") is not False:
        raise ValueError("Both platform packages must come from the same clean committed source")
    # Older releases predate the generated sound assets. For the newer
    # catalogue, both platforms must have the extra preset and 15 companions.
    mac_sounds = sound_hashes(mac["appFiles"], "Contents/Resources/KeyboardSounds/")
    win_sounds = sound_hashes(win["files"], "Assets/KeyboardSounds/")
    if mac_sounds != win_sounds:
        differing = sorted(path for path in mac_sounds.keys() | win_sounds.keys()
                           if mac_sounds.get(path) != win_sounds.get(path))
        raise ValueError("Platform audio assets differ: " + ", ".join(differing))
    has_street_beat = "streetBeat/samples.wav" in mac_sounds
    hi_fi_count = sum(path.endswith("/samples-hifi.wav") for path in mac_sounds)
    expected_hi_fi = 15 if has_street_beat else 0
    if hi_fi_count != expected_hi_fi or win.get("packagedHiFiPresetCount", 0) != expected_hi_fi:
        raise ValueError("Platform Hi-Fi sound catalogues are incomplete or differ")
    if has_street_beat and not {"hifi-manifest.json", "street-beat-manifest.json"} <= mac_sounds.keys():
        raise ValueError("Generated audio catalogues are missing")
    if not (mac["archiveContentsVerified"] and mac["diskImageContentsVerified"] and
            win["archiveContentsVerified"] and win["installerTested"] and
            win["packagedPresetCount"] == 24 + int(has_street_beat)):
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
                      "verifiedSharedAudioFiles": len(mac_sounds), "hiFiRecordings": hi_fi_count,
                      "windowsHardwareKeyboardTested": win["hardwareKeyboardTested"],
                      "windowsDevicePlaybackTested": win["devicePlaybackTested"]}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--version", default="1.0.0")
    args = parser.parse_args()
    verify(args.directory, args.version)
