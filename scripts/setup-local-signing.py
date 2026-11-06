#!/usr/bin/env python3
"""Explicitly create one app-local signing identity, without modifying trust."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import ssl
import stat
import sys
import tempfile
from signing_support import DEFAULT_DIRECTORY, helper, load_profile, run, unlock

def create(directory: Path, name: str):
    if not directory.is_absolute() or directory.resolve() != directory:
        raise RuntimeError("The signing directory must be an absolute non-symlink path.")
    if directory.exists():
        info = directory.stat()
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise RuntimeError("The existing signing directory must be owner-only mode 0700.")
    else:
        directory.mkdir(mode=0o700, parents=True)
    profile = directory / "profile.json"
    if profile.exists():
        data = load_profile(profile)
        unlock(data)
        print(json.dumps({"created": False, "profile": str(profile), "identity_sha1": data["identity_sha1"]}))
        return
    keychain = directory / "KeyWoo-local-signing.keychain-db"
    password = directory / "keychain-password.secret"
    certificate = directory / "certificate.pem"
    if any(p.exists() for p in [keychain, password, certificate]):
        raise RuntimeError("Partial signing setup already exists. Refusing to replace or regenerate an identity.")
    openssl = shutil.which("openssl")
    if not openssl:
        raise RuntimeError("OpenSSL is required to create the local certificate.")
    fd = os.open(password, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(secrets.token_urlsafe(48) + "\n")
    imported = False
    committed = False
    temporary_profile = None
    try:
        with tempfile.TemporaryDirectory(prefix=".provision-", dir=directory) as temporary:
            temp = Path(temporary)
            os.chmod(temp, 0o700)
            key, cert, p12 = temp / "encrypted-key.pem", temp / "certificate.pem", temp / "identity.p12"
            p12_password = temp / "p12-password.secret"
            p12_password.write_text(secrets.token_urlsafe(48) + "\n")
            os.chmod(p12_password, 0o600)
            config = temp / "certificate.cnf"
            config.write_text("[req]\nprompt=no\ndistinguished_name=subject\nx509_extensions=signing\n"
                              f"[subject]\nCN={name}\nO=KeyWoo Local Development\n"
                              "[signing]\nbasicConstraints=critical,CA:FALSE\n"
                              "keyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n"
                              "subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n")
            run([openssl, "req", "-new", "-x509", "-newkey", "rsa:3072", "-sha256", "-days", "3650",
                 "-passout", f"file:{password}", "-keyout", key, "-out", cert, "-config", config])
            run([openssl, "pkcs12", "-export", "-inkey", key, "-in", cert, "-name", name,
                 "-passin", f"file:{password}", "-passout", f"file:{p12_password}",
                 "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1", "-iter", "100000", "-out", p12])
            for path in [key, cert, p12]:
                os.chmod(path, 0o600)
            result = json.loads(run([helper(), "create", keychain, password, p12, p12_password]))
            hashes = result.get("identity", result)
            imported = True
            der = ssl.PEM_cert_to_DER_cert(cert.read_text())
            identity_sha1 = hashlib.sha1(der).hexdigest()
            if hashes.get("certificateSHA1", "").lower() != identity_sha1:
                raise RuntimeError("Imported certificate fingerprint does not match the generated public certificate.")
            certificate.write_bytes(cert.read_bytes())
            os.chmod(certificate, 0o600)
        data = {"schema": 1, "bundle_identifier": "app.keydance.mac", "kind": "local-self-signed",
                "name": name, "identity_sha1": identity_sha1, "identity_sha256": hashlib.sha256(der).hexdigest(),
                "keychain_path": str(keychain), "password_file": str(password), "certificate_path": str(certificate),
                "trust_settings_modified": False, "private_key_exportable": False,
                "private_key_allowed_application": "/usr/bin/codesign"}
        fd, temporary_name = tempfile.mkstemp(prefix=".profile-", dir=directory)
        temporary_profile = Path(temporary_name)
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2); f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        # The exclusive password file reserves this setup. Publish the complete
        # profile atomically, without replacing a pre-existing profile.
        os.link(temporary_profile, profile)
        committed = True
        temporary_profile.unlink()
        temporary_profile = None
        print(json.dumps({"created": True, "profile": str(profile), "identity_sha1": identity_sha1,
                          "trust_settings_modified": False,
                          "actual_key_attributes": result["actualKeyAttributes"],
                          "default_keychain_unchanged": result["defaultUnchanged"],
                          "search_list_unchanged": result["searchListUnchanged"],
                          "dedicated_keychain_in_search_list": result["dedicatedKeychainInSearchList"],
                          "lock_settings": result.get("settings")}))
    except Exception:
        # Roll back only the new identity this invocation created, never an
        # existing keychain or a pre-existing profile.
        if not committed:
            if imported or keychain.exists():
                run([helper(), "delete", keychain, password])
            for path in [password, certificate]:
                path.unlink(missing_ok=True)
        raise
    finally:
        if temporary_profile is not None:
            temporary_profile.unlink(missing_ok=True)

if __name__ == "__main__":
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=DEFAULT_DIRECTORY)
    parser.add_argument("--name", default="KeyWoo Local Code Signing")
    args = parser.parse_args()
    if not args.name or any(c in args.name for c in "\r\n=[]"):
        parser.error("Invalid local certificate name.")
    try:
        create(args.directory, args.name)
    except Exception as error:
        print(f"Local signing setup failed: {error}", file=sys.stderr); sys.exit(1)
