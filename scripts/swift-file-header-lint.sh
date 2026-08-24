#!/usr/bin/env bash
# Enforces the file comment that distinguishes each tracked Swift file from the
# declarations it contains.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/lint-rationale.sh
source "$SCRIPT_DIR/lib/lint-rationale.sh"

# Test seam: the self-test points discovery at a throwaway Git repository.
REPO_ROOT="${SWIFT_FILE_HEADER_LINT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
INVENTORY="$(mktemp)"
trap 'rm -f "$INVENTORY"' EXIT

if ! git -C "$REPO_ROOT" ls-files -z -- '*.swift' > "$INVENTORY"; then
    echo "swift-file-header-lint: tracked Swift discovery failed in $REPO_ROOT" >&2
    exit 1
fi

checked=0
violations=0
while IFS= read -r -d '' path; do
    checked=$((checked + 1))
    first_line=""
    IFS= read -r first_line < "$REPO_ROOT/$path" || true

    reason=""
    if [[ "$first_line" != "//"* ]]; then
        reason="line 1 is not an ordinary // file comment"
    elif [[ "$first_line" == "///"* ]]; then
        reason="line 1 starts declaration documentation (///), not a file comment"
    else
        comment_text="${first_line#//}"
        comment_text="$(printf '%s' "$comment_text" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        if [[ "$comment_text" == "$(basename "$path")" ]]; then
            reason="line 1 is only the file name, not a useful file comment"
        fi
    fi

    if [[ -n "$reason" ]]; then
        echo "swift-file-header-lint: $path: $reason" >&2
        violations=$((violations + 1))
    fi
done < "$INVENTORY"

if (( checked == 0 )); then
    echo "swift-file-header-lint: no tracked Swift files found in $REPO_ROOT" >&2
    exit 1
fi

if (( violations > 0 )); then
    lint_rationale <<'EOF'
Every tracked Swift file starts with an ordinary // file comment on line 1.
That comment explains the file's purpose. Keep declaration documentation (///)
with the declaration it documents, and replace filename-only Xcode banners with
a useful file comment. A // swift-tools-version: directive also satisfies the rule.
EOF
    exit 1
fi

echo "Swift file-header lint passed ($checked files)"
