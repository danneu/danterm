#!/usr/bin/env bash
# Stable entry point for the single-process tracked Swift file-header lint.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$SCRIPT_DIR/swift-file-header-lint.py"
