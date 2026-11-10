"""Bounded offline publish state-machine tests. No GitHub calls or production keys."""
import importlib.util
import pathlib
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("publish_update", pathlib.Path(__file__).with_name("publish-update.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class DraftLookupTests(unittest.TestCase):
    def test_missing_tag_endpoint_reconciles_visible_draft(self):
        client = MODULE.GitHub(pathlib.Path('.'))
        draft = {"id": 7, "tag_name": "v0.3.7", "draft": True}
        answers = {"releases/tags/v0.3.7": None, "releases?per_page=100&page=1": [draft]}
        client.api = lambda endpoint, **_: answers[endpoint]
        self.assertEqual(client.read_release("0.3.7"), draft)

    def test_duplicate_draft_fails_closed(self):
        client = MODULE.GitHub(pathlib.Path('.'))
        draft = {"tag_name": "v0.3.7", "draft": True}
        client.api = lambda endpoint, **_: None if '/tags/' in endpoint else [draft, draft]
        with self.assertRaises(MODULE.ReleaseError):
            client.read_release("0.3.7")


class Repo:
    def __init__(self):
        self.tag = None
        self.pushed = False
        self.fail_push = False
        self.calls = []

    def preflight(self, receipt):
        self.calls.append("preflight")
        if self.tag is not None and self.tag != receipt["sourceCommit"]:
            raise MODULE.ReleaseError("different tag")

    def ensure_tag(self, receipt):
        if self.tag is None:
            self.calls.append("tag")
            self.tag = receipt["sourceCommit"]

    def activate_feed(self, receipt):
        self.calls.append("push-feed")
        if self.fail_push:
            raise MODULE.ReleaseError("push interrupted")
        self.pushed = True


class Hosting:
    def __init__(self):
        self.release = None
        self.asset = None
        self.fail_read = False
        self.fail_upload = False
        self.stale_feed = False
        self.calls = []

    def read_release(self, version):
        if self.fail_read:
            raise MODULE.ReleaseError("network unavailable")
        return self.release

    def ensure_draft(self, receipt):
        if self.release is None:
            self.calls.append("create")
            self.release = {"id": 1, "draft": True, "prerelease": False}
        return self.release

    def verify_or_upload_asset(self, release, receipt):
        if self.asset is None:
            if not release["draft"]:
                raise MODULE.ReleaseError("missing public asset")
            self.calls.append("upload")
            self.asset = receipt["dmgSHA256"]
            if self.fail_upload:
                raise MODULE.ReleaseError("upload response lost")
        if self.asset != receipt["dmgSHA256"]:
            raise MODULE.ReleaseError("different remote archive")

    def publish_release(self, release, receipt):
        if release["draft"]:
            self.calls.append("publish")
            release["draft"] = False

    def verify_live_feed(self, receipt):
        if self.stale_feed:
            raise MODULE.ReleaseError("feed not yet live")
        self.calls.append("verified-live")


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.repo = Repo()
        self.hosting = Hosting()
        self.receipt = {"version": "9.8.7", "sourceCommit": "a" * 40, "dmgSHA256": "b" * 64, "feedSHA256": "c" * 64}

    def run_publish(self):
        MODULE.publish(self.repo, self.hosting, self.receipt)

    def test_network_failure_does_not_create_tag_or_release(self):
        self.hosting.fail_read = True
        with self.assertRaises(MODULE.ReleaseError):
            self.run_publish()
        self.assertIsNone(self.repo.tag)
        self.assertEqual(self.hosting.calls, [])

    def test_existing_wrong_tag_rejected(self):
        self.repo.tag = "wrong"
        with self.assertRaises(MODULE.ReleaseError):
            self.run_publish()
        self.assertEqual(self.hosting.calls, [])

    def test_existing_wrong_archive_never_replaced_or_activated(self):
        self.hosting.release = {"id": 1, "draft": True, "prerelease": False}
        self.hosting.asset = "wrong"
        with self.assertRaises(MODULE.ReleaseError):
            self.run_publish()
        self.assertTrue(self.hosting.release["draft"])
        self.assertFalse(self.repo.pushed)
        self.assertNotIn("upload", self.hosting.calls)

    def test_repeated_publish_only_creates_once(self):
        self.run_publish()
        self.run_publish()
        for call in ["create", "upload", "publish"]:
            self.assertEqual(self.hosting.calls.count(call), 1)
        self.assertEqual(self.repo.calls.count("tag"), 1)

    def test_unknown_upload_outcome_is_reconciled_before_retry(self):
        self.hosting.fail_upload = True
        with self.assertRaises(MODULE.ReleaseError):
            self.run_publish()
        self.assertFalse(self.repo.pushed)
        self.hosting.fail_upload = False
        self.run_publish()
        self.assertEqual(self.hosting.calls.count("upload"), 1)

    def test_resume_after_release_published_but_feed_push_failed(self):
        self.repo.fail_push = True
        with self.assertRaises(MODULE.ReleaseError):
            self.run_publish()
        self.repo.fail_push = False
        self.run_publish()
        self.assertEqual(self.hosting.calls.count("create"), 1)
        self.assertEqual(self.hosting.calls.count("publish"), 1)
        self.assertTrue(self.repo.pushed)

    def test_stale_feed_does_not_report_success_and_can_resume(self):
        self.hosting.stale_feed = True
        with self.assertRaises(MODULE.ReleaseError):
            self.run_publish()
        self.hosting.stale_feed = False
        self.run_publish()
        self.assertEqual(self.hosting.calls.count("create"), 1)
        self.assertIn("verified-live", self.hosting.calls)

    def test_github_only_explicit_http_404_means_absent(self):
        self.assertIsNone(MODULE.decode_api_response(1, b'HTTP/2.0 404 Not Found\r\n\r\n{"message":"Not Found"}', allow_missing=True))
        for payload in [b"", b"network error", b'HTTP/2.0 500 Error\r\n\r\n{}', b'HTTP/2.0 403 Forbidden\r\n\r\n{}']:
            with self.assertRaises(MODULE.ReleaseError):
                MODULE.decode_api_response(1, payload, allow_missing=True)

    def test_api_success_requires_valid_status_and_json(self):
        self.assertEqual(MODULE.decode_api_response(0, b'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n{"id":1}'), {"id": 1})
        with self.assertRaises(MODULE.ReleaseError):
            MODULE.decode_api_response(0, b"not-json")


class OfflineGitRepo(MODULE.GitRepo):
    def text(self, *args):
        value = super().text(*args)
        if args == ("remote", "get-url", "origin"):
            # get-url expands insteadOf; expose the original URL to the allowlist,
            # while all actual Git transports remain the isolated local bare repo.
            assert value.startswith("file://")
            return "https://github.com/IvyYang1999/KeyKeeper.git"
        return value


class RealGitTests(unittest.TestCase):
    """Production Git adapter, actual commits/tags/pushes to an isolated local bare repo."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="keykeeper-release-git-")
        self.addCleanup(self.temp.cleanup)
        folder = pathlib.Path(self.temp.name)
        self.root = folder / "source"
        self.root.mkdir()
        self.remote = folder / "remote.git"
        self.git("init", "--bare", str(self.remote))
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "core.hooksPath", "/dev/null")
        self.git("config", "commit.gpgSign", "false")
        self.git("config", "tag.gpgSign", "false")
        # Git uses a local transport for the production origin URL; no network or credentials.
        self.git("config", f"url.{self.remote.as_uri()}.insteadOf", "https://github.com/IvyYang1999/KeyKeeper.git")
        self.git("remote", "add", "origin", "https://github.com/IvyYang1999/KeyKeeper.git")
        (self.root / "appcast.xml").write_text("old feed")
        (self.root / "VERSION").write_text("9.8.7")
        self.git("add", ".")
        self.git("commit", "-m", "synthetic source")
        self.git("push", "origin", "main")
        self.source = self.git("rev-parse", "HEAD").strip()
        (self.root / "appcast.xml").write_text("new feed")
        self.receipt = {"version": "9.8.7", "sourceCommit": self.source,
            "feedSHA256": MODULE.digest(b"new feed"), "dmgSHA256": "b" * 64}

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, stderr=subprocess.DEVNULL, text=True)

    def test_real_tag_feed_commit_push_and_idempotent_resume(self):
        hosting = Hosting()
        MODULE.publish(OfflineGitRepo(self.root), hosting, self.receipt)
        head = self.git("rev-parse", "HEAD").strip()
        self.assertNotEqual(head, self.source)
        self.assertEqual(self.git("rev-parse", "v9.8.7^{commit}").strip(), self.source)
        self.assertEqual(self.git("--git-dir", str(self.remote), "show", "main:appcast.xml"), "new feed")
        MODULE.publish(OfflineGitRepo(self.root), hosting, self.receipt)
        self.assertEqual(self.git("rev-parse", "HEAD").strip(), head)

    def test_different_source_after_prepare_stops_before_tag(self):
        (self.root / "VERSION").write_text("9.8.8")
        self.git("add", "VERSION")
        self.git("commit", "-m", "source changed")
        with self.assertRaises(MODULE.ReleaseError):
            MODULE.publish(OfflineGitRepo(self.root), Hosting(), self.receipt)
        self.assertEqual(self.git("tag", "--list"), "")

    def test_unrelated_dirty_file_is_not_committed_or_pushed(self):
        (self.root / "unrelated.txt").write_text("user edit")
        with self.assertRaises(MODULE.ReleaseError):
            MODULE.publish(OfflineGitRepo(self.root), Hosting(), self.receipt)
        self.assertEqual(self.git("--git-dir", str(self.remote), "show", "main:appcast.xml"), "old feed")

    def test_edit_during_upload_stops_before_feed_push(self):
        repo = OfflineGitRepo(self.root)
        repo.preflight(self.receipt)
        (self.root / "unrelated.txt").write_text("user edit during upload")
        self.git("add", "unrelated.txt")
        with self.assertRaises(MODULE.ReleaseError):
            repo.activate_feed(self.receipt)
        self.assertEqual(self.git("--git-dir", str(self.remote), "show", "main:appcast.xml"), "old feed")
        self.assertIn("A  unrelated.txt", self.git("status", "--porcelain"))


if __name__ == "__main__":
    unittest.main()
