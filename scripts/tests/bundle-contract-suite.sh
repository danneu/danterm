#!/usr/bin/env bash
# The four bundle contract tests, run against one build of DanTermBundleLayoutTool.
#
# They are one gate step rather than four because they share a build product. Each
# reads the layout plan the tool emits, so as four independent steps they built the
# same tool into four private scratch paths -- three of those builds answering a
# question the first had already answered. This builds it once, exports the path, and
# runs the four in sequence on one worker.
#
# Nothing else belongs here. A test that does not need the layout tool is independent
# and should stay its own step, where the pool can run it in parallel.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# shellcheck source=../lib/bundle-layout-tool.sh
source "$ROOT_DIR/scripts/lib/bundle-layout-tool.sh"
bundle_layout_tool_init "$ROOT_DIR" "$TEST_ROOT/layout-tool-build"
DANTERM_BUNDLE_LAYOUT_TOOL="$(bundle_layout_tool_path)"
export DANTERM_BUNDLE_LAYOUT_TOOL

for test_script in \
    verify-bundle-layout_test.sh \
    dev-build-configuration-contract_test.sh \
    build-app-helpers-contract_test.sh \
    bundle-transformations_test.sh
do
    "$SCRIPT_DIR/$test_script"
done
