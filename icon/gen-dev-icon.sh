#!/usr/bin/env bash
#
# Generate raw-dev.svg from raw.svg: lift the mark clear of the bottom of the
# tile, then drop a "dev" badge into the space that opens up.
#
# The badge occupies a reserved band, y=650 to y=910. MARK_LIFT is what keeps
# the mark out of it, and it is tuned to the mark raw.svg currently holds
# (y=302 to y=722, so lifting by 140 leaves a 68 unit gap). Change the mark's
# height or vertical position and this number has to move with it -- the two
# files share no layout, so nothing here will notice on its own.
#
# The word is drawn, not typeset, from the same parts the mark is made of: one
# stroke weight, round caps, a circle for every bowl. Metrics: x-height 120,
# stroke 24, baseline y=873, and the d's ascender is 1.56 x-heights, the same
# ratio raw.svg uses. The letters are placed by measurement, not on cells; see
# below.
#
# The letters are sized by the e, not the d. An e's counter is the gap between
# its bar and the inside of its bowl, which is (r - stroke), and it is the
# first thing to fill in as the word gets smaller. At stroke 24 on a 120
# x-height that gap is a full stroke width, so the e stays open; at the 104
# x-height this badge used before it was half that, and the e read as an o.
#
# The three letters are NOT on evenly spaced cells, and should not be. Even
# cells put 1.65x as much white between "ev" as between "de", because a v only
# reaches its cell edges at the very top and leaks the rest. The positions
# below were solved instead for equal white area inside the x-height band,
# which is the standard test: e sits 4 right and v 14 left of their cells.
# Areas come out within 0.2% of each other.
#
# The word is then centred the same way. Centring its bounding box on the plate
# leaves 1.2x as much white to the right of the v as to the left of the d,
# because both outer letters are round or pointed and fall away from their
# extremes; the word is shifted 5 right of box centre so the two side areas
# match. Move a letter and both balances are gone.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT="$SCRIPT_DIR/raw.svg"
OUTPUT="$SCRIPT_DIR/raw-dev.svg"

MARK_LIFT=140

{
  sed \
    -e "s|<svg \([^>]*\)>|<svg \1>\\
  <g transform=\"translate(0 -${MARK_LIFT})\">|" \
    -e '/<\/svg>/d' \
    "$INPUT"
  cat <<'BADGE'
  </g>
  <!-- "dev" plate. The word is drawn in the mark's own monoline vocabulary. -->
  <rect x="282" y="650" width="460" height="260" rx="20" fill="#16a34a"/>
  <g fill="none" stroke="#FFFFFF" stroke-width="24" stroke-linecap="round" stroke-linejoin="round">

    <!-- "d": circular bowl tangent to a straight stem, same as the big one -->
    <circle cx="386" cy="813" r="48"/>
    <path d="M434 698 L434 861"/>

    <!-- "e": a bar on the bowl's diameter, the bowl open at the lower right -->
    <path d="M480 813 L576 813"/>
    <path d="M576 813 A48 48 0 1 0 561.9 846.9"/>

    <!-- "v": two straight strokes meeting on the baseline -->
    <path d="M600 765 L648 861 L696 765"/>
  </g>
</svg>
BADGE
} > "$OUTPUT"

echo "Generated: $OUTPUT"
