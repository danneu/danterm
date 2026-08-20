#!/usr/bin/env bash
# Reject ambient process-identity and root-directory resolution outside the three
# named seams.
#
# Every filesystem path DanTerm keys by process identity -- the control socket, the
# recovery directory and its three files, the IPC audit log, the scrollback replay
# directory -- comes from one `DanTermInstancePaths` value that launch builds once and
# hands down. That is a structure a compiler cannot hold up on its own: any leaf can
# call `DanTermInstanceIdentity(bundle:)` and `FileManager.urls(for:.cachesDirectory...)`
# again and derive a directory of its own, the strings would agree, and every test
# would still pass -- until one of the six leaves disagreed and the lock, the
# checkpoints, and the audit log stopped co-locating. So the gate is structural:
# resolving the running process into an identity or into a user-domain root is
# allowed in three files and nowhere else.
#
# The three seams, and why each is one:
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
# Run with no target it sweeps app/, lib/, cli/, and tools/; run with targets it
# checks those alone, which is how the self-test proves each verdict without the
# real tree. Test targets are out of scope: a test names the instance and the roots
# it means, and the hermetic-paths fixture is how it does that.
set -euo pipefail

# Test seam: the self-test points the sweep at a fixture tree so both the stale-entry
# check and the allowlist are proven without the real tree. Nothing else sets this.
ROOT="${AMBIENT_IDENTITY_LINT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# Root-relative paths, matched as a path suffix so the self-test can stage the same
# layout under a temporary directory. The suffix includes the directories, so an
# allowlisted basename somewhere else earns nothing.
ALLOWLIST=(
    'app/LaunchInstancePaths.swift'
    'lib/DanTermCore/Sources/DanTermCore/CoreEnvironment.swift'
    'lib/DanTermProtocol/Sources/DanTermProtocol/SocketPath.swift'
)

if [[ "$#" -eq 0 ]]; then
    # An allowlist entry naming a file that no longer exists exempts nothing while
    # still reading as policy, so a rename must fail here rather than pass silently.
    stale=0
    for entry in "${ALLOWLIST[@]}"; do
        if [[ ! -f "$ROOT/$entry" ]]; then
            echo "ambient-identity-lint: the allowlist names '$entry', which is not a file" >&2
            stale=1
        fi
    done
    [[ "$stale" -eq 0 ]] || exit 1

    targets=()
    for dir in app lib cli tools; do
        [[ -d "$ROOT/$dir" ]] && targets+=("$ROOT/$dir")
    done
    set -- "${targets[@]}"
fi

# `DanTermInstanceIdentity(bundleIdentifier:)` and `(developmentSlot:)` are explicit
# inputs and stay legal everywhere; only the two bundle-reading forms are ambient.
PATTERN='^(?![[:space:]]*//).*(DanTermInstanceIdentity\(\)|DanTermInstanceIdentity\(bundle:|\.applicationSupportDirectory|\.cachesDirectory)'

hits="$(rg --pcre2 --glob '*.swift' --glob '!**/Tests/**' -n "$PATTERN" "$@" || true)"

violations=""
while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    file="${hit%%:*}"
    allowed=0
    for entry in "${ALLOWLIST[@]}"; do
        if [[ "$file" == *"/$entry" ]]; then
            allowed=1
            break
        fi
    done
    [[ "$allowed" -eq 1 ]] || violations+="$hit"$'\n'
done <<< "$hits"

if [[ -n "$violations" ]]; then
    printf '%s' "$violations" >&2
    cat >&2 <<'EOF'

=======================================================================
ambient-identity lint FAILED: the running process was resolved into an
identity or a root directory outside the three allowlisted seams.

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
    exit 1
fi

echo "ambient identity lint passed"
