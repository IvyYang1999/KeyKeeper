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


def get_field(credential_id, field_name):
    return _run("get", credential_id, field_name)


def get_key(credential_id, field_name):
    return _run("get", credential_id, field_name)


def run(credential_ids, command, prefix="", verbose=False):
    """Run a command with secrets injected as environment variables.

    Args:
        credential_ids: A credential ID string or list of IDs.
        command: Command and arguments as a list (e.g. ["python", "script.py"]).
        prefix: Optional prefix for env var names.
        verbose: If True, print injected variable names to stderr.

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
    args.append("--")
    args.extend(command)
    return subprocess.run(args)
