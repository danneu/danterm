#!/usr/bin/env bash
# Reject checkpoint payload assembly in the app runtime.
#
# A recovery checkpoint's cost is projecting and encoding every pane's scrollback, and the only
# thing keeping that off the main thread is where the code lives: `app/` captures, and
# DanTermCore's deferred `CheckpointCapture.encoder()` does the rest on the checkpoint queue.
# Nothing in the type system stops a future edit from grafting or encoding at the capture site
# instead -- the bytes would be identical and every unit test would still pass, while the UI
# froze again. So the gate is structural: the runtime may build a capture and hand its encoder
# to the writer, but the stages themselves (graft, truncate, init-file assembly, JSON encoding)
# must not appear where it captures.
#
# `truncateScrollback` is banned here rather than exempted at its one predicate call site --
# `hasCheckpointableScrollback` asks that question by name, so the raw cut has no business in
# the runtime at all.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$#" -eq 0 ]]; then
    set -- "$ROOT/app/AppRuntime.swift"
fi

PATTERN='^(?![[:space:]]*//).*(graftScrollback\(|truncateScrollback\(|toInitFile\(|JSONEncoder\()'

if rg --pcre2 --glob '*.swift' -n "$PATTERN" "$@"; then
    echo "checkpoint-off-main-lint: checkpoint payload assembled where the runtime captures it" >&2
    echo "  build a CheckpointCapture and pass capture.encoder() to CheckpointWriter instead" >&2
    exit 1
fi

echo "checkpoint off-main lint passed"
