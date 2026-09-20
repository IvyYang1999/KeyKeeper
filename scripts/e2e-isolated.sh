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

echo "==> provider templates: save --provider fills in id/field, checks the shape, verifies afterwards"
OUT="$("$KK" providers 2>&1)"; expect_contains "providers listed" "openai | OpenAI" "$OUT"
OUT="$("$KK" providers show claude 2>&1)"; expect_contains "template shown as JSON" "console.anthropic.com" "$OUT"
printf 'WRONG = "AKIA-not-an-openai-key-at-all-0123456789"\nOK = "sk-proj-synthetic-e2e-%s"\n' "$(printf 'x%.0s' $(seq 1 60))" > "$TMP/providers.py"
# Telegram documents a bot-id:token grammar; OpenAI does not promise a universal key prefix.
OUT="$("$KK" save --provider telegram --from-source "$TMP/providers.py" --python-symbol WRONG --create --purpose "e2e: wrong shape" 2>&1 || true)"
expect_contains "wrong shape refused before writing" "documented format" "$OUT"
OUT="$("$KK" list 2>&1)"; expect_not_contains "nothing created for the refused save" "telegram |" "$OUT"
OUT="$("$KK" save --provider openai --from-source "$TMP/providers.py" --python-symbol OK --create --purpose "e2e: synthetic openai key" 2>&1)"
expect_contains "saved under the template's id" "Saved" "$OUT"
case "$OUT" in *"rejected the key"*|*"could not reach"*) pass "verification ran (synthetic key: rejected or unreachable)";; *) fail "verification ran" "$OUT";; esac
OUT="$("$KK" list --detail 2>&1)"; expect_contains "credential uses the template's id and field" "openai |" "$OUT"

echo "==> browser proposal: receiver, local paste, terminal status and secret-free recovery"
BROWSER_LOG="$TMP/browser-import.log"
"$KK" save -c browser-fixture --field key --from-browser --create --purpose "e2e: browser import" >"$BROWSER_LOG" 2>&1 &
BROWSER_PID=$!
for _ in $(seq 1 40); do
    BROWSER_URL="$(grep -m1 '^http://127\.0\.0\.1:' "$BROWSER_LOG" 2>/dev/null || true)"
    PROPOSAL_ID="$(sed -n 's/^Proposal ID: //p' "$BROWSER_LOG" | head -1)"
    [ -n "$BROWSER_URL" ] && [ -n "$PROPOSAL_ID" ] && break
    sleep 0.25
done
if [ -n "${BROWSER_URL:-}" ] && [ -n "${PROPOSAL_ID:-}" ]; then
    pass "browser receiver and public proposal id returned"
else
    fail "browser receiver and public proposal id returned" "$(head -8 "$BROWSER_LOG")"
fi
AUTH_FRAGMENT="${BROWSER_URL##*#}"
BROWSER_BASE="${BROWSER_URL%%#*}"
BROWSER_ORIGIN="${BROWSER_BASE%/}"
OUT="$(/usr/bin/curl -sS --max-time 5 -X POST "${BROWSER_BASE}import" \
    -H "Origin: $BROWSER_ORIGIN" -H 'Content-Type: text/plain;charset=UTF-8' \
    -H "X-KeyKeeper-Session: $AUTH_FRAGMENT" --data-binary 'synthetic-browser-e2e')"
expect_contains "browser paste becomes a proposal" '"state":"pasteReceived"' "$OUT"
expect_not_contains "browser response contains no secret" "synthetic-browser-e2e" "$OUT"
if wait "$BROWSER_PID"; then
    OUT="$(cat "$BROWSER_LOG")"
    expect_contains "browser import commits" "Saved" "$OUT"
    expect_not_contains "browser CLI output contains no secret" "synthetic-browser-e2e" "$OUT"
else
    fail "browser import commits" "$(head -8 "$BROWSER_LOG")"
fi
OUT="$("$KK" proposal status "$PROPOSAL_ID" --json 2>&1)"
expect_contains "terminal proposal remains queryable" '"state":"committed"' "$OUT"
expect_not_contains "proposal status contains no secret" "synthetic-browser-e2e" "$OUT"

echo "==> browser proposal: pasted candidate survives an App restart without another paste"
export KEYKEEPER_TEST_AUTO_APPROVE=
stop_app; start_app
RECOVERY_LOG="$TMP/browser-recovery.log"
"$KK" save -c browser-restart-fixture --field key --from-browser --create --purpose "e2e: restart recovery" >"$RECOVERY_LOG" 2>&1 &
RECOVERY_PID=$!
RECOVERY_URL=""; RECOVERY_ID=""
for _ in $(seq 1 40); do
    RECOVERY_URL="$(grep -m1 '^http://127\.0\.0\.1:' "$RECOVERY_LOG" 2>/dev/null || true)"
    RECOVERY_ID="$(sed -n 's/^Proposal ID: //p' "$RECOVERY_LOG" | head -1)"
    [ -n "$RECOVERY_URL" ] && [ -n "$RECOVERY_ID" ] && break
    sleep 0.25
done
RECOVERY_FRAGMENT="${RECOVERY_URL##*#}"
RECOVERY_BASE="${RECOVERY_URL%%#*}"
RECOVERY_ORIGIN="${RECOVERY_BASE%/}"
OUT="$(/usr/bin/curl -sS --max-time 5 -X POST "${RECOVERY_BASE}import" \
    -H "Origin: $RECOVERY_ORIGIN" -H 'Content-Type: text/plain;charset=UTF-8' \
    -H "X-KeyKeeper-Session: $RECOVERY_FRAGMENT" --data-binary 'synthetic-browser-restart-e2e')"
expect_contains "restart candidate staged before quit" '"state":"pasteReceived"' "$OUT"
stop_app
wait "$RECOVERY_PID" 2>/dev/null || true
export KEYKEEPER_TEST_AUTO_APPROVE=once
start_app
OUT="$("$KK" proposal status "$RECOVERY_ID" --json 2>&1)"
expect_contains "same proposal id is recoverable after restart" '"state":"pasteReceived"' "$OUT"
expect_not_contains "recovered status contains no secret" "synthetic-browser-restart-e2e" "$OUT"
"$KK" proposal open "$RECOVERY_ID" --json >/dev/null
OUT=""
for _ in $(seq 1 40); do
    OUT="$("$KK" proposal status "$RECOVERY_ID" --json 2>&1 || true)"
    [[ "$OUT" == *'"state":"committed"'* ]] && break
    sleep 0.25
done
expect_contains "reopened proposal commits without another paste" '"state":"committed"' "$OUT"
OUT="$("$KK" run -c browser-restart-fixture --reason "e2e: recovered value" -- sh -c 'test "$KEY" = synthetic-browser-restart-e2e && echo MATCH' 2>&1)"
expect_contains "recovered candidate became the intended credential" "MATCH" "$OUT"

echo "==> durable field validation: reject a receiver URL before write, then persist the rule"
VALIDATION_LOG="$TMP/browser-validation.log"
"$KK" save -c oauth-fixture --field client-id --from-browser --create --reject-url \
    --expect-suffix .apps.googleusercontent.com --purpose "e2e: validated browser import" >"$VALIDATION_LOG" 2>&1 &
VALIDATION_PID=$!
VALIDATION_URL=""
for _ in $(seq 1 40); do
    VALIDATION_URL="$(grep -m1 '^http://127\.0\.0\.1:' "$VALIDATION_LOG" 2>/dev/null || true)"
    [ -n "$VALIDATION_URL" ] && break
    sleep 0.25
done
if [ -z "$VALIDATION_URL" ]; then
    fail "validation receiver returned" "$(head -8 "$VALIDATION_LOG")"
    kill "$VALIDATION_PID" 2>/dev/null || true
    wait "$VALIDATION_PID" 2>/dev/null || true
    exit 1
fi
VALIDATION_FRAGMENT="${VALIDATION_URL##*#}"
VALIDATION_BASE="${VALIDATION_URL%%#*}"
VALIDATION_ORIGIN="${VALIDATION_BASE%/}"
OUT="$(/usr/bin/curl -sS --max-time 5 -X POST "${VALIDATION_BASE}import" \
    -H "Origin: $VALIDATION_ORIGIN" -H 'Content-Type: text/plain;charset=UTF-8' \
    -H "X-KeyKeeper-Session: $VALIDATION_FRAGMENT" --data-binary "$VALIDATION_BASE")"
expect_contains "wrong URL reaches validation proposal" '"state":"pasteReceived"' "$OUT"
if wait "$VALIDATION_PID"; then
    fail "receiver URL refused before write" "$(head -8 "$VALIDATION_LOG")"
else
    OUT="$(cat "$VALIDATION_LOG")"
    expect_contains "receiver URL refused before write" "rejects web URLs" "$OUT"
fi
OUT="$("$KK" list 2>&1)"; expect_not_contains "refused value created no credential" "oauth-fixture |" "$OUT"

: >"$VALIDATION_LOG"
"$KK" save -c oauth-fixture --field client-id --from-browser --create --reject-url \
    --expect-suffix .apps.googleusercontent.com --purpose "e2e: validated browser import" >"$VALIDATION_LOG" 2>&1 &
VALIDATION_PID=$!
VALIDATION_URL=""
for _ in $(seq 1 40); do
    VALIDATION_URL="$(grep -m1 '^http://127\.0\.0\.1:' "$VALIDATION_LOG" 2>/dev/null || true)"
    [ -n "$VALIDATION_URL" ] && break
    sleep 0.25
done
if [ -z "$VALIDATION_URL" ]; then
    fail "validation receiver returned" "$(head -8 "$VALIDATION_LOG")"
    kill "$VALIDATION_PID" 2>/dev/null || true
    wait "$VALIDATION_PID" 2>/dev/null || true
    exit 1
fi
VALIDATION_FRAGMENT="${VALIDATION_URL##*#}"
VALIDATION_BASE="${VALIDATION_URL%%#*}"
VALIDATION_ORIGIN="${VALIDATION_BASE%/}"
OUT="$(/usr/bin/curl -sS --max-time 5 -X POST "${VALIDATION_BASE}import" \
    -H "Origin: $VALIDATION_ORIGIN" -H 'Content-Type: text/plain;charset=UTF-8' \
    -H "X-KeyKeeper-Session: $VALIDATION_FRAGMENT" --data-binary 'synthetic.apps.googleusercontent.com')"
expect_contains "matching value reaches validation proposal" '"state":"pasteReceived"' "$OUT"
if wait "$VALIDATION_PID"; then
    OUT="$(cat "$VALIDATION_LOG")"
    expect_contains "matching value commits" "Persistent field validation saved" "$OUT"
else
    fail "matching value commits" "$(head -8 "$VALIDATION_LOG")"
fi
OUT="$("$KK" meta oauth-fixture 2>&1)"
expect_contains "metadata records durable URL rejection" '"rejectURL" : true' "$OUT"
expect_contains "metadata records durable suffix" '.apps.googleusercontent.com' "$OUT"

echo "==> provider aliases: one stored value reaches official SDK variables"
OUT="$("$KK" save --provider zhipu-cn --from-source "$TMP/config.py" --python-symbol TOKEN --create --purpose "e2e: new SDK aliases" 2>&1)"
expect_contains "new canonical provider saved" "Saved" "$OUT"
OUT="$("$KK" run -c zhipu-cn --reason "e2e: SDK alias equality" -- sh -c 'test -n "$ZAI_API_KEY" && test "$ZAI_API_KEY" = "$ZHIPUAI_API_KEY" && echo MATCH' 2>&1)"
expect_contains "same value in new and legacy SDK env" "MATCH" "$OUT"
OUT="$("$KK" save --provider zhipu --from-source "$TMP/config.py" --python-symbol TOKEN --create --purpose "e2e: legacy save target" 2>&1)"
expect_contains "old provider spelling preserves old target" "Saved" "$OUT"
OUT="$("$KK" run -c zhipu --reason "e2e: legacy default target" -- sh -c 'test -n "$ZHIPUAI_API_KEY" && test "$ZHIPUAI_API_KEY" = "$ZAI_API_KEY" && echo MATCH' 2>&1)"
expect_contains "old default credential still runs" "MATCH" "$OUT"
OUT="$("$KK" save --provider modelscope-cn --from-source "$TMP/config.py" --python-symbol TOKEN --create --purpose "e2e: ModelScope aliases" 2>&1)"
expect_contains "ModelScope saved once" "Saved" "$OUT"
OUT="$("$KK" run -c modelscope-cn --reason "e2e: ModelScope aliases" -- sh -c 'test -n "$MODELSCOPE_API_TOKEN" && test "$MODELSCOPE_API_TOKEN" = "$MODELSCOPE_SDK_TOKEN" && echo MATCH' 2>&1)"
expect_contains "both ModelScope SDK env names work" "MATCH" "$OUT"

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

echo "==> add one missing secret field without renaming or replacing the credential"
OUT="$("$KK" save -c svc --field second-token --from-source "$TMP/config.py" --python-symbol STRICT_KEY --add-field 2>&1)"
expect_contains "add-field is explicit and succeeds" "Added the secret field" "$OUT"
expect_not_contains "add-field output contains no secret" "synthetic-strict-e2e" "$OUT"
OUT="$("$KK" meta svc 2>&1)"
expect_contains "existing credential now declares the new field" "second-token" "$OUT"
expect_contains "existing credential kept its original field" '"token"' "$OUT"

echo "==> plain fields through the promptless edit path, served only when the app vouches for meta.json"
OUT="$("$KK" edit svc --set region=us-east-1 --title Svc 2>&1)"; expect_contains "edit plain field" "region" "$OUT"
OUT="$("$KK" get svc region 2>&1)"; expect_contains "get plain field" "us-east-1" "$OUT"
# 【独立审计 2026-09-14】a plain value a caller wrote over the socket is not injected until the person confirms it in the app.
OUT="$("$KK" run -c svc -- sh -c 'echo "REGION=$REGION"' 2>&1)"
expect_contains "unconfirmed plain field is held back with an explanation" "Not injected from 'svc': region" "$OUT"
expect_not_contains "and not injected" "REGION=us-east-1" "$OUT"

echo "==> import a project's dotenv file: every value protected in the Keychain"
mkdir -p "$TMP/proj"
cat >"$TMP/proj/.env" <<'ENV'
# synthetic project env
OPENAI_API_KEY=sk-synthetic-env-1234567890
export DATABASE_URL="postgres://user:pw@db.example/app"
PORT=3000
EMPTY=
ENV
OUT="$("$KK" import "$TMP/proj/.env" --id envproj --label "Env Project" 2>&1)"
expect_contains "import reports counts, never values" "3 secret, 0 plain, 1 skipped" "$OUT"
expect_not_contains "no value in the CLI output" "sk-synthetic-env" "$OUT"
[ -f "$TMP/proj/.env" ] && pass "original .env untouched" || fail "original .env untouched" "file gone"
OUT="$("$KK" list --detail 2>&1)"
expect_contains "credential listed with its label" "Env Project" "$OUT"
expect_contains "imported credential is inject-only" "inject-only" "$OUT"
OUT="$("$KK" run -c envproj --reason "e2e: env import" -- sh -c 'test "$OPENAI_API_KEY" = sk-synthetic-env-1234567890 && test "$PORT" = 3000 && test -n "$DATABASE_URL" && echo MATCH' 2>&1)"
expect_contains "run injects protected values under their original names" "MATCH" "$OUT"
OUT="$("$KK" meta envproj 2>&1)"
expect_not_contains "ordinary settings are not exposed in metadata" '"value"' "$OUT"
OUT="$("$KK" get envproj port 2>&1 || true)"
expect_contains "get cannot expose ordinary imported settings either" "inject-only" "$OUT"
OUT="$("$KK" get envproj openai-api-key 2>&1 || true)"
expect_contains "get refuses the imported secret" "inject-only" "$OUT"
OUT="$("$KK" import "$TMP/proj/.env" --id envproj 2>&1 || true)"
expect_contains "importing onto an existing id is refused" "already exists" "$OUT"
OUT="$("$KK" import "$TMP/config.py" --id pyenv 2>&1 || true)"
expect_contains "a non-.env file is refused before the App reads it" ".env" "$OUT"

echo "==> strict credential: every run asks, the instance answers 'once'"
OUT="$("$KK" save -c strict1 --field key --from-source "$TMP/config.py" --python-symbol STRICT_KEY --create 2>&1)"
expect_contains "save strict" "Saved" "$OUT"
# 2026-09-15: a request without a reason still gets its window (the window says so); the
# isolated instance answers it like any other, so the run goes through.
OUT="$("$KK" run -c strict1 -- sh -c 'test "$KEY" = synthetic-strict-e2e && echo MATCH' 2>&1)"
expect_contains "a first request without a reason still reaches the window" "MATCH" "$OUT"
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

echo "==> relaunch: nothing lost"
stop_app; start_app
OUT="$("$KK" run -c svc -- sh -c 'test "$TOKEN" = synthetic-token-e2e && echo MATCH' 2>&1)"
expect_contains "values survive relaunch" "MATCH" "$OUT"

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

echo "==> relaunch: tampered metadata stays refused"
stop_app; start_app
OUT="$("$KK" run -c svc -- sh -c 'test "$TOKEN" = synthetic-token-e2e && echo MATCH' 2>&1 || true)"
expect_contains "relaunch does not bless tampered metadata" "changed outside KeyKeeper" "$OUT"
expect_not_contains "tampered relaunch injects no value" "MATCH" "$OUT"

echo "==> quit with cleanup: no Keychain item left behind"
stop_app; start_app 1; stop_app
LEFT=0
for svc in "$KEYKEEPER_KEYCHAIN_SERVICE" "$KEYKEEPER_KEYCHAIN_SERVICE.browser-sessions" \
           "$KEYKEEPER_KEYCHAIN_SERVICE.browser-import-proposals" \
           "$KEYKEEPER_KEYCHAIN_SERVICE.approvals" "$KEYKEEPER_KEYCHAIN_SERVICE.metadata-mac"; do
    if security find-generic-password -s "$svc" >/dev/null 2>&1; then LEFT=$((LEFT+1)); echo "       left behind: $svc"; fi
done
if [ "$LEFT" = 0 ]; then pass "keychain clean"; else fail "keychain clean" "$LEFT item(s) remain"; fi

echo
echo "e2e: $PASSED passed, $FAILED failed"
[ "$FAILED" = 0 ]
