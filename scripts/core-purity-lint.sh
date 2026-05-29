#!/usr/bin/env bash
# Local purity lint with two profiles:
#
#   pure     (default; target lib/DanTermCore/Sources/DanTermCore)
#            Bans Cocoa/AppKit/SwiftUI imports AND a denylist of side-effecting /
#            nondeterministic tokens, so the pure core stays free of IO and
#            ambient nondeterminism. Two tiers:
#              - hard bans (no allowlist): FileManager, Process(, DispatchSource,
#                URLSession, ProcessInfo, import Darwin/Network, ... -- this code
#                belongs in app/ or lib/DanTermSupport, never the pure core.
#              - banned-with-allowlist: NSHomeDirectory, bare UUID(), bare Date().
#                Permitted ONLY on a line carrying the marker `// core-purity:
#                ambient-seam` (the three designated ambient seams: CoreEnv.live
#                and the abbreviateHome/expandTilde leaf defaults). Anywhere else
#                they are a fresh nondeterminism leak.
#   portable (target lib/DanTermSupport/Sources/DanTermSupport)
#            Bans Cocoa/AppKit/SwiftUI AND GhosttyKit imports -- and nothing else.
#            DanTermSupport legitimately performs portable IO (FileManager,
#            Process, DispatchSource, ProcessInfo), so the pure-tier IO bans do
#            NOT apply here. The profiles are deliberately kept separate.
#
# The regex denylist is a heuristic regression guard, not the proof of purity:
# the real proof is structural (the nested test packages compile core/support
# with no GhosttyKit and no cross-module IO dependency). The lint keeps it that way.
#
# The token pass strips comments and string literals before tokenizing (so a pure
# comment mentioning FileManager/DispatchSourceTimer does not false-positive) but
# tests the allowlist marker on the RAW, unstripped line -- the marker is itself a
# `//` comment, so stripping first would erase it and trip every seam. The import
# rules are line-anchored and need no stripping. The self-test
# (scripts/tests/core-purity-lint_test.sh) pins every edge case in both directions.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CORE_DEFAULT="$SCRIPT_DIR/../lib/DanTermCore/Sources/DanTermCore"

PROFILE="pure"
TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) PROFILE="${2:?--profile needs a value}"; shift 2 ;;
        --profile=*) PROFILE="${1#*=}"; shift ;;
        *) TARGET="$1"; shift ;;
    esac
done
[[ -n "$TARGET" ]] || TARGET="$CORE_DEFAULT"

case "$PROFILE" in
    pure|portable) ;;
    *) echo "core-purity-lint: unknown profile '$PROFILE' (expected pure|portable)" >&2; exit 2 ;;
esac

# --- Cocoa/AppKit/SwiftUI import rule (both profiles). Line-anchored; tolerates
# leading whitespace + an optional @<attr>; the trailing non-identifier guard
# stops `import CocoaLumberjack`/`CocoaAsyncSocket` from false-positiving. ---
if grep -rnE '^[[:space:]]*(@[^[:space:]]+[[:space:]]+)?import[[:space:]]+(Cocoa|AppKit|SwiftUI)([^[:alnum:]_]|$)' "$TARGET"; then
    echo "Cocoa/AppKit/SwiftUI import found in $TARGET (must stay UI-free)" >&2
    exit 1
fi

if [[ "$PROFILE" == "portable" ]]; then
    # --- GhosttyKit import rule (portable only; echoes the structural guarantee
    # that the support nested package has no GhosttyKit dependency). ---
    if grep -rnE '^[[:space:]]*(@[^[:space:]]+[[:space:]]+)?import[[:space:]]+GhosttyKit([^[:alnum:]_]|$)' "$TARGET"; then
        echo "GhosttyKit import found in $TARGET (DanTermSupport must stay GhosttyKit-free)" >&2
        exit 1
    fi
    exit 0
fi

# --- pure profile: token denylist on comment/string-stripped lines. ---
# The awk program is intentionally single-quoted: its $0/FILENAME/etc. are awk's,
# not the shell's, so they must NOT be expanded by bash (SC2016 is expected here).
# shellcheck disable=SC2016
if find "$TARGET" -name '*.swift' -print0 | xargs -0 awk '
    BEGIN {
        # Hard-ban patterns (ERE). The marker NEVER exempts these.
        nh = 0
        hard[++nh] = "(^|[^A-Za-z0-9_])import[ \t]+Darwin([^A-Za-z0-9_]|$)"
        hard[++nh] = "(^|[^A-Za-z0-9_])import[ \t]+Network([^A-Za-z0-9_]|$)"
        hard[++nh] = "(^|[^A-Za-z0-9_])FileManager([^A-Za-z0-9_]|$)"
        hard[++nh] = "(^|[^A-Za-z0-9_])Process\\("
        hard[++nh] = "(^|[^A-Za-z0-9_])DispatchSource"
        hard[++nh] = "(^|[^A-Za-z0-9_])DispatchQueue\\("
        hard[++nh] = "\\.asyncAfter"
        hard[++nh] = "(^|[^A-Za-z0-9_])Timer\\("
        hard[++nh] = "(^|[^A-Za-z0-9_])URLSession"
        hard[++nh] = "(^|[^A-Za-z0-9_])NSWorkspace"
        hard[++nh] = "(^|[^A-Za-z0-9_])setsockopt"
        hard[++nh] = "Data\\(contentsOf:"
        hard[++nh] = "\\.write\\(to:"
        hard[++nh] = "(^|[^A-Za-z0-9_])ProcessInfo"

        # Banned-with-allowlist patterns. Empty-parens only for UUID()/Date() so
        # the deterministic UUID(uuidString:)/Date(timeIntervalSince1970:) parses
        # in core never trip.
        ns = 0
        seam[++ns] = "(^|[^A-Za-z0-9_])NSHomeDirectory"
        seam[++ns] = "(^|[^A-Za-z0-9_])UUID\\(\\)"
        seam[++ns] = "(^|[^A-Za-z0-9_])Date\\(\\)"

        marker = "core-purity: ambient-seam"
        bad = 0
    }
    FNR == 1 { inBlock = 0 }   # block-comment state must not bleed across files
    {
        raw = $0
        line = raw

        # Close an open /* */ block carried from a previous line.
        if (inBlock) {
            i = index(line, "*/")
            if (i > 0) { line = substr(line, i + 2); inBlock = 0 } else { next }
        }
        # Strip double-quoted string-literal bodies (so // or tokens inside a
        # string do not register). Simple form: no escaped-quote handling needed
        # for this pure value code.
        gsub(/"[^"]*"/, "", line)
        # Strip inline /* */ blocks; open a multi-line block if unterminated.
        while ((s = index(line, "/*")) > 0) {
            rest = substr(line, s + 2)
            e = index(rest, "*/")
            if (e > 0) { line = substr(line, 1, s - 1) substr(rest, e + 2) }
            else { line = substr(line, 1, s - 1); inBlock = 1; break }
        }
        # Strip the // line comment (now guaranteed not inside a string).
        c = index(line, "//")
        if (c > 0) line = substr(line, 1, c - 1)

        # Hard bans: flag on the stripped line regardless of any marker.
        for (p = 1; p <= nh; p++)
            if (match(line, hard[p])) {
                printf("%s:%d: [hard-ban IO/nondeterminism] %s\n", FILENAME, FNR, raw) > "/dev/stderr"
                bad = 1
            }
        # Ambient-seam tokens: allowed ONLY when the RAW line carries the marker.
        hasMarker = (index(raw, marker) > 0)
        for (p = 1; p <= ns; p++)
            if (match(line, seam[p]) && !hasMarker) {
                printf("%s:%d: [ambient token outside an allowlisted seam] %s\n", FILENAME, FNR, raw) > "/dev/stderr"
                bad = 1
            }
    }
    END { if (bad) exit 1 }
'; then
    exit 0
fi

cat >&2 <<'EOF'

=======================================================================
core-purity lint FAILED: lib/DanTermCore must stay pure -- no IO, no
ambient nondeterminism. Two violation kinds (see the [tags] above):

  [hard-ban IO/nondeterminism] -- FileManager, Process(, DispatchSource,
    URLSession, ProcessInfo, import Darwin/Network, etc. Side-effecting
    or platform IO has no place in the pure core. Move the code to app/
    (runtime) or lib/DanTermSupport (portable side effects), as the
    earlier phases did, and call it from there.

  [ambient token outside an allowlisted seam] -- NSHomeDirectory, bare
    UUID(), or bare Date() used off-seam. The rule -- inject vs. ambient:

      Inject an explicit value when the result is SAVED (to disk),
      SENT (over IPC), or ASSERTED (in a test) -- anything a second
      execution will compare against. Leave it AMBIENT (read the real
      value) ONLY when the result is just SHOWN live and discarded.

    Thread the value through CoreEnv (env.newId()/now()/homeDirectory())
    or a `home:` parameter instead. The only legitimate ambient reads are
    the seams already marked `// core-purity: ambient-seam` (CoreEnv.live
    and the abbreviateHome/expandTilde leaf defaults). Add that marker
    ONLY when establishing a genuine new ambient seam -- and never to
    silence a hard-ban token (the marker does not exempt those).

  See the ADR subsection "When to inject an ambient input:
  save/send/assert vs. show" in
  docs/design/2026-05-28-pure-core-support-split.md.
=======================================================================
EOF
exit 1
