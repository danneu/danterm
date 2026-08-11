#!/usr/bin/env bash
#
# Generate app/ChipArtwork.swift from icon/chips/*.svg and icon/chips/chips.json.
#
# The SVGs and the manifest are the source of truth: preview.html and this
# script read the same two inputs, so what the preview shows is what ships.
# The generated Swift carries no SVG -- every path is flattened here to
# move/line/cubic/close, so the app needs no path parser and no arc math.
#
# Usage: ./gen-chips.sh [--chips DIR] [--out PATH] [--dump-svg DIR]
#
#   --chips DIR     read artwork and chips.json from DIR instead of ./chips.
#                   Lets a change be rendered and compared before it is made to
#                   the real artwork.
#   --dump-svg DIR  also write each flattened path back out as an SVG, for
#                   diffing against the original to prove the conversion.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="$REPO_ROOT/app/ChipArtwork.swift"
CHIPS="$SCRIPT_DIR/chips"
DUMP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chips)    CHIPS="$2"; shift 2 ;;
        --out)      OUT="$2"; shift 2 ;;
        --dump-svg) DUMP="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

python3 - "$CHIPS" "$OUT" "$DUMP" <<'PY'
import json, math, re, sys, os
import xml.etree.ElementTree as ET

CHIPS_DIR, OUT, DUMP = sys.argv[1], sys.argv[2], sys.argv[3]


def _report(kind, exc, tb):
    """Bad artwork is ordinary user error -- a malformed SVG, an unsupported
    path command -- so report it as one line rather than a Python traceback."""
    if kind is ValueError:
        print(f'error: {exc}', file=sys.stderr)
    else:
        sys.__excepthook__(kind, exc, tb)


sys.excepthook = _report

NUM = re.compile(r'[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?')
CMDS = 'MmLlHhVvCcSsQqTtAaZz'

MOVE, LINE, CURVE, CLOSE = 0, 1, 2, 3


class Scanner:
    """Path-data cursor. Arc flags are read as single characters, not numbers:
    SVG allows '0 0 1-31.105', where a plain number scan would swallow '011'."""

    def __init__(self, s):
        self.s, self.i = s, 0

    def _skip(self):
        while self.i < len(self.s) and self.s[self.i] in ' ,\t\r\n':
            self.i += 1

    def done(self):
        self._skip()
        return self.i >= len(self.s)

    def peek_cmd(self):
        self._skip()
        if self.i < len(self.s) and self.s[self.i] in CMDS:
            return self.s[self.i]
        return None

    def cmd(self):
        c = self.peek_cmd()
        self.i += 1
        return c

    def num(self):
        self._skip()
        m = NUM.match(self.s, self.i)
        if not m:
            raise ValueError(f'expected number at offset {self.i}: {self.s[self.i:self.i+20]!r}')
        self.i = m.end()
        return float(m.group())

    def flag(self):
        self._skip()
        c = self.s[self.i]
        if c not in '01':
            raise ValueError(f'expected arc flag at offset {self.i}, got {c!r}')
        self.i += 1
        return int(c)


def arc_to_cubics(x0, y0, rx, ry, phi_deg, large, sweep, x, y):
    """Endpoint-parameterized elliptical arc -> a list of cubic segments.
    Degenerate radii collapse to a line, per the SVG spec."""
    if rx == 0 or ry == 0 or (x0 == x and y0 == y):
        return [(LINE, x, y)]

    phi = math.radians(phi_deg)
    cosp, sinp = math.cos(phi), math.sin(phi)
    dx2, dy2 = (x0 - x) / 2, (y0 - y) / 2
    x1p, y1p = cosp * dx2 + sinp * dy2, -sinp * dx2 + cosp * dy2
    rx, ry = abs(rx), abs(ry)

    # Scale up radii that are too small to span the endpoints.
    lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lam > 1:
        s = math.sqrt(lam)
        rx, ry = rx * s, ry * s

    num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    co = math.sqrt(max(0.0, num / den))
    if large == sweep:
        co = -co
    cxp, cyp = co * rx * y1p / ry, -co * ry * x1p / rx
    cx = cosp * cxp - sinp * cyp + (x0 + x) / 2
    cy = sinp * cxp + cosp * cyp + (y0 + y) / 2

    def angle(ux, uy, vx, vy):
        d = (ux * vx + uy * vy) / (math.hypot(ux, uy) * math.hypot(vx, vy))
        a = math.acos(max(-1.0, min(1.0, d)))
        return -a if ux * vy - uy * vx < 0 else a

    ux, uy = (x1p - cxp) / rx, (y1p - cyp) / ry
    vx, vy = (-x1p - cxp) / rx, (-y1p - cyp) / ry
    theta = angle(1, 0, ux, uy)
    sweep_angle = angle(ux, uy, vx, vy)
    if not sweep and sweep_angle > 0:
        sweep_angle -= 2 * math.pi
    elif sweep and sweep_angle < 0:
        sweep_angle += 2 * math.pi

    # A cubic approximates at most a quarter turn to within drawing tolerance.
    steps = max(1, math.ceil(abs(sweep_angle) / (math.pi / 2)))
    delta = sweep_angle / steps
    k = 4 / 3 * math.tan(delta / 4)

    def point(a):
        return (cx + rx * math.cos(a) * cosp - ry * math.sin(a) * sinp,
                cy + rx * math.cos(a) * sinp + ry * math.sin(a) * cosp)

    def deriv(a):
        return (-rx * math.sin(a) * cosp - ry * math.cos(a) * sinp,
                -rx * math.sin(a) * sinp + ry * math.cos(a) * cosp)

    out = []
    for step in range(steps):
        a1 = theta + step * delta
        a2 = a1 + delta
        p1, p2 = point(a1), point(a2)
        d1, d2 = deriv(a1), deriv(a2)
        out.append((CURVE,
                    p1[0] + k * d1[0], p1[1] + k * d1[1],
                    p2[0] - k * d2[0], p2[1] - k * d2[1],
                    p2[0], p2[1]))
    return out


def flatten(d):
    """SVG path data -> [(op, *coords)] using only move/line/cubic/close."""
    sc = Scanner(d)
    ops = []
    cx = cy = 0.0          # current point
    sx = sy = 0.0          # subpath start, for Z
    prev_c2 = None         # previous cubic's second control, for S
    prev_q = None          # previous quadratic's control, for T
    cmd = None

    def cubic(c1x, c1y, c2x, c2y, x, y):
        ops.append((CURVE, c1x, c1y, c2x, c2y, x, y))

    while not sc.done():
        if sc.peek_cmd():
            cmd = sc.cmd()
        elif cmd is None:
            raise ValueError('path data does not start with a command')
        elif cmd in 'Mm':
            cmd = 'L' if cmd == 'M' else 'l'   # implicit lineto after moveto

        rel = cmd.islower()
        ox, oy = (cx, cy) if rel else (0.0, 0.0)
        up = cmd.upper()

        if up == 'Z':
            ops.append((CLOSE,))
            cx, cy = sx, sy
            prev_c2 = prev_q = None
            continue

        if up == 'M':
            cx, cy = sc.num() + ox, sc.num() + oy
            sx, sy = cx, cy
            ops.append((MOVE, cx, cy))
            prev_c2 = prev_q = None
        elif up == 'L':
            cx, cy = sc.num() + ox, sc.num() + oy
            ops.append((LINE, cx, cy))
            prev_c2 = prev_q = None
        elif up == 'H':
            cx = sc.num() + ox
            ops.append((LINE, cx, cy))
            prev_c2 = prev_q = None
        elif up == 'V':
            cy = sc.num() + oy
            ops.append((LINE, cx, cy))
            prev_c2 = prev_q = None
        elif up == 'C':
            c1x, c1y = sc.num() + ox, sc.num() + oy
            c2x, c2y = sc.num() + ox, sc.num() + oy
            x, y = sc.num() + ox, sc.num() + oy
            cubic(c1x, c1y, c2x, c2y, x, y)
            prev_c2, prev_q = (c2x, c2y), None
            cx, cy = x, y
        elif up == 'S':
            c1x, c1y = (2 * cx - prev_c2[0], 2 * cy - prev_c2[1]) if prev_c2 else (cx, cy)
            c2x, c2y = sc.num() + ox, sc.num() + oy
            x, y = sc.num() + ox, sc.num() + oy
            cubic(c1x, c1y, c2x, c2y, x, y)
            prev_c2, prev_q = (c2x, c2y), None
            cx, cy = x, y
        elif up in 'QT':
            if up == 'Q':
                qx, qy = sc.num() + ox, sc.num() + oy
            else:
                qx, qy = (2 * cx - prev_q[0], 2 * cy - prev_q[1]) if prev_q else (cx, cy)
            x, y = sc.num() + ox, sc.num() + oy
            # Degree-elevate the quadratic to a cubic; exact, not an approximation.
            cubic(cx + 2 / 3 * (qx - cx), cy + 2 / 3 * (qy - cy),
                  x + 2 / 3 * (qx - x), y + 2 / 3 * (qy - y), x, y)
            prev_q, prev_c2 = (qx, qy), None
            cx, cy = x, y
        elif up == 'A':
            rx, ry, rot = sc.num(), sc.num(), sc.num()
            large, sweep = sc.flag(), sc.flag()
            x, y = sc.num() + ox, sc.num() + oy
            ops.extend(arc_to_cubics(cx, cy, rx, ry, rot, large, sweep, x, y))
            prev_c2 = prev_q = None
            cx, cy = x, y
        else:
            raise ValueError(f'unsupported command {cmd!r}')

    return ops


def parse_svg(path):
    """Pull viewBox and paths out of an SVG without a namespace-aware parser --
    these files are hand-checked single-path marks, not arbitrary documents.

    Extraction is by regex, but the file is parsed first purely to reject
    malformed XML. Without that check a broken file still generates: regexes do
    not care that, say, a comment contains a double hyphen, so the Swift comes
    out fine while every renderer refuses the SVG."""
    text = open(path, encoding='utf-8').read()
    try:
        ET.fromstring(text)
    except ET.ParseError as e:
        raise ValueError(f'{path}: malformed XML: {e}') from None
    vb = re.search(r'viewBox\s*=\s*"([^"]+)"', text)
    if not vb:
        raise ValueError(f'{path}: no viewBox')
    box = [float(v) for v in re.split(r'[\s,]+', vb.group(1).strip())]
    if box[0] != 0 or box[1] != 0:
        raise ValueError(f'{path}: viewBox must start at 0 0, got {box}')

    paths = []
    for tag in re.findall(r'<path\b[^>]*>', text):
        def attr(name):
            m = re.search(rf'{name}\s*=\s*"([^"]*)"', tag)
            return m.group(1) if m else None
        paths.append({
            'd': attr('d'),
            'evenodd': (attr('fill-rule') or 'nonzero') == 'evenodd',
            'stroked': (attr('fill') or '') == 'none',
            'stroke_width': float(attr('stroke-width') or 0),
            'cap': attr('stroke-linecap') or 'butt',
            'join': attr('stroke-linejoin') or 'miter',
        })
    if not paths:
        raise ValueError(f'{path}: no <path>')
    return {'w': box[2], 'h': box[3], 'paths': paths}


def rgba(hexstr):
    s = hexstr.lstrip('#')
    if len(s) == 6:
        s += 'FF'
    if len(s) != 8:
        raise ValueError(f'expected #RRGGBB or #RRGGBBAA, got {hexstr!r}')
    return [int(s[i:i + 2], 16) / 255 for i in (0, 2, 4, 6)]


def fmt(v):
    return f'{round(v, 4):g}'


CAPS = {'butt': 'butt', 'round': 'round', 'square': 'square'}
JOINS = {'miter': 'miter', 'round': 'round', 'bevel': 'bevel'}

manifest = json.load(open(os.path.join(CHIPS_DIR, 'chips.json'), encoding='utf-8'))
kinds = manifest['kinds']

def ink_bounds(ops, pad):
    """Tight bounds of the drawn mark, in viewBox units.

    Tight, not control-point: a cubic's control points sit outside the curve
    they steer, so using them would overstate a curve-heavy mark. `pad` is how
    far paint reaches past the path -- half the stroke width, or half the
    dilation for a filled mark.
    """
    xs, ys = [], []

    def extrema(p0, p1, p2, p3):
        # A cubic's extremes are its endpoints plus the roots of its derivative.
        values = [p0, p3]
        a = 3 * (-p0 + 3 * p1 - 3 * p2 + p3)
        b = 6 * (p0 - 2 * p1 + p2)
        c = 3 * (p1 - p0)
        roots = []
        if abs(a) < 1e-12:
            if abs(b) > 1e-12:
                roots = [-c / b]
        else:
            disc = b * b - 4 * a * c
            if disc >= 0:
                roots = [(-b + s * math.sqrt(disc)) / (2 * a) for s in (1, -1)]
        for t in roots:
            if 0 < t < 1:
                u = 1 - t
                values.append(u**3 * p0 + 3 * u**2 * t * p1 + 3 * u * t**2 * p2 + t**3 * p3)
        return values

    cursor = (0.0, 0.0)
    for op in ops:
        if op[0] in (MOVE, LINE):
            cursor = (op[1], op[2])
            xs.append(cursor[0])
            ys.append(cursor[1])
        elif op[0] == CURVE:
            x1, y1, x2, y2, x3, y3 = op[1:]
            xs += extrema(cursor[0], x1, x2, x3)
            ys += extrema(cursor[1], y1, y2, y3)
            cursor = (x3, y3)
    return (min(xs) - pad, min(ys) - pad, max(xs) + pad, max(ys) + pad)


# The viewBox is the ink. A mark's box must hug what it draws, so that `fill`
# means the share of the chip the mark actually covers and the fills of two
# marks are comparable. This floor is the tolerance on "hug" -- not a style
# preference, since slack inside the box shrinks the mark by a factor `fill`
# does not show, and it does so silently.
COVERAGE_FLOOR = 0.97
failures = []

glyphs = {}
for name, spec in kinds.items():
    svg = parse_svg(os.path.join(CHIPS_DIR, spec['svg']))
    if len(svg['paths']) > 1:
        raise ValueError(f'{spec["svg"]}: expected one <path>, found {len(svg["paths"])}')
    p = svg['paths'][0]
    ops = flatten(p['d'])
    glyphs[name] = {'svg': svg, 'path': p, 'ops': ops}
    counts = {MOVE: 0, LINE: 0, CURVE: 0, CLOSE: 0}
    for op in ops:
        counts[op[0]] += 1
    # `fill` sizes the viewBox, so the viewBox has to be the ink for the number
    # to mean anything. Measure the drawn extent and hold the author to it.
    pad = (p['stroke_width'] if p['stroked'] else spec.get('dilate', 0) * svg['w'] / 24) / 2
    x0, y0, x1, y1 = ink_bounds(ops, pad)
    cover_w, cover_h = (x1 - x0) / svg['w'], (y1 - y0) / svg['h']
    short = min(cover_w, cover_h) < COVERAGE_FLOOR
    print(f'  {name:9s} {spec["svg"]:14s} '
          f'{int(svg["w"])}x{int(svg["h"])}  '
          f'move {counts[MOVE]}  line {counts[LINE]}  '
          f'cubic {counts[CURVE]}  close {counts[CLOSE]}  '
          f'ink {cover_w:.2f}x{cover_h:.2f}{"  <- short" if short else ""}',
          file=sys.stderr)
    if short:
        effective = spec['fill'] * min(cover_w, cover_h)
        # Say what the box should be, since the fix is mechanical: move the ink
        # to the origin and shrink the box onto it, then scale `fill` by the
        # same factor so the mark still draws the size it does today.
        axis = svg['w'] if svg['w'] / svg['h'] >= 1 else svg['h']
        span = (x1 - x0) if svg['w'] / svg['h'] >= 1 else (y1 - y0)
        failures.append(
            f'{name}: ink spans {cover_w:.2f}x{cover_h:.2f} of its viewBox, so '
            f'fill {spec["fill"]} draws at about {effective:.2f} and is not '
            f'comparable to the other marks. Translate the path by '
            f'({-x0:g}, {-y0:g}), set viewBox to "0 0 {fmt(x1 - x0)} '
            f'{fmt(y1 - y0)}", and set fill to {fmt(spec["fill"] * span / axis)}.')

# Refuse to generate rather than warn: a rule that still produces output is one
# the artwork drifts past. The viewBox-starts-at-0-0 check is the other half of
# the same invariant.
if failures:
    for failure in failures:
        print(f'error: {failure}', file=sys.stderr)
    sys.exit(1)

# Optional round-trip: write the flattened geometry back out as SVG so it can be
# rastered and diffed against the original. Proves the conversion, including arcs.
if DUMP:
    os.makedirs(DUMP, exist_ok=True)
    for name, g in glyphs.items():
        parts = []
        for op in g['ops']:
            if op[0] == MOVE:
                parts.append('M' + ' '.join(fmt(v) for v in op[1:]))
            elif op[0] == LINE:
                parts.append('L' + ' '.join(fmt(v) for v in op[1:]))
            elif op[0] == CURVE:
                parts.append('C' + ' '.join(fmt(v) for v in op[1:]))
            else:
                parts.append('Z')
        p = g['path']
        paint = (f'fill="none" stroke="#000" stroke-width="{fmt(p["stroke_width"])}"'
                 f' stroke-linecap="{p["cap"]}" stroke-linejoin="{p["join"]}"'
                 if p['stroked'] else
                 f'fill="#000" fill-rule="{"evenodd" if p["evenodd"] else "nonzero"}"')
        out = (f'<svg xmlns="http://www.w3.org/2000/svg" '
               f'viewBox="0 0 {fmt(g["svg"]["w"])} {fmt(g["svg"]["h"])}">'
               f'<path d="{" ".join(parts)}" {paint}/></svg>\n')
        open(os.path.join(DUMP, f'{name}.svg'), 'w', encoding='utf-8').write(out)
    print(f'  round-trip SVGs -> {DUMP}', file=sys.stderr)

# --- emit Swift ------------------------------------------------------------

L = []
w = L.append

w('// Pane-kind chip artwork: the glyph geometry and paint values behind the')
w('// terminal / Claude / Codex chips shown in the sidebar and the pane toolbar.')
w('//')
w('// GENERATED by icon/gen-chips.sh from icon/chips/*.svg and icon/chips/chips.json.')
w('// Do not edit by hand -- rerun the script after changing artwork or tuning.')
w('//')
w('// Only data lives here. Drawing, and the mapping from a pane to a chip kind,')
w('// belong elsewhere: this file must stay free of anything a generator cannot')
w('// reproduce from those two inputs.')
w('')
w('import CoreGraphics')
w('')
w('/// A chip glyph as flattened geometry. Coordinates stay in the source')
w('/// viewBox rather than being normalized, so the drawing code performs the')
w('/// same aspect fit that icon/chips/preview.html does and the two agree.')
w('struct ChipGlyph {')
w('    /// Opcodes: 0 move, 1 line, 2 cubic, 3 close. Each consumes 2, 2, 6, and 0')
w('    /// coordinates from `points` respectively, in order.')
w('    let opcodes: [UInt8]')
w('    let points: [CGFloat]')
w('    let viewBox: CGSize')
w('    /// Stroke width in viewBox units for a stroked mark; nil for a filled one.')
w('    let strokeWidth: CGFloat?')
w('    let lineCap: CGLineCap')
w('    let lineJoin: CGLineJoin')
w('    let usesEvenOddFill: Bool')
w('}')
w('')
w('/// How one chip is painted at a given appearance.')
w('struct ChipPalette {')
w('    let background: CGColor')
w('    let foreground: CGColor')
w('}')
w('')
w('/// The two states of a chip in a tab row\'s pane strip.')
w('struct ChipPaneListPalette {')
w('    let inactive: ChipPalette')
w('    let active: ChipPalette')
w('}')
w('')
w('/// One pane-kind chip: its glyph, its optical tuning, and its colors.')
w('///')
w('/// `fill` is the fraction of the chip box the mark occupies, per-kind because')
w('/// equal measured size does not read as equal optical size. `dilate` re-strokes')
w('/// a filled path in its own color to hold thin features at chip size, and is')
w('/// expressed on a 24-unit box for every mark so the value stays comparable')
w('/// across glyphs with different viewBoxes.')
w('struct ChipDefinition {')
w('    let glyph: ChipGlyph')
w('    let fill: CGFloat')
w('    let dilate: CGFloat')
w('    let light: ChipPalette')
w('    let dark: ChipPalette')
w('}')
w('')
w('enum ChipArtwork {')
w(f'    /// Chip corner radius as a fraction of the chip\'s edge length.')
w(f'    static let cornerRadius: CGFloat = {fmt(manifest["cornerRadius"])}')
w(f'    static let sidebarSize: CGFloat = {fmt(manifest["sizes"]["sidebar"])}')
w(f'    static let toolbarSize: CGFloat = {fmt(manifest["sizes"]["toolbar"])}')
w('    /// The per-pane chips on a multi-pane tab\'s second line, smaller than the')
w('    /// row\'s own chip so the enumeration reads as subordinate to the title.')
w(f'    static let paneRowSize: CGFloat = {fmt(manifest["sizes"]["paneRow"])}')


def color(c):
    r, g, b, a = rgba(c)
    return (f'CGColor(srgbRed: {fmt(r)}, green: {fmt(g)}, '
            f'blue: {fmt(b)}, alpha: {fmt(a)})')


for name, spec in kinds.items():
    g = glyphs[name]
    p = g['path']
    opcodes, points = [], []
    for op in g['ops']:
        opcodes.append(op[0])
        points.extend(op[1:])

    w('')
    w(f'    static let {name} = ChipDefinition(')
    w('        glyph: ChipGlyph(')
    w('            opcodes: [' + ', '.join(str(o) for o in opcodes) + '],')
    w('            points: [' + ', '.join(fmt(v) for v in points) + '],')
    w(f'            viewBox: CGSize(width: {fmt(g["svg"]["w"])}, '
      f'height: {fmt(g["svg"]["h"])}),')
    w(f'            strokeWidth: '
      f'{fmt(p["stroke_width"]) if p["stroked"] else "nil"},')
    w(f'            lineCap: .{CAPS[p["cap"]]},')
    w(f'            lineJoin: .{JOINS[p["join"]]},')
    w(f'            usesEvenOddFill: {"true" if p["evenodd"] else "false"}')
    w('        ),')
    w(f'        fill: {fmt(spec["fill"])},')
    w(f'        dilate: {fmt(spec["dilate"])},')
    w(f'        light: ChipPalette(background: {color(spec["light"]["bg"])}, '
      f'foreground: {color(spec["light"]["fg"])}),')
    w(f'        dark: ChipPalette(background: {color(spec["dark"]["bg"])}, '
      f'foreground: {color(spec["dark"]["fg"])})')
    w('    )')

# The pane strip's own palette. Not per kind: the strip answers "which pane am
# I looking at", so every chip in it drops its brand colors for one shared pair
# and only the mark tells them apart.
pl = manifest["paneList"]
w('')
w('    /// The pane strip\'s palette, which is the same for every kind: only the')
w('    /// active chip is lifted out, and by luminance rather than by hue, so it')
w('    /// reads on a plain row and on the accent-colored selected row alike.')
w('    /// Fixed per appearance for that reason -- sidebar selection is')
w('    /// NSOutlineView-owned and does not reload the cell, so nothing in here')
w('    /// may depend on whether the row is selected.')
w('    static let paneListLight = ChipPaneListPalette(')
w(f'        inactive: ChipPalette(background: {color(pl["light"]["fixed"]["bg"])}, '
  f'foreground: {color(pl["light"]["fixed"]["fg"])}),')
w(f'        active: ChipPalette(background: {color(pl["light"]["fixed"]["onBg"])}, '
  f'foreground: {color(pl["light"]["fixed"]["onFg"])})')
w('    )')
w('    static let paneListDark = ChipPaneListPalette(')
w(f'        inactive: ChipPalette(background: {color(pl["dark"]["fixed"]["bg"])}, '
  f'foreground: {color(pl["dark"]["fixed"]["fg"])}),')
w(f'        active: ChipPalette(background: {color(pl["dark"]["fixed"]["onBg"])}, '
  f'foreground: {color(pl["dark"]["fixed"]["onFg"])})')
w('    )')

# Every chip, named. Emitted rather than hand-listed so a kind added to
# chips.json cannot be missed by a caller that walks all of them -- which is how
# the render check silently stopped covering a new mark.
w('')
w('    /// Every chip in the manifest, in declaration order.')
w('    static let all: [(name: String, chip: ChipDefinition)] = [')
for name in kinds:
    w(f'        ("{name}", {name}),')
w('    ]')

w('}')

os.makedirs(os.path.dirname(OUT), exist_ok=True)
open(OUT, 'w', encoding='utf-8').write('\n'.join(L) + '\n')
print(f'Generated: {OUT}', file=sys.stderr)
PY
