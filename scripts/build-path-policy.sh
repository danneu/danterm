#!/usr/bin/env bash
# Verifies that persistent gate lanes use distinct descendants of one owned root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/build-paths.sh"

fail() {
    echo "build-path-policy: $*" >&2
    exit 1
}

collect_declarations() {
    local step_number=0 path_number step path word previous
    while IFS= read -r step; do
        step_number=$((step_number + 1))
        path_number=0
        previous=""
        for word in $step; do
            path=""
            if [[ "$previous" == "--scratch-path" || "$previous" == "--build-path" ]]; then
                path="$word"
            elif [[ "$word" == --scratch-path=* || "$word" == --build-path=* ]]; then
                path="${word#*=}"
            fi
            previous="$word"
            [[ -n "$path" ]] || continue
            path_number=$((path_number + 1))
            if [[ "$path" == \$* ]]; then
                printf 'gate-step-%s-path-%s\tthrowaway\t%s\n' "$step_number" "$path_number" "$path"
            else
                printf 'gate-step-%s-path-%s\tgate\t%s\n' "$step_number" "$path_number" "$path"
            fi
        done
    done < <("$SCRIPT_DIR/run-test-suite.sh" --list-steps)
    "$SCRIPT_DIR/run-test-suite.sh" --list-build-paths
    "$SCRIPT_DIR/ios-portability-gate.sh" --list-build-paths
    "$SCRIPT_DIR/tests/terminal-capture-api-gate_test.sh" --list-build-paths
    "$SCRIPT_DIR/ios-app.sh" --list-build-paths
    source "$SCRIPT_DIR/lib/bundle-layout-tool.sh"
    printf 'bundle-layout-tool\tgate\t%s\n' "$(bundle_layout_tool_build_path "$REPO_ROOT")"
}

declarations="${DANTERM_BUILD_PATH_POLICY_INPUT:-}"
if [[ -z "$declarations" ]]; then
    declarations="$(mktemp)"
    trap 'rm -f "$declarations"' EXIT
    collect_declarations >"$declarations"
fi

gate_root="$(danterm_gate_build_root "$REPO_ROOT")"
owned_paths=()
owned_lanes=()
while IFS=$'\t' read -r lane kind path extra; do
    [[ -n "$lane" && -n "$kind" && -n "$path" && -z "$extra" ]] \
        || fail "invalid declaration: $lane $kind $path $extra"
    case "$kind" in
        gate)
            [[ "$path" == "$gate_root/"* ]] \
                || fail "$lane is outside the owned $gate_root root: $path"
            for index in "${!owned_paths[@]}"; do
                if [[ "${owned_paths[$index]}" == "$path" ]]; then
                    fail "$lane and ${owned_lanes[$index]} resolve to the same persistent path: $path"
                fi
            done
            owned_paths+=("$path")
            owned_lanes+=("$lane")
            ;;
        implicit-default|throwaway)
            ;;
        app)
            [[ "$path" == "$REPO_ROOT/.spm-build/ios-app/"* ]] \
                || fail "$lane is outside the owned iOS app root: $path"
            ;;
        *) fail "$lane has unknown path kind '$kind'" ;;
    esac
done <"$declarations"

if [[ "${1:-}" == "--list" ]]; then
    cat "$declarations"
elif [[ -n "${1:-}" ]]; then
    fail "unknown argument: $1. Use --list or no argument."
fi
