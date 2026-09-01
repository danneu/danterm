#!/usr/bin/env bash
# Reject checkpoint payload assembly in the app runtime.
#
# A recovery checkpoint's cost is projecting and encoding every pane's scrollback, and the only
# thing keeping that off the main thread is where the code lives: `app/` captures, and
# DanTermCore's deferred capture `encoder()` does the rest on the checkpoint queue.
# Nothing in the type system stops a future edit from grafting or encoding at the capture site
# instead -- the bytes would be identical and every unit test would still pass, while the UI
# froze again. So the gate is structural: the runtime may build a capture and hand its encoder
# to the writer, but the stages themselves (graft, truncate, init-file assembly, JSON encoding)
# must not appear where it captures.
#
# The rule is about a place, not a file, so it sweeps the whole runtime tree. `app/AppRuntime.swift`
# is 1800+ lines with three capture sites; splitting it is a plausible refactor, and a rule scoped
# to that one name would follow none of the pieces. The stage spellings and the encoder-handoff
# rule are unique enough to the checkpoint path to sweep with no false positives.
#
# `JSONEncoder(` is the exception: the runtime encodes JSON for unrelated reasons (todo payloads,
# provenance), so a tree-wide ban would fail on code that has nothing to do with a checkpoint.
# It stays scoped to the file that captures, which is therefore the one path here a rename could
# disarm -- `lint_resolve_targets` is what stops that, by failing red when a named target resolves
# to nothing.
#
# `truncateScrollback` is banned here rather than exempted at its one predicate call site --
# `hasCheckpointableScrollback` asks that question by name, so the raw cut has no business in
# the runtime at all.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/lint-targets.sh
source "$SCRIPT_DIR/lib/lint-targets.sh"

ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ "$#" -eq 0 ]]; then
    set -- "$ROOT/app" "$ROOT/app/AppRuntime.swift"
fi
if [[ "$#" -ne 2 ]]; then
    echo "usage: checkpoint-off-main-lint.sh [<runtime-tree> <capture-site>]" >&2
    exit 2
fi

lint_resolve_targets "checkpoint-off-main-lint" '*.swift' "$1"
RUNTIME_FILES=("${LINT_TARGET_FILES[@]}")
lint_resolve_targets "checkpoint-off-main-lint" '*.swift' "$2"
CAPTURE_FILES=("${LINT_TARGET_FILES[@]}")

STAGE_PATTERN='^(?![[:space:]]*//).*(graftScrollback\(|truncateScrollback\(|toInitFile\(|encodeScrollbackSidecar\()'

if rg --pcre2 -n "$STAGE_PATTERN" "${RUNTIME_FILES[@]}"; then
    echo "checkpoint-off-main-lint: checkpoint payload assembled in the app runtime" >&2
    echo "  build a checkpoint capture and pass capture.encoder() to CheckpointWriter instead" >&2
    exit 1
fi

if rg --pcre2 -n '^(?![[:space:]]*//).*JSONEncoder\(' "${CAPTURE_FILES[@]}"; then
    echo "checkpoint-off-main-lint: the checkpoint is encoded where the runtime captures it" >&2
    echo "  build a checkpoint capture and pass capture.encoder() to CheckpointWriter instead" >&2
    exit 1
fi

# Handing the encoder to a writer is the whole point; keeping it in a local is how the runtime
# ends up calling it, which runs the encode on the main thread with the stages still off-site,
# so the rule above sees nothing wrong. State-export did exactly that. The gate is therefore
# where the encoder GOES: it must be an argument on the spot, so `.encoder(` and the `encode:`
# label it feeds have to appear together on one line.
ENCODER_PATTERN='^(?![[:space:]]*//)(?!.*encode:).*\.encoder\('

if rg --pcre2 -n "$ENCODER_PATTERN" "${RUNTIME_FILES[@]}"; then
    echo "checkpoint-off-main-lint: a checkpoint encoder is bound here instead of handed off" >&2
    echo "  pass it straight in as 'encode: capture.encoder()' -- a local invites a main-thread" >&2
    echo "  encode, which is the cost the deferred encoder exists to avoid" >&2
    exit 1
fi

echo "checkpoint off-main lint passed"
