#!/usr/bin/env bash
# Behavioral tests for the DanTermBundleLayoutTool resolver in scripts/lib/bundle-layout-tool.sh.
#
# The resolver carries two properties the four contract tests depend on, and neither
# was pinned by anything. First, the suite runner hands one built binary down to every
# child, so the gate step pays for one build rather than four. Second, a script run by
# hand with nothing exported still gets a working tool. The build lands in a cached
# tree in the checkout, so the third property is that a later run reuses that tree
# instead of compiling the tool again.
#
# This runs as a child of scripts/tests/bundle-contract-suite.sh because it needs the
# same build product. As its own gate step it would build into the same cached tree as
# the suite, and two steps sharing a build directory is exactly what the pool forbids.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CACHE_DIR="$ROOT_DIR/.build-bundle-layout-tool"

fail() {
    echo "bundle-layout-tool_test: $*" >&2
    exit 1
}

# Modification time in seconds. GNU coreutils and the BSD stat macOS ships spell this
# differently, and either one can come first on an agent's or a developer's PATH.
mtime() {
    stat -c %Y "$1" 2> /dev/null || stat -f %m "$1"
}

# The handoff the suite exists for: every child sees one already-built binary.
[[ -n "${DANTERM_BUNDLE_LAYOUT_TOOL:-}" ]] \
    || fail "the suite did not export DANTERM_BUNDLE_LAYOUT_TOOL"
[[ -x "$DANTERM_BUNDLE_LAYOUT_TOOL" ]] \
    || fail "the exported tool path is not executable: $DANTERM_BUNDLE_LAYOUT_TOOL"

# shellcheck source=../lib/bundle-layout-tool.sh
source "$ROOT_DIR/scripts/lib/bundle-layout-tool.sh"

# With nothing exported the resolver builds its own copy, which is how each contract
# script stays runnable on its own. That build must land in the cached tree.
unset DANTERM_BUNDLE_LAYOUT_TOOL
bundle_layout_tool_init "$ROOT_DIR"
own_copy="$(bundle_layout_tool_path)"
[[ -x "$own_copy" ]] || fail "resolving without an exported path gave no usable tool"
[[ "$own_copy" == "$CACHE_DIR/"* ]] \
    || fail "the tool was built outside the cached tree: $own_copy"

bundle_layout_tool release > /dev/null \
    || fail "the tool resolved without an exported path could not emit a plan"

# A later run reuses the cached tree: SwiftPM finds the product up to date and leaves
# the binary alone. Comparing the binary's timestamp says "it was not rebuilt" without
# measuring how long anything took.
before="$(mtime "$own_copy")"
unset _BUNDLE_LAYOUT_TOOL_BIN
bundle_layout_tool_init "$ROOT_DIR"
after="$(mtime "$(bundle_layout_tool_path)")"
[[ "$before" == "$after" ]] \
    || fail "a second resolve rebuilt the tool instead of reusing $CACHE_DIR"

# End to end: a contract script run the way a developer runs it, with nothing in the
# environment to help it.
env -u DANTERM_BUNDLE_LAYOUT_TOOL "$SCRIPT_DIR/bundle-transformations_test.sh" > /dev/null \
    || fail "a contract script could not run on its own"

echo "bundle layout tool resolver tests passed"
