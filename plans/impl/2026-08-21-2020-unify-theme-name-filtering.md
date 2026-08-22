# Unify theme-name filtering without unifying interaction models

## Problem

The theme browser and remote-theme picker independently implement the same
theme-name filter. Those copies can drift. Their list ownership and selection
behavior are intentionally separate: the browser previews a selection
immediately, while the picker waits for an explicit commit.

The shared cell factory already owns theme-row rendering. The remaining shared
rule is a total function of the catalog and query.

## Decision

Use one pure, app-local filter function for the ordered catalog and query. Both
surfaces call it while continuing to own their catalogs, visible names, AppKit
lifecycles, table presentation, and selection effects.

Do not put this function in `DanTermCore`. Theme-list filtering is ephemeral
presentation behavior that is only shown and discarded.

## Invariants

- I1: The same catalog and query produce the same visible names on both
  surfaces. Filtering trims spaces, compares case-insensitively, preserves
  catalog order, and restores the complete catalog for an empty or
  whitespace-only query.
- I2: Every query change recomputes selection from the current theme. A pending
  non-current picker selection is discarded even when it remains visible;
  filtering the current theme out deselects it, and clearing the query
  reselects its exact-name row.
- I3: Filtering and programmatic reselection never apply or commit a theme.
- I4: A browser selection still previews immediately. A picker selection stays
  pending until Select or double-click commits it.
- I5: Current-theme checkmarks, swatches, catalog ordering, context-menu row
  identity, and table presentation do not change.

## Proof obligations

- PO1 (I1, I2): On both surfaces, prove filtering and current-theme reselection
  across a query that excludes the current theme, clearing the query, and a
  whitespace-only query. On the picker, also prove that a query change discards
  a pending non-current selection that remains visible.
- PO2 (I3, I4): Prove that the browser sends nothing during filtering and
  programmatic reselection, while a user selection still previews immediately.
  Prove that the picker fires no selection callback during filtering, updates
  Select availability with selection validity, and commits only through its
  existing gestures.
- PO3 (I5): Keep the existing UI coverage for checkmarks, swatches, filtered
  row indexing, context menus, immediate preview, and deferred commit green.
- PO4: Run the UI harness and the full local gate.

## Rejected direction

- RI1: Do not share an `NSTableViewDataSource`/delegate controller or a composite
  theme-list view. Those designs couple distinct activation and lifecycle rules
  through callbacks or policy branches. Sharing the pure filter removes the
  accidental duplication without absorbing the deliberate differences.

## Implementation discretion

- The helper name and source-file placement are free choices. Any new source
  used by the standalone UI harness must be included in its explicit compile
  inputs.
