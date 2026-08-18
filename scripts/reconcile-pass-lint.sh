#!/usr/bin/env bash
# Reject a reconcile pass that originates a Msg.
#
# A view-discovered fact must travel back in the pass's return value, and the
# runtime dispatches it after the sweep. A pass that calls send() instead
# re-enters the whole sweep from inside itself: the nested pass diffs the new
# model against a projection cache the outer pass has not advanced yet, and
# issues row ops against an outline that is mid-mutation.
#
# The gate names the boundary, not the passes, so renaming or splitting a helper
# cannot slip past it. Two kinds of region are checked:
#
#   whole file      app/Reconcile.swift and app/SidebarReconcileDriver.swift are
#                   the sweep and its one cache-owning driver; nothing in them
#                   may send.
#   marked region   app/SidebarView.swift is both a pass executor and an
#                   interaction handler, so only the executor half is fenced. The
#                   markers below delimit it, and a missing marker fails: deleting
#                   the fence must not be the way to pass.
#
# What this check CANNOT see is a send laundered through AppKit's own dispatch --
# an outline mutation reaching delegate feedback, a field-editor teardown reaching
# the end-editing callback. The responder-move edge, where a pass's
# makeFirstResponder reached becomeFirstResponder, is gone: the pane view reports
# focus from the click that asks for it, not from responder state. The remaining
# edges carry their own dispositions, and the runtime's outermost-only drain rule
# is the backstop for any edge this gate misses.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

WHOLE_FILES=("$ROOT/app/Reconcile.swift" "$ROOT/app/SidebarReconcileDriver.swift")
REGION_FILES=("$ROOT/app/SidebarView.swift")
# Explicit targets (the self-test uses these) replace both defaults, so a run
# can exercise either rule on its own.
if [[ "$#" -gt 0 ]]; then
    WHOLE_FILES=()
    REGION_FILES=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --whole)  WHOLE_FILES+=("${2:?--whole needs a path}");  shift 2 ;;
            --region) REGION_FILES+=("${2:?--region needs a path}"); shift 2 ;;
            *) echo "reconcile-pass-lint: unknown argument '$1'" >&2; exit 2 ;;
        esac
    done
fi

BEGIN_MARKER='reconcile-pass-lint: no-send begin'
END_MARKER='reconcile-pass-lint: no-send end'
# A send call that is not itself commented out. `sendNow(` and `sendText(` must
# not match, so the call name is anchored on a non-identifier character.
SEND_PATTERN='^(?![[:space:]]*//).*(^|[^A-Za-z0-9_])send\('

status=0

for file in ${WHOLE_FILES[@]+"${WHOLE_FILES[@]}"}; do
    [[ -f "$file" ]] || continue
    if rg --pcre2 -n "$SEND_PATTERN" "$file"; then
        echo "reconcile-pass-lint: $file drives reconcile passes and must not send()" >&2
        echo "  return the fact from the pass instead; the runtime dispatches it after the sweep" >&2
        status=1
    fi
done

for file in ${REGION_FILES[@]+"${REGION_FILES[@]}"}; do
    [[ -f "$file" ]] || continue
    begins="$(grep -c "$BEGIN_MARKER" "$file" || true)"
    ends="$(grep -c "$END_MARKER" "$file" || true)"
    if [[ "$begins" -ne 1 || "$ends" -ne 1 ]]; then
        echo "reconcile-pass-lint: $file needs exactly one begin and one end marker" >&2
        echo "  found $begins begin, $ends end -- the fenced region is the whole gate" >&2
        status=1
        continue
    fi
    if awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
        index($0, begin) { inRegion = 1; next }
        index($0, end)   { inRegion = 0; next }
        inRegion {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            if (line ~ /^\/\//) next
            if (line ~ /(^|[^A-Za-z0-9_])send\(/) {
                printf("%s:%d: %s\n", FILENAME, FNR, $0) > "/dev/stderr"
                bad = 1
            }
        }
        END { exit bad ? 1 : 0 }
    ' "$file"; then
        :
    else
        echo "reconcile-pass-lint: a send() call sits inside $file's no-send region" >&2
        echo "  report the fact through the pass's return value instead" >&2
        status=1
    fi
done

if [[ "$status" -ne 0 ]]; then
    exit 1
fi

echo "reconcile pass lint passed"
