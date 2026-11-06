#!/usr/bin/env python3
"""Compile a frozen CPU-only remapping verifier and run real elapsed-time QA.

No global tap, key injection, TCC interaction, audio output, or model is involved.
Use --prepare-only when a separate persistent foreground exec session owns the run.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    "Sources/KeyDance/RemapModels.swift",
    "Sources/KeyDance/RemapStateMachine.swift",
    "Sources/KeyDance/RemapCaptureShield.swift",
    "Sources/KeyDance/RemapSoakVerifier.swift",
    "scripts/remap-soak.swift",
]
PROVENANCE_ONLY = [
    "Sources/KeyDance/RemapEventCodec.swift",
    "Sources/KeyDance/RemapController.swift",
    "Sources/KeyDance/RemapStore.swift",
    "Sources/KeyDance/KeyboardMonitor.swift",
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duration", type=float, default=25560,
                        help="qualifying real elapsed seconds (default: 7.1 hours)")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    if args.duration < 1:
        parser.error("duration must be at least one second")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if (out / "run.json").exists() or (out / "result.json").exists():
        parser.error("output already contains a run; choose a fresh directory")
    snapshot = out / "source-snapshot"
    snapshot.mkdir(exist_ok=True)
    hashes = {}
    copied = []
    for relative in SOURCES + PROVENANCE_ONLY:
        source = ROOT / relative
        data = source.read_bytes()
        hashes[relative] = hashlib.sha256(data).hexdigest()
        destination = snapshot / source.name
        destination.write_bytes(data)
        if relative in SOURCES:
            copied.append(str(destination))
    (out / "source-hashes.json").write_text(json.dumps(hashes, indent=2, sort_keys=True) + "\n")
    (out / "build-metadata.json").write_text(json.dumps({
        "compiled_sources": SOURCES,
        "provenance_only_sources": PROVENANCE_ONLY,
        "scope": "long run executes the pure state machine; codec/backend hashes identify the corresponding release, not native tap validation"
    }, indent=2, sort_keys=True) + "\n")
    binary = out / "remap-soak"
    cache = out / "module-cache"
    cache.mkdir(exist_ok=True)
    command = ["xcrun", "swiftc", "-O", "-swift-version", "5", "-parse-as-library",
               "-module-cache-path", str(cache), *copied, "-o", str(binary)]
    build = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (out / "build.log").write_text(build.stdout)
    if build.returncode:
        print(build.stdout, file=sys.stderr)
        return build.returncode
    run = [str(binary), str(args.duration), str(out)]
    (out / "launch-command.txt").write_text(shlex.join(run) + "\n")
    print(shlex.join(run), flush=True)
    if args.prepare_only:
        return 0
    os.execv(str(binary), run)


if __name__ == "__main__":
    raise SystemExit(main())
