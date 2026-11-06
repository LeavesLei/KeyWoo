#!/usr/bin/env python3
"""Record the exact committed input tree before compilation, and detect edits."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def receipt():
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=ROOT)
    paths = sorted(filter(None, git("ls-files", "-z").decode().split("\0")))
    files = {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in paths}
    return {"sourceCommit": git("rev-parse", "HEAD").decode().strip(),
            "sourceDirty": bool(git("status", "--porcelain", "--untracked-files=no").strip()),
            "sourceTreeSHA256": hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    current = receipt()
    if args.verify:
        if json.loads(args.path.read_text()) != current:
            raise SystemExit("Build inputs changed during compilation; rebuild the final snapshot")
    else:
        args.path.write_text(json.dumps(current, sort_keys=True, indent=2) + "\n")
