#!/usr/bin/env python3
"""Stage the shipping sound library with losslessly compressed WAV files."""

import argparse
import gzip
from pathlib import Path
import shutil


def package(source, destination):
    if source.resolve() == destination.resolve() or destination.resolve().is_relative_to(source.resolve()):
        raise ValueError("The shipping library must be staged outside its source folder.")
    if not (source / "manifest.json").is_file():
        raise ValueError("Missing keyboard sound catalogue.")
    destination.mkdir(parents=True)
    source_bytes = 0
    packaged_bytes = 0
    for path in sorted(source.rglob("*")):
        if not path.is_file():
            continue
        target = destination / path.relative_to(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        size = path.stat().st_size
        if path.suffix == ".wav":
            with target.with_suffix(".wav.gz").open("wb") as raw:
                with gzip.GzipFile(filename="", mode="wb", compresslevel=6, fileobj=raw, mtime=0) as compressed:
                    with path.open("rb") as original:
                        shutil.copyfileobj(original, compressed)
            target = target.with_suffix(".wav.gz")
        else:
            shutil.copyfile(path, target)
        source_bytes += size
        packaged_bytes += target.stat().st_size
    if source_bytes == 0:
        raise ValueError("No keyboard sounds to package.")
    print(f"Keyboard sounds: {source_bytes:,} source bytes -> {packaged_bytes:,} packaged bytes")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    package(args.source, args.destination)
