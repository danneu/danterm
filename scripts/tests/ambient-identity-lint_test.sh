#!/usr/bin/env bash
# Self-test for the ambient-identity gate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../ambient-identity-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

mkdir -p "$TMP/allowed/app" \
    "$TMP/allowed/lib/DanTermCore/Sources/DanTermCore" \
    "$TMP/allowed/lib/DanTermProtocol/Sources/DanTermProtocol" \
    "$TMP/denied/app"

cat > "$TMP/allowed/app/LaunchInstancePaths.swift" <<'SWIFT'
identity: DanTermInstanceIdentity(bundle: .main),
applicationSupportRoot: fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
cachesRoot: fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
SWIFT
cat > "$TMP/allowed/lib/DanTermCore/Sources/DanTermCore/CoreEnvironment.swift" <<'SWIFT'
instanceIdentity: { DanTermInstanceIdentity(bundle: .main) }
SWIFT
cat > "$TMP/allowed/lib/DanTermProtocol/Sources/DanTermProtocol/SocketPath.swift" <<'SWIFT'
cachesRoot: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
SWIFT
cat > "$TMP/allowed/app/Runtime.swift" <<'SWIFT'
let identity = DanTermInstanceIdentity(bundleIdentifier: "com.danneu.danterm")
let slot = DanTermInstanceIdentity(developmentSlot: 3)
let recovery = paths.applicationSupportRoot.appendingPathComponent("Recovery")
// DanTermInstanceIdentity(bundle: .main) and .cachesDirectory belong to the launch resolver.
SWIFT
"$LINT" "$TMP/allowed" >/dev/null || fail "the allowlisted seams and explicit inputs should pass"

for construct in \
    'let identity = DanTermInstanceIdentity()' \
    'let identity = DanTermInstanceIdentity(bundle: .main)' \
    'let identity = DanTermInstanceIdentity(bundle: someBundle)' \
    'let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]' \
    'let root = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]'
do
    printf '%s\n' "$construct" > "$TMP/denied/app/Runtime.swift"
    if "$LINT" "$TMP/denied" >/dev/null 2>&1; then
        fail "ambient resolution should fail: $construct"
    fi
done

# An allowlisted basename earns nothing outside the path the allowlist names: the
# exemption is the file, not the name.
printf 'let identity = DanTermInstanceIdentity(bundle: .main)\n' \
    > "$TMP/denied/app/CoreEnvironment.swift"
if "$LINT" "$TMP/denied/app/CoreEnvironment.swift" >/dev/null 2>&1; then
    fail "an allowlisted basename at the wrong path should fail"
fi

# The no-target sweep finds its own targets under the root and exempts the three
# seams it names.
rm -f "$TMP/denied/app/CoreEnvironment.swift" "$TMP/denied/app/Runtime.swift"
AMBIENT_IDENTITY_LINT_ROOT="$TMP/allowed" "$LINT" >/dev/null \
    || fail "the sweep should pass a tree whose only ambient reads are the named seams"

# An allowlist entry that no longer names a file exempts nothing while still reading
# as policy, so the sweep must reject it rather than pass a tree it cannot vouch for.
mv "$TMP/allowed/app/LaunchInstancePaths.swift" "$TMP/allowed/app/Renamed.swift"
if AMBIENT_IDENTITY_LINT_ROOT="$TMP/allowed" "$LINT" >/dev/null 2>&1; then
    fail "a renamed allowlist entry should fail the sweep"
fi

echo "ambient identity lint self-test passed"
