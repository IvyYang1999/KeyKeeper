"""Only public RFC 8032 test vectors; never reads the user's KeyKeeper store."""
import base64
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("sparkle_key", Path(__file__).with_name("sparkle-key.py"))
subject = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(subject)
SEED = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
PUBLIC = base64.b64decode("11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=")
TEXT = base64.b64encode(SEED).decode()


class SigningTests(unittest.TestCase):
    def test_rfc_vector_matches(self):
        self.assertEqual(subject.validate_key(TEXT, PUBLIC), TEXT.encode())

    def test_same_length_wrong_key_is_refused(self):
        with self.assertRaises(subject.KeyMismatch):
            subject.validate_key(base64.b64encode(bytes(32)).decode(), PUBLIC)

    def test_prompt_invalid_suffix_whitespace_and_wrong_lengths_are_refused(self):
        for value in ("some accidentally copied prompt", TEXT + "!", TEXT + "\n",
                      base64.b64encode(bytes(31)).decode(), base64.b64encode(bytes(64)).decode()):
            with self.subTest(value_length=len(value)), self.assertRaises(subject.KeyMismatch):
                subject.validate_key(value, PUBLIC)

    def test_legacy_public_tail_cannot_impersonate_the_real_private_key(self):
        forged = base64.b64encode(bytes(64) + PUBLIC).decode()
        with self.assertRaises(subject.KeyMismatch):
            subject.validate_key(forged, PUBLIC)

    def test_derivation_unavailable_is_not_a_key_mismatch(self):
        with patch.object(subject.subprocess, "run", side_effect=FileNotFoundError()):
            with self.assertRaises(subject.VerifierUnavailable):
                subject.validate_key(TEXT, PUBLIC)

    def test_generator_receives_key_only_on_stdin_and_never_in_environment(self):
        with patch.object(subject.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
            subject.sign_feed(TEXT.encode(), "/trusted/generate_appcast", ["-o", "feed.xml", "archives"],
                              {"PATH": "/usr/bin", "PRIVATE_KEY": TEXT, "UNRELATED_TOKEN": "synthetic"})
        kwargs = run.call_args.kwargs
        self.assertEqual(kwargs["input"], TEXT.encode() + b"\n")
        self.assertNotIn("PRIVATE_KEY", kwargs["env"])
        self.assertNotIn("UNRELATED_TOKEN", kwargs["env"])
        self.assertNotIn(TEXT, str(run.call_args.args))
        self.assertEqual(run.call_args.args[0][:3], ["/trusted/generate_appcast", "--ed-key-file", "-"])

    def test_signing_cannot_override_the_validated_input(self):
        for args in (["--ed-key-file", "elsewhere"], ["--account", "other"], ["-s", "x"],
                     ["--ed-key-file=elsewhere"], ["--account=other"]):
            with self.subTest(args=args), self.assertRaises(subject.KeyMismatch):
                subject.sign_feed(TEXT.encode(), "generator", args, {})

    def test_prepare_uses_keykeeper_and_built_app_identity(self):
        source = Path(__file__).with_name("prepare-update.sh").read_text()
        self.assertIn('keykeeper run -c "$SIGNING_CREDENTIAL_ID"', source)
        self.assertIn('dist/dmg/KeyKeeper.app/Contents/Info.plist', source)
        self.assertNotIn('--account com.keykeeper.app', source)


if __name__ == "__main__":
    unittest.main()
