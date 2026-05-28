#!/usr/bin/env bash
# Validate and print the Ghostty tag that build and CI callers are allowed to
# trust. This is the single parser for .ghostty-version.
set -euo pipefail

version_file="${GHOSTTY_VERSION_FILE:-./.ghostty-version}"

display_value() {
    local value="$1"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    if [ "${#value}" -gt 80 ]; then
        value="${value:0:80}..."
    fi
    printf '%s' "$value"
}

fail_value() {
    local reason="$1"
    local value="$2"
    printf 'Invalid Ghostty version in %s: %s: "%s"\n' \
        "$version_file" "$reason" "$(display_value "$value")" >&2
    exit 1
}

if [ ! -f "$version_file" ]; then
    printf 'Invalid Ghostty version file: file not found: %s\n' "$version_file" >&2
    exit 1
fi

raw=$(<"$version_file")

case "$raw" in
    *$'\n'*)
        fail_value "embedded newline" "$raw"
        ;;
esac

# Ghostty currently publishes vX.Y.Z tags; widen this only with an explicit
# review of prerelease/build-metadata inputs entering GitHub Actions env files.
if [[ ! "$raw" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail_value "does not match vX.Y.Z" "$raw"
fi

printf '%s\n' "$raw"
