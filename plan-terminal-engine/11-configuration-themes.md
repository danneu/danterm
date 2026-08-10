# Configuration and Themes

## Problem

Reproducing Ghostty configuration would import unrelated product decisions and
delay the engine. Designing a complete new configuration surface before real
usage would also front-load speculation.

## Decision

The initial engine uses good baked-in defaults. Internally, terminal behavior
receives coherent settings rather than reading ambient config throughout the
engine. Settings are explicit inputs to the deterministic policy described in
[Engine architecture and testability](03-engine-architecture.md), so future
configuration does not require rewriting terminal semantics.

The initial defaults include:

- macOS monospaced system font, 13 pt, normal weight
- derived line height and disabled ligatures
- one dark theme
- steady block cursor unless the application requests another behavior
- native macOS Option composition
- one-cell East Asian Ambiguous width
- fixed 10 MiB scrollback
- fixed OSC 52 policy

Future config, theme, and keybinding formats are owned by DanTerm and optimized
for DanTerm's behavior. Existing themes from other projects may be translated
into the DanTerm format; their source formats do not constrain the result.

## Invariants

- Engine semantics do not read Ghostty configuration or theme files.
- A future configuration layer changes explicit settings without introducing
  hidden ambient inputs into the pure terminal core.
- A theme defines presentation only; it cannot change parser or PTY behavior.
- Invalid future config cannot leave a pane partially configured.

## Proof obligations

- The engine launches and passes its compatibility gate without any user config
  file.
- The baked theme has readable foreground, background, cursor, selection, link,
  and ANSI palette behavior.
- Applying a complete settings value produces consistent behavior across newly
  created panes.

## Non-goals

- Ghostty config, theme, or keybinding compatibility.
- An initial preferences UI or comprehensive user config format.
- Preserving names or semantics solely because another terminal exposes them.

## Implementation discretion

- The future DanTerm config and theme syntax.
- Which defaults become configurable after the initial replacement.
