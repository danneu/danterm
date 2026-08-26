#!/usr/bin/env bash
# Reject ambient resolution of the paths a DanTerm process owns -- its identity, its
# root directories, and its config file -- outside the seams named for each.
#
# Every filesystem path DanTerm keys by process identity -- the control socket, the
# recovery directory and its three files, the IPC audit log, the scrollback replay
# directory -- comes from one `DanTermInstancePaths` value that launch builds once and
# hands down. Which config file the process owns is the other half: one launch-resolved
# URL, decided from the `--config` argument or the standard per-user layout, and handed
# down beside the paths value. Neither is a structure a compiler can hold up on its own:
# any leaf can call `DanTermInstanceIdentity(bundle:)`, `FileManager.urls(for:
# .cachesDirectory...)`, or the config resolver again and derive a path of its own, the
# strings would agree, and every test would still pass -- until one leaf disagreed and
# the lock, the checkpoints, and the audit log stopped co-locating, or a dev slot wrote
# the user's config. So the gate is structural, and each rule carries its own allowlist:
# a seam is exempt from the rule it serves and from no other.
#
# Rule 1, the running process into an identity or a user-domain root:
#
#   app/LaunchInstancePaths.swift      Builds the process's paths value. This is the
#                                      resolution everything else is downstream of.
#   .../DanTermCore/CoreEnvironment.swift
#                                      `CoreEnv.live.instanceIdentity`, the
#                                      authorization seam behind the `quit` IPC
#                                      method. It answers "which instance am I?" for
#                                      privilege, not for a path.
#   .../DanTermProtocol/SocketPath.swift
#                                      `userControlSocketPath`, for the bare
#                                      executables -- the `danterm` CLI and the
#                                      identity tool -- that own no launch-resolved
#                                      value. Its identity stays an explicit input;
#                                      only the caches root is resolved here.
#
# Rule 2, the `DanTermConfigPaths` symbol -- asking which config file is standard:
#
#   .../DanTermSupport/DanTermConfigPaths.swift
#                                      Declares it.
#   app/LaunchInstancePaths.swift      The app's launch resolution, the default behind
#                                      an absent `--config`.
#   cli/main.swift                     The `danterm` CLI, a bare executable that owns
#                                      no launch-resolved value, so it names the home
#                                      its doctor probes share and derives the file
#                                      from it once.
#
# Rule 3, the standard config path spelled by hand. A literal is a resolution no
# rename reaches, so it is rejected even where the symbol is allowed:
#
#   .../DanTermSupport/DanTermConfigPaths.swift
#                                      The one place the layout is written.
#   cli/Doctor.swift                   Names the standard file in its report text.
#
# Run with no target it sweeps app/, lib/, cli/, and tools/; run with targets it
# checks those alone, which is how the self-test proves each verdict without the
# real tree. Test targets are out of scope: a test names the instance and the roots
# it means, and the hermetic-paths fixture is how it does that.
set -euo pipefail

# Test seam: the self-test points the sweep at a fixture tree so both the stale-entry
# check and the allowlists are proven without the real tree. Nothing else sets this.
ROOT="${AMBIENT_IDENTITY_LINT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# Root-relative paths, matched as a path suffix so the self-test can stage the same
# layout under a temporary directory. The suffix includes the directories, so an
# allowlisted basename somewhere else earns nothing. One list per rule, never a shared
# one: appending would license the config seam to resolve user-domain roots and the
# launch resolver to spell config strings.
IDENTITY_ALLOWLIST='app/LaunchInstancePaths.swift
lib/DanTermCore/Sources/DanTermCore/CoreEnvironment.swift
lib/DanTermProtocol/Sources/DanTermProtocol/SocketPath.swift'

CONFIG_SYMBOL_ALLOWLIST='lib/DanTermSupport/Sources/DanTermSupport/DanTermConfigPaths.swift
app/LaunchInstancePaths.swift
cli/main.swift'

CONFIG_PATH_ALLOWLIST='lib/DanTermSupport/Sources/DanTermSupport/DanTermConfigPaths.swift
cli/Doctor.swift'

# `DanTermInstanceIdentity(bundleIdentifier:)` and `(developmentSlot:)` are explicit
# inputs and stay legal everywhere; only the two bundle-reading forms are ambient.
IDENTITY_PATTERN='^(?![[:space:]]*//).*(DanTermInstanceIdentity\(\)|DanTermInstanceIdentity\(bundle:|\.applicationSupportDirectory|\.cachesDirectory)'
CONFIG_SYMBOL_PATTERN='^(?![[:space:]]*//).*DanTermConfigPaths'
CONFIG_PATH_PATTERN='^(?![[:space:]]*//).*\.config/danterm'

if [[ "$#" -eq 0 ]]; then
    # An allowlist entry naming a file that no longer exists exempts nothing while
    # still reading as policy, so a rename must fail here rather than pass silently.
    stale=0
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        if [[ ! -f "$ROOT/$entry" ]]; then
            echo "ambient-identity-lint: an allowlist names '$entry', which is not a file" >&2
            stale=1
        fi
    done <<< "$IDENTITY_ALLOWLIST"$'\n'"$CONFIG_SYMBOL_ALLOWLIST"$'\n'"$CONFIG_PATH_ALLOWLIST"
    [[ "$stale" -eq 0 ]] || exit 1

    targets=()
    for dir in app lib cli tools; do
        [[ -d "$ROOT/$dir" ]] && targets+=("$ROOT/$dir")
    done
    set -- "${targets[@]}"
fi

# Prints the hits for one rule that its own allowlist does not exempt. Takes the
# pattern and the allowlist first so the sweep targets stay "$@".
violations_for() {
    local pattern="$1" allowlist="$2"
    shift 2
    local hits hit file entry allowed found=""
    hits="$(rg --pcre2 --glob '*.swift' --glob '!**/Tests/**' -n "$pattern" "$@" || true)"
    while IFS= read -r hit; do
        [[ -z "$hit" ]] && continue
        file="${hit%%:*}"
        allowed=0
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            if [[ "$file" == *"/$entry" ]]; then
                allowed=1
                break
            fi
        done <<< "$allowlist"
        [[ "$allowed" -eq 1 ]] || found+="$hit"$'\n'
    done <<< "$hits"
    printf '%s' "$found"
}

failed=0

identity_violations="$(violations_for "$IDENTITY_PATTERN" "$IDENTITY_ALLOWLIST" "$@")"
if [[ -n "$identity_violations" ]]; then
    failed=1
    printf '%s\n' "$identity_violations" >&2
    cat >&2 <<'EOF'

=======================================================================
ambient-identity lint FAILED: the running process was resolved into an
identity or a root directory outside the allowlisted seams.

Take the paths you need as a `DanTermInstancePaths` value instead. The
app builds one in app/LaunchInstancePaths.swift and hands it to the
delegate, the runtime, and the IPC server; every path keyed by the
instance is a property on it. A leaf that resolves its own identity or
its own root re-opens the split this value closed: the session lock,
both checkpoint tiers, and the IPC audit log would co-locate only by
coincidence, and no test could redirect them.

If you need an identity for privilege rather than for a path, that is
`CoreEnv.live.instanceIdentity` -- inject it, do not re-derive it. See
"The identity seam" in
docs/design/2026-05-28-pure-core-support-split.md.
=======================================================================
EOF
fi

config_symbol_violations="$(violations_for "$CONFIG_SYMBOL_PATTERN" "$CONFIG_SYMBOL_ALLOWLIST" "$@")"
if [[ -n "$config_symbol_violations" ]]; then
    failed=1
    printf '%s\n' "$config_symbol_violations" >&2
    cat >&2 <<'EOF'

=======================================================================
ambient-identity lint FAILED: the standard config file was resolved
outside the launch seams.

Which config file a process owns is a launch decision, not an ambient
fact. The app resolves it once in app/LaunchInstancePaths.swift, from
the `--config` argument or the standard per-user layout, and hands the
URL down; take it as an input instead of asking again. A leaf that
re-resolves it points a dev slot or a benchmark harness at the user's
own config file, which is exactly what the launch argument exists to
prevent.
=======================================================================
EOF
fi

config_path_violations="$(violations_for "$CONFIG_PATH_PATTERN" "$CONFIG_PATH_ALLOWLIST" "$@")"
if [[ -n "$config_path_violations" ]]; then
    failed=1
    printf '%s\n' "$config_path_violations" >&2
    cat >&2 <<'EOF'

=======================================================================
ambient-identity lint FAILED: the standard config path was spelled by
hand.

The layout lives in one place,
lib/DanTermSupport/Sources/DanTermSupport/DanTermConfigPaths.swift. A
hand-written copy is a second answer that no rename reaches and no test
can redirect. Compose the path through that seam, or take the resolved
file as an input.
=======================================================================
EOF
fi

[[ "$failed" -eq 0 ]] || exit 1

echo "ambient identity lint passed"
