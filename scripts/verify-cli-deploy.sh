#!/bin/bash

set -u

fail() {
    echo "ERROR: KeyKeeper CLI deployment verification failed: $*" >&2
    return 1
}

read_version() {
    local binary="$1"
    if [ ! -x "$binary" ]; then
        return 1
    fi
    "$binary" --version 2>/dev/null
}

verify_deploy() {
    local built_binary="$1"
    local expected_version="$2"
    local target_binary="$3"
    local built_version
    local deployed_version

    if ! built_version="$(read_version "$built_binary")"; then
        fail "built CLI is missing, not executable, or cannot report a version: $built_binary"
        return 1
    fi
    if [ "$built_version" != "$expected_version" ]; then
        fail "built CLI reports '$built_version'; expected '$expected_version'"
        return 1
    fi
    if ! deployed_version="$(read_version "$target_binary")"; then
        fail "deployed CLI is missing, not executable, or cannot report a version: $target_binary"
        return 1
    fi
    if [ "$deployed_version" != "$expected_version" ]; then
        fail "deployed CLI at $target_binary reports '$deployed_version'; expected '$expected_version'"
        return 1
    fi
}

self_test() {
    local temporary_directory
    local matching_output
    local matching_error
    local stale_error
    local script_path

    temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/keykeeper-deploy-test.XXXXXX")" || return 1
    trap 'rm -rf "$temporary_directory"' RETURN
    script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

    printf '#!/bin/sh\nprintf "%%s\\n" "keykeeper test123"\n' > "$temporary_directory/built"
    cp "$temporary_directory/built" "$temporary_directory/matching"
    printf '#!/bin/sh\nprintf "%%s\\n" "keykeeper stale000"\n' > "$temporary_directory/stale"
    chmod 755 "$temporary_directory/built" "$temporary_directory/matching" "$temporary_directory/stale"

    matching_output="$temporary_directory/matching.stdout"
    matching_error="$temporary_directory/matching.stderr"
    if ! "$script_path" "$temporary_directory/built" "keykeeper test123" "$temporary_directory/matching" >"$matching_output" 2>"$matching_error"; then
        echo "SELF-TEST FAIL: matching deployment was rejected" >&2
        return 1
    fi
    if [ -s "$matching_output" ] || [ -s "$matching_error" ]; then
        echo "SELF-TEST FAIL: matching deployment was not silent" >&2
        return 1
    fi
    echo "SELF-TEST PASS: matching deployment accepted silently"

    stale_error="$temporary_directory/stale.stderr"
    if "$script_path" "$temporary_directory/built" "keykeeper test123" "$temporary_directory/stale" >/dev/null 2>"$stale_error"; then
        echo "SELF-TEST FAIL: stale deployment was accepted" >&2
        return 1
    fi
    if ! grep -q "ERROR" "$stale_error"; then
        echo "SELF-TEST FAIL: stale deployment did not emit an error" >&2
        return 1
    fi
    echo "SELF-TEST PASS: stale deployment rejected"
    sed 's/^/  evidence: /' "$stale_error"
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit $?
fi

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "Usage: $0 <built-cli> <expected-version> [deployed-cli]" >&2
    exit 64
fi

verify_deploy "$1" "$2" "${3:-/usr/local/bin/keykeeper}"
