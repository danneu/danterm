#!/usr/bin/env bash
# Signs one app bundle nested-code-first and re-verifies it against its layout.
#
# Signing is the last step that can change a bundle before it ships, so the
# verification belongs here and not in each caller: a workflow that signs cannot
# forget to check what it produced. Extra codesign arguments (hardened runtime,
# entitlements) are passed through, since they differ per caller while the order
# and the verification do not.
set -euo pipefail

if [[ $# -lt 4 ]]; then
    echo "usage: sign-app-bundle.sh <app-bundle> <layout-json> <repo-root>" \
        "<signing-identity> [codesign-argument ...]" >&2
    exit 2
fi

bundle="$1"
layout_plan="$2"
repo_root="$3"
identity="$4"
shift 4
script_dir="$(cd "$(dirname "$0")" && pwd)"

# Nested code must carry its own signature before the container seals it, or the
# app's signature covers a helper signature that is then replaced. The nested set
# is read from the layout -- every built product except the main executable, which
# the container's own signature covers -- so signing needs no second path list.
nested_paths=$(python3 - "$layout_plan" <<'PY'
import json
import sys

try:
    with open(sys.argv[1]) as stream:
        plan = json.load(stream)
except (OSError, json.JSONDecodeError) as error:
    print(f"sign-app-bundle: cannot read layout plan {sys.argv[1]}: {error}", file=sys.stderr)
    raise SystemExit(1)

paths = [
    entry["path"]
    for entry in plan["entries"]
    if entry["source"]["kind"] == "product" and entry["id"] != "appExecutable"
]
# Deepest first, so a nested bundle is sealed before anything that contains it.
for path in sorted(paths, key=lambda value: (-value.count("/"), value)):
    print(path)
PY
)

while IFS= read -r relative_path; do
    [[ -n "$relative_path" ]] || continue
    codesign --force --sign "$identity" "$@" "$bundle/$relative_path"
done <<< "$nested_paths"

codesign --force --deep --sign "$identity" "$@" "$bundle"
codesign --verify --deep --strict --verbose=2 "$bundle"
PATH="$PATH:$script_dir" verify-bundle-layout.sh "$bundle" "$layout_plan" "$repo_root"
