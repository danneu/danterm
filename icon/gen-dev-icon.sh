#!/usr/bin/env bash
#
# Generate raw-dev.svg from raw.svg by injecting a "dev" badge.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT="$SCRIPT_DIR/raw.svg"
OUTPUT="$SCRIPT_DIR/raw-dev.svg"

DEV_BADGE='  <!-- "dev" label with green background -->\
  <rect x="282" y="650" width="460" height="260" rx="20" fill="#16a34a"/>\
  <text x="512" y="850" text-anchor="middle" font-family="'"'"'Monaco'"'"'" font-size="220" font-weight="bold" fill="#FFFFFF">dev</text>'

sed "s|</svg>|${DEV_BADGE}\n</svg>|" "$INPUT" > "$OUTPUT"

echo "Generated: $OUTPUT"
