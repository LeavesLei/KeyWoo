"""Local signing support. Private material stays outside the workspace."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import shlex
from contextlib import contextmanager
import fcntl

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DIRECTORY = Path.home() / "Library/Application Support/KeyDance/Signing"

def run(args, **kwargs):
    result = subprocess.run([str(x) for x in args], text=True, capture_output=True, **kwargs)
    if result.returncode:
        # These tools receive file paths, never password values in argv.
        raise RuntimeError(f"{Path(str(args[0])).name} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout

def private_file(path: Path):
    if not path.is_absolute() or path.resolve() != path:
        raise RuntimeError("Signing paths must be absolute and must not traverse symlinks.")
    info = path.lstat()
    parent = path.parent.stat()
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1
            or parent.st_uid != os.getuid() or stat.S_IMODE(parent.st_mode) != 0o700):
        raise RuntimeError("Signing files require an owner-only directory (0700) and owner-only files (0600).")

def helper() -> Path:
    source = ROOT / "scripts/SigningKeychain.swift"
    c_source = ROOT / "scripts/SigningKeyHeader.c"
    header = ROOT / "scripts/SigningKeyHeader.h"
    directory = ROOT / ".build/signing-tools"
    directory.mkdir(parents=True, exist_ok=True)
    binary = directory / "keywoo-signing-keychain"
    marker = directory / "helper-source.sha256"
    digest = hashlib.sha256(b"\0".join(p.read_bytes() for p in [source, c_source, header])).hexdigest()
    if not binary.exists() or not marker.exists() or marker.read_text().strip() != digest:
        cache = ROOT / ".build/module-cache"
        cache.mkdir(parents=True, exist_ok=True)
        object_file = directory / "signing-key-header.o"
        c_result = subprocess.run(["clang", "-Wno-deprecated-declarations", "-c", str(c_source), "-o", str(object_file)],
                                  text=True, capture_output=True)
        (directory / "c-compile.log").write_text(c_result.stdout + c_result.stderr)
        if c_result.returncode:
            raise RuntimeError("Signing key-header helper did not compile; see .build/signing-tools/c-compile.log.")
        result = subprocess.run(["swiftc", "-module-cache-path", str(cache), "-import-objc-header", str(header),
                                 str(source), str(object_file), "-o", str(binary)],
                                text=True, capture_output=True)
        (directory / "compile.log").write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError("Signing helper did not compile; see .build/signing-tools/compile.log.")
        marker.write_text(digest + "\n")
    return binary

def profile_path() -> Path:
    return Path(os.environ.get("KEYWOO_SIGNING_PROFILE", str(DEFAULT_DIRECTORY / "profile.json")))

def load_profile(path: Path | None = None):
    path = path or profile_path()
    if not path.exists():
        raise RuntimeError("No stable signing profile. Run python3 scripts/setup-local-signing.py first; release builds never silently use ad-hoc signing.")
    private_file(path)
    data = json.loads(path.read_text())
    if data.get("schema") != 1 or data.get("bundle_identifier") != "app.keydance.mac":
        raise RuntimeError("Unexpected signing-profile schema or application identifier.")
    fingerprint = data.get("identity_sha1", "").lower()
    if not re.fullmatch(r"[0-9a-f]{40}", fingerprint):
        raise RuntimeError("The signing profile must pin an exact certificate SHA-1 fingerprint.")
    for key in ["keychain_path", "password_file", "certificate_path"]:
        private_file(Path(data[key]))
    data["identity_sha1"] = fingerprint
    return data

def unlock(data):
    result = json.loads(run([helper(), "unlock", data["keychain_path"], data["password_file"]]))
    if result.get("identity", result).get("certificateSHA1", "").lower() != data["identity_sha1"]:
        raise RuntimeError("The dedicated keychain identity differs from the pinned signing profile.")
    return result

@contextmanager
def signing_search_path(data):
    # codesign also needs its identity in the search list to construct the
    # certificate chain. Add only this dedicated chain for the signing call.
    path = data["keychain_path"]
    with (Path(path).parent / "signing.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        before = shlex.split(run(["security", "list-keychains", "-d", "user"]))
        added = path not in before
        if added:
            run(["security", "list-keychains", "-d", "user", "-s", *before, path])
        try:
            yield
        finally:
            if added:
                current = shlex.split(run(["security", "list-keychains", "-d", "user"]))
                run(["security", "list-keychains", "-d", "user", "-s", *[p for p in current if p != path]])
