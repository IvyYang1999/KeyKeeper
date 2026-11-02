#!/usr/bin/env python3
"""Create isolated, signed synthetic probes. Never installs or launches an app."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import shutil
import subprocess
import tempfile

TEAM = "ZPTA4LP594"
APP_ID = "dev.keykeeper.app"
CONTAINER = "iCloud.dev.keykeeper.app"
REPO = Path(__file__).resolve().parent.parent


def run(args, capture=False, input_bytes=None):
    child = subprocess.Popen(args, cwd=REPO, start_new_session=True,
                             stdin=subprocess.PIPE if input_bytes is not None else subprocess.DEVNULL,
                             stdout=subprocess.PIPE if capture else None,
                             stderr=subprocess.PIPE if capture else None)
    try:
        stdout, stderr = child.communicate(input=input_bytes, timeout=300)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGTERM)
        try:
            child.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.communicate(timeout=2)
        raise RuntimeError("Probe build deadline; owned process group stopped; no retry")
    result = subprocess.CompletedProcess(args, child.returncode, stdout, stderr)
    result.check_returncode()
    return result


def local_directory(directory):
    directory = directory.resolve(strict=True)
    forbidden = {"CloudStorage", "Mobile Documents", "Desktop", "Documents"}
    if forbidden.intersection(directory.parts):
        raise ValueError("Output must be a pure local directory")
    for ancestor in [directory, *directory.parents]:
        attrs = run(["/usr/bin/xattr", str(ancestor)], True).stdout.decode()
        if "fileprovider" in attrs.lower():
            raise ValueError("File Provider output is prohibited")
    return directory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--identity", required=True, help="Existing certificate SHA-1")
    parser.add_argument("--output-parent", type=Path, required=True)
    parser.add_argument("--probe", choices=["cloud", "identity", "all"], default="all")
    args = parser.parse_args()
    parent = local_directory(args.output_parent)
    if shutil.disk_usage(parent).free < 1024**3:
        raise ValueError("Insufficient space")
    profile_bytes = args.profile.read_bytes()
    profile = plistlib.loads(run(["security", "cms", "-D"], True, profile_bytes).stdout)
    grants = profile["Entitlements"]
    cert = args.identity.upper()
    if (profile["TeamIdentifier"] != [TEAM]
            or grants.get("com.apple.application-identifier") != f"{TEAM}.{APP_ID}"
            or grants.get("com.apple.developer.icloud-container-environment") != "Production"
            or CONTAINER not in grants.get("com.apple.developer.icloud-container-identifiers", [])
            or f"{TEAM}.*" not in grants.get("keychain-access-groups", [])
            or cert not in [hashlib.sha1(c).hexdigest().upper() for c in profile["DeveloperCertificates"]]
            or profile["ExpirationDate"] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)):
        raise ValueError("Profile does not authorize this isolated candidate")
    if grants.get("com.apple.developer.icloud-services") not in ("*", ["CloudKit"]):
        raise ValueError("Profile does not authorize CloudKit")
    entitlements = {
        "com.apple.application-identifier": f"{TEAM}.{APP_ID}",
        "com.apple.developer.team-identifier": TEAM,
        "keychain-access-groups": [f"{TEAM}.{APP_ID}"],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.developer.icloud-container-identifiers": [CONTAINER],
        "com.apple.developer.icloud-container-environment": "Production",
    }
    tasks = []
    if args.probe in ("cloud", "all"):
        tasks.append(("CloudProbe", "KeyKeeperCloudProbe", APP_ID))
    if args.probe in ("identity", "all"):
        tasks.extend([("OldIdentityProbe", "KeyKeeperIdentityProbe", "com.keykeeper.app"),
                      ("NewIdentityProbe", "KeyKeeperIdentityProbe", APP_ID)])
    for target in sorted({task[1] for task in tasks}):
        run(["swift", "build", "--disable-keychain", "--product", target])
    build = Path(run(["swift", "build", "--disable-keychain", "--show-bin-path"], True).stdout.decode().strip())
    output = Path(tempfile.mkdtemp(prefix="keykeeper-sync-probes-", suffix=".noindex", dir=parent))
    (output / "entitlements.plist").write_bytes(plistlib.dumps(entitlements))
    receipt = {"profileSHA256": hashlib.sha256(profile_bytes).hexdigest(),
               "environment": "Production", "certificateSHA1": cert, "apps": []}
    for name, target, bundle_id in tasks:
        app = output / f"{name}.app"
        contents = app / "Contents"
        executable = contents / "MacOS" / target
        executable.parent.mkdir(parents=True)
        shutil.copy2(build / target, executable)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle_id, "CFBundleName": name,
            "CFBundleExecutable": target, "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "0.0.1",
            "LSUIElement": True, "LSMinimumSystemVersion": "14.0",
        }))
        sign = ["codesign", "--force", "--sign", cert, "--options", "runtime", "--timestamp"]
        if bundle_id == APP_ID:
            (contents / "embedded.provisionprofile").write_bytes(profile_bytes)
            sign += ["--entitlements", str(output / "entitlements.plist")]
        run(sign + [str(app)])
        run(["codesign", "--verify", "--strict", "--deep", str(app)])
        receipt["apps"].append({"name": name, "identifier": bundle_id,
                                "executableSHA256": hashlib.sha256(executable.read_bytes()).hexdigest()})
    (output / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"PROBE_OUTPUT={output}")


if __name__ == "__main__":
    main()
