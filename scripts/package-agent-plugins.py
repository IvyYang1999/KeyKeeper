#!/usr/bin/env python3
"""Stage the allowlisted, self-contained two-host marketplace before App signing."""
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]


def stage(destination):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=False)
    for relative in (".agents/plugins/marketplace.json", ".claude-plugin/marketplace.json"):
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, target)
    shutil.copytree(ROOT / "Plugins/keykeeper", destination / "Plugins/keykeeper",
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".DS_Store"))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: package-agent-plugins.py <new-destination>")
    stage(sys.argv[1])
