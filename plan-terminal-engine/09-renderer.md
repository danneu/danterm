# Renderer

## Problem

The first renderer must prove terminal geometry, Unicode fallback, selection,
cursor, and damage behavior without making GPU optimization a prerequisite for
terminal correctness.

## Decision

The initial renderer is an AppKit renderer using CoreText/CoreGraphics and
macOS font fallback. It consumes terminal state and damage but does not own
terminal semantics.

Rendering separates deterministic planning from Apple-framework execution.
Given a read-only terminal snapshot and explicit presentation inputs, planning
decides the required drawing work; CoreText/CoreGraphics resolve and execute
the system-specific glyph and drawing operations. Procedural terminal glyphs
follow the separate, implementation-facing
[terminal sprite system contract](../docs/terminal-sprites.md).

Initial presentation defaults are:

- macOS monospaced system font at 13 pt, normal weight
- ligatures disabled
- line height derived from font metrics
- one baked-in dark theme
- 16-color, 256-color, and RGB color support
- a steady block cursor by default
- application-requested cursor shapes; blink variants render steadily until
  the deferred post-milestone enhancement lands
- selection, hyperlink, underline-style, and other supported cell decoration
- Retina-correct geometry

Metal is a possible later renderer, not an initial dependency.

## Invariants

- Rendering never changes terminal state or terminal cell width.
- Font fallback changes glyph choice without changing grid geometry.
- Damage outside the visible pane causes no drawing work.
- A newly visible pane can produce a complete frame from current terminal state.
- Renderer teardown leaves no timer, display callback, or AppKit message aimed
  at a deallocated object.
- Identical snapshots and explicit presentation inputs produce identical
  planned drawing work.

## Proof obligations

- Deterministic planning fixtures cover colors, decorations, selection, cursor,
  damage, and wide-cell geometry; focused AppKit snapshots prove glyph
  placement and display-scale behavior.
- Spanish, Chinese, basic emoji, and fallback glyphs render without overlap or
  neighboring-cell corruption.
- Damage redraw, including after primary- and alternate-screen width or height
  changes, produces the same final frame as a full redraw.
- Hiding and revealing a pane suppresses hidden drawing and then restores a
  complete correct frame.

## Non-goals

- Initial Metal rendering.
- Ligatures, terminal image protocols, or RTL shaping.
- User-configurable font and line-height controls in the first engine slice.

## Accepted risks

- The correctness-first renderer may use more CPU during heavy visible output
  than a mature GPU renderer. Behavioral correctness and quiescent idle behavior
  take priority.

## Implementation discretion

- Glyph caching, batching, dirty-region merging, and drawing primitives.
- The threshold for replacing or supplementing the renderer with Metal.
