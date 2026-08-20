#!/usr/bin/env bash
# Local purity lint. Run with no target it sweeps every first-party module; run
# with one it checks that module alone.
#
# The sweep is the entry point the gate uses, and it is what makes coverage total.
# The gate used to list eleven targets by hand while the tree held thirty-five
# modules, so twenty-seven went unchecked and the step list gave no sign of it.
# Now the lint derives every package from shared tracked-manifest discovery, then
# visits every non-test target those manifests declare, at whatever path each
# declares. A module nobody names in policy is checked anyway; a policy entry
# whose module is gone fails, and so does a declared target with no directory,
# because an entry that checks nothing still reads as coverage. See
# docs/design/2026-05-28-pure-core-support-split.md.
#
# Profiles, plus an opt-in import-free gate:
#
#   pure     (the default for a single-target run)
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
#   portable (the sweep's floor for an undeclared module)
#            Bans Cocoa/AppKit/SwiftUI imports -- and nothing else.
#            DanTermSupport legitimately performs portable IO (FileManager,
#            Process, DispatchSource, ProcessInfo), so the pure-tier IO bans do
#            NOT apply here. The profiles are deliberately kept separate.
#   ui       Sweep-only. Declares a module that legitimately draws with a
#            platform toolkit, so no check runs. It is an exemption, which is why
#            it must be written down rather than inferred from an absent target.
#   --forbid-imports
#            Rejects every real Swift import, including Foundation. Import-free
#            modules use this alongside the pure profile so they cannot silently
#            acquire a toolchain- or OS-versioned framework.
#   --allow-imports <module[,module...]>
#            Rejects every real Swift import except the exact named modules.
#            TerminalCore and TerminalRenderPlanning use this alongside the pure
#            profile for their exact package dependencies without acquiring
#            framework imports.
#
# The regex denylist is a heuristic regression guard, not the proof of purity:
# the real proof is structural (the nested test packages compile core/support
# with no cross-module IO dependency). The lint keeps it that way.
#
# The token pass strips comments and string literals before tokenizing (so a pure
# comment mentioning FileManager/DispatchSourceTimer does not false-positive) but
# tests the allowlist marker on the RAW, unstripped line -- the marker is itself a
# `//` comment, so stripping first would erase it and trip every seam. The import
# rules are line-anchored and need no stripping. The self-test
# (scripts/tests/core-purity-lint_test.sh) pins every edge case in both directions.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Test seams: the self-test points the sweep at a fixture tree of module
# directories and a fixture policy file, so each verdict is proven without the
# real tree. Nothing else sets these.
SWEEP_ROOT="${CORE_PURITY_LINT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
POLICY_FILE="${CORE_PURITY_LINT_POLICY:-$SCRIPT_DIR/core-purity-policy.conf}"

# Checks every first-party module in one pass, at the policy file's profile or the
# portable floor.
#
# The sweep, not the policy file, is what makes coverage total: it enumerates the
# tree and looks each module up, so a module nobody declared is checked anyway. The
# gate used to name eleven targets by hand against thirty-five modules, and the
# twenty-seven it missed were silent. A policy entry naming a module that no longer
# exists fails too -- an entry that checks nothing reads as coverage.
run_sweep() {
    local status=0 target_list kind module rel spec profile rule

    while read -r rel _; do
        [[ -z "$rel" || "$rel" == \#* ]] && continue
        if [[ ! -d "$SWEEP_ROOT/$rel" ]]; then
            echo "core-purity-lint: $POLICY_FILE names '$rel', which is not a module directory" >&2
            status=1
        fi
    done < "$POLICY_FILE"

    # The manifests decide what a module is. A target declared at any path -- the
    # root package's `app` and `cli`, a TestSupport/ helper -- is visited; a
    # directory no manifest claims compiles into nothing and is not. A declared
    # target whose directory is missing fails for the same reason a stale policy
    # entry does: it reads as coverage while checking nothing. Test targets are
    # not modules and may import anything.
    target_list="$(python3 "$SCRIPT_DIR/manifest_targets.py" --targets --root "$SWEEP_ROOT")" \
        || return 1
    while IFS=$'\t' read -r kind rel; do
        [[ "$kind" == "testTarget" ]] && continue
        module="$SWEEP_ROOT/$rel"
        if [[ ! -d "$module" ]]; then
            echo "core-purity-lint: a manifest declares a target at '$rel', which is not a directory" >&2
            status=1
            continue
        fi
        spec="$(awk -v want="$rel" '$1 == want { $1 = ""; sub(/#.*/, ""); print; exit }' "$POLICY_FILE")"
        read -r profile rule <<<"$spec"
        [[ -n "$profile" ]] || profile="portable"

        case "$profile" in
            ui) continue ;;
            pure | portable) ;;
            *)
                echo "core-purity-lint: $rel declares unknown profile '$profile'" >&2
                status=1
                continue
                ;;
        esac

        case "$rule" in
            "") "$0" --profile "$profile" "$module" || status=1 ;;
            forbid-imports) "$0" --profile "$profile" --forbid-imports "$module" || status=1 ;;
            allow=*) "$0" --profile "$profile" --allow-imports "${rule#allow=}" "$module" || status=1 ;;
            *)
                echo "core-purity-lint: $rel declares unknown import rule '$rule'" >&2
                status=1
                ;;
        esac
    done <<< "$target_list"

    if [[ "$status" -eq 0 ]]; then
        echo "core-purity lint: every module checked (portable floor, policy in ${POLICY_FILE#"$SWEEP_ROOT"/})"
    fi
    return "$status"
}

PROFILE="pure"
TARGET=""
FORBID_IMPORTS=0
ALLOWED_IMPORTS=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) PROFILE="${2:?--profile needs a value}"; shift 2 ;;
        --profile=*) PROFILE="${1#*=}"; shift ;;
        --forbid-imports) FORBID_IMPORTS=1; shift ;;
        --allow-imports) ALLOWED_IMPORTS="${2:?--allow-imports needs a value}"; shift 2 ;;
        --allow-imports=*) ALLOWED_IMPORTS="${1#*=}"; shift ;;
        *) TARGET="$1"; shift ;;
    esac
done
# No target means the whole tree. A flag with no target would silently apply to
# every module, so it is an error rather than a sweep with a surprising profile.
if [[ -z "$TARGET" ]]; then
    if [[ "$PROFILE" != "pure" || "$FORBID_IMPORTS" -eq 1 || -n "$ALLOWED_IMPORTS" ]]; then
        echo "core-purity-lint: flags need a target; the sweep takes its profiles from $POLICY_FILE" >&2
        exit 2
    fi
    run_sweep
    exit $?
fi

if [[ "$FORBID_IMPORTS" -eq 1 && -n "$ALLOWED_IMPORTS" ]]; then
    echo "core-purity-lint: --forbid-imports and --allow-imports are mutually exclusive" >&2
    exit 2
fi

case "$PROFILE" in
    pure|portable) ;;
    *) echo "core-purity-lint: unknown profile '$PROFILE' (expected pure|portable)" >&2; exit 2 ;;
esac

# Import-free modules may use the Swift standard library without an import, but
# no explicit module dependency. Line anchoring ignores commented-out examples.
if [[ "$FORBID_IMPORTS" -eq 1 ]] &&
   grep -rnE '^[[:space:]]*((@[^[:space:]]+|public|internal|package|private|fileprivate)[[:space:]]+)*import[[:space:]]+[[:alnum:]_][[:alnum:]_.]*([^[:alnum:]_]|$)' "$TARGET"; then
    echo "Swift import found in $TARGET (module must remain import-free)" >&2
    exit 1
fi

if [[ -n "$ALLOWED_IMPORTS" ]]; then
    # Single-quoted for the same reason as the token pass below: the $0/FILENAME
    # inside belong to awk, not to bash.
    # shellcheck disable=SC2016
    if ! find "$TARGET" -name '*.swift' -print0 | xargs -0 awk -v allowed="$ALLOWED_IMPORTS" '
    BEGIN {
        count = split(allowed, modules, ",")
        for (i = 1; i <= count; i++) allowedModule[modules[i]] = 1
        bad = 0
    }
    {
        line = $0
        if (line ~ /^[[:space:]]*((@[^[:space:]]+|public|internal|package|private|fileprivate)[[:space:]]+)*import[[:space:]]+[[:alnum:]_][[:alnum:]_.]*([^[:alnum:]_]|$)/) {
            sub(/^[[:space:]]*((@[^[:space:]]+|public|internal|package|private|fileprivate)[[:space:]]+)*import[[:space:]]+/, "", line)
            module = line
            sub(/[^[:alnum:]_.].*$/, "", module)
            if (!(module in allowedModule)) {
                printf("%s:%d: disallowed Swift import %s\n", FILENAME, FNR, module) > "/dev/stderr"
                bad = 1
            }
        }
    }
    END { if (bad) exit 1 }
'; then
        echo "Swift import outside allowlist '$ALLOWED_IMPORTS' found in $TARGET" >&2
        exit 1
    fi
fi

# --- Cocoa/AppKit/SwiftUI import rule (both profiles). Line-anchored; tolerates
# leading whitespace + an optional @<attr>; the trailing non-identifier guard
# stops `import CocoaLumberjack`/`CocoaAsyncSocket` from false-positiving. ---
if grep -rnE '^[[:space:]]*(@[^[:space:]]+[[:space:]]+)?import[[:space:]]+(Cocoa|AppKit|SwiftUI)([^[:alnum:]_]|$)' "$TARGET"; then
    echo "Cocoa/AppKit/SwiftUI import found in $TARGET (must stay UI-free)" >&2
    exit 1
fi

if [[ "$PROFILE" == "portable" ]]; then
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
