"""Resumable release delivery. Never infer absence from an unavailable service."""
import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys

REPOSITORY = "IvyYang1999/KeyKeeper"
FEED_URL = f"https://raw.githubusercontent.com/{REPOSITORY}/main/appcast.xml"


class ReleaseError(Exception):
    pass


def command(argv, cwd, timeout=60, check=True):
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GH_PROMPT_DISABLED="1")
    try:
        result = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ReleaseError(f"{argv[0]} unavailable or timed out; inspect remote state before retrying") from error
    if check and result.returncode:
        raise ReleaseError(f"{argv[0]} failed (exit {result.returncode}); nothing is assumed absent")
    return result


def digest(data):
    return hashlib.sha256(data).hexdigest()


def decode_api_response(code, output, allow_missing=False):
    # gh api --include writes an HTTP status line before its body, including on 404.
    normalized = output.replace(b"\r\n", b"\n")
    match = re.match(rb"HTTP/\S+ (\d{3})[^\n]*\n", normalized)
    if not match:
        raise ReleaseError("GitHub response has no verified HTTP status")
    status_code = int(match[1])
    if status_code == 404 and allow_missing:
        return None
    if code or status_code != 200:
        raise ReleaseError(f"GitHub read failed (HTTP {status_code})")
    try:
        return json.loads(normalized.split(b"\n\n", 1)[1])
    except (ValueError, IndexError) as error:
        raise ReleaseError("Invalid GitHub JSON response") from error


def publish(repo, hosting, receipt):
    repo.preflight(receipt)
    release = hosting.read_release(receipt["version"])  # Read BEFORE the first external write.
    if release and release.get("prerelease"):
        raise ReleaseError("Existing prerelease requires explicit reconciliation")
    repo.ensure_tag(receipt)
    release = release or hosting.ensure_draft(receipt)
    hosting.verify_or_upload_asset(release, receipt)
    hosting.publish_release(release, receipt)
    repo.activate_feed(receipt)
    hosting.verify_live_feed(receipt)  # A push is not proof the public feed is serving these bytes.


class GitRepo:
    def __init__(self, root):
        self.root = root
        self.remote_tag = None

    def git(self, *args, check=True):
        return command(["git", "-c", "core.askPass=", *args], self.root, check=check)

    def text(self, *args):
        return self.git(*args).stdout.decode().strip()

    def check_local_source(self, receipt):
        if self.text("branch", "--show-current") != "main":
            raise ReleaseError("Publish from main only")
        changes = self.git("status", "--porcelain").stdout.decode().rstrip("\n")
        if changes not in ("", " M appcast.xml", "M  appcast.xml", "?? appcast.xml"):
            raise ReleaseError("Only the verified appcast may be uncommitted")
        source = receipt["sourceCommit"]
        self.git("merge-base", "--is-ancestor", source, "HEAD")
        if set(self.text("diff", "--name-only", source, "HEAD").splitlines()) - {"appcast.xml"}:
            raise ReleaseError("Source changed after preparing the candidate")

    def preflight(self, receipt):
        self.check_local_source(receipt)
        source = receipt["sourceCommit"]
        origin = self.text("remote", "get-url", "origin")
        if origin not in (f"https://github.com/{REPOSITORY}", f"https://github.com/{REPOSITORY}.git", f"git@github.com:{REPOSITORY}.git"):
            raise ReleaseError("Unexpected origin; refusing to publish elsewhere")
        tag = "v" + receipt["version"]
        local = self.git("rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}", check=False)
        if local.returncode == 0 and local.stdout.decode().strip() != source:
            raise ReleaseError("Local tag points to a different source; never overwrite it")
        refs = self.text("ls-remote", "origin", "refs/heads/main", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}")
        refs = dict(line.split()[::-1] for line in refs.splitlines())
        remote_main = refs.get("refs/heads/main")
        if not remote_main:
            raise ReleaseError("Remote main missing")
        # Fetch only for ancestry proof, without changing the local branch or tag.
        self.git("fetch", "--no-tags", "origin", "main")
        self.git("merge-base", "--is-ancestor", remote_main, "HEAD")
        self.remote_tag = refs.get(f"refs/tags/{tag}^{{}}", refs.get(f"refs/tags/{tag}"))
        if self.remote_tag is not None and self.remote_tag != source:
            raise ReleaseError("Remote tag points to a different source; never overwrite it")

    def ensure_tag(self, receipt):
        self.check_local_source(receipt)
        if self.remote_tag is not None:
            return
        tag = "v" + receipt["version"]
        if self.git("show-ref", "--verify", f"refs/tags/{tag}", check=False).returncode:
            self.git("tag", "-a", tag, receipt["sourceCommit"], "-m", "KeyKeeper " + receipt["version"])
        if self.text("rev-parse", f"refs/tags/{tag}^{{commit}}") != receipt["sourceCommit"]:
            raise ReleaseError("Local tag changed before push")
        self.git("push", "origin", f"refs/tags/{tag}")  # No force, including on resume.

    def activate_feed(self, receipt):
        self.check_local_source(receipt)
        if digest((self.root / "appcast.xml").read_bytes()) != receipt["feedSHA256"]:
            raise ReleaseError("Feed changed during publication")
        current = self.git("show", "HEAD:appcast.xml", check=False)
        if current.returncode or digest(current.stdout) != receipt["feedSHA256"]:
            self.git("add", "--", "appcast.xml")
            # Release gates already ran; legacy post-commit installs/restarts the live App.
            # This commit must NOT invoke deployment or push hooks behind the release protocol.
            self.git("-c", "core.hooksPath=/dev/null", "commit", "--only", "-m", "发布：更新 appcast 至 " + receipt["version"], "--", "appcast.xml")
        if digest(self.git("show", "HEAD:appcast.xml").stdout) != receipt["feedSHA256"]:
            raise ReleaseError("Committed feed differs from the verified candidate")
        self.git("push", "origin", "main")


class GitHub:
    def __init__(self, root):
        self.root = root

    def api(self, endpoint, allow_missing=False):
        result = command(["gh", "api", "--include", f"repos/{REPOSITORY}/{endpoint}"], self.root, check=False)
        return decode_api_response(result.returncode, result.stdout, allow_missing)

    def read_release(self, version):
        return self.api(f"releases/tags/v{version}", allow_missing=True)

    def ensure_draft(self, receipt):
        version = receipt["version"]
        command(["gh", "release", "create", "v" + version, "--repo", REPOSITORY, "--verify-tag", "--draft",
                 "--title", "KeyKeeper " + version, "--notes-file", str(self.root / "release-notes" / (version + ".md"))], self.root)
        release = self.read_release(version)
        if not release:
            raise ReleaseError("Created release could not be read back; stop and reconcile")
        return release

    def verify_or_upload_asset(self, release, receipt):
        version = receipt["version"]
        filename = "KeyKeeper-" + version + ".dmg"
        assets = self.api(f'releases/{release["id"]}/assets?per_page=100')
        matches = [asset for asset in assets if asset["name"] == filename]
        if not matches:
            if not release["draft"]:
                raise ReleaseError("Public release has no expected archive; stop for reconciliation")
            archive = self.root / "dist" / filename
            if digest(archive.read_bytes()) != receipt["dmgSHA256"]:
                raise ReleaseError("Local archive changed before upload")
            command(["gh", "release", "upload", "v" + version, str(archive), "--repo", REPOSITORY], self.root, timeout=300)
            assets = self.api(f'releases/{release["id"]}/assets?per_page=100')
            matches = [asset for asset in assets if asset["name"] == filename]
        if len(matches) != 1 or matches[0].get("state") != "uploaded":
            raise ReleaseError("Remote asset missing, duplicated or still uploading")
        # Check actual remote bytes, not its name, size or an optional API digest.
        downloaded = command(["gh", "api", f'repos/{REPOSITORY}/releases/assets/{matches[0]["id"]}',
            "-H", "Accept: application/octet-stream"], self.root, timeout=180).stdout
        if digest(downloaded) != receipt["dmgSHA256"]:
            raise ReleaseError("Remote archive differs; it will not be overwritten or advertised")

    def publish_release(self, release, receipt):
        if release["draft"]:
            command(["gh", "release", "edit", "v" + receipt["version"], "--repo", REPOSITORY,
                "--draft=false", "--latest"], self.root)
        live = self.read_release(receipt["version"])
        if not live or live["draft"] or live["prerelease"]:
            raise ReleaseError("Release is not publicly available")

    def verify_live_feed(self, receipt):
        result = command(["curl", "--fail", "--silent", "--show-error", "--location", "--max-time", "30",
            "--proto", "=https", "--proto-redir", "=https", FEED_URL + "?release=" + receipt["version"]], self.root, timeout=40)
        if digest(result.stdout) != receipt["feedSHA256"]:
            raise ReleaseError("Public feed is not serving the verified candidate yet; safe to resume later")


def checked_candidate(root, version):
    result = command(["/usr/bin/swift", str(root / "scripts/verify-update.swift"), str(root / "Resources/Info.plist"),
        str(root / "appcast.xml"), str(root / "dist" / f"KeyKeeper-{version}.dmg"), version], root)
    record = json.loads(result.stdout)
    record["notesSHA256"] = digest((root / "release-notes" / (version + ".md")).read_bytes())
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--confirm-version")
    group.add_argument("--record-candidate", action="store_true")
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent.parent
    version = (root / "VERSION").read_text().strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or (not args.record_candidate and args.confirm_version != version):
        raise ReleaseError("Explicit version does not match VERSION")
    repo = GitRepo(root)
    common = pathlib.Path(repo.text("rev-parse", "--path-format=absolute", "--git-common-dir"))
    with (common / "keykeeper-release.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ReleaseError("Another release operation is running") from error
        verified = checked_candidate(root, version)
        record_file = root / "dist" / f"KeyKeeper-{version}.update.json"
        if args.record_candidate:
            changes = repo.git("status", "--porcelain").stdout.decode().rstrip("\n")
            if repo.text("rev-parse", "HEAD") != repo.text("rev-parse", "refs/heads/main") or changes not in (" M appcast.xml", "?? appcast.xml"):
                raise ReleaseError("Record only a clean main candidate plus its newly generated feed")
            verified["sourceCommit"] = repo.text("rev-parse", "HEAD")
            if record_file.exists():
                if json.loads(record_file.read_text()) != verified:
                    raise ReleaseError("An immutable candidate already exists for this version")
            else:
                with record_file.open("x") as output:
                    json.dump(verified, output, sort_keys=True, indent=2)
            print("Recorded verified candidate " + version)
            return
        receipt = json.loads(record_file.read_text())
        if {key: value for key, value in receipt.items() if key != "sourceCommit"} != verified:
            raise ReleaseError("Candidate changed after preparation; never upload a rebuild under the same tag")
        publish(repo, GitHub(root), receipt)
        print("Published KeyKeeper " + version + "; remote archive and live signed feed verified")


if __name__ == "__main__":
    try:
        main()
    except (ReleaseError, OSError, ValueError, KeyError) as error:
        print("RELEASE STOPPED: " + str(error), file=sys.stderr)
        sys.exit(1)
