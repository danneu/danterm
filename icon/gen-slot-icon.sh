#!/usr/bin/env bash
#
# Generate raw-dev-<slot>.svg from raw-dev.svg by dropping a numbered plate into
# the bottom-right corner, beside the "dev" badge.
#
# The plate is a disc at (776, 736) with radius 230, and it is deliberately big
# enough to overlap what is under it. The number has to be readable across a room
# in a Cmd-Tab strip, and a disc tucked into the corner beside the "dev" badge is
# not: at Dock size its digit is a few pixels tall. So the disc covers the "v" of
# "dev" and touches the mark's cursor. "de" plus a numbered disc still reads as
# the dev app, and the digit is what the eye lands on first.
#
# The size has a ceiling. The icon is masked to a squircle, and this disc already
# reaches x=1006 and y=966; growing it much further, or moving it down or right,
# pushes its edge into the mask and the disc comes back clipped flat.
#
# Each slot gets its own hue as well as its own digit, because at the smallest
# sizes colour is still the first thing that separates two icons. None of the
# eight is the "dev" badge's green, so the disc never reads as part of the badge.
#
# The digits are drawn, not typeset, in the same monoline vocabulary as the mark
# and the "dev" badge: one stroke weight, round caps, a circle for every bowl.
# They are laid out in a 64 x 96 cap box whose origin the plate transform places.
# DIGIT_SCALE then sizes them to the disc, and is tied to the radius: it is what
# keeps the cap height at a fixed fraction of the diameter when the radius moves.
# Nothing here depends on a font being installed.
#
# Usage: ./gen-slot-icon.sh <slot 1-8> <output.svg>
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT="$SCRIPT_DIR/raw-dev.svg"

SLOT="${1:?usage: gen-slot-icon.sh <slot 1-8> <output.svg>}"
OUTPUT="${2:?usage: gen-slot-icon.sh <slot 1-8> <output.svg>}"

PLATE_X=776
PLATE_Y=736
PLATE_R=230
DIGIT_SCALE=2.821
BADGE_SHIFT=150

case "$SLOT" in
  1) HUE="#dc2626"; DIGIT='<path d="M 18 20 L 40 0 L 40 96"/>' ;;
  2) HUE="#ea580c"; DIGIT='<path d="M 8 26 A 26 26 0 0 1 56 26 L 8 96 L 58 96"/>' ;;
  3) HUE="#ca8a04"; DIGIT='<path d="M 10 22 A 26 26 0 1 1 34 48 A 26 26 0 1 1 10 74"/>' ;;
  4) HUE="#0d9488"; DIGIT='<path d="M 56 68 L 6 68 L 44 0 L 44 96"/>' ;;
  5) HUE="#0284c7"; DIGIT='<path d="M 56 2 L 16 2 L 13 42 A 27 27 0 1 1 16 80"/>' ;;
  6) HUE="#4f46e5"; DIGIT='<path d="M 52 4 A 44 44 0 0 0 6 62"/><circle cx="32" cy="70" r="26"/>' ;;
  7) HUE="#9333ea"; DIGIT='<path d="M 6 4 L 58 4 L 26 96"/>' ;;
  8) HUE="#db2777"; DIGIT='<circle cx="32" cy="24" r="22"/><circle cx="32" cy="70" r="26"/>' ;;
  *) echo "gen-slot-icon: slot must be 1 through 8, got '$SLOT'" >&2; exit 2 ;;
esac

{
  # Slide the whole "dev" badge left, out from under the disc, so the word stays
  # readable and the disc only laps its tail. The badge is everything raw-dev.svg
  # draws after the mark, so it moves as one group and the mark stays put.
  awk -v shift="$BADGE_SHIFT" '
    /<!-- "dev" plate/ { print "  <g transform=\"translate(-" shift " 0)\">" }
    /<\/svg>/ { print "  </g>"; next }
    { print }
  ' "$INPUT"
  cat <<PLATE
  <!-- Slot $SLOT plate. Hue first, digit second: see gen-slot-icon.sh. -->
  <circle cx="$PLATE_X" cy="$PLATE_Y" r="$PLATE_R" fill="$HUE"/>
  <g transform="translate($PLATE_X $PLATE_Y) scale($DIGIT_SCALE) translate(-32 -48)" fill="none" stroke="#FFFFFF" stroke-width="20" stroke-linecap="round" stroke-linejoin="round">$DIGIT</g>
</svg>
PLATE
} > "$OUTPUT"

echo "Generated: $OUTPUT"
