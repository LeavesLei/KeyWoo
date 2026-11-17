#!/usr/bin/env python3
"""Verify the four release artifacts and write download checksums.

Requires macOS package read-back checks and Windows installation/upgrade/uninstall
checks. These are build gates, not a claim of physical Windows audio/keyboard QA.
"""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import zipfile


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def sound_catalogue(archive, files, prefix, archive_prefix=""):
    catalogues = {"manifest.json", "synthetic-manifest.json", "hifi-manifest.json", "street-beat-manifest.json"}
    hashes = {}
    expected = {}
    preset_count = hi_fi_count = 0
    with zipfile.ZipFile(archive) as bundle:
        for item in files:
            if not item["path"].startswith(prefix):
                continue
            relative = item["path"][len(prefix):]
            if relative not in catalogues and not relative.endswith((".wav", ".wav.gz")):
                continue
            data = bundle.read(archive_prefix + item["path"])
            if hashlib.sha256(data).hexdigest() != item["sha256"]:
                raise ValueError("Packaged sound asset differs from manifest: " + relative)
            if relative in catalogues:
                packs = json.loads(data)["packs"]
                for pack in packs.values():
                    if pack["file"] in expected:
                        raise ValueError("Duplicate sound catalogue entry: " + pack["file"])
                    expected[pack["file"]] = pack["sha256"]
                if relative == "hifi-manifest.json":
                    hi_fi_count = len(packs)
                else:
                    preset_count += len(packs)
            if relative.endswith(".wav.gz"):
                relative = relative.removesuffix(".gz")
                with gzip.GzipFile(fileobj=io.BytesIO(data)) as compressed:
                    data = compressed.read(25_000_000)
                if len(data) == 25_000_000:
                    raise ValueError("Packaged recording is too large: " + relative)
            if relative in hashes:
                raise ValueError("Duplicate packaged sound asset: " + relative)
            hashes[relative] = hashlib.sha256(data).hexdigest()
    if not {"manifest.json", "synthetic-manifest.json"} <= hashes.keys() or expected != {
            path: value for path, value in hashes.items() if path.endswith(".wav")
    }:
        raise ValueError("Packaged sounds do not match their catalogues")
    return hashes, preset_count, hi_fi_count


def verify(folder, version):
    prefix = "KeyWoo-" + version
    mac = json.loads((folder / (prefix + "-mac-arm64-manifest.json")).read_text())
    win = json.loads((folder / (prefix + "-win-x64-manifest.json")).read_text(encoding="utf-8-sig"))
    if mac["version"] != version or win["version"] != version or mac["build"] != win["build"]:
        raise ValueError("Platform version/build mismatch")
    if not mac.get("sourceCommit") or mac["sourceCommit"] != win.get("sourceCommit") or mac.get("sourceDirty") is not False:
        raise ValueError("Both platform packages must come from the same clean committed source")
    mac_sounds, preset_count, hi_fi_count = sound_catalogue(
        folder / (prefix + "-mac-arm64.zip"), mac["appFiles"], "Contents/Resources/KeyboardSounds/", "KeyWoo.app/")
    win_sounds, win_count, win_hi_fi_count = sound_catalogue(
        folder / win["archive"], win["files"], "Assets/KeyboardSounds/")
    if mac_sounds != win_sounds:
        differing = sorted(path for path in mac_sounds.keys() | win_sounds.keys()
                           if mac_sounds.get(path) != win_sounds.get(path))
        raise ValueError("Platform audio assets differ: " + ", ".join(differing))
    if hi_fi_count != win_hi_fi_count or win.get("packagedHiFiPresetCount", 0) != hi_fi_count:
        raise ValueError("Platform Hi-Fi sound catalogues are incomplete or differ")
    if not (mac["archiveContentsVerified"] and mac["diskImageContentsVerified"] and
            win["archiveContentsVerified"] and win["installerTested"] and
            win["packagedPresetCount"] == win_count == preset_count):
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
