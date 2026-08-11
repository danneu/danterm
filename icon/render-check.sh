#!/usr/bin/env bash
# Checks that ChipRenderer paints what icon/chips/preview.html shows.
#
# Two independent renderings of the same chip: one through the real Swift
# renderer (compiled here with swiftc -- no app build), one as an SVG built the
# way preview.html builds its markup and rasterized by ImageMagick. Their
# per-pixel difference is the answer. This is the first check that tests the
# consumer of the generated artwork rather than the generator itself.
#
# ImageMagick is a dependency of this check only. icon/gen-chips.sh, which is
# what actually produces shipped code, stays dependency-free.
#
# Usage: icon/render-check.sh [--size N] [--keep] [--tolerance R]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

SIZE=256
# Two rasterizers disagree on antialiasing, so the residual is never zero. The
# observed noise is around 0.012, while a one-pixel misplacement of the mark
# scores 0.039 or worse -- this sits between them.
TOLERANCE=0.02
KEEP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --size) SIZE="$2"; shift 2 ;;
    --tolerance) TOLERANCE="$2"; shift 2 ;;
    --keep) KEEP="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v magick >/dev/null || { echo "render-check needs ImageMagick (magick)" >&2; exit 1; }

WORK="${KEEP:-$(mktemp -d)}"
mkdir -p "$WORK/swift" "$WORK/svg" "$WORK/reference"
[[ -n "$KEEP" ]] || trap 'rm -rf "$WORK"' EXIT

echo "== compiling the renderer"
swiftc -O \
  "$REPO_DIR/app/ChipArtwork.swift" \
  "$REPO_DIR/app/ChipRenderer.swift" \
  "$SCRIPT_DIR/render-check/main.swift" \
  -o "$WORK/render-check"

echo "== rendering through ChipRenderer"
"$WORK/render-check" "$WORK/swift" "$SIZE" >/dev/null

echo "== building reference SVGs the way preview.html does"
CHIPS_DIR="$SCRIPT_DIR/chips" OUT_DIR="$WORK/svg" SIZE="$SIZE" python3 <<'PY'
import json, os, re
import xml.etree.ElementTree as ET

chips_dir = os.environ['CHIPS_DIR']
out_dir = os.environ['OUT_DIR']
size = float(os.environ['SIZE'])

manifest = json.load(open(os.path.join(chips_dir, 'chips.json'), encoding='utf-8'))


def split_color(value):
    """chips.json states colors as #RRGGBB or #RRGGBBAA. ImageMagick's own SVG
    renderer does not read the 8-digit form, so hand it a color and an opacity."""
    value = value.strip()
    if len(value) == 9:
        return value[:7], int(value[7:], 16) / 255.0
    return value, 1.0


def read_art(name):
    text = open(os.path.join(chips_dir, name), encoding='utf-8').read()
    root = ET.fromstring(text)
    vb = [float(v) for v in re.split(r'[\s,]+', root.get('viewBox').strip())]
    paths = []
    for element in root.iter():
        if not element.tag.endswith('path'):
            continue
        paths.append({
            'd': element.get('d'),
            'rule': element.get('fill-rule') or 'nonzero',
            'stroked': (element.get('fill') or '') == 'none',
            'sw': float(element.get('stroke-width') or 0),
            'cap': element.get('stroke-linecap') or 'butt',
            'join': element.get('stroke-linejoin') or 'miter',
        })
    return {'vb': vb, 'w': vb[2], 'h': vb[3], 'paths': paths}


for kind, spec in manifest['kinds'].items():
    art = read_art(spec['svg'])
    ratio = art['w'] / art['h']
    fill = spec['fill']
    if ratio >= 1:
        w = size * fill
        h = w / ratio
    else:
        h = size * fill
        w = h * ratio
    dilate = spec.get('dilate', 0) * (art['w'] / 24)

    for mode in ('light', 'dark'):
        bg, bg_opacity = split_color(spec[mode]['bg'])
        fg, fg_opacity = split_color(spec[mode]['fg'])

        body = ''
        for p in art['paths']:
            if p['stroked']:
                body += (
                    f'<path d="{p["d"]}" fill="none" stroke="{fg}" stroke-opacity="{fg_opacity}"'
                    f' stroke-width="{p["sw"]}" stroke-linecap="{p["cap"]}"'
                    f' stroke-linejoin="{p["join"]}"/>'
                )
            else:
                body += (
                    f'<path d="{p["d"]}" fill="{fg}" fill-opacity="{fg_opacity}"'
                    f' fill-rule="{p["rule"]}"'
                )
                if dilate:
                    body += (
                        f' stroke="{fg}" stroke-opacity="{fg_opacity}"'
                        f' stroke-width="{dilate}" stroke-linejoin="round"'
                    )
                body += '/>'

        radius = size * manifest['cornerRadius']
        vb = ' '.join(str(v) for v in art['vb'])
        svg = (
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}"'
            f' viewBox="0 0 {size} {size}">'
            f'<rect width="{size}" height="{size}" rx="{radius}" ry="{radius}"'
            f' fill="{bg}" fill-opacity="{bg_opacity}"/>'
            f'<svg x="{(size - w) / 2}" y="{(size - h) / 2}" width="{w}" height="{h}"'
            f' viewBox="{vb}" overflow="visible">{body}</svg>'
            f'</svg>'
        )
        with open(os.path.join(out_dir, f'{kind}-{mode}.svg'), 'w', encoding='utf-8') as f:
            f.write(svg)
PY

echo "== comparing"
status=0
for file in "$WORK"/svg/*.svg; do
  name="$(basename "$file" .svg)"
  # -background none keeps the chip's own alpha; both sides then carry the same
  # transparent corners outside the rounded rect.
  magick -background none -density 300 "$file" \
    -resize "${SIZE}x${SIZE}!" "PNG32:$WORK/reference/$name.png"

  # `compare` exits non-zero whenever the images differ at all, which is the
  # normal case here -- read the metric, not the exit status.
  rmse="$({ magick compare -metric RMSE \
    "$WORK/swift/$name.png" "$WORK/reference/$name.png" null: 2>&1 || true; } |
    sed -n 's/.*(\(.*\)).*/\1/p')"

  # A comparison that did not run is a failure, not a pass. Without this an
  # unreadable or missing rendering yields an empty metric, and an empty metric
  # in the arithmetic below is false -- so the chip reads "ok" having never been
  # compared to anything.
  if [[ ! "$rmse" =~ ^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; then
    printf '%-18s rmse %-12s %s\n' "$name" "${rmse:-none}" "FAIL (no metric)"
    status=1
    continue
  fi

  verdict="ok"
  if (( $(echo "$rmse > $TOLERANCE" | bc -l) )); then
    verdict="FAIL"
    status=1
  fi
  printf '%-18s rmse %-12s %s\n' "$name" "$rmse" "$verdict"
done

[[ -n "$KEEP" ]] && echo "artifacts kept in $KEEP"
exit $status
