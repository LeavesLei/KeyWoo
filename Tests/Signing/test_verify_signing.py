"""No identities, keys, signatures or Keychain mutations: mocked command outputs."""
import hashlib
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/verify-signing.py"
spec = importlib.util.spec_from_file_location("verify_signing", SCRIPT)
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
IDENTIFIER = "app.keydance.mac"
CERTIFICATE = b"public DER fixture; not a real identity or private key"
FINGERPRINT = hashlib.sha1(CERTIFICATE).hexdigest().upper()
REQUIREMENT = signing.pinned_requirement(IDENTIFIER, FINGERPRINT)


class FakeTools:
    def __init__(self):
        self.bundles = {}
        self.calls = []
        self.requirement_calls = 0
        self.fail_requirement_call = None
        self.fail_integrity = False

    def add(self, app, *, requirement=REQUIREMENT, certificate=CERTIFICATE,
            signed_identifier=IDENTIFIER, adhoc=False, architectures=("arm64",)):
        self.bundles[str(app.resolve())] = dict(requirement=requirement, certificate=certificate,
            signed_identifier=signed_identifier, adhoc=adhoc, architectures=architectures)

    def __call__(self, command):
        self.calls.append(command)
        if command[0] == signing.LIPO:
            app = str(Path(command[-1]).parents[2])
            return " ".join(self.bundles[app]["architectures"])
        data = self.bundles[command[-1]]
        if "--verify" in command:
            if self.fail_integrity:
                raise signing.VerificationError("mock damaged resource seal")
            if "-R" in command:
                self.requirement_calls += 1
                if self.requirement_calls == self.fail_requirement_call:
                    raise signing.VerificationError("mock explicit requirement failure")
            return ""
        if any(x.startswith("--extract-certificates=") for x in command):
            prefix = next(x.split("=", 1)[1] for x in command if x.startswith("--extract-certificates="))
            Path(prefix + "0").write_bytes(data["certificate"])
            return ""
        if "-r-" in command:
            return "Executable=/fixture\n# designated => " + data["requirement"]
        signature = "Signature=adhoc" if data["adhoc"] else "Signature size=1234"
        return "Identifier=%s\n%s\n" % (data["signed_identifier"], signature)


class SigningVerifierTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="keywoo-verifier-tests-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.current = self.bundle("New.app")
        self.previous = self.bundle("Previous.app")
        self.tools = FakeTools()
        self.tools.add(self.current)
        self.tools.add(self.previous)

    def bundle(self, name, identifier=IDENTIFIER):
        app = self.root / name
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/MacOS/KeyDance").write_bytes(b"non-executable fixture")
        with (app / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": identifier, "CFBundleExecutable": "KeyDance"}, handle)
        return app

    def test_accepts_only_semantically_pinned_conjunctions(self):
        variants = [REQUIREMENT, '(certificate 0 = H"%s") and ((identifier %s))' %
                    (FINGERPRINT.lower(), IDENTIFIER)]
        for value in variants:
            with self.subTest(value=value):
                signing.validate_requirement(value, IDENTIFIER, FINGERPRINT)

    def test_rejects_identifier_only_or_bypass_and_build_specific_cdhash(self):
        bad = ['identifier "%s"' % IDENTIFIER,
               REQUIREMENT + ' or true',
               REQUIREMENT.replace(' and ', ' or '),
               'identifier "%s" and anchor trusted' % IDENTIFIER,
               'cdhash H"%s"' % FINGERPRINT,
               REQUIREMENT.replace(IDENTIFIER, 'app.attacker.mac'),
               REQUIREMENT.replace(FINGERPRINT, '0' * 40),
               REQUIREMENT + ')', '(' + REQUIREMENT,
               REQUIREMENT.replace('leaf', '1'),
               REQUIREMENT + ' and identifier "app.other.mac"']
        for value in bad:
            with self.subTest(value=value), self.assertRaises(signing.VerificationError):
                signing.validate_requirement(value, IDENTIFIER, FINGERPRINT)

    def test_bidirectional_evaluation_uses_literal_requirements_and_all_architectures(self):
        self.tools.add(self.current, architectures=("arm64", "x86_64"))
        report = signing.verify(self.current, FINGERPRINT, self.previous, runner=self.tools)
        self.assertTrue(report["compatibility"]["new_satisfies_previous"])
        self.assertTrue(report["compatibility"]["previous_satisfies_new"])
        self.assertEqual(report["current"]["architectures"], ["arm64", "x86_64"])
        explicit = [call for call in self.tools.calls if "-R" in call]
        self.assertEqual(len(explicit), 4)
        for call in explicit:
            self.assertIn("--all-architectures", call)
            self.assertTrue(call[call.index("-R") + 1].startswith("=identifier"))
        self.assertEqual(explicit[-2][-1], str(self.current.resolve()))
        self.assertEqual(explicit[-1][-1], str(self.previous.resolve()))
        self.assertFalse(any("--sign" in call for call in self.tools.calls))

    def test_reverse_compatibility_failure_is_not_ignored(self):
        self.tools.fail_requirement_call = 4
        with self.assertRaisesRegex(signing.VerificationError, "explicit requirement failure"):
            signing.verify(self.current, FINGERPRINT, self.previous, runner=self.tools)
        self.assertEqual(self.tools.requirement_calls, 4)

    def test_equivalent_reordered_dr_is_evaluated_not_rejected_by_text_comparison(self):
        self.tools.add(self.previous, requirement='certificate leaf = H"%s" and identifier %s' %
                       (FINGERPRINT, IDENTIFIER))
        report = signing.verify(self.current, FINGERPRINT, self.previous, runner=self.tools)
        self.assertTrue(report["compatibility"]["new_satisfies_previous"])
        self.assertTrue(report["compatibility"]["previous_satisfies_new"])
        self.assertFalse(report["compatibility"]["designated_requirement_texts_equal"])
        self.assertEqual(self.tools.requirement_calls, 4)

    def test_leaf_certificate_is_checked_independently_of_the_dr_text(self):
        self.tools.add(self.current, certificate=b"different public certificate")
        with self.assertRaisesRegex(signing.VerificationError, "Embedded leaf certificate"):
            signing.verify(self.current, FINGERPRINT, runner=self.tools)

    def test_wrong_signed_identifier_is_rejected_even_when_plist_and_dr_look_correct(self):
        self.tools.add(self.current, signed_identifier="app.other.mac")
        with self.assertRaisesRegex(signing.VerificationError, "Signed identifier"):
            signing.verify(self.current, FINGERPRINT, runner=self.tools)

    def test_wrong_plist_identifier_is_rejected_before_running_tools(self):
        app = self.bundle("Wrong.app", identifier="app.other.mac")
        with self.assertRaisesRegex(signing.VerificationError, "Info.plist"):
            signing.verify(app, FINGERPRINT, runner=self.tools)
        self.assertEqual(self.tools.calls, [])

    def test_adhoc_is_refused_in_stable_mode_and_cannot_be_a_previous_baseline(self):
        self.tools.add(self.current, adhoc=True)
        with self.assertRaisesRegex(signing.VerificationError, "Ad-hoc"):
            signing.verify(self.current, FINGERPRINT, runner=self.tools)
        self.tools.add(self.current)
        self.tools.add(self.previous, adhoc=True)
        with self.assertRaisesRegex(signing.VerificationError, "Ad-hoc"):
            signing.verify(self.current, FINGERPRINT, self.previous, runner=self.tools)

    def test_debug_is_explicit_and_never_reports_stable_compatibility(self):
        self.tools.add(self.current, adhoc=True, requirement='cdhash H"%s"' % FINGERPRINT)
        report = signing.verify(self.current, None, allow_adhoc=True, runner=self.tools)
        self.assertFalse(report["stable_identity"])
        self.assertFalse(report["compatibility"]["checked"])
        self.assertEqual(report["current"]["certificate_sha1_by_arch"], {})
        for fingerprint, previous in [(FINGERPRINT, None), (None, self.previous)]:
            with self.assertRaises(signing.VerificationError):
                signing.verify(self.current, fingerprint, previous, allow_adhoc=True, runner=self.tools)

    def test_damaged_signature_is_a_hard_failure(self):
        self.tools.fail_integrity = True
        with self.assertRaisesRegex(signing.VerificationError, "damaged resource seal"):
            signing.verify(self.current, FINGERPRINT, runner=self.tools)

    def test_missing_or_malformed_fingerprint_never_selects_debug_implicitly(self):
        for value in [None, "", "-", "00", FINGERPRINT + "a"]:
            with self.subTest(value=value), self.assertRaises(signing.VerificationError):
                signing.verify(self.current, value, runner=self.tools)

    def test_displayed_requirement_must_be_unambiguous(self):
        for output in ["no designated requirement", "designated => true\n# designated => false"]:
            with self.assertRaises(signing.VerificationError):
                signing.extract_requirement(output)


if __name__ == "__main__":
    unittest.main()
