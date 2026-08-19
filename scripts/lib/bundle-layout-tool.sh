# shellcheck shell=bash
# One resolver for the DanTermBundleLayoutTool binary the bundle contract tests read.
#
# Four test scripts need the emitted layout plan, and each used to `swift run` the tool
# into a scratch of its own -- four cold builds of one tool to answer seven questions.
# The binary is a build product, so it is built once and handed down: the gate's
# bundle-contract suite builds it and exports DANTERM_BUNDLE_LAYOUT_TOOL, and a script
# run on its own builds a private copy. Sourcing this defines no state; the caller's
# init call is what resolves the path.

# Resolves the layout tool once for this process, into <scratch> if it must build it.
#
# Takes the repository root and a scratch path the caller owns. An exported
# DANTERM_BUNDLE_LAYOUT_TOOL wins, which is how the suite runner collapses four builds
# into one; without it the caller pays for its own, so every script stays runnable by
# hand. Build progress goes to stderr because callers redirect the tool's stdout into
# a plan file.
bundle_layout_tool_init() {
    local root="$1" scratch="$2"
    if [[ -n "${DANTERM_BUNDLE_LAYOUT_TOOL:-}" ]]; then
        _BUNDLE_LAYOUT_TOOL_BIN="$DANTERM_BUNDLE_LAYOUT_TOOL"
        return
    fi
    swift build --package-path "$root" --scratch-path "$scratch" \
        --product DanTermBundleLayoutTool >&2
    _BUNDLE_LAYOUT_TOOL_BIN="$(
        swift build --package-path "$root" --scratch-path "$scratch" --show-bin-path
    )/DanTermBundleLayoutTool"
}

# Runs the resolved tool with the caller's arguments, writing the plan to stdout.
bundle_layout_tool() {
    "$_BUNDLE_LAYOUT_TOOL_BIN" "$@"
}

# The resolved binary's path, for a caller that must pass it to child processes.
bundle_layout_tool_path() {
    printf '%s\n' "$_BUNDLE_LAYOUT_TOOL_BIN"
}
