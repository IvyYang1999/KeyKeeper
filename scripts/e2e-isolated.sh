#!/bin/bash
# End-to-end check of a built KeyKeeper.app against an isolated instance: its own data directory,
# its own Keychain items, its own socket. The real vault is never touched, no prompt ever appears
# (the instance approves its own requests), and the Keychain items are removed at the end.
#
#   scripts/e2e-isolated.sh            # uses dist/dmg/KeyKeeper.app
#   scripts/e2e-isolated.sh --build    # builds it first (scripts/build-app.sh --skip-dmg)
#
# Nothing goes to /Applications until this passes.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$PROJECT_DIR/dist/dmg/KeyKeeper.app"
if [ "${1:-}" = "--build" ]; then "$PROJECT_DIR/scripts/build-app.sh" --skip-dmg; fi
[ -x "$APP/Contents/MacOS/KeyKeeperApp" ] || { echo "no built app at $APP (run with --build)" >&2; exit 64; }
KK="$APP/Contents/MacOS/keykeeper"

RUN_ID="$(date +%H%M%S)-$$"
TMP="$(mktemp -d /tmp/kk-e2e.XXXXXX)"
export KEYKEEPER_DATA_DIR="$TMP/data"
export KEYKEEPER_KEYCHAIN_SERVICE="com.keykeeper.test.e2e-$RUN_ID"
export KEYKEEPER_TEST_SOCKET="/tmp/keykeeper-test-$RUN_ID.sock"
export KEYKEEPER_TEST_AUTO_APPROVE=once
export KEYKEEPER_UI_LANGUAGE=en
mkdir -p "$KEYKEEPER_DATA_DIR"

APP_PID=""
PASSED=0; FAILED=0
pass() { PASSED=$((PASSED+1)); echo "  ok   $1"; }
fail() { FAILED=$((FAILED+1)); echo "  FAIL $1"; echo "       $2" | head -5; }
expect_contains() { # name, needle, output
    if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1" "wanted '$2' in: $3"; fi
}
expect_not_contains() {
    if [[ "$3" != *"$2"* ]]; then pass "$1"; else fail "$1" "did not want '$2' in: $3"; fi
}

start_app() {
    KEYKEEPER_TEST_CLEANUP_ON_QUIT="${1:-0}" "$APP/Contents/MacOS/KeyKeeperApp" >"$TMP/app.log" 2>&1 &
    APP_PID=$!
    for _ in $(seq 1 40); do
        [ -S "$KEYKEEPER_TEST_SOCKET" ] && [ "$("$KK" status 2>/dev/null || true)" = "ready" ] && return 0
        sleep 0.25
    done
    echo "app did not come up; log:" >&2; cat "$TMP/app.log" >&2; exit 1
}
stop_app() {
    [ -n "$APP_PID" ] || return 0
    kill -TERM "$APP_PID" 2>/dev/null || true
    for _ in $(seq 1 40); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.25; done
    kill -KILL "$APP_PID" 2>/dev/null || true
    APP_PID=""
}
cleanup() {
    stop_app
    rm -f "$KEYKEEPER_TEST_SOCKET"
    rm -rf "$TMP"
}
trap cleanup EXIT

echo "==> isolated instance: $KEYKEEPER_DATA_DIR / $KEYKEEPER_KEYCHAIN_SERVICE"
cat >"$TMP/config.py" <<'PY'
TOKEN = "synthetic-token-e2e"
STRICT_KEY = "synthetic-strict-e2e"
PY

# ---- optional: start from 0.3.3's files (upgrade first launch) ----
FIXTURES="$PROJECT_DIR/Tests/KeyKeeperAppTests/Fixtures/v0.3.3"
cp "$FIXTURES/grants.json" "$FIXTURES/service-grants.json" "$KEYKEEPER_DATA_DIR/"

start_app
echo "==> fresh vault, upgraded approvals files"
OUT="$("$KK" status)"; expect_contains "status ready" "ready" "$OUT"
OUT="$("$KK" list)"; expect_contains "list is empty" "No credentials stored" "$OUT"
OUT="$("$KK" grants list 2>&1)"
expect_contains "upgrade kept the background mode" "allowed (permissive)" "$OUT"
expect_contains "upgrade moved the background approval into the Keychain" "com.openai.codex" "$OUT"
expect_not_contains "unowned old approvals are not carried over" "g-unowned-always" "$OUT"
OUT="$(ls "$KEYKEEPER_DATA_DIR" | tr '\n' ' ')"
expect_contains "old approvals files kept as a record" "service-grants.json.migrated-" "$OUT"
expect_not_contains "old approvals files no longer live" " grants.json " "$OUT"

echo "==> save without any clipboard, with the agent's suggestions"
OUT="$("$KK" save -c svc --field token --from-source "$TMP/config.py" --python-symbol TOKEN --create --security standard --expires 2027-01-31 2>&1 || true)"
expect_contains "background protection needs a declared purpose" "--purpose" "$OUT"
OUT="$("$KK" save -c svc --field token --from-source "$TMP/config.py" --python-symbol TOKEN --create --security standard --expires 2027-01-31 --purpose "e2e: nightly synthetic job" --frequency scheduled --background 2>&1)"
expect_contains "save from source" "Saved" "$OUT"
OUT="$("$KK" list)"; expect_contains "list shows credential" "svc |" "$OUT"; expect_contains "list shows expiry" "expires: 2027-01-31" "$OUT"

echo "==> agent-created credentials are inject-only: get refuses, run works"
OUT="$("$KK" get svc token 2>&1 || true)"
expect_contains "get is refused for an inject-only credential" "inject-only" "$OUT"
expect_not_contains "and prints nothing" "synthetic-token-e2e" "$OUT"
OUT="$("$KK" list --detail 2>&1)"; expect_contains "list says so" "inject-only" "$OUT"

echo "==> run a Background OK credential (no prompt)"
OUT="$("$KK" run -c svc -- sh -c 'test "$TOKEN" = synthetic-token-e2e && echo MATCH' 2>&1)"
expect_contains "value injected" "MATCH" "$OUT"
OUT="$("$KK" run -c svc -- sh -c 'echo "$TOKEN"' 2>&1)"
expect_contains "child output redacted" "[REDACTED]" "$OUT"; expect_not_contains "value never printed" "synthetic-token-e2e" "$OUT"

echo "==> plain fields through the promptless edit path, served only when the app vouches for meta.json"
OUT="$("$KK" edit svc --set region=us-east-1 --title Svc 2>&1)"; expect_contains "edit plain field" "region" "$OUT"
OUT="$("$KK" get svc region 2>&1)"; expect_contains "get plain field" "us-east-1" "$OUT"
# 【独立审计 2026-09-14】a plain value a caller wrote over the socket is not injected until the person confirms it in the app.
OUT="$("$KK" run -c svc -- sh -c 'echo "REGION=$REGION"' 2>&1)"
expect_contains "unconfirmed plain field is held back with an explanation" "Not injected from 'svc': region" "$OUT"
expect_not_contains "and not injected" "REGION=us-east-1" "$OUT"

echo "==> strict credential: every run asks, the instance answers 'once'"
OUT="$("$KK" save -c strict1 --field key --from-source "$TMP/config.py" --python-symbol STRICT_KEY --create 2>&1)"
expect_contains "save strict" "Saved" "$OUT"
OUT="$("$KK" run -c strict1 -- sh -c 'test "$KEY" = synthetic-strict-e2e && echo MATCH' 2>&1 || true)"
expect_contains "a first request without a reason is refused" "--reason" "$OUT"
expect_not_contains "and nothing is handed out" "MATCH" "$OUT"
OUT="$("$KK" run -c strict1 --reason "e2e: checking the key is injected" -- sh -c 'test "$KEY" = synthetic-strict-e2e && echo MATCH' 2>&1)"
expect_contains "strict run after approval" "MATCH" "$OUT"
OUT="$("$KK" run -c strict1 --reason "e2e: second run" --duration always -- sh -c 'test "$KEY" = synthetic-strict-e2e && echo MATCH' 2>&1)"
expect_contains "strict run asks again (once was spent)" "MATCH" "$OUT"
OUT="$("$KK" grants list --credential strict1 2>&1)"
expect_contains "once-approvals are spent after use" "spent" "$OUT"
# A new once-approval for the same caller and target replaces the spent one, so one line is listed.
LISTED="$(printf '%s' "$OUT" | grep -c 'credential: strict1')"; SPENT="$(printf '%s' "$OUT" | grep -c '^  spent')"
if [ "$LISTED" -ge 1 ] && [ "$LISTED" = "$SPENT" ]; then pass "every once-approval for strict1 is spent"; else fail "every once-approval for strict1 is spent" "listed $LISTED, spent $SPENT"; fi
OUT="$("$KK" grants revoke no-such-id 2>&1 || true)"; expect_contains "revoking a wrong id says so" "No approval has that ID" "$OUT"

echo "==> meta.json is signed, and a forged line is not honored"
OUT="$(grep -c '"integrity"' "$KEYKEEPER_DATA_DIR/meta.json")"
expect_contains "meta.json signed" "1" "$OUT"
python3 - "$KEYKEEPER_DATA_DIR/meta.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['credentials']['svc']['fields']['region']['value']='attacker'
json.dump(d,open(p,'w'),indent=2,sort_keys=True)
PY
OUT="$("$KK" get svc region 2>&1 || true)"; expect_contains "tampered meta.json refused" "changed outside KeyKeeper" "$OUT"
expect_not_contains "tampered value not served" "attacker" "$OUT"

echo "==> relaunch: nothing lost"
stop_app; start_app
OUT="$("$KK" run -c svc -- sh -c 'test "$TOKEN" = synthetic-token-e2e && echo MATCH' 2>&1)"
expect_contains "values survive relaunch" "MATCH" "$OUT"

echo "==> quit with cleanup: no Keychain item left behind"
stop_app; start_app 1; stop_app
LEFT=0
for svc in "$KEYKEEPER_KEYCHAIN_SERVICE" "$KEYKEEPER_KEYCHAIN_SERVICE.browser-sessions" \
           "$KEYKEEPER_KEYCHAIN_SERVICE.approvals" "$KEYKEEPER_KEYCHAIN_SERVICE.metadata-mac"; do
    if security find-generic-password -s "$svc" >/dev/null 2>&1; then LEFT=$((LEFT+1)); echo "       left behind: $svc"; fi
done
if [ "$LEFT" = 0 ]; then pass "keychain clean"; else fail "keychain clean" "$LEFT item(s) remain"; fi

echo
echo "e2e: $PASSED passed, $FAILED failed"
[ "$FAILED" = 0 ]
