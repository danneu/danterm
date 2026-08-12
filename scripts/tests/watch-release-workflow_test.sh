#!/usr/bin/env bash
# Verifies that release monitoring waits for the run attached to the pushed
# commit, then watches that exact run and preserves the workflow's exit status.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$GH_CALLS"
if [[ "$1 $2" == "run list" ]]; then
    count=0
    [[ ! -f "$GH_COUNT" ]] || count="$(<"$GH_COUNT")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$GH_COUNT"
    (( count >= 2 )) && printf '4242\n'
    exit 0
fi

[[ "$1 $2 $3 $4" == "run watch 4242 --exit-status" ]] || exit 90
exit "${GH_WATCH_STATUS:-0}"
EOF
chmod +x "$TMP/bin/gh"
cat >"$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/sleep"

export GH_CALLS="$TMP/calls"
export GH_COUNT="$TMP/count"
export PATH="$TMP/bin:$PATH"

"$ROOT/scripts/watch-release-workflow.sh" deadbeef

grep -qF 'run list --workflow release-stable.yml --commit deadbeef --limit 1 --json databaseId --jq .[0].databaseId' "$GH_CALLS"
grep -qF 'run watch 4242 --exit-status' "$GH_CALLS"

rm -f "$GH_CALLS" "$GH_COUNT"
export GH_WATCH_STATUS=17
if "$ROOT/scripts/watch-release-workflow.sh" cafebabe; then
    echo "workflow failure must make release monitoring fail" >&2
    exit 1
else
    status=$?
fi
[[ "$status" == 17 ]] || {
    echo "expected workflow exit status 17, got $status" >&2
    exit 1
}

release_recipe="$(just --justfile "$ROOT/justfile" --working-directory "$ROOT" --dry-run release patch 2>&1)"
[[ "$release_recipe" == *'./scripts/watch-release-workflow.sh "$(git rev-parse HEAD)"'* ]] || {
    echo "the release recipe does not watch the workflow for its release commit" >&2
    exit 1
}
