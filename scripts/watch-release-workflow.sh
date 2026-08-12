#!/usr/bin/env bash
# Waits for GitHub to register the stable release run for a pushed commit, then
# follows that exact run until it succeeds or fails.
set -euo pipefail

commit="${1:?Usage: watch-release-workflow.sh COMMIT}"
run_id=""

echo "Waiting for release workflow..."
for ((attempt = 1; attempt <= 30; attempt++)); do
    run_id="$(gh run list \
        --workflow release-stable.yml \
        --commit "$commit" \
        --limit 1 \
        --json databaseId \
        --jq '.[0].databaseId')"
    [[ -n "$run_id" ]] && break
    (( attempt < 30 )) && sleep 2
done

if [[ -z "$run_id" ]]; then
    echo "Release workflow did not appear within 60 seconds" >&2
    exit 1
fi

exec gh run watch "$run_id" --exit-status
