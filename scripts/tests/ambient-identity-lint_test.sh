#!/usr/bin/env bash
# Self-test for the ambient-identity gate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../ambient-identity-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

mkdir -p "$TMP/allowed/app" \
    "$TMP/allowed/cli" \
    "$TMP/allowed/lib/DanTermCore/Sources/DanTermCore" \
    "$TMP/allowed/lib/DanTermProtocol/Sources/DanTermProtocol" \
    "$TMP/allowed/lib/DanTermSupport/Sources/DanTermSupport" \
    "$TMP/allowed/tools/DanTermLaunchFactsTool" \
    "$TMP/denied/app"

cat > "$TMP/allowed/app/LaunchInstancePaths.swift" <<'SWIFT'
identity: DanTermInstanceIdentity(bundle: .main),
applicationSupportRoot: fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
cachesRoot: fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
configFile: DanTermConfigPaths.standardConfigFilePath(home: home)
SWIFT
cat > "$TMP/allowed/lib/DanTermSupport/Sources/DanTermSupport/DanTermConfigPaths.swift" <<'SWIFT'
enum DanTermConfigPaths {
    static func standardConfigFilePath(home: String) -> String {
        "\(home)/.config/danterm/config.json"
    }
}
SWIFT
cat > "$TMP/allowed/cli/main.swift" <<'SWIFT'
let configFilePath = DanTermConfigPaths.standardConfigFilePath(home: home.path)
SWIFT
cat > "$TMP/allowed/tools/DanTermLaunchFactsTool/main.swift" <<'SWIFT'
"standardConfigPath": DanTermConfigPaths.standardConfigFilePath(home: home.path),
SWIFT
cat > "$TMP/allowed/cli/Doctor.swift" <<'SWIFT'
message: "No font.family set in ~/.config/danterm/config.json."
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
let config = launch.configFileURL
// DanTermInstanceIdentity(bundle: .main) and .cachesDirectory belong to the launch resolver.
// DanTermConfigPaths and ~/.config/danterm belong to the launch and CLI seams.
SWIFT
"$LINT" "$TMP/allowed" >/dev/null || fail "the allowlisted seams and explicit inputs should pass"

for construct in \
    'let identity = DanTermInstanceIdentity()' \
    'let identity = DanTermInstanceIdentity(bundle: .main)' \
    'let identity = DanTermInstanceIdentity(bundle: someBundle)' \
    'let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]' \
    'let root = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]' \
    'let config = DanTermConfigPaths.standardConfigFilePath(home: home)' \
    'let config = "\(home)/.config/danterm/config.json"'
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

# Each rule keeps its own allowlist, so a seam is exempt from the rule it serves and
# from no other: the config resolver may not resolve a user-domain root, and the
# launch resolver may not spell the config path by hand.
denied_config_seam="$TMP/denied/lib/DanTermSupport/Sources/DanTermSupport/DanTermConfigPaths.swift"
mkdir -p "$(dirname "$denied_config_seam")"
printf 'let root = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]\n' > "$denied_config_seam"
if "$LINT" "$denied_config_seam" >/dev/null 2>&1; then
    fail "the config seam should not be exempt from the identity rule"
fi
printf 'let config = "\\(home)/.config/danterm/config.json"\n' \
    > "$TMP/denied/app/LaunchInstancePaths.swift"
if "$LINT" "$TMP/denied/app/LaunchInstancePaths.swift" >/dev/null 2>&1; then
    fail "the launch resolver should not be exempt from the config-path rule"
fi

# The no-target sweep finds its own targets under the root and exempts the
# seams it names.
rm -rf "$TMP/denied/app/CoreEnvironment.swift" "$TMP/denied/app/Runtime.swift" \
    "$TMP/denied/app/LaunchInstancePaths.swift" "$TMP/denied/lib"
AMBIENT_IDENTITY_LINT_ROOT="$TMP/allowed" "$LINT" >/dev/null \
    || fail "the sweep should pass a tree whose only ambient reads are the named seams"

# An allowlist entry that no longer names a file exempts nothing while still reading
# as policy, so the sweep must reject it rather than pass a tree it cannot vouch for.
# Every rule's allowlist is held to that, not just the identity one.
config_seam="$TMP/allowed/lib/DanTermSupport/Sources/DanTermSupport/DanTermConfigPaths.swift"
mv "$config_seam" "$(dirname "$config_seam")/Renamed.swift"
if AMBIENT_IDENTITY_LINT_ROOT="$TMP/allowed" "$LINT" >/dev/null 2>&1; then
    fail "a renamed config seam should fail the sweep"
fi
mv "$(dirname "$config_seam")/Renamed.swift" "$config_seam"

mv "$TMP/allowed/app/LaunchInstancePaths.swift" "$TMP/allowed/app/Renamed.swift"
if AMBIENT_IDENTITY_LINT_ROOT="$TMP/allowed" "$LINT" >/dev/null 2>&1; then
    fail "a renamed allowlist entry should fail the sweep"
fi

echo "ambient identity lint self-test passed"
