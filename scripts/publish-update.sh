#!/bin/bash
set -euo pipefail

# The explicit --confirm-version gate is enforced by the resumable publisher.
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec /usr/bin/python3 -B "$PROJECT_DIR/scripts/publish-update.py" "$@"
