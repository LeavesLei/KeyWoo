#!/usr/bin/env python3
"""Build a deterministic, <=20 MiB-part ZIP of KeyWoo's binary application assets.

Only WAVs in the two resource trees and the two exact approved icons are included.
License, configuration and source-code text remains outside the archive.
Python 3.9+, standard library only; no network or system configuration changes.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import zipfile

_spec = importlib.util.spec_from_file_location("keywoo_asset_safety", Path(__file__).with_name("prepare-assets.py"))
safety = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(safety)


def inventory(root):
    paths = []
    for prefix in safety.AUDIO_ROOTS:
        folder = root / prefix
        safety.checked_target(root, prefix + "inventory-probe.wav")
        if not folder.is_dir():
            raise safety.AssetError("Required audio resource directory is absent: " + prefix)
        for parent, directories, names in os.walk(str(folder), followlinks=False):
            for name in directories:
                path = Path(parent) / name
                if safety.is_link_or_reparse(path.lstat()):
                    raise safety.AssetError("Refusing linked resource directory: " + str(path))
            for name in names:
                if name.endswith(".wav"):
                    relative = (Path(parent) / name).relative_to(root).as_posix()
                    safety.checked_target(root, relative)
                    paths.append(relative)
    for icon in safety.ICONS:
        safety.checked_target(root, icon)
        if not (root / icon).is_file():
            raise safety.AssetError("Required approved icon is absent: " + icon)
        paths.append(icon)
    if len(paths) > safety.FILE_COUNT_LIMIT or len(set(p.casefold() for p in paths)) != len(paths):
        raise safety.AssetError("Oversized or case-colliding resource catalogue")
    return sorted(paths)


def pack(root, output, part_size=safety.PART_LIMIT):
    root = Path(root).resolve(strict=True)
    output = Path(output).absolute()
    safety.require_size(part_size, safety.PART_LIMIT, "part size")
    if output.is_symlink() or (output.exists() and safety.is_link_or_reparse(output.lstat())):
        raise safety.AssetError("Output directory must not be a link")
    output.mkdir(parents=True, exist_ok=True)
    output = output.resolve(strict=True)
    paths = inventory(root)
    if sum((root / relative).stat().st_size for relative in paths) > safety.ARCHIVE_LIMIT:
        raise safety.AssetError("Uncompressed resource catalogue is too large")
    with tempfile.TemporaryDirectory(prefix=".pack-keywoo-", dir=str(output.parent)) as temporary:
        temporary = Path(temporary)
        archive_path = temporary / "archive.zip"
        entries = []
        with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9, allowZip64=False) as archive:
            for relative in paths:
                path = safety.checked_target(root, relative)
                before = path.stat()
                safety.require_size(before.st_size, safety.FILE_LIMIT, "input file size")
                info = zipfile.ZipInfo(relative, date_time=(1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                info._compresslevel = 9
                size, digest = 0, hashlib.sha256()
                with safety.open_regular(path) as source, archive.open(info, "w") as destination:
                    for data in iter(lambda: source.read(safety.CHUNK), b""):
                        size += len(data); digest.update(data); destination.write(data)
                after = path.stat()
                if (before.st_size, before.st_mtime_ns, before.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino) or size != before.st_size:
                    raise safety.AssetError("Source changed while packing: " + relative)
                entries.append({"path": relative, "bytes": size, "sha256": digest.hexdigest()})
        archive_bytes, archive_hash = safety.file_digest(archive_path)
        safety.require_size(archive_bytes, safety.ARCHIVE_LIMIT, "archive size")
        parts = []
        with archive_path.open("rb") as source:
            index = 1
            while True:
                data = source.read(part_size)
                if not data:
                    break
                name = "keywoo-assets-%03d.part" % index
                (temporary / name).write_bytes(data)
                parts.append({"file": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
                index += 1
        manifest = {"schema": 1, "partSize": part_size,
                    "archive": {"format": "zip", "bytes": archive_bytes, "sha256": archive_hash},
                    "parts": parts, "files": entries}
        # No wall-clock, machine paths, IDs or source mtimes enter the manifest.
        (temporary / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False, sort_keys=True) + "\n", encoding="utf-8")
        safety.load_manifest(temporary)
        for part in parts:
            os.replace(str(temporary / part["file"]), str(output / part["file"]))
        os.replace(str(temporary / "manifest.json"), str(output / "manifest.json"))
        expected = {part["file"] for part in parts}
        for path in output.glob("keywoo-assets-*.part"):
            if re.fullmatch(r"keywoo-assets-[0-9]{3}\.part", path.name) and path.name not in expected and path.is_file() and not path.is_symlink():
                path.unlink()
    return {"files": len(entries), "sourceBytes": sum(x["bytes"] for x in entries),
            "archiveBytes": archive_bytes, "parts": len(parts), "archiveSHA256": archive_hash}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--part-size", type=int, default=4 * 1024 * 1024,
                        help="Maximum bytes per part (default: 4 MiB)")
    args = parser.parse_args()
    output = args.output if args.output is not None else args.root / "assets"
    try:
        print(json.dumps(pack(args.root, output, part_size=args.part_size), sort_keys=True))
        return 0
    except (safety.AssetError, OSError, zipfile.BadZipFile, RuntimeError) as error:
        print("Asset packing failed: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
