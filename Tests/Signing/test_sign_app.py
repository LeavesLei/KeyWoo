"""Signing orchestration tests. No real keys, keychains, or codesign execution."""
import contextlib
import importlib.util
import io
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
spec = importlib.util.spec_from_file_location("keywoo_sign_app_test_module", SCRIPTS / "sign-app.py")
sign_app = importlib.util.module_from_spec(spec)
with mock.patch.object(sys, "path", [str(SCRIPTS)] + sys.path):
    spec.loader.exec_module(sign_app)


class SignAppOrchestrationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="keywoo-sign-app-tests-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.current = self.bundle("New.app")
        self.previous = self.bundle("Previous.app")
        self.fingerprint = "A" * 40
        self.profile = {"identity_sha1": self.fingerprint,
                        "keychain_path": str(self.root / "never-open-this.keychain-db")}
        self.calls = []
        self.old_verification_fails = False

    def bundle(self, name):
        app = self.root / name
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/MacOS/KeyDance").write_bytes(b"non-executable fixture")
        with (app / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": "app.keydance.mac", "CFBundleExecutable": "KeyDance"}, handle)
        return app

    def fake_run(self, arguments):
        command = [str(value) for value in arguments]
        self.calls.append(command)
        if self.old_verification_fails and len(self.calls) == 1:
            raise RuntimeError("previous signature rejected")
        return ""

    def invoke(self, previous, *extra):
        arguments = [str(SCRIPTS / "sign-app.py"), str(self.current), "--previous", str(previous), *extra]
        with mock.patch.object(sign_app, "load_profile", return_value=self.profile), \
                mock.patch.object(sign_app, "unlock", return_value={}), \
                mock.patch.object(sign_app, "signing_search_path", return_value=contextlib.nullcontext()), \
                mock.patch.object(sign_app, "run", side_effect=self.fake_run), \
                mock.patch.object(sys, "argv", arguments), \
                contextlib.redirect_stdout(io.StringIO()):
            sign_app.main()

    def test_missing_explicit_previous_is_rejected_before_any_signing(self):
        for flags in [(), ("--allow-identity-migration",)]:
            with self.subTest(flags=flags), self.assertRaisesRegex(RuntimeError, "previous bundle does not exist"):
                self.invoke(self.root / "Missing.app", *flags)
        self.assertEqual(self.calls, [])

    def test_same_bundle_cannot_be_both_new_and_previous(self):
        for flags in [(), ("--allow-identity-migration",)]:
            with self.subTest(flags=flags), self.assertRaisesRegex(RuntimeError, "must be different copies"):
                self.invoke(self.current, *flags)
        self.assertEqual(self.calls, [])

    def test_symlink_alias_cannot_disguise_previous_bundle_as_new(self):
        alias = self.root / "Alias.app"
        alias.symlink_to(self.current, target_is_directory=True)
        for flags in [(), ("--allow-identity-migration",)]:
            with self.subTest(flags=flags), self.assertRaisesRegex(RuntimeError, "must be different copies"):
                self.invoke(alias, *flags)
        self.assertEqual(self.calls, [])

    def test_existing_directory_without_bundle_info_does_not_skip_validation(self):
        invalid = self.root / "NotAnApp.app"
        invalid.mkdir()
        with self.assertRaisesRegex(RuntimeError, "not an application"):
            self.invoke(invalid)
        self.assertEqual(self.calls, [])

    def test_previous_is_verified_before_signing_then_both_bundles_are_compared(self):
        self.invoke(self.previous)
        self.assertEqual(len(self.calls), 3)
        first, signing, comparison = self.calls
        self.assertEqual(first, [sys.executable, str(SCRIPTS / "verify-signing.py"),
                                 str(self.previous), self.fingerprint])
        self.assertEqual(signing[0], "/usr/bin/codesign")
        self.assertIn("--force", signing)
        self.assertEqual(signing[-1], str(self.current))
        self.assertEqual(comparison, [sys.executable, str(SCRIPTS / "verify-signing.py"),
                                      str(self.current), self.fingerprint, "--previous", str(self.previous)])

    def test_previous_verification_failure_preserves_new_bundle_without_signing(self):
        self.old_verification_fails = True
        with self.assertRaisesRegex(RuntimeError, "previous signature rejected"):
            self.invoke(self.previous)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0][1], str(SCRIPTS / "verify-signing.py"))
        self.assertFalse(any(command[0] == "/usr/bin/codesign" for command in self.calls))


if __name__ == "__main__":
    unittest.main()
