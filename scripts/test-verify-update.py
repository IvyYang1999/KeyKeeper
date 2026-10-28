"""Offline signature regressions; the only private key is a PUBLIC RFC 8032 vector."""
import base64
import pathlib
import plistlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
PUBLIC = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
URL = "https://github.com/IvyYang1999/KeyKeeper/releases/download/v9.8.7/KeyKeeper-9.8.7.dmg"


class SignatureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="keykeeper-public-signature-fixture-")
        cls.root = pathlib.Path(cls.temp.name)
        cls.tool = cls.root / "verify-update"
        subprocess.run(["swiftc", str(ROOT / "scripts/verify-update.swift"), "-o", str(cls.tool)], check=True)
        # Public test vector, NOT a production credential.
        cls.key = cls.root / "rfc8032.der"
        cls.key.write_bytes(bytes.fromhex("302e020100300506032b657004220420" +
            "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"))

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def sign(self, data):
        payload = self.root / "payload"
        payload.write_bytes(data)
        return base64.b64encode(subprocess.check_output([
            "openssl", "pkeyutl", "-sign", "-rawin", "-keyform", "DER",
            "-inkey", str(self.key), "-in", str(payload)])).decode()

    def setUp(self):
        self.plist = self.root / "Info.plist"
        self.plist.write_bytes(plistlib.dumps({"SUPublicEDKey": PUBLIC}))
        self.dmg = self.root / "KeyKeeper-9.8.7.dmg"
        self.dmg.write_bytes(b"synthetic archive A")
        self.feed = self.root / "appcast.xml"
        self.write_feed()

    def write_feed(self, url=URL, version="9.8.7"):
        data = self.dmg.read_bytes()
        content = (f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
            f'<channel><item><sparkle:version>{version}</sparkle:version>'
            f'<enclosure url="{url}" length="{len(data)}" sparkle:edSignature="{self.sign(data)}"/>'
            '</item></channel></rss>\n').encode()
        self.feed.write_bytes(content + (f'<!-- sparkle-signatures:\nedSignature: {self.sign(content)}\n'
            f'length: {len(content)}\n-->\n').encode())

    def verify(self):
        return subprocess.run([str(self.tool), str(self.plist), str(self.feed), str(self.dmg), "9.8.7"],
            capture_output=True, text=True)

    def test_signed_candidate_passes(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"dmgSHA256"', result.stdout)

    def test_same_size_different_archive_rejected(self):
        self.dmg.write_bytes(b"synthetic archive B")
        self.assertNotEqual(self.verify().returncode, 0)

    def test_feed_tampering_rejected(self):
        self.feed.write_bytes(self.feed.read_bytes().replace(b"<channel>", b"<channel> "))
        self.assertNotEqual(self.verify().returncode, 0)

    def test_wrong_key_rejected(self):
        self.plist.write_bytes(plistlib.dumps({"SUPublicEDKey": base64.b64encode(bytes(32)).decode()}))
        self.assertNotEqual(self.verify().returncode, 0)

    def test_signed_wrong_version_rejected(self):
        self.write_feed(version="9.8.6")
        self.assertNotEqual(self.verify().returncode, 0)

    def test_signed_wrong_origin_rejected(self):
        self.write_feed(url="https://example.com/KeyKeeper-9.8.7.dmg")
        self.assertNotEqual(self.verify().returncode, 0)


if __name__ == "__main__":
    unittest.main()
