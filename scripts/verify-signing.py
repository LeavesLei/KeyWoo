#!/usr/bin/env python3
"""Read-only verification of KeyWoo's pinned signing identity and update DRs.

Stable build:
  python3 scripts/verify-signing.py NEW.app CERTIFICATE_SHA1 --previous OLD.app
Explicit ad-hoc debug build (does not establish a stable identity):
  python3 scripts/verify-signing.py DEBUG.app --allow-adhoc

This checks every Mach-O architecture. It never signs code or accesses private
keys. Public DER certificates are extracted into a temporary directory only.
It does not establish notarization, Gatekeeper acceptance, or TCC authorization.

Policy deliberately permits only conjunctions of the expected identifier and
the pinned leaf certificate. Other otherwise-valid Apple requirement languages
must be reviewed rather than silently accepted as equivalent to this policy.

References:
https://developer.apple.com/library/archive/technotes/tn2206/
https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
from typing import Callable, Dict, List, Optional, Sequence


DEFAULT_IDENTIFIER = "app.keydance.mac"
CODESIGN = "/usr/bin/codesign"
LIPO = "/usr/bin/lipo"


class VerificationError(RuntimeError):
    pass


def run_tool(arguments: Sequence[str]) -> str:
    try:
        result = subprocess.run(
            list(arguments), capture_output=True, text=True, timeout=30,
            env=dict(os.environ, LC_ALL="C", LANG="C"),
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise VerificationError("Could not run %s: %s" % (arguments[0], exc)) from exc
    output = result.stdout + "\n" + result.stderr
    if result.returncode:
        raise VerificationError("%s failed (%d): %s" % (
            Path(arguments[0]).name, result.returncode, output.strip()[:3000]))
    return output


def normalize_fingerprint(value: str) -> str:
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", value):
        raise VerificationError("Expected a complete 40-hex-digit certificate SHA-1 fingerprint.")
    return value.upper()


def validate_identifier(value: str) -> None:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]{0,254}", value):
        raise VerificationError("The expected signing identifier is not a valid bundle identifier.")


def pinned_requirement(identifier: str, fingerprint: str) -> str:
    validate_identifier(identifier)
    return 'identifier "%s" and certificate leaf = H"%s"' % (
        identifier, normalize_fingerprint(fingerprint))


def extract_requirement(output: str) -> str:
    lines = re.findall(r"^\s*(?:#\s*)?designated\s*=>\s*(.+)$", output, re.MULTILINE)
    if len(lines) != 1:
        raise VerificationError("Expected exactly one displayed designated requirement per architecture.")
    return lines[0].strip()


def validate_requirement(requirement: str, identifier: str, fingerprint: str) -> None:
    """Accept only an AND expression that necessarily pins both identity parts.

    A substring check would accept `identifier ... or certificate leaf ...` or
    even a quoted string containing such words. A small complete parser rejects
    disjunction, negation, cdhash, unpinned anchors, and unknown/trailing tokens.
    """
    expected = normalize_fingerprint(fingerprint)
    if len(requirement) > 4096:
        raise VerificationError("Designated requirement exceeds this policy's size limit.")
    token_pattern = re.compile(r'\s*(H"[0-9A-Fa-f]+"|"[^"\\]*"|[A-Za-z0-9_.-]+|[()=])')
    tokens: List[str] = []
    offset = 0
    while offset < len(requirement.rstrip()):
        match = token_pattern.match(requirement, offset)
        if not match:
            raise VerificationError("Unsupported syntax in designated requirement.")
        tokens.append(match.group(1))
        offset = match.end()
    position = 0
    found = set()

    def take() -> str:
        nonlocal position
        if position >= len(tokens):
            raise VerificationError("Incomplete designated requirement.")
        value = tokens[position]
        position += 1
        return value

    def expression(depth: int = 0) -> None:
        if depth > 24:
            raise VerificationError("Designated requirement nesting is too deep.")
        term(depth)
        while position < len(tokens) and tokens[position] == "and":
            take()
            term(depth)

    def term(depth: int) -> None:
        token = take()
        if token == "(":
            expression(depth + 1)
            if take() != ")":
                raise VerificationError("Unbalanced designated requirement.")
        elif token == "identifier":
            if take().strip('"') != identifier:
                raise VerificationError("Designated requirement has the wrong identifier.")
            found.add("identifier")
        elif token == "certificate":
            if take() not in ("leaf", "0") or take() != "=":
                raise VerificationError("Designated requirement must pin the leaf certificate hash.")
            value = take()
            if not re.fullmatch(r'H"[0-9A-Fa-f]{40}"', value) or value[2:-1].upper() != expected:
                raise VerificationError("Designated requirement pins a different certificate.")
            found.add("certificate")
        else:
            raise VerificationError("Only identifier and pinned-leaf conjunctions are permitted in the DR.")

    expression()
    if position != len(tokens) or found != {"identifier", "certificate"}:
        raise VerificationError("DR must require both the expected identifier and pinned leaf; no alternatives.")


def bundle_executable(app: Path, identifier: str) -> Path:
    if not app.is_dir():
        raise VerificationError("Not an application bundle directory: %s" % app)
    try:
        with (app / "Contents/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, ValueError, plistlib.InvalidFileException) as exc:
        raise VerificationError("Cannot read the application Info.plist: %s" % exc) from exc
    if not isinstance(info, dict) or info.get("CFBundleIdentifier") != identifier:
        raise VerificationError("Info.plist has the wrong bundle identifier: %s" % app)
    name = info.get("CFBundleExecutable")
    if not isinstance(name, str) or not name or name in (".", "..") or Path(name).name != name:
        raise VerificationError("Info.plist must name a bundle-local executable.")
    executable = (app / "Contents/MacOS" / name).resolve()
    if not executable.is_file() or not executable.is_relative_to(app):
        raise VerificationError("Executable is missing or resolves outside the application bundle.")
    return executable


def verify_explicit(app: Path, requirement: str, runner: Callable[[Sequence[str]], str]) -> None:
    # '=' is essential: without it codesign treats -R's argument as a file path.
    runner([CODESIGN, "--verify", "--deep", "--strict", "--all-architectures",
            "-R", "=" + requirement, str(app)])


def inspect_bundle(app: Path, identifier: str, fingerprint: Optional[str],
                   allow_adhoc: bool, runner: Callable[[Sequence[str]], str]) -> Dict:
    app = app.resolve()
    executable = bundle_executable(app, identifier)
    runner([CODESIGN, "--verify", "--deep", "--strict", "--all-architectures", str(app)])
    architectures = runner([LIPO, "-archs", str(executable)]).split()
    if (not architectures or len(architectures) > 16 or len(set(architectures)) != len(architectures)
            or any(not re.fullmatch(r"[A-Za-z0-9_]+", arch) for arch in architectures)):
        raise VerificationError("Could not enumerate the executable's Mach-O architectures.")
    requirements = {}
    certificates = {}
    with tempfile.TemporaryDirectory(prefix="keywoo-signing-verification-") as directory:
        for arch in architectures:
            display = runner([CODESIGN, "--display", "--verbose=4", "--architecture", arch, str(app)])
            identifiers = re.findall(r"^Identifier=(.*)$", display, re.MULTILINE)
            if identifiers != [identifier]:
                raise VerificationError("Signed identifier differs from expected identifier (%s)." % arch)
            adhoc = bool(re.search(r"^Signature=adhoc\s*$|flags=.*\badhoc\b", display, re.MULTILINE))
            if allow_adhoc != adhoc:
                raise VerificationError("%s: %s" % (arch, "Ad-hoc signatures cannot establish a stable identity."
                                        if adhoc else "--allow-adhoc is for ad-hoc debug bundles only."))
            requirement = extract_requirement(runner([
                CODESIGN, "-d", "-r-", "--architecture", arch, str(app)]))
            requirements[arch] = requirement
            if allow_adhoc:
                continue
            assert fingerprint is not None
            validate_requirement(requirement, identifier, fingerprint)
            prefix = Path(directory) / ("certificate-" + arch + "-")
            runner([CODESIGN, "--display", "--architecture", arch,
                    "--extract-certificates=" + str(prefix), str(app)])
            leaf = Path(str(prefix) + "0")
            if not leaf.is_file():
                raise VerificationError("Signed code has no embedded leaf certificate (%s)." % arch)
            actual = hashlib.sha1(leaf.read_bytes()).hexdigest().upper()
            if actual != fingerprint:
                raise VerificationError("Embedded leaf certificate does not match the expected SHA-1 (%s)." % arch)
            certificates[arch] = actual
    if not allow_adhoc:
        assert fingerprint is not None
        verify_explicit(app, pinned_requirement(identifier, fingerprint), runner)
    return {"path": str(app), "architectures": architectures,
            "designated_requirements": requirements, "certificate_sha1_by_arch": certificates}


def verify(app: Path, fingerprint: Optional[str], previous: Optional[Path] = None,
           identifier: str = DEFAULT_IDENTIFIER, allow_adhoc: bool = False,
           runner: Callable[[Sequence[str]], str] = run_tool) -> Dict:
    validate_identifier(identifier)
    if allow_adhoc:
        if fingerprint is not None or previous is not None:
            raise VerificationError("Ad-hoc debug verification cannot accept a fingerprint or previous bundle.")
    elif fingerprint is None:
        raise VerificationError("Stable verification requires an expected certificate SHA-1.")
    else:
        fingerprint = normalize_fingerprint(fingerprint)
    current = inspect_bundle(app, identifier, fingerprint, allow_adhoc, runner)
    report = {"passed": True, "stable_identity": not allow_adhoc,
              "mode": "adhoc-debug" if allow_adhoc else "stable",
              "identifier": identifier, "certificate_sha1": fingerprint, "current": current,
              "compatibility": {"checked": False},
              "scope": "Signature integrity, pinned identity and optional bidirectional DR compatibility; "
                       "not Gatekeeper, notarization or TCC authorization."}
    if previous is not None:
        prior = inspect_bundle(previous, identifier, fingerprint, False, runner)
        # Check both directions even when the displayed requirements are equal.
        # Equality is descriptive; actual codesign evaluation is authoritative.
        for requirement in sorted(set(prior["designated_requirements"].values())):
            verify_explicit(Path(current["path"]), requirement, runner)
        for requirement in sorted(set(current["designated_requirements"].values())):
            verify_explicit(Path(prior["path"]), requirement, runner)
        report["previous"] = prior
        report["compatibility"] = {
            "checked": True, "new_satisfies_previous": True, "previous_satisfies_new": True,
            "designated_requirement_texts_equal": set(current["designated_requirements"].values())
                                                  == set(prior["designated_requirements"].values()),
        }
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("app", type=Path)
    parser.add_argument("expected_sha1", nargs="?")
    parser.add_argument("--previous", type=Path, help="Previously installed stable bundle; rejects ad-hoc migration.")
    parser.add_argument("--identifier", default=DEFAULT_IDENTIFIER)
    parser.add_argument("--allow-adhoc", action="store_true", help="Explicit debug-only check, not stable identity.")
    args = parser.parse_args()
    try:
        report = verify(args.app, args.expected_sha1, args.previous, args.identifier, args.allow_adhoc)
    except (VerificationError, OSError) as exc:
        print("Signing verification failed: %s" % exc, file=sys.stderr)
        return 1
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
