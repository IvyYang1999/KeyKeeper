import subprocess
import shutil

__version__ = "0.1.0"


class KeyKeeperError(Exception):
    pass


def _find_cli():
    path = shutil.which("keykeeper")
    if path:
        return path
    for p in ["/usr/local/bin/keykeeper", "/opt/homebrew/bin/keykeeper"]:
        import os
        if os.path.isfile(p):
            return p
    raise KeyKeeperError(
        "keykeeper CLI not found. Install KeyKeeper from https://github.com/IvyYang1999/KeyKeeper"
    )


def _run(*args):
    cli = _find_cli()
    result = subprocess.run(
        [cli] + list(args), capture_output=True, text=True
    )
    if result.returncode != 0:
        raise KeyKeeperError(result.stderr.strip() or f"keykeeper exited with code {result.returncode}")
    return result.stdout


def list_credentials():
    output = _run("list")
    if "No credentials stored" in output:
        return []
    names = []
    for line in output.strip().split("\n"):
        line = line.strip()
        if " | " in line:
            names.append(line.split(" | ")[0].strip())
    return names


def _reason_args(reason):
    """A sentence for the approval window, written by the caller.

    KeyKeeper shows it marked as unverified and it never affects any decision — but without
    it the person approving sees only a bundle id and a credential name, which is what
    happens to every SDK caller today.
    """
    return ["--reason", reason] if reason else []


def get_field(credential_id, field_name, reason=None):
    return _run("get", credential_id, field_name, *_reason_args(reason))


def get_key(credential_id, field_name, reason=None):
    return get_field(credential_id, field_name, reason=reason)


def run(credential_ids, command, prefix="", verbose=False, reason=None):
    """Run a command with secrets injected as environment variables.

    Args:
        credential_ids: A credential ID string or list of IDs.
        command: Command and arguments as a list (e.g. ["python", "script.py"]).
        prefix: Optional prefix for env var names.
        verbose: If True, print injected variable names to stderr.
        reason: One line shown in KeyKeeper's approval window explaining why you need this.

    Returns:
        subprocess.CompletedProcess
    """
    if isinstance(credential_ids, str):
        credential_ids = [credential_ids]
    cli = _find_cli()
    args = [cli, "run"]
    for cid in credential_ids:
        args.extend(["-c", cid])
    if prefix:
        args.extend(["--prefix", prefix])
    if verbose:
        args.append("--verbose")
    args.extend(_reason_args(reason))
    args.append("--")
    args.extend(command)
    return subprocess.run(args)
