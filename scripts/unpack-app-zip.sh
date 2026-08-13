#!/usr/bin/env bash
# Unpacks a distributed app ZIP and re-verifies the round-tripped bundle.
#
# ZIP transport is the last thing that touches a released bundle, and an archive
# that drops a file or a signature still unzips cleanly. Unpacking and verifying
# are one step here so no caller can round-trip a bundle without checking it.
set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "usage: unpack-app-zip.sh <zip> <destination-directory> <layout-json> <repo-root>" >&2
    exit 2
fi

zip_path="$1"
destination="$2"
layout_plan="$3"
repo_root="$4"
script_dir="$(cd "$(dirname "$0")" && pwd)"

if [[ -e "$destination" && ( -L "$destination" || ! -d "$destination" ) ]]; then
    echo "unpack-app-zip: destination is not a removable directory: $destination" >&2
    exit 1
fi
rm -rf "$destination"
mkdir -p "$destination"
unzip -q "$zip_path" -d "$destination"

# The bundle is found rather than named: the archive itself decides what it holds,
# and anything other than one app is a packaging mistake worth failing on.
shopt -s nullglob
bundles=("$destination"/*.app)
shopt -u nullglob
if [[ ${#bundles[@]} -ne 1 ]]; then
    echo "unpack-app-zip: expected exactly one app bundle in $zip_path;" \
        "found ${#bundles[@]}" >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "${bundles[0]}"
PATH="$PATH:$script_dir" verify-bundle-layout.sh "${bundles[0]}" "$layout_plan" "$repo_root"
