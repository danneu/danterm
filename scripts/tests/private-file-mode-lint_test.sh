#!/usr/bin/env bash
# Self-test for the private-file-mode gate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/../private-file-mode-lint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

SEAM_DIR='lib/PrivateFile/Sources/PrivateFile'
SUPPORT_DIR='lib/DanTermSupport/Sources/DanTermSupport'
IOS_DIR='ios/DanTermMobileKit/Sources/DanTermMobileKit'
mkdir -p "$TMP/allowed/app" "$TMP/allowed/$SEAM_DIR" "$TMP/allowed/$SUPPORT_DIR" \
    "$TMP/allowed/$IOS_DIR" "$TMP/denied/app" "$TMP/denied/$IOS_DIR"

cat > "$TMP/allowed/$SEAM_DIR/PrivateFile.swift" <<'SWIFT'
let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, fileMode)
if mkdir(path, directoryMode) == 0 {
Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
SWIFT
cat > "$TMP/allowed/app/DanTermConfigStore.swift" <<'SWIFT'
try $0.write(to: $1, options: .atomic)
try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
SWIFT
cat > "$TMP/allowed/$SUPPORT_DIR/CLIPathInstaller.swift" <<'SWIFT'
try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
SWIFT
cat > "$TMP/allowed/$SUPPORT_DIR/TailnetListener.swift" <<'SWIFT'
Darwin.bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
SWIFT

# A routed caller is legal because of how it spells the call, not because it sits in an
# exempt file: these are ordinary product files under the sweep.
cat > "$TMP/allowed/app/Runtime.swift" <<'SWIFT'
try PrivateFile.createDirectory(at: recoveryDirectory)
try PrivateFile.createFile(data, at: url)
try PrivateFile.writeAtomically(data, to: url)
let handle = try PrivateFile.openForAppending(at: logURL)
try PrivateFile.createEmptyFile(atPath: marker)
checkpointWriter.write(to: url, async: true, encode: capture.encoder())
// try Data(json).write(to: url, options: .atomic) is what this replaced.
SWIFT
# The iOS product is swept on the same terms as the Mac one: a routed create there passes
# because of how it spells the call, exactly like a routed create in app/.
cat > "$TMP/allowed/$IOS_DIR/PaneReplicaCheckpoint.swift" <<'SWIFT'
try PrivateFile.createDirectory(at: fileURL.deletingLastPathComponent())
try PrivateFile.writeAtomically(data, to: url)
SWIFT
"$LINT" "$TMP/allowed" >/dev/null || fail "the seam, its routed callers, and the allowlist should pass"

# A raw create under ios/ is a violation, not an exemption: the sweep covers every tree
# that compiles into a shipped product, and the phone's checkpoint holds terminal state.
printf 'try data.write(to: url, options: .atomic)\n' \
    > "$TMP/denied/$IOS_DIR/PaneReplicaCheckpoint.swift"
if "$LINT" "$TMP/denied" >/dev/null 2>&1; then
    fail "a raw create under ios/ should fail"
fi
rm -f "$TMP/denied/$IOS_DIR/PaneReplicaCheckpoint.swift"

# Every entry is Swift source for the lint to read, never shell for this file to expand,
# so a `$` inside one stays single-quoted on purpose.
# shellcheck disable=SC2016
for construct in \
    'try data.write(to: url, options: .atomic)' \
    'try data.write(to: url)' \
    'try text.write(toFile: path, atomically: true, encoding: .utf8)' \
    'try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)' \
    'FileManager.default.createFile(atPath: url.path, contents: data)' \
    'try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)' \
    'let fd = Darwin.open(path, O_WRONLY | O_CREAT, 0o644)' \
    'guard mkdir(path, 0o755) == 0 else { return }' \
    'Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))'
do
    printf '%s\n' "$construct" > "$TMP/denied/app/Runtime.swift"
    if "$LINT" "$TMP/denied" >/dev/null 2>&1; then
        fail "a raw create should fail: $construct"
    fi
done

# The seam's own name is not a password: a raw create beside a routed one is still caught,
# because the exemption is the call spelling and not the line.
printf 'try PrivateFile.createDirectory(at: dir); try data.write(to: url)\n' \
    > "$TMP/denied/app/Runtime.swift"
if "$LINT" "$TMP/denied" >/dev/null 2>&1; then
    fail "a raw create on a line that also names the seam should fail"
fi

# An allowlisted basename earns nothing outside the path the allowlist names: the exemption
# is the file, not the name.
printf 'try data.write(to: url, options: .atomic)\n' > "$TMP/denied/app/PrivateFile.swift"
if "$LINT" "$TMP/denied/app/PrivateFile.swift" >/dev/null 2>&1; then
    fail "an allowlisted basename at the wrong path should fail"
fi
rm -f "$TMP/denied/app/PrivateFile.swift"

# A failing run owes the reader the rule, not just the line it measured.
printf 'try data.write(to: url, options: .atomic)\n' > "$TMP/denied/app/Runtime.swift"
"$LINT" "$TMP/denied" >/dev/null 2>"$TMP/rationale.txt" || true
grep -q 'private-file-mode lint FAILED' "$TMP/rationale.txt" \
    || fail "the failure should print the rationale block"
grep -q 'Route it through' "$TMP/rationale.txt" \
    || fail "the failure should name the seam to use instead"

# The no-target sweep finds its own targets under the root and exempts the files it names.
rm -f "$TMP/denied/app/Runtime.swift"
PRIVATE_FILE_MODE_LINT_ROOT="$TMP/allowed" "$LINT" >/dev/null \
    || fail "the sweep should pass a tree whose only raw creates are the named files"

# PO4: the no-target sweep reaches ios/ because ios/ is one of its roots. The explicit-target
# case above proves the verdict; this proves the sweep goes looking there at all.
printf 'try data.write(to: url, options: .atomic)\n' > "$TMP/allowed/$IOS_DIR/Raw.swift"
if PRIVATE_FILE_MODE_LINT_ROOT="$TMP/allowed" "$LINT" >/dev/null 2>&1; then
    fail "the sweep should reach a raw create under ios/"
fi
rm -f "$TMP/allowed/$IOS_DIR/Raw.swift"

# An allowlist entry that no longer names a file exempts nothing while still reading as
# policy, so the sweep must reject it rather than pass a tree it cannot vouch for.
mv "$TMP/allowed/$SEAM_DIR/PrivateFile.swift" "$TMP/allowed/$SEAM_DIR/Renamed.swift"
if PRIVATE_FILE_MODE_LINT_ROOT="$TMP/allowed" "$LINT" >/dev/null 2>&1; then
    fail "a renamed allowlist entry should fail the sweep"
fi

echo "private file mode lint self-test passed"
