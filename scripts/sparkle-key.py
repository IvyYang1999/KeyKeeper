"""Verify a Sparkle seed and optionally sign with that exact value, without exporting it."""
import argparse
import base64
import binascii
import os
import plistlib
import subprocess
import sys


class KeyMismatch(Exception):
    pass


class VerifierUnavailable(Exception):
    pass


def child_environment(env):
    # Do not propagate KeyKeeper-injected credentials to OpenSSL or Sparkle.
    return {name: env[name] for name in ("PATH", "HOME", "TMPDIR", "LANG") if name in env}


def derive_public(seed):
    der = bytes.fromhex("302e020100300506032b657004220420") + seed
    try:
        result = subprocess.run(
            ["openssl", "pkey", "-inform", "DER", "-pubout", "-outform", "DER"],
            input=der, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env=child_environment(os.environ), timeout=15, check=True)
    except (OSError, subprocess.SubprocessError):
        raise VerifierUnavailable() from None
    prefix = bytes.fromhex("302a300506032b6570032100")
    if len(result.stdout) != 44 or not result.stdout.startswith(prefix):
        raise VerifierUnavailable()
    return result.stdout[len(prefix):]


def self_test():
    # Public RFC 8032 test vector, never a production credential.
    seed = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
    if derive_public(seed) != base64.b64decode("11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="):
        raise VerifierUnavailable()


def validate_key(value, expected):
    try:
        raw = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error):
        raise KeyMismatch() from None
    if len(raw) != 32 or base64.b64encode(raw).decode() != value:
        raise KeyMismatch()
    if derive_public(raw) != expected:
        raise KeyMismatch()
    return value.encode("ascii")


def sign_feed(value, generator, arguments, env):
    allowed = {"--download-url-prefix", "--embed-release-notes", "--maximum-deltas", "--link", "-o"}
    if any(arg.startswith("-") and arg not in allowed for arg in arguments):
        raise KeyMismatch()
    result = subprocess.run(
        [generator, "--ed-key-file", "-"] + arguments, input=value + b"\n",
        env=child_environment(env), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        timeout=300)
    if result.returncode:
        raise VerifierUnavailable()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--plist")
    parser.add_argument("--field-env", default="PRIVATE_KEY")
    parser.add_argument("--sign", metavar="GENERATE_APPCAST")
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        self_test()
        if args.self_test:
            print("ed25519 derivation works on this machine")
            return 0
        with open(args.plist, "rb") as file:
            expected_text = plistlib.load(file)["SUPublicEDKey"]
        expected = base64.b64decode(expected_text, validate=True)
        if len(expected) != 32:
            raise VerifierUnavailable()
        value = validate_key(os.environ.get(args.field_env, ""), expected)
        if args.sign:
            arguments = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
            sign_feed(value, args.sign, arguments, os.environ)
            print("SIGNED: appcast generated with the verified app signing key.")
        else:
            print("MATCHES: the stored key signs updates this app accepts.")
        return 0
    except KeyMismatch:
        print("DOES NOT MATCH: invalid seed format or a different app signing key. Nothing signed.", file=sys.stderr)
        return 2
    except (VerifierUnavailable, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        print("ERROR: verification or signing could not complete. No success claimed.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
