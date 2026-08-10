#!/usr/bin/env bash
# Reject the generic-sequence `unicodeScalars.append(contentsOf:)` overload inside TerminalCore.
#
# That overload routes through `String.+`, which leaves the accumulator non-uniquely referenced
# and copies the whole string on every call. Inside a per-cell walk it makes projection
# quadratic: it is the exact frame under `projectedHistoryText` in the 30.10s quit hang, where a
# budget-full 16 MiB history took 38s to project instead of 0.15s. The code reads fine and the
# output is correct, so nothing but cost distinguishes it -- which is why it earns a textual
# gate rather than a review habit.
#
# What this does NOT catch: accumulation through a bound `String.UnicodeScalarView`, or any
# other spelling of the same overload. No lint can recognize "this append sits in a walk", and
# the semantic guarantee is not this gate's job -- `primaryHistoryTextStaysLinear` pins the
# projection's scaling directly. This guard covers the one concrete mechanism that already bit.
#
# A bounded single append into a fresh string is correct as written and is not what this is
# about, so such a site may carry a trailing `// scalar-append: bounded-single-append` marker
# (the same shape as core-purity-lint's `// core-purity: ambient-seam`). The marker is exact:
# an arbitrary trailing comment does not silence the gate.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$#" -eq 0 ]]; then
    set -- "$ROOT/lib/TerminalCore/Sources"
fi

fail() {
    echo "terminal-scalar-append-lint: $1" >&2
    exit 1
}

# A gate that cannot find its target must fail, not pass. `rg` exits 2 on a missing path and 1
# on a clean scan, and an `if` treats both as "no match" -- so a renamed source tree would leave
# this printing "passed" over nothing at all.
for target in "$@"; do
    [[ -e "$target" ]] || fail "missing scan target: $target"
done

PATTERN='^(?![[:space:]]*//)(?!.*//[[:space:]]*scalar-append:[[:space:]]*bounded-single-append).*unicodeScalars[[:space:]]*\.[[:space:]]*append\([[:space:]]*contentsOf:'

set +e
rg --pcre2 --glob '*.swift' -n "$PATTERN" "$@"
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
    echo "terminal-scalar-append-lint: generic-sequence append into a string's scalar view" >&2
    echo "  append scalars singly (\`for s in xs { out.unicodeScalars.append(s) }\`), or mark a" >&2
    echo "  bounded single append with \`// scalar-append: bounded-single-append\`" >&2
    exit 1
elif [[ "$status" -ne 1 ]]; then
    fail "rg failed with status $status"
fi

echo "terminal scalar append lint passed"
