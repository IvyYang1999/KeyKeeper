#!/usr/bin/env python3
"""Opt-in dev.keykeeper.app candidate / signed migration probes. Builds only; never installs or runs."""
import argparse
import datetime
import hashlib
import importlib.util
import json
import plistlib
from pathlib import Path
import re
import shutil
import tempfile

REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("sync_probe_build", REPO / "scripts/build-sync-probes.py")
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
run = base.run
TEAM, APP_ID, CONTAINER = base.TEAM, base.APP_ID, base.CONTAINER


def validate_profile(profile_bytes, identity):
    profile = plistlib.loads(run(["security", "cms", "-D"], True, profile_bytes).stdout)
    ent = profile["Entitlements"]
    groups = ent.get("keychain-access-groups", [])
    if (not re.fullmatch(r"[0-9A-F]{40}", identity)
            or profile["TeamIdentifier"] != [TEAM]
            or ent.get("com.apple.application-identifier") != f"{TEAM}.{APP_ID}"
            or ent.get("com.apple.developer.icloud-container-environment") != "Production"
            or CONTAINER not in ent.get("com.apple.developer.icloud-container-identifiers", [])
            or not ({f"{TEAM}.*", f"{TEAM}.{APP_ID}"} & set(groups))
            or identity not in [hashlib.sha1(c).hexdigest().upper() for c in profile["DeveloperCertificates"]]
            or profile["ExpirationDate"] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
            or ent.get("com.apple.developer.icloud-services") not in ("*", ["CloudKit"])):
        raise ValueError("Profile does not authorize this candidate")
    return {
        "com.apple.application-identifier": f"{TEAM}.{APP_ID}",
        "com.apple.developer.team-identifier": TEAM,
        "keychain-access-groups": [f"{TEAM}.{APP_ID}"],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.developer.icloud-container-identifiers": [CONTAINER],
        "com.apple.developer.icloud-container-environment": "Production",
    }


def assemble_app(app, build, profile_bytes, entitlements, identity, probe=False, old=False):
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    resources = contents / "Resources"
    resources.mkdir()
    executable = "KeyKeeperMigrationProbe" if probe else "KeyKeeperApp"
    shutil.copy2(build / executable, contents / "MacOS" / executable)
    info = plistlib.loads((REPO / "Resources/Info.plist").read_bytes())
    version = (REPO / "VERSION").read_text().strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Invalid version")
    info.update(CFBundleIdentifier="com.keykeeper.app" if old else APP_ID, CFBundleExecutable=executable,
                CFBundleVersion=version, CFBundleShortVersionString=version)
    if probe:
        info.update(CFBundleName=app.stem, LSUIElement=True)
        for key in list(info):
            if key.startswith("SU"):
                del info[key]
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    (contents / "PkgInfo").write_bytes(b"APPL????")
    if not old:
        (contents / "embedded.provisionprofile").write_bytes(profile_bytes)
        helpers = contents / "Helpers"
        helpers.mkdir()
        helper = helpers / "KeyKeeperMigrationBridge"
        shutil.copy2(build / "KeyKeeperMigrationBridge", helper)
        sign(helper, identity, ["--identifier", "com.keykeeper.app"])
    if not probe:
        shutil.copy2(build / "keykeeper", contents / "MacOS/keykeeper")
        shutil.copy2(REPO / "Assets/KeyKeeper.icns", resources / "KeyKeeper.icns")
        shutil.copy2(REPO / "Assets/Compiled/Assets.car", resources / "Assets.car")
        shutil.copytree(REPO / "browser-extension", resources / "browser-extension")
        shutil.copy2(REPO / "Resources/browser-native-host", resources / "browser-native-host")
        shutil.copy2(REPO / "skill/keykeeper.md", resources / "keykeeper.md")
        run(["python3", str(REPO / "scripts/package-agent-plugins.py"), str(resources / "AgentPlugins")])
        (contents / "Frameworks").mkdir()
        framework = contents / "Frameworks/Sparkle.framework"
        source = REPO / ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
        run(["ditto", str(source), str(framework)])
        for name, extra in [
            ("Versions/B/XPCServices/Installer.xpc", []),
            ("Versions/B/XPCServices/Downloader.xpc", ["--preserve-metadata=entitlements"]),
            ("Versions/B/Autoupdate", []), ("Versions/B/Updater.app", [])]:
            sign(framework / name, identity, extra)
        sign(framework, identity)
        # The CLI receives no application/keychain group entitlements.
        sign(contents / "MacOS/keykeeper", identity)
    sign(app, identity, [] if old else ["--entitlements", str(entitlements)])
    run(["codesign", "--verify", "--deep", "--strict", str(app)])
    if not old:
        actual = plistlib.loads(run(["codesign", "-d", "--entitlements", ":-", str(app)], True).stdout)
        if actual.get("keychain-access-groups") != [f"{TEAM}.{APP_ID}"]:
            raise ValueError("App access-group differs from candidate")
        run(["codesign", "--verify", "--strict", "-R",
             f'=anchor apple generic and identifier "com.keykeeper.app" and certificate leaf[subject.OU] = "{TEAM}"',
             str(contents / "Helpers/KeyKeeperMigrationBridge")])
    return {"name": app.name, "identifier": info["CFBundleIdentifier"],
            "executableSHA256": hashlib.sha256((contents / "MacOS" / executable).read_bytes()).hexdigest()}


def sign(target, identity, extra=None):
    run(["codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp", *(extra or []), str(target)])


def create_release_image(stage, archive, identity):
    # Only the app and the standard installation link may enter a public archive.
    if {p.name for p in stage.iterdir()} - {"KeyKeeper.app", "Applications"}:
        raise ValueError("Unexpected files in release image staging directory")
    link = stage / "Applications"
    if not link.is_symlink() and link.exists():
        raise ValueError("Applications must be an installation symlink")
    if link.is_symlink():
        if link.readlink() != Path("/Applications"):
            raise ValueError("Unexpected installation symlink")
    else:
        link.symlink_to("/Applications")
    if archive.exists():
        raise ValueError("Archive already exists; reconcile it instead of overwriting")
    run(["hdiutil", "create", "-volname", "KeyKeeper", "-srcfolder", str(stage),
         "-format", "UDZO", str(archive)])
    run(["codesign", "--force", "--sign", identity, "--timestamp", str(archive)])
    run(["codesign", "--verify", "--verbose=2", str(archive)])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--identity", required=True, help="Existing Developer ID certificate SHA-1")
    parser.add_argument("--output-parent", type=Path, required=True)
    parser.add_argument("--release", action="store_true", help="Build production app and DMG in clean dist/dmg; never installs")
    parser.add_argument("--migration-probes", action="store_true", help="Build isolated signed seam harness apps instead of the product")
    args = parser.parse_args()
    if run(["git", "status", "--porcelain", "--untracked-files=all"], True).stdout.strip():
        raise ValueError("Freeze and commit the candidate before building; working tree must be clean")
    if args.release and args.migration_probes:
        raise ValueError("Release cannot contain migration probes")
    parent = base.local_directory(args.output_parent)
    if shutil.disk_usage(parent).free < 10 * 1024**3:
        raise ValueError("At least 10 GiB free space required")
    identity = args.identity.upper()
    profile_bytes = args.profile.read_bytes()
    entitlements = validate_profile(profile_bytes, identity)
    products = ["KeyKeeperMigrationBridge", "KeyKeeperMigrationProbe"] if args.migration_probes else ["KeyKeeperMigrationBridge", "KeyKeeperApp", "keykeeper"]
    for product in products:
        run(["swift", "build", "--disable-keychain", "-c", "release", "--product", product])
    build = Path(run(["swift", "build", "--disable-keychain", "-c", "release", "--show-bin-path"], True).stdout.decode().strip())
    if args.release:
        output = parent / "dmg"
        if output.exists():
            raise ValueError("Release staging already exists; archive or remove only the known build output first")
        output.mkdir()
    else:
        output = Path(tempfile.mkdtemp(prefix="keykeeper-identity-candidate-", suffix=".noindex", dir=parent))
    entitlements_path = output / "entitlements.plist"
    entitlements_path.write_bytes(plistlib.dumps(entitlements))
    names = [("OldMigrationProbe.app", True), ("NewMigrationProbe.app", False)] if args.migration_probes else [("KeyKeeper.app", False)]
    apps = [assemble_app(output / name, build, profile_bytes, entitlements_path, identity, args.migration_probes, old) for name, old in names]
    receipt = {"sourceHEAD": run(["git", "rev-parse", "HEAD"], True).stdout.decode().strip(),
               "sourceDiffSHA256": hashlib.sha256(run(["git", "diff", "HEAD", "--binary"], True).stdout).hexdigest(),
               "profileSHA256": hashlib.sha256(profile_bytes).hexdigest(), "certificateSHA1": identity,
               "installed": False, "launched": False, "apps": apps}
    if args.release:
        # Entitlements and build metadata stay outside the distributable image.
        entitlements_path.replace(parent / "release-entitlements.plist")
        version = (REPO / "VERSION").read_text().strip()
        archive = parent / f"KeyKeeper-{version}.dmg"
        create_release_image(output, archive, identity)
        receipt["archiveSHA256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
        receipt_path = parent / f"KeyKeeper-{version}.build.json"
    else:
        receipt_path = output / "build-receipt.json"
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"CANDIDATE_OUTPUT={output}")


if __name__ == "__main__":
    main()
