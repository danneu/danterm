#!/usr/bin/env bash
# Local core-purity lint: fail if `lib/DanTermCore/Sources/DanTermCore` adds
# an `import Cocoa`/`AppKit`/`SwiftUI`. The nested test package alone can't
# catch system-framework imports (any macOS SwiftPM target links them by
# default), so this regex is R1's only guard against Cocoa creep.
#
# The regex tolerates leading whitespace and an optional `@<attr>` (`@preconcurrency`,
# `@_exported`, `@_spi(...)`) before `import`, and the trailing non-identifier
# guard stops `import CocoaLumberjack`/`CocoaAsyncSocket` from false-positiving
# on `Cocoa`. The lint self-test at `scripts/tests/core-purity-lint_test.sh`
# pins these edge cases.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_TARGET="$SCRIPT_DIR/../lib/DanTermCore/Sources/DanTermCore"
TARGET="${1:-$DEFAULT_TARGET}"

if grep -rnE '^[[:space:]]*(@[^[:space:]]+[[:space:]]+)?import[[:space:]]+(Cocoa|AppKit|SwiftUI)([^[:alnum:]_]|$)' "$TARGET"; then
    echo "Cocoa/AppKit/SwiftUI import found in DanTermCore (core must stay UI-free)"
    exit 1
fi
