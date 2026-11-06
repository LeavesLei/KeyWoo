#!/usr/bin/env python3
"""Verify or restore KeyWoo's explicitly whitelisted binary application assets.

Python 3.9+, standard library only. No network access, extraction of executable
code, or credentials. The committed manifest is the trust anchor; checksums
prove parts and files match it, not an independent publisher signature.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import tempfile
import unicodedata
import zipfile

PART_LIMIT = 20 * 1024 * 1024
ARCHIVE_LIMIT = 512 * 1024 * 1024
FILE_LIMIT = 128 * 1024 * 1024
FILE_COUNT_LIMIT = 1024
CHUNK = 1024 * 1024
AUDIO_ROOTS = ("Sources/KeyDance/Resources/KeyboardSounds/", "Sources/KeyDance/Resources/Music/")
ICON = "Resources/KeyWooIconSource.png"
ICONS = (ICON, "Resources/KeyWooIcon.png")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
WINDOWS_RESERVED = {"CON", "PRN", "AUX", "NUL"} | {"COM%d" % i for i in range(1, 10)} | {"LPT%d" % i for i in range(1, 10)}


class AssetError(Exception):
    pass


def checked_path(value):
    if not isinstance(value, str) or not value or "\\" in value or ":" in value or any(ord(c) < 32 for c in value):
        raise AssetError("Invalid asset path")
    path = PurePosixPath(value)
    if path.is_absolute() or path.as_posix() != value or any(p in ("", ".", "..") for p in path.parts):
        raise AssetError("Non-canonical or traversing asset path: " + value)
    if unicodedata.normalize("NFC", value) != value:
        raise AssetError("Asset path must use canonical Unicode")
    for part in path.parts:
        if part.endswith((".", " ")) or part.split(".")[0].upper() in WINDOWS_RESERVED:
            raise AssetError("Ambiguous platform path: " + value)
    if value not in ICONS and not (value.endswith(".wav") and any(value.startswith(prefix) for prefix in AUDIO_ROOTS)):
        raise AssetError("Asset is outside the binary-data whitelist: " + value)
    return path


def is_link_or_reparse(info):
    return stat.S_ISLNK(info.st_mode) or bool(getattr(info, "st_file_attributes", 0) & 0x400)


def checked_target(root, relative, create_parents=False):
    parts = checked_path(relative).parts
    current = root
    for index, part in enumerate(parts):
        current = current / part
        try:
            info = current.lstat()
        except FileNotFoundError:
            if create_parents and index < len(parts) - 1:
                current.mkdir()
                info = current.lstat()
            else:
                continue
        if is_link_or_reparse(info):
            raise AssetError("Refusing symlink/reparse asset path: " + relative)
        if index < len(parts) - 1 and not stat.S_ISDIR(info.st_mode):
            raise AssetError("Asset parent is not a directory: " + relative)
        if index == len(parts) - 1 and not stat.S_ISREG(info.st_mode):
            raise AssetError("Asset destination is not a regular file: " + relative)
    return current


def open_regular(path):
    info = path.lstat()
    if is_link_or_reparse(info) or not stat.S_ISREG(info.st_mode):
        raise AssetError("Expected a regular file: " + str(path))
    fd = os.open(str(path), os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0))
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise AssetError("Input changed type: " + str(path))
    return os.fdopen(fd, "rb")


def file_digest(path):
    digest = hashlib.sha256()
    size = 0
    with open_regular(path) as source:
        for data in iter(lambda: source.read(CHUNK), b""):
            size += len(data)
            digest.update(data)
    return size, digest.hexdigest()


def require_size(value, maximum, label, allow_zero=False):
    if type(value) is not int or value < (0 if allow_zero else 1) or value > maximum:
        raise AssetError("Invalid " + label)
    return value


def require_hash(value):
    if not isinstance(value, str) or not SHA_RE.fullmatch(value):
        raise AssetError("Invalid SHA-256 in asset manifest")
    return value


def unique_json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise AssetError("Duplicate JSON key in asset manifest: " + key)
        result[key] = value
    return result


def load_manifest(assets):
    with open_regular(assets / "manifest.json") as source:
        raw = source.read(4 * 1024 * 1024 + 1)
    if len(raw) > 4 * 1024 * 1024:
        raise AssetError("Asset manifest is too large")
    try:
        manifest = json.loads(raw, object_pairs_hook=unique_json_object)
    except (ValueError, UnicodeError) as error:
        raise AssetError("Invalid asset manifest JSON") from error
    if not isinstance(manifest, dict) or type(manifest.get("schema")) is not int or manifest.get("schema") != 1:
        raise AssetError("Unsupported asset manifest schema")
    archive = manifest.get("archive")
    if not isinstance(archive, dict) or archive.get("format") != "zip":
        raise AssetError("Expected a ZIP asset archive")
    archive_bytes = require_size(archive.get("bytes"), ARCHIVE_LIMIT, "archive size")
    require_hash(archive.get("sha256"))
    part_size = require_size(manifest.get("partSize"), PART_LIMIT, "part size")
    parts = manifest.get("parts")
    if not isinstance(parts, list) or not parts or len(parts) > 128:
        raise AssetError("Invalid asset part list")
    total = 0
    for index, part in enumerate(parts):
        if not isinstance(part, dict) or part.get("file") != "keywoo-assets-%03d.part" % (index + 1):
            raise AssetError("Invalid or out-of-order asset part filename")
        size = require_size(part.get("bytes"), part_size, "part length")
        if index < len(parts) - 1 and size != part_size:
            raise AssetError("Only the final part may be shorter")
        require_hash(part.get("sha256")); total += size
    if total != archive_bytes:
        raise AssetError("Part lengths do not match archive length")
    files = manifest.get("files")
    if not isinstance(files, list) or not files or len(files) > FILE_COUNT_LIMIT:
        raise AssetError("Invalid asset file list")
    paths, folded, total = [], set(), 0
    for item in files:
        if not isinstance(item, dict):
            raise AssetError("Invalid file entry")
        relative = str(checked_path(item.get("path")))
        if relative.casefold() in folded:
            raise AssetError("Duplicate or case-colliding asset path: " + relative)
        folded.add(relative.casefold()); paths.append(relative)
        total += require_size(item.get("bytes"), FILE_LIMIT, "asset file size")
        require_hash(item.get("sha256"))
    if paths != sorted(paths) or total > ARCHIVE_LIMIT:
        raise AssetError("Unsorted or oversized asset catalogue")
    return manifest


def checked_assets_directory(path):
    path = Path(path)
    if path.is_symlink() or (path.exists() and is_link_or_reparse(path.lstat())):
        raise AssetError("Asset-part directory must not be a symlink/reparse point")
    return path.resolve(strict=True)


def inspect_existing(root, files):
    missing = []
    for item in files:
        target = checked_target(root, item["path"])
        try:
            size, digest = file_digest(target)
        except FileNotFoundError:
            missing.append(item["path"]); continue
        if size != item["bytes"] or digest != item["sha256"]:
            missing.append(item["path"])
    return missing


def assemble(assets, manifest, target):
    archive_hash = hashlib.sha256()
    with target.open("wb") as output:
        for part in manifest["parts"]:
            digest, size = hashlib.sha256(), 0
            with open_regular(assets / part["file"]) as source:
                for data in iter(lambda: source.read(CHUNK), b""):
                    size += len(data)
                    if size > part["bytes"]:
                        raise AssetError("Oversized asset part: " + part["file"])
                    digest.update(data); archive_hash.update(data); output.write(data)
            if size != part["bytes"] or digest.hexdigest() != part["sha256"]:
                raise AssetError("Asset part checksum mismatch: " + part["file"])
    if target.stat().st_size != manifest["archive"]["bytes"] or archive_hash.hexdigest() != manifest["archive"]["sha256"]:
        raise AssetError("Complete asset ZIP checksum mismatch")


def stage_zip(archive_path, manifest, stage):
    expected = {item["path"]: item for item in manifest["files"]}
    with zipfile.ZipFile(archive_path, "r") as archive:
        entries = archive.infolist()
        if len(entries) != len(expected):
            raise AssetError("ZIP entry count does not match the whitelist")
        seen = set()
        for entry in entries:
            if entry.orig_filename != entry.filename:
                raise AssetError("Ambiguous ZIP filename")
            relative = str(checked_path(entry.filename))
            mode = entry.external_attr >> 16
            if relative in seen or relative not in expected or entry.is_dir():
                raise AssetError("Unexpected or duplicate ZIP entry: " + relative)
            if stat.S_IFMT(mode) not in (0, stat.S_IFREG) or entry.flag_bits & 1:
                raise AssetError("Refusing ZIP links, special files or encryption: " + relative)
            if entry.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
                raise AssetError("Unsupported ZIP compression")
            if entry.file_size != expected[relative]["bytes"]:
                raise AssetError("ZIP file length differs from manifest: " + relative)
            seen.add(relative)
        for entry in entries:
            item = expected[entry.filename]
            target = checked_target(stage, entry.filename, create_parents=True)
            size, digest = 0, hashlib.sha256()
            with archive.open(entry, "r") as source, target.open("xb") as output:
                for data in iter(lambda: source.read(CHUNK), b""):
                    size += len(data)
                    if size > item["bytes"]:
                        raise AssetError("Expanded asset exceeds manifest size")
                    digest.update(data); output.write(data)
            if size != item["bytes"] or digest.hexdigest() != item["sha256"]:
                raise AssetError("Extracted asset checksum mismatch: " + item["path"])
            os.chmod(target, 0o644)


def replace_staged(root, relative, staged):
    target = checked_target(root, relative, create_parents=True)
    # POSIX uses an anchored directory descriptor: a concurrently substituted
    # parent symlink cannot redirect the final replacement outside the root.
    if os.name == "posix" and os.open in os.supports_dir_fd:
        current = os.open(str(root), os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0))
        try:
            for part in PurePosixPath(relative).parts[:-1]:
                following = os.open(part, os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0), dir_fd=current)
                os.close(current); current = following
            os.replace(str(staged), target.name, dst_dir_fd=current)
        finally:
            os.close(current)
    else:
        # Windows lstat rejects junctions/reparse points above. Recheck directly
        # before replacement; extraction never follows a link from the ZIP.
        checked_target(root, relative)
        os.replace(str(staged), str(target))


def prepare(root, assets, check_only=False):
    root = Path(root).resolve(strict=True)
    assets = checked_assets_directory(assets)
    manifest = load_manifest(assets)
    missing = inspect_existing(root, manifest["files"])
    result = {"files": len(manifest["files"]), "bytes": sum(x["bytes"] for x in manifest["files"])}
    if not missing:
        return dict(result, status="verified", replaced=0)
    if check_only:
        raise AssetError("Missing or mismatched binary assets: " + ", ".join(missing))
    # Validate every part and every extracted file before touching destination
    # assets. License/config/code text never belongs to this replacement list.
    with tempfile.TemporaryDirectory(prefix=".keywoo-assets-", dir=str(root)) as temporary:
        temporary = Path(temporary)
        archive = temporary / "archive.zip"
        stage = temporary / "staged"; stage.mkdir()
        assemble(assets, manifest, archive)
        stage_zip(archive, manifest, stage)
        for relative in missing:
            checked_target(root, relative)
        for relative in missing:
            replace_staged(root, relative, stage / relative)
    if inspect_existing(root, manifest["files"]):
        raise AssetError("Asset verification failed after replacement")
    return dict(result, status="prepared", replaced=len(missing))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--assets-dir", type=Path)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    assets = args.assets_dir if args.assets_dir is not None else args.root / "assets"
    try:
        print(json.dumps(prepare(args.root, assets, args.check_only), sort_keys=True))
        return 0
    except (AssetError, OSError, zipfile.BadZipFile, RuntimeError) as error:
        print("Asset preparation failed: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
