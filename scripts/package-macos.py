#!/usr/bin/env python3
"""Package and read back a signed KeyWoo app as a ZIP and drag-to-install DMG.

This never installs, changes privacy permissions, or creates a signing identity.
The release records local signing honestly; it does not claim notarization.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release_version", ROOT / "scripts/release-version.py")
version_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(version_module)


def run(*args):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True).stdout


def digest(path):
    sha = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


def inventory(folder):
    result = []
    for path in sorted(folder.rglob("*")):
        relative = path.relative_to(folder).as_posix()
        if path.is_symlink():
            result.append({"path": relative, "symlink": os.readlink(path)})
        elif path.is_file():
            result.append({"path": relative, "bytes": path.stat().st_size, "sha256": digest(path)})
    return result


def verify_app(app, expected_version):
    run("codesign", "--verify", "--deep", "--strict", app)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == "app.keydance.mac", "Unexpected app identity"
    assert info["CFBundleShortVersionString"] == expected_version["version"], "Version mismatch"
    assert info["CFBundleVersion"] == str(expected_version["build"]), "Build mismatch"
    executable = app / "Contents/MacOS/KeyDance"
    architectures = run("lipo", "-archs", executable).decode().strip()
    assert architectures == "arm64", "This release filename is restricted to Apple Silicon"
    resources = app / "Contents/Resources"
    assert not (resources / "Music").exists() and not (resources / "AI").exists(), "Internal music assets in release"
    for notice in ("THIRD-PARTY-NOTICES.md", "Mechvibes-LICENSE", "kbsim-LICENSE.md"):
        assert (resources / "KeyboardSounds" / notice).is_file(), "Missing sound license: " + notice
    assert (resources / "Documentation/docs/INSTALL.md").is_file(), "Installation guide missing"
    return info


def package(app, output):
    version = version_module.load_version()
    verify_app(app, version)
    receipt = json.loads((app / "Contents/Resources/build-source.json").read_text())
    if receipt["sourceDirty"]:
        raise RuntimeError("Release app must be built from a committed, clean source snapshot")
    original = inventory(app)
    stem = "KeyWoo-" + version["version"] + "-mac-arm64"
    names = [stem + ".zip", stem + ".dmg", stem + "-manifest.json"]
    output.mkdir(parents=True, exist_ok=True)
    if any((output / name).exists() for name in names):
        raise RuntimeError("Release files already exist; choose a new output directory to preserve them")
    with tempfile.TemporaryDirectory(prefix=".keywoo-package-", dir=output) as temporary:
        work = Path(temporary)
        zip_path, dmg_path = work / names[0], work / names[1]
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, zip_path)
        extracted = work / "zip-check"
        run("ditto", "-x", "-k", zip_path, extracted)
        verify_app(extracted / "KeyWoo.app", version)
        assert inventory(extracted / "KeyWoo.app") == original, "ZIP round-trip mismatch"
        stage = work / "image"
        stage.mkdir()
        run("ditto", app, stage / "KeyWoo.app")
        (stage / "Applications").symlink_to("/Applications")
        shutil.copytree(app / "Contents/Resources/Documentation", stage / "Documentation")
        notice = stage / "Documentation/THIRD-PARTY-NOTICES.md"
        notice.write_text(notice.read_text().replace("../KeyboardSounds/", "../KeyWoo.app/Contents/Resources/KeyboardSounds/"))
        (stage / "Install.txt").write_text(
            "键舞 / KeyWoo " + version["version"] + "\n\n"
            "将 KeyWoo.app 拖入 Applications，然后从启动台打开。\n"
            "Drag KeyWoo.app into Applications, then open KeyWoo from Launchpad.\n\n"
            "macOS 14+ · Apple silicon\n"
            "安装与权限说明 / Installation: Documentation/docs/INSTALL.md\n")
        run("hdiutil", "create", "-volname", "KeyWoo " + version["version"], "-srcfolder", stage,
            "-format", "UDZO", dmg_path)
        run("hdiutil", "verify", dmg_path)
        mount = work / "mounted"
        mount.mkdir()
        run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, dmg_path)
        try:
            verify_app(mount / "KeyWoo.app", version)
            assert inventory(mount / "KeyWoo.app") == original, "DMG round-trip mismatch"
            assert os.readlink(mount / "Applications") == "/Applications", "Missing install shortcut"
        finally:
            run("hdiutil", "detach", mount)
        # Detect edits to the source bundle while packaging.
        assert inventory(app) == original, "App changed while packaging"
        manifest = {"version": version["version"], "build": version["build"], "platform": "macOS",
                    "architecture": "arm64", "minimumOSVersion": "14.0", "bundleIdentifier": "app.keydance.mac",
                    "signing": "fixed-local-identity", "developerIDSigned": False, "notarized": False,
                    "archiveContentsVerified": True, "diskImageContentsVerified": True,
                    **receipt,
                    "artifacts": [{"file": p.name, "bytes": p.stat().st_size, "sha256": digest(p)} for p in (zip_path, dmg_path)],
                    "appFiles": original}
        (work / names[2]).write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        for name in names:
            (work / name).rename(output / name)
    print(json.dumps({"version": version["version"], "artifacts": names, "verified": True}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "dist/KeyWoo.app")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/releases/v1.0.0")
    args = parser.parse_args()
    package(args.app.resolve(strict=True), args.output.resolve())
