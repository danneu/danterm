# Pane-kind chips

The small square marks that say what a pane is running: a plain terminal, Claude
Code, Codex, or an agent DanTerm doesn't have a mark for. They appear in sidebar
rows and in the pane toolbar.

## The land

```
chips.json + *.svg  ->  icon/gen-chips.sh  ->  app/ChipArtwork.swift
        |                                              |
        +--> preview.html (browser)                    +--> app/ChipRenderer.swift
                     \                                              /
                      +----- icon/render-check.sh compares them ---+
```

- **`chips.json`** -- one entry per kind: which SVG, how big to draw it
  (`fill`), how much to thicken it (`dilate`), and its light and dark colors.
- **`*.svg`** -- one `<path>` each, either stroked or filled.
- **`preview.html`** -- reads those two directly and draws every chip at every
  size in both appearances. Edit either file, reload, see the result.
- **`app/ChipArtwork.swift`** -- generated, never edited by hand. Paths arrive
  flattened to move/line/cubic/close, so the app needs no SVG parser.
- **`app/ChipRenderer.swift`** -- the only code that paints a chip. Sidebar,
  toolbar, and menu images all go through it.

## The one rule: the viewBox is the ink

A mark's `viewBox` must hug what it draws -- out to the edge of the stroke, not
the centerline. `fill` scales the viewBox, so slack inside the box shrinks the
mark by a factor the number doesn't show, and two marks' `fill` values stop
being comparable.

`gen-chips.sh` measures the drawn extent and refuses to generate if a box is
loose. It also prints the fix, because the fix is mechanical:

```
error: terminal: ink spans 0.86x0.76 of its viewBox, so fill 0.62 draws at about
0.47 and is not comparable to the other marks. Translate the path by (-1.7, -2.2),
set viewBox to "0 0 20.6 13.6", and set fill to 0.5322.
```

Do those three edits and it passes. The recomputed `fill` keeps the mark the
same size on screen, so the rule costs nothing visually.

## Working on a chip

Serve the directory (the preview uses `fetch`, which `file://` blocks):

```
cd icon/chips && python3 -m http.server 8731    # then open /preview.html
```

Resize a mark by changing `fill` in `chips.json`, never by scaling the path --
scaling ink and viewBox together does nothing, and scaling ink alone breaks the
rule above. Then:

```
./icon/gen-chips.sh        # regenerate app/ChipArtwork.swift
./icon/render-check.sh     # prove the app paints what the preview showed
```

`render-check.sh` renders through the real `ChipRenderer` and compares against
SVGs built the way `preview.html` builds its markup. It needs ImageMagick, which
is why it isn't in `just test`; `gen-chips.sh` stays dependency-free.

## Adding a kind

1. Drop the SVG here and add an entry to `chips.json`.
2. Run `gen-chips.sh` and fix the box if it complains.
3. Add the case to `ChipKind` in `lib/DanTermProtocol/Sources/DanTermProtocol/`
   and to `ChipKind.artwork` in `app/ChipView.swift`.

`preview.html` and `render-check.sh` both walk the manifest, so they pick up the
new kind on their own.
