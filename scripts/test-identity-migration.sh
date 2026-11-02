#!/bin/bash
# Synthetic only. Signing/profile preparation belongs to the caller, never this harness.
set -euo pipefail
if [[ $# -ne 3 ]]; then
  echo "Usage: $0 /absolute/old-signed-probe /absolute/new-signed-probe TEAM_ID" >&2
  exit 2
fi
old_probe=$1
new_probe=$2
probe_team=$3
[[ "$old_probe" = /* && "$new_probe" = /* && -x "$old_probe" && -x "$new_probe" ]] || exit 2
[[ "$old_probe" != "$new_probe" && "$probe_team" =~ ^[A-Z0-9]{10}$ ]] || exit 2
probe_id=$(/usr/bin/uuidgen)
probe_root="/private/tmp/keykeeper-identity-$probe_id"
/bin/mkdir -m 700 "$probe_root"
# Covers native Security.framework calls too: a timeout never starts a second request.
/usr/bin/python3 - "$old_probe" "$new_probe" "$probe_root" "$probe_id" "$probe_team" <<'PY'
import os
import signal
import subprocess
import sys

old, new, root, run_id, team = sys.argv[1:]
commands = [[old, "self-test"], [old, "producer", "--receiver", new, "--root", root,
                               "--run-id", run_id, "--team", team]]
for command in commands:
    child = subprocess.Popen(command, start_new_session=True,
                             env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"})
    try:
        result = child.wait(timeout=60)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGTERM)
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=2)
        print("FAIL identity probe: deadline; owned test process group stopped; no retry", file=sys.stderr)
        sys.exit(1)
    if result:
        sys.exit(1)
PY
echo "Synthetic source retained for recovery verification: $probe_root"
echo "Synthetic Keychain prefix: com.keykeeper.test.$probe_id"
echo "No production identity, vault, ACL, authorization or setting was changed."
