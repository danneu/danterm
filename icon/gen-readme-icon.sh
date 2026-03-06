#!/usr/bin/env bash
# Generate raw-readme.svg from raw.svg by adding a rounded rect background.
set -euo pipefail

cd "$(dirname "$0")"

sed 's|<svg \([^>]*\)>|<svg \1>\
  <rect x="0" y="0" width="1024" height="1024" rx="228" fill="#1a1a2e"/>|' raw.svg > raw-readme.svg

echo "Generated icon/raw-readme.svg"
