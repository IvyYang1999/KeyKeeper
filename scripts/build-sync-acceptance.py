#!/usr/bin/env python3
"""Build an isolated signed Core/native acceptance tool; never install or launch it."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import tempfile

REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("identity_build", REPO / "scripts/build-identity-candidate.py")
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
run = base.run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--output-parent", type=Path, required=True)
    args = parser.parse_args()
    if run(["git", "status", "--porcelain", "--untracked-files=all"], True).stdout.strip():
        raise ValueError("Commit the accepted candidate before packaging")
    parent = base.base.local_directory(args.output_parent)
    if shutil.disk_usage(parent).free < 10 * 1024**3:
        raise ValueError("At least 10 GiB free space required")
    identity = args.identity.upper()
    profile_bytes = args.profile.read_bytes()
    entitlements = base.validate_profile(profile_bytes, identity)
    output = Path(tempfile.mkdtemp(prefix="keykeeper-sync-acceptance-", suffix=".noindex", dir=parent))
    # A separate cache prevents the test-only compiler flag from contaminating the product.
    scratch = output / "build"
    build_args = ["swift", "build", "--disable-keychain", "--scratch-path", str(scratch),
                  "-c", "release", "-Xswiftc", "-DKEYKEEPER_SYNC_ACCEPTANCE"]
    run([*build_args, "--product", "KeyKeeperSyncAcceptance"])
    binary_dir = Path(run([*build_args, "--show-bin-path"], True).stdout.decode().strip())
    app = output / "KeyKeeperSyncAcceptance.app"
    contents = app / "Contents"
    executable = contents / "MacOS/KeyKeeperSyncAcceptance"
    executable.parent.mkdir(parents=True)
    shutil.copy2(binary_dir / "KeyKeeperSyncAcceptance", executable)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": base.APP_ID,
        "CFBundleName": "KeyKeeper Synthetic Sync Acceptance",
        "CFBundleExecutable": executable.name,
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "CFBundleShortVersionString": "0.0.1",
        "LSUIElement": True, "LSMinimumSystemVersion": "14.0",
    }))
    (contents / "PkgInfo").write_bytes(b"APPL????")
    (contents / "embedded.provisionprofile").write_bytes(profile_bytes)
    entitlements_file = output / "entitlements.plist"
    entitlements_file.write_bytes(plistlib.dumps(entitlements))
    base.sign(app, identity, ["--entitlements", str(entitlements_file)])
    run(["codesign", "--verify", "--strict", "--deep", "-R",
         f'=anchor apple generic and identifier "{base.APP_ID}" and certificate leaf[subject.OU] = "{base.TEAM}"', str(app)])
    actual = plistlib.loads(run(["codesign", "-d", "--entitlements", ":-", str(app)], True).stdout)
    if actual != entitlements:
        raise ValueError("Signed entitlements differ from the reviewed scope")
    manifest = {str(p.relative_to(app)): {"sha256": hashlib.sha256(p.read_bytes()).hexdigest(),
                "bytes": p.stat().st_size} for p in sorted(app.rglob("*")) if p.is_file()}
    receipt = {
        "sourceHEAD": run(["git", "rev-parse", "HEAD"], True).stdout.decode().strip(),
        "sourceTree": run(["git", "rev-parse", "HEAD^{tree}"], True).stdout.decode().strip(),
        "profileSHA256": hashlib.sha256(profile_bytes).hexdigest(),
        "certificateSHA1": identity, "compilerFlag": "KEYKEEPER_SYNC_ACCEPTANCE",
        "installed": False, "launched": False, "app": str(app), "files": manifest,
    }
    (output / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"ACCEPTANCE_OUTPUT={output}")


if __name__ == "__main__":
    main()
