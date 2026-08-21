# Pane Toolbar Whole-Render Refactor

## Problem and outcome

`PaneWrapperView` receives one `PaneToolbarRender` decomposed into 13 arguments.
Defaults permit partial updates, while separate `isZoomed` and `hasSplits`
fields mirror part of the last render for menu construction.

The runtime also caches the render outside the wrapper. That cache can advance
when no wrapper exists, recording a value as applied even though no view
received it.

Replace this with one whole-value application boundary. A newly added
projection field must reach the view automatically, and every application must
replace all toolbar state instead of preserving omitted values.

## Decision

- Pass `PaneToolbarRender` whole from `reconcilePaneChrome` into
  `PaneWrapperView`. Remove the field-by-field production mapping and every
  partial-update default.
- Make the wrapper the only owner of the last applied render. Offer every
  desired pane render to its wrapper on each reconcile, and let the wrapper skip
  an equal value.
- Remove the runtime's pane-toolbar cache. A missing wrapper consumes no render,
  so the same value is offered again on the next reconcile.
- Derive both toolbar presentation and the pane menu's zoom title and enablement
  from that same applied render.
- Remove the separate `isZoomed` and `hasSplits` properties and their constructor
  arguments. Wrapper construction has an explicit unrendered state; its neutral
  presentation is the same as today's `isZoomed: false, hasSplits: false`
  placeholders and hides render-dependent affordances.
- If a menu is requested before the first render, show disabled "Zoom Pane".
- Convert UI fixtures to construct complete render values through one test
  fixture. That fixture must initialize `PaneToolbarRender` exhaustively so a
  new field produces a compile error in one place.

No public, CLI, wire, persistence, or terminal-engine interface changes.
`PaneToolbarRender` and its derivation remain unchanged.

## Invariants

- **I1:** The reconciler passes one complete render value, and
  `PaneToolbarRender` fields have no defaults; no producer, production mapping,
  or test fixture can silently omit a new projection field.
- **I2:** Applying a render replaces every toolbar field. Nil, false, and zero
  values clear the presentation left by the previous render.
- **I3:** The zoom button and pane menu use the same applied zoom and split facts.
- **I4:** Wrapper construction does not claim initial model facts through
  placeholder booleans.
- **I5:** Existing label, progress, remote, agent, chip, alert, TODO, zoom, split,
  and grid-claim behavior remains unchanged.
- **I6:** A render offered while its wrapper is missing remains unapplied and is
  retried unchanged after the wrapper appears.

## Proof obligations

- **PO1 (I1):** Convert the production caller and UI tests to the whole-value
  interface. Compilation must require a complete `PaneToolbarRender`.
- **PO2 (I2, I5):** Apply a populated render followed by a neutral render and
  verify that all visible accessories, progress, badges, TODO state, zoom state,
  and grid-claim state clear.
- **PO3 (I3):** Preserve the existing persistent-wrapper test across
  single-pane, split, zoomed, and back-to-single transitions; the menu and zoom
  button must agree after every render.
- **PO4 (I5):** Preserve the existing zoom-direction, grid-claim, chip-detach,
  and single-line toolbar tests after they use complete renders.
- **PO5:** Keep the existing core projection tests unchanged; this refactor
  changes delivery and ownership, not projection semantics.
- **PO6 (I4):** On a freshly constructed wrapper with no render applied, verify
  that the zoom button is collapsed and the pane menu contains a disabled
  "Zoom Pane" item.
- Follow repository TDD: change or add the whole-render behavioral test first,
  confirm the expected failure, then implement. Run `just test` and
  `just test-ui`.

## Non-goals and rejected alternatives

- Do not change `PaneToolbarRender` fields, projection derivation, reconcile
  scheduling, other reconcile caches, menu actions, or other live-model menu
  items.
- Do not introduce a general projection-rendering abstraction; other views
  already accept their projections whole.
- Reject retaining the runtime toolbar cache for reconcile-pass uniformity. It
  duplicates the wrapper's baseline and can record a render that no wrapper
  received.
- Reject making only the three booleans non-optional. It preserves the 13-field
  drift boundary.
- Reject reading current model zoom state when the menu opens. A coalesced
  reconcile could make the menu describe newer state than the toolbar being
  shown.
- Reject requiring an initial toolbar render during `PaneHost` construction. It
  would duplicate projection work and couple staged host creation to reconcile
  inputs.

## Implementation discretion

- Private names and the exact representation of the wrapper's
  unrendered/rendered state.
- The organization and naming of the exhaustive UI-test render fixture.
