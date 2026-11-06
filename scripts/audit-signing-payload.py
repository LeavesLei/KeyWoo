#!/usr/bin/env python3
"""Read-only payload audit for KeyWoo signing-only changes; never signs code.

snapshot APP OUTPUT.json
compare BEFORE.json APP OUTPUT.json
Only the embedded signature, LC_CODE_SIGNATURE, and __LINKEDIT allocation sizes
are excluded from code equivalence. Resources, code/data sections, all other
load commands and pre-signature __LINKEDIT data must remain exactly unchanged.
"""
import argparse
import hashlib
import json
import plistlib
import struct
import subprocess
from pathlib import Path


def digest(data):
    return hashlib.sha256(data).hexdigest()


def macho(path):
    data = path.read_bytes()
    header = struct.unpack_from("<8I", data)
    if header[0] != 0xFEEDFACF:
        raise ValueError("Only the currently shipped little-endian 64-bit Mach-O is supported")
    offset = 32
    commands, sections, linkedit = [], {}, None
    signature = None
    for _ in range(header[4]):
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > 32 + header[5]:
            raise ValueError("Invalid Mach-O load command")
        raw = bytearray(data[offset:offset + size])
        if command == 0x1D:  # LC_CODE_SIGNATURE
            signature = struct.unpack_from("<II", raw, 8)
        else:
            if command == 0x19:  # LC_SEGMENT_64
                seg = struct.unpack_from("<II16sQQQQiiII", raw)
                name = seg[2].split(b"\0")[0].decode()
                if name == "__LINKEDIT":
                    linkedit = (seg[5], seg[6])
                    # Signing can resize __LINKEDIT to hold the CMS blob.
                    struct.pack_into("<Q", raw, 32, 0)  # vmsize
                    struct.pack_into("<Q", raw, 48, 0)  # filesize
                for index in range(seg[9]):
                    section = struct.unpack_from("<16s16sQQIIIIIIII", raw, 72 + index * 80)
                    section_name = section[0].split(b"\0")[0].decode()
                    section_size, section_offset, flags = section[3], section[4], section[8]
                    zero_fill = flags & 0xFF in (1, 0xC, 0x12)
                    if not zero_fill and section_offset + section_size > len(data):
                        raise ValueError("Out-of-bounds Mach-O section")
                    sections[name + "/" + section_name] = {
                        "address": section[2], "size": section_size,
                        "flags": flags, "zeroFill": zero_fill,
                        "sha256": None if zero_fill else digest(data[section_offset:section_offset + section_size]),
                    }
            commands.append({"command": command, "size": size, "sha256": digest(raw)})
        offset += size
    if signature is None or linkedit is None:
        raise ValueError("Expected an already-signed app with __LINKEDIT")
    if not linkedit[0] <= signature[0] <= len(data) or signature[0] + signature[1] > len(data):
        raise ValueError("Invalid signature bounds")
    return {
        "wholeFileSHA256": digest(data),
        "inode": path.stat().st_ino,
        "signatureOffset": signature[0], "signatureSize": signature[1],
        "equivalentPayload": {
            "header": list(header), "loadCommands": commands, "sections": sections,
            "linkeditBeforeSignatureSHA256": digest(data[linkedit[0]:signature[0]]),
        },
    }


def snapshot(app):
    app = Path(app).resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    executable = "Contents/MacOS/" + info["CFBundleExecutable"]
    files = {}
    for path in sorted(app.rglob("*")):
        if path.is_symlink():
            raise ValueError("Unexpected symlink: " + str(path))
        if path.is_file():
            relative = str(path.relative_to(app))
            if relative != executable and not relative.startswith("Contents/_CodeSignature/"):
                files[relative] = {"size": path.stat().st_size, "sha256": digest(path.read_bytes())}
    verify = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)], capture_output=True, text=True)
    details = subprocess.run(["/usr/bin/codesign", "-dvvv", "-r-", str(app)], capture_output=True, text=True)
    return {"app": str(app), "bundleID": info["CFBundleIdentifier"],
            "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
            "files": files, "executable": executable, "macho": macho(app / executable),
            "signatureValid": verify.returncode == 0, "verification": verify.stdout + verify.stderr,
            "signatureDetails": details.stdout + details.stderr}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    snap = sub.add_parser("snapshot")
    snap.add_argument("app"); snap.add_argument("output")
    compare = sub.add_parser("compare")
    compare.add_argument("before"); compare.add_argument("app"); compare.add_argument("output")
    args = parser.parse_args()
    result = snapshot(args.app)
    passed = result["signatureValid"]
    if args.action == "compare":
        before = json.loads(Path(args.before).read_text())
        checks = {
            "resourcesAndInfoPlistIdentical": before["files"] == result["files"],
            "codeAndDataIdentical": before["macho"]["equivalentPayload"] == result["macho"]["equivalentPayload"],
            "bundleIdentityUnchanged": before["bundleID"] == result["bundleID"],
            "signatureValid": result["signatureValid"],
        }
        result["comparison"] = checks
        result["freshExecutableInode"] = before["macho"]["inode"] != result["macho"]["inode"]
        passed = all(checks.values())
    result["passed"] = passed
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output).write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"passed": passed, "report": args.output, "comparison": result.get("comparison")}, ensure_ascii=False))
    raise SystemExit(0 if passed else 1)


if __name__ == "__main__":
    main()
