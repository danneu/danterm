# Decisions -- auditable decision log

No entries yet. `D1` is owed at the Phase 2 gate, after `T1` gives the fallback
path a paired per-frame bracket: it chooses between the ligature policy moved
into the face alone (`H2`, 1.8x on `F1`), a cross-frame `CTLine` memo (`H1`,
4.7x on `F1`, keeps `CTLineDraw` per cell), and the ideal shaped-glyph cache
that submits fallback cells the way ASCII cells are submitted (`H5`), with the
ideal priced beside whichever is chosen. It also settles where the ligature
policy lives (descriptor vs string attribute) against the base font's own
behaviour on the fast path, and what value, if any, the language attribute
carries (`H3`).

Rejections made during scoping (a language attribute as the fix, `CTTypesetter`
reuse, moving the draw off the main thread) are in [README.md](README.md)
`## Rejected`, with their reasons; none rests on a measurement this file
would own.
