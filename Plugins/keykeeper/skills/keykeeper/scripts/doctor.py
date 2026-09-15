#!/usr/bin/env python3
"""Optional, metadata-free readiness check. Python is not required to install the plugin."""
import argparse
import json
import platform
import re
import shutil
import subprocess


def inspect(cli, timeout=5):
    result = {"cli": "missing", "app": "unchecked", "credentialAccess": "unchecked"}
    if not cli:
        return result

    def query(*args):
        # Only fixed --help/--version/status calls. Never forward raw output.
        completed = subprocess.run([cli, *args], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   timeout=timeout, check=True)
        return completed.stdout.decode("utf-8", errors="replace").strip()

    try:
        version = query("--version")
        help_text = query("run", "--help")
        save_help = query("save", "--help")
        if "--reason" not in help_text or "--from-clipboard" not in save_help:
            result["cli"] = "incompatible"
            return result
        result["cli"] = "available"
        if re.fullmatch(r"(?:\d+\.\d+\.\d+|[0-9a-f]{7,40})(?:-dirty)?", version):
            result["version"] = version
        result["capabilities"] = {flag[2:]: flag in save_help for flag in (
            "--from-browser", "--from-file", "--from-source", "--replace", "--expect", "--provider")}
        reply = query("status")
        if reply == "ready":
            result["app"] = "ready"
        elif reply == "app not running (it starts automatically when a key is requested)":
            result["app"] = "not-running"
        else:
            result["app"] = "unavailable"
    except FileNotFoundError:
        pass
    except (OSError, subprocess.SubprocessError):
        result["cli" if result["cli"] == "missing" else "app"] = "unavailable"
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", help="Exact KeyKeeper CLI path, if not on PATH")
    args = parser.parse_args()
    report = (inspect(args.cli or shutil.which("keykeeper")) if platform.system() == "Darwin"
              else {"cli": "unsupported-platform", "app": "unchecked", "credentialAccess": "unchecked"})
    print(json.dumps(report, sort_keys=True))
    raise SystemExit(0 if report["cli"] == "available" and report["app"] == "ready" else 1)
