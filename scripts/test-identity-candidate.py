#!/usr/bin/env python3
"""Pure synthetic packaging tests. No signing, profiles, Keychain or launched executables."""
import datetime
import hashlib
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("identity_build", Path(__file__).with_name("build-identity-candidate.py"))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class IdentityCandidateTests(unittest.TestCase):
    def profile(self):
        certificate = b"synthetic-public-certificate"
        return {
            "TeamIdentifier": [build.TEAM], "DeveloperCertificates": [certificate],
            "ExpirationDate": datetime.datetime(2099, 1, 1),
            "Entitlements": {
                "com.apple.application-identifier": f"{build.TEAM}.{build.APP_ID}",
                "com.apple.developer.icloud-container-environment": "Production",
                "com.apple.developer.icloud-container-identifiers": [build.CONTAINER],
                "keychain-access-groups": [f"{build.TEAM}.*"],
                "com.apple.developer.icloud-services": ["CloudKit"],
            },
        }, hashlib.sha1(certificate).hexdigest().upper()

    def test_profile_rejects_wrong_identity_group_environment_and_expiry(self):
        original = build.run
        try:
            profile, identity = self.profile()
            build.run = lambda *_: subprocess.CompletedProcess([], 0, plistlib.dumps(profile), b"")
            self.assertEqual(build.validate_profile(b"synthetic", identity)["keychain-access-groups"], [f"{build.TEAM}.{build.APP_ID}"])
            for field, bad in [("keychain-access-groups", ["OTHER.*"]),
                               ("com.apple.application-identifier", "OTHER.app"),
                               ("com.apple.developer.icloud-container-environment", "Development")]:
                before = profile["Entitlements"][field]
                profile["Entitlements"][field] = bad
                with self.assertRaises(ValueError): build.validate_profile(b"synthetic", identity)
                profile["Entitlements"][field] = before
            profile["ExpirationDate"] = datetime.datetime(2000, 1, 1)
            with self.assertRaises(ValueError): build.validate_profile(b"synthetic", identity)
        finally:
            build.run = original

    def test_probe_assembly_keeps_helper_old_and_new_parent_entitlements(self):
        original = build.run
        calls = []
        entitlements = {"keychain-access-groups": [f"{build.TEAM}.{build.APP_ID}"]}
        def fake(args, *_):
            calls.append(args)
            data = plistlib.dumps(entitlements) if "--entitlements" in args and "-d" in args else b""
            return subprocess.CompletedProcess(args, 0, data, b"")
        try:
            build.run = fake
            with tempfile.TemporaryDirectory(prefix="keykeeper-package-fixture-") as directory:
                root = Path(directory); binaries = root / "bin"; binaries.mkdir()
                for name in ["KeyKeeperMigrationProbe", "KeyKeeperMigrationBridge"]:
                    (binaries / name).write_bytes(b"synthetic executable")
                ent = root / "entitlements.plist"; ent.write_bytes(plistlib.dumps(entitlements))
                old = root / "Old.app"; new = root / "New.app"
                build.assemble_app(old, binaries, b"synthetic profile", ent, "A" * 40, probe=True, old=True)
                build.assemble_app(new, binaries, b"synthetic profile", ent, "A" * 40, probe=True)
                self.assertFalse((old / "Contents/embedded.provisionprofile").exists())
                self.assertTrue((new / "Contents/Helpers/KeyKeeperMigrationBridge").is_file())
                self.assertEqual(plistlib.loads((new / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"], build.APP_ID)
                helper_sign = [c for c in calls if "--identifier" in c]
                self.assertEqual(len(helper_sign), 1)
                self.assertEqual(helper_sign[0][helper_sign[0].index("--identifier") + 1], "com.keykeeper.app")
                self.assertFalse(any(c[-1] == str(old) and "--entitlements" in c for c in calls))
        finally:
            build.run = original


if __name__ == "__main__":
    unittest.main()
