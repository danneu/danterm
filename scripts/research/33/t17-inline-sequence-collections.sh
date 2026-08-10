#!/usr/bin/env bash
# Research doc 33, task T17: require retained CSI values to own no heap allocations.

set -euo pipefail

root=$(cd "$(dirname "$0")/../../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

cp "$root/lib/TerminalCore/Sources/TerminalCore/EscapeAbsorber.swift" "$scratch/EscapeAbsorber.swift"
cp "$root/scripts/research/33/t17-inline-sequence-collections-probe.swift" "$scratch/main.swift"

CLANG_MODULE_CACHE_PATH="$scratch/clang-module-cache" \
    SWIFT_MODULECACHE_PATH="$scratch/swift-module-cache" \
    xcrun swiftc -O "$scratch/EscapeAbsorber.swift" "$scratch/main.swift" -o "$scratch/probe"
output=$(
    MallocNanoZone=0 "$scratch/probe"
)
printf '%s\n' "$output"

csi_allocations=$(printf '%s\n' "$output" | sed -n 's/^csiLiveHeapBlocks=//p')
escape_allocations=$(printf '%s\n' "$output" | sed -n 's/^escapeLiveHeapBlocks=//p')
if [[ "$csi_allocations" != 0 ]]; then
    echo "FAIL: retained CSI values own $csi_allocations heap blocks; expected 0" >&2
    exit 1
fi
if [[ "$escape_allocations" != 0 ]]; then
    echo "FAIL: retained escape values own $escape_allocations heap blocks; expected 0" >&2
    exit 1
fi

terminal="$root/lib/TerminalCore/Sources/TerminalCore/Terminal.swift"
dispatch=$(sed -n '/private mutating func dispatchCSI(_ sequence/,/private func movementAmount/p' "$terminal")
if printf '%s\n' "$dispatch" | rg -q 'sequence\.intermediates =='; then
    echo 'FAIL: dispatchCSI still routes through intermediate collection comparisons' >&2
    exit 1
fi

echo 'PASS: allocations per CSI: 0; intermediate routing uses one packed switch'
