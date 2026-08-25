#!/usr/bin/env bash
# Stable entry point for the single-process module purity lint.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$SCRIPT_DIR/core-purity-lint.py" "$@"
