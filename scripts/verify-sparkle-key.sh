#!/bin/bash
set -euo pipefail

# Prove that the Sparkle signing key KeyKeeper holds is THE key this app's updates are
# verified against — without ever displaying it.
#
# It derives the ed25519 public key from the stored private key and compares it with
# SUPublicEDKey in Resources/Info.plist, which is what every installed copy checks updates
# against. Only "matches" or "does not match" is ever printed.
#
# Note: `sign_update --verify` does NOT do this. It only proves a key is self-consistent,
# never that it is this app's key.
#
#   ./scripts/verify-sparkle-key.sh [credential-id] [field-name]
#   ./scripts/verify-sparkle-key.sh --self-test

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Derives the ed25519 public key (base64) for a 32-byte seed given as hex on stdin.
# Wraps the seed in the PKCS#8 prefix for ed25519 and lets OpenSSL do the curve maths.
derive_public_key() {
    local seed_hex
    read -r seed_hex
    printf "302e020100300506032b657004220420%s" "$seed_hex" \
        | xxd -r -p \
        | openssl pkey -inform DER -pubout -outform DER 2>/dev/null \
        | tail -c 32 \
        | base64
}

# A verifier that cannot derive must not be allowed to report "does not match": that would
# read as "your key is wrong" when it means "this machine cannot check". RFC 8032 test vector 1.
self_test() {
    local got
    got="$(echo "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60" | derive_public_key)"
    if [ "$got" != "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=" ]; then
        echo "ERROR: this machine cannot derive ed25519 public keys (openssl: $(openssl version))." >&2
        echo "       Nothing was checked. Install an OpenSSL 3 build and try again." >&2
        return 1
    fi
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    echo "ed25519 derivation works on this machine"
    exit 0
fi

CREDENTIAL="${1:-${KEYKEEPER_SPARKLE_CREDENTIAL_ID:-keykeeper-sparkle-signing}}"
FIELD="${2:-private-key}"
ENV_NAME="$(printf '%s' "$FIELD" | tr '[:lower:]-' '[:upper:]_')"
EXPECTED="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PROJECT_DIR/Resources/Info.plist")"

self_test

export EXPECTED_PUBLIC_KEY="$EXPECTED"
export DERIVE_ENV_NAME="$ENV_NAME"
keykeeper run -c "$CREDENTIAL" \
    --reason "核对 Sparkle 签名私钥是否与 App 内置的更新公钥一致（只回是/否，不显示私钥）" \
    -- /bin/bash -c '
set -euo pipefail
secret="$(printf "%s" "${!DERIVE_ENV_NAME:-}" | tr -d "[:space:]")"
if [ -z "$secret" ]; then
    echo "ERROR: credential holds no value for that field" >&2
    exit 1
fi
raw_hex="$(printf "%s" "$secret" | base64 -d 2>/dev/null | xxd -p -c 256 || true)"
bytes=$(( ${#raw_hex} / 2 ))
case "$bytes" in
    32)
        # New Sparkle format: the secret is the seed, so the public key has to be derived.
        public="$(printf "302e020100300506032b657004220420%s" "$raw_hex" \
            | xxd -r -p | openssl pkey -inform DER -pubout -outform DER 2>/dev/null | tail -c 32 | base64)"
        ;;
    96)
        # An embedded public-key suffix is not proof of the corresponding private key.
        echo "DOES NOT MATCH: legacy format is unsupported by this seed verifier." >&2
        exit 2
        ;;
    *)
        echo "DOES NOT MATCH: stored value decodes to $bytes bytes; a Sparkle signing key is 32 (or 96 for the legacy format)." >&2
        exit 2
        ;;
esac
if [ "$public" = "$EXPECTED_PUBLIC_KEY" ]; then
    echo "MATCHES: the stored key signs updates this app accepts."
else
    echo "DOES NOT MATCH: the stored key is a valid ed25519 key, but not the one Info.plist trusts." >&2
    exit 2
fi
'
