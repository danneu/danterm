#!/usr/bin/env bash
# Reject creating a file or a directory in the running product outside the private-write
# seam.
#
# Every artifact this process writes -- the recovery checkpoints and their directory, the
# session lock, the state export, the scrollback replay files, the IPC audit log and its
# rotation, the control socket and its replacement lock -- holds terminal content or names
# something that does. `PrivateFile` creates all of them, and it states the mode itself
# instead of inheriting whatever umask the process was launched with.
#
# That is a structure no compiler can hold up. `Data.write(options: .atomic)` and
# `FileManager.createDirectory` are one line each and always available, so the next writer
# reintroduces a world-readable scrollback file by simply not knowing the seam exists. That
# is exactly how the tree reached the state the audit found: of fifteen creation sites, two
# set a mode, and the three that did disagreed on how. So the gate is structural: creating
# a file or a directory is allowed in the seam and in the four files the allowlist names.
#
# Out of the sweep, and why:
#
#   tools/           Source-maintenance tools that rewrite git-tracked files in the working
#                    tree. They preserve the modes they find; they are not the product.
#   ios/             A different product with its own container, not this process.
#   Tests/           A test names the directory it writes into, and a fixture that has to
#                    stage a 0644 file is how the seam's narrowing is proven at all.
#   TestSupport/     Standalone harness executables that write into a directory their caller
#                    names. Same reason as Tests/: run by the suite, not shipped.
#
# Run with no target it sweeps app/, lib/, and cli/; run with targets it checks those alone,
# which is how the self-test proves each verdict without the real tree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/lint-rationale.sh
source "$SCRIPT_DIR/lib/lint-rationale.sh"

# Test seam: the self-test points the sweep at a fixture tree so both the stale-entry check
# and the allowlist are proven without the real tree. Nothing else sets this.
ROOT="${PRIVATE_FILE_MODE_LINT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Root-relative paths, matched as a path suffix so the self-test can stage the same layout
# under a temporary directory. The suffix includes the directories, so an allowlisted
# basename somewhere else earns nothing.
#
#   PrivateFile.swift      The seam, in the package of its own that both products depend on.
#                          It is the one place that creates anything, so it is the one place
#                          the raw syscalls belong.
#   DanTermConfigStore.swift
#                          The config file and its directory: the user edits them by hand and
#                          they hold no terminal content, so they keep umask-default creation.
#   CLIPathInstaller.swift The `danterm` symlink, which the user inspects on their PATH. Its
#                          privileged branch also shells out to `/bin/mkdir -p` under
#                          osascript to make a directory in the user's own bin path; that
#                          spelling is a string, so no text search sees it either way.
#   TailnetListener.swift  An AF_INET bind. It creates no filesystem node, so no mode applies
#                          -- it is here only because `Darwin.bind(` cannot tell the two
#                          address families apart on one line.
ALLOWLIST=(
    'lib/PrivateFile/Sources/PrivateFile/PrivateFile.swift'
    'app/DanTermConfigStore.swift'
    'lib/DanTermSupport/Sources/DanTermSupport/CLIPathInstaller.swift'
    'lib/DanTermSupport/Sources/DanTermSupport/TailnetListener.swift'
)

if [[ "$#" -eq 0 ]]; then
    # An allowlist entry naming a file that no longer exists exempts nothing while still
    # reading as policy, so a rename must fail here rather than pass silently.
    stale=0
    for entry in "${ALLOWLIST[@]}"; do
        if [[ ! -f "$ROOT/$entry" ]]; then
            echo "private-file-mode-lint: the allowlist names '$entry', which is not a file" >&2
            stale=1
        fi
    done
    [[ "$stale" -eq 0 ]] || exit 1

    targets=()
    for dir in app lib cli; do
        [[ -d "$ROOT/$dir" ]] && targets+=("$ROOT/$dir")
    done
    set -- "${targets[@]}"
fi

# The creation spellings this codebase uses. Two properties are worth stating:
#
# The `PrivateFile.` lookbehind is what makes a routed call legal. A caller is exempt
# because of how it spells the call, not because the lint skips its line -- so a raw
# `FileManager` create sitting beside a routed one is still caught.
#
# The `async:` lookahead keeps `CheckpointWriter.write(to:async:encode:)` legal. That method
# is a seam caller, not a create; only Foundation's `Data`/`String` writes, which have no
# such label, are the spelling being banned.
#
# This is a regression guard over the spellings in the tree, not a proof: `copyItem`, a
# hand-rolled `syscall`, or an API Foundation adds later would pass it.
PATTERN='^(?![[:space:]]*//)(?!.*\basync:).*((?<!PrivateFile\.)\bcreateDirectory\(|(?<!PrivateFile\.)\bcreateFile\(|\bcreateSymbolicLink\(|\.write\(to(File)?:|\bO_CREAT\b|\bmkdir\(|\bDarwin\.bind\()'

hits="$(rg --pcre2 --glob '*.swift' --glob '!**/Tests/**' --glob '!**/TestSupport/**' \
    -n "$PATTERN" "$@" || true)"

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
    lint_rationale <<'EOF'
private-file-mode lint FAILED: the running product created a file or a
directory outside the private-write seam.

A file created here inherits its mode from whatever umask launched the
process, so it lands world-readable on a default umask -- and everything
this product writes either holds a pane's scrollback or names something
that does. An atomic Foundation write cannot be corrected afterwards
either: it renames a umask-default sibling into place, so the content is
already nameable at the wrong mode before any chmod could run.

Route it through `PrivateFile` instead:
`createDirectory(at:)`, `writeAtomically(_:to:)`, `createFile(_:at:)`,
`openForAppending(at:)`, `openForLocking(at:)`,
`createEmptyFile(atPath:)`, `bindSocket(at:)`. Each states its mode
before the artifact is reachable under the name a reader would use.

An artifact the user edits or inspects directly, and that carries no
terminal content, may stay umask-default -- but it says so at its call
site and it joins the allowlist at the top of this script with the
reason. There are three today: the config file, its directory, and the
CLI symlink. See "The same identity keys the paths, and it is resolved
once" in docs/design/2026-05-28-pure-core-support-split.md.
EOF
    exit 1
fi

echo "private file mode lint passed"
