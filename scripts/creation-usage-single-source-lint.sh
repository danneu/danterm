#!/usr/bin/env bash
# Reject a second copy of any `danterm` usage text in the protocol module.
#
# `tab new`, `pane split`, and `group new` share a flag grammar. Each command's usage line is
# composed once, from one shared flag-text constant, and is read by two callers: the command's
# own arg parser, which renders its errors with it, and CLIParser, whose post-parse guards
# report it. Writing the line out a second time to serve the second reader is exactly how the
# two drifted apart before, and nothing in the type system notices -- both spellings compile,
# and the tests that pin one message keep passing while the other message rots.
#
# So the gate is textual: within the module's sources, no creation command's usage literal and
# no copy of the shared flag text may appear twice. Tests carry their own independent literals
# on purpose -- they are the harness that proves the messages did not change -- so only the
# Sources tree is scanned. Commands outside the creation family are out of scope: they share no
# grammar, and several of them do still repeat their own usage text.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$#" -eq 0 ]]; then
    set -- "$ROOT/lib/DanTermProtocol/Sources/DanTermProtocol"
fi

fail=0

# A usage literal runs from `usage: danterm` to the closing quote of the string it sits in.
# An interpolation inside it is part of the literal, which is what makes a composed line
# distinct from a hand-written copy of the same rendered text.
# `rg` exits 1 when it matches nothing, which is a passing state here, not a failure.
duplicates="$({ rg --no-filename --only-matching --glob '*.swift' 'usage: danterm (tab new|pane split|group new) [^"]*' "$@" || true; } | sort | uniq -d)"
if [[ -n "$duplicates" ]]; then
    echo "creation-usage-single-source-lint: a usage line is written out more than once" >&2
    printf '  %s\n' "$duplicates" >&2
    echo "  define it once next to the flags it documents and read that constant instead" >&2
    fail=1
fi

shared_count="$({ rg --count-matches --no-filename --glob '*.swift' --fixed-strings -- '[--cmd <s>] [--cwd <p>]' "$@" || true; } | awk '{ total += $1 } END { print total + 0 }')"
if [[ "${shared_count:-0}" -gt 1 ]]; then
    echo "creation-usage-single-source-lint: the shared creation flags are spelled out ${shared_count} times" >&2
    echo "  interpolate newCommandFlagsUsage into each command's usage line instead" >&2
    fail=1
fi

if [[ "$fail" -ne 0 ]]; then
    exit 1
fi

echo "creation usage single-source lint passed"
