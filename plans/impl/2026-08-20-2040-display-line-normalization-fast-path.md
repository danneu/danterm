# DisplayLine normalization allocates nothing on text that is already one clean line

Source: LOOKUP-3 in `docs/scratch/2026-08-18-construction-audit.md` (absorbs the pruned RECON-3).

## 1. Problem and evidence

`DisplayLine.init` (`lib/DanTermCore/Sources/DanTermCore/DisplayLine.swift`) is the
constructor for every `DisplayLine`-typed projection field. Its normalizer always does three
passes with at least two heap allocations (split/join, scalar filter into a
fresh `UnicodeScalarView`, split/join again) and one Unicode property-table
lookup per scalar (`generalCategory == .control`).

Every reconcile sweep rebuilds the projections from scratch -- `reconcile()` in
`app/Reconcile.swift` has no model-equality short circuit -- so
`desiredPaneToolbar`, `desiredSidebar`, and `desiredWindowChrome`
(`lib/DanTermCore/Sources/DanTermCore/Projections.swift`) construct roughly
four `DisplayLine`s per pane, three per tab row, and two for window chrome on
every sweep, at up to ~13 Hz under the 0.075 s coalesce window. Nearly every
input is a plain title, cwd, or `user@host` that the normalizer returns
unchanged after allocating. The AppKit readouts are diffed against caches, so
the per-sweep cost is entirely on the projection side.

Load-bearing premises:

- P1. `docs/design/2026-08-10-session-owned-terminal-reported-facts.md` D6:
  terminal-reported text is stored verbatim; normalization happens once, at
  the projection boundary. `DisplayLine` is deliberately not `Codable`.
- P2. Unicode General_Category `Cc` is exactly U+0000-001F and U+007F-009F,
  and Unicode's stability policy freezes that set, so a code-point range test
  is a permanent equivalent of the property lookup.
- P3. The current whitespace collapse is grapheme-level (`Character.isWhitespace`),
  so U+00A0 and "\r\n" count as whitespace; `DisplayLineTests` pins this.
- P4. `String.singleLineName` (`EntityTitle.swift`) and
  `SingleLineLabel.stringValue` (`app/SingleLineLabel.swift`) both route through
  `DisplayLine`, so they inherit any change to it. This is not the only
  single-line normalizer in the app -- `TodoRowView.configure` collapses todo
  text with its own regex -- and nothing here changes that one.

## 2. Decision

Keep `DisplayLine` as the one normalizing boundary for terminal-reported text
(P1) and make the
normalizer allocate nothing on input that is already normal: scan first, and
return the input `String` unchanged when the scan finds nothing to change;
fall through to a rewrite only when it does. Replace the `generalCategory`
property lookup with the fixed Cc range test (P2). No stored or cached value
is added anywhere; the projection stays a pure function of the model.

Rejected direction (RECON-3): normalize at ingress and store `DisplayLine` (or
a raw+display pair) on the model. It removes the per-sweep scan entirely but
puts derived presentation into the model, which D6 and the type's own
declaration comment forbid, touches `update()` and the snapshot codec, and buys
microseconds nobody has measured.

Scope: `DisplayLine.swift`, its tests, and the audit document (mark LOOKUP-3
done; correct the P6 "combined fix" sentence that still says "Store DisplayLine
on the model, normalized once at ingress", which the vetting pass rejected).

## 3. Invariants

- I1. `DisplayLine(raw).text` is byte-identical to what it is today for every
  input: whitespace runs (grapheme-level, P3) collapse to one U+0020, leading
  and trailing whitespace is dropped, C0/C1 controls and the bidi overrides
  and isolates (U+202A-202E, U+2066-2069) are stripped, a line break separates
  words rather than gluing them, whitespace exposed by a strip is still
  trimmed, and everything else -- including ZWJ and other `Format` scalars --
  passes through unchanged.
- I2. Three rules compose in a fixed order. Whitespace first: every run of
  whitespace becomes one U+0020, and leading and trailing whitespace is
  dropped. Removal second, over what is left: a scalar disappears iff it is
  `Cc` or lies in a bidi range. The six scalars that are both whitespace and
  `Cc` -- TAB, LF, VT, FF, CR, and NEL -- are consumed by the first rule and so
  separate words rather than vanishing. No other scalar is removed. Collapse
  again third, over U+0020 only: removal can leave two spaces adjacent or a
  space at an edge, and `"a \u{0007} b"` must come back as `"a b"`, not
  `"a  b"`.
- I3. Normalization is idempotent, and text that is already normal comes back
  equal to the input.
- I4. The model, IPC, and checkpoints keep holding terminal-reported text
  verbatim; nothing `DisplayLine`-typed becomes stored or encoded (P1, unchanged).

## 4. Proof obligations

- PO1 (I1): the existing `DisplayLineTests` suite passes untouched.
- PO2 (I1, I3): added cases for a single leading or trailing space, two
  interior spaces, and an already-normal string with interior single spaces.
  Assert on UTF-8 bytes, not `String` equality, and include an input whose
  scalars are canonically decomposed (`"e\u{301}"`) so an implementation that
  recomposed it would fail. Never assert identity or allocation.
- PO3a (I2, third rule): `"a \u{0007} b"` normalizes to `"a b"`, pinning the
  collapse that runs after removal in the interior. The existing suite already
  covers whitespace exposed at an edge.
- PO3 (I2, first two rules): an exhaustive behavioral test over at least the BMP. For a scalar
  placed between two letters, `"a<s>b"` normalizes to exactly one of three
  results, and which one is decided by the composed rule of I2: `"a b"` when
  the scalar is whitespace (whether or not it is also `Cc`), `"ab"` when it is
  a non-whitespace `Cc` or a bidi scalar, and `"a<s>b"` otherwise. Drive the
  oracle from `Character.isWhitespace` and `generalCategory`, so the test pins
  the range test to the property it replaces without naming any private
  helper.
- PO4 (I4): no new test; the `lib/DanTermCore` package has no `Codable`
  conformance on `DisplayLine` and the model types are unchanged, which
  `git diff` shows.
- Measurement: none on the ladder can see this, and no test asserts timing or
  allocation. The clean path stays O(n) in scalars -- only the allocations and
  the property lookup go away -- so `DisplayLine.normalize` may still appear in
  a profile. If a number is wanted, `just benchmark-sample btop-scroll 20` is
  the diagnostic instrument: `Unicode.Scalar.Properties.generalCategory` should
  leave the main thread. `String.split` may stay, because the rewrite path is
  free to keep using it; any drop there is an observation, not a requirement.
  It issues no verdict.

## 5. Non-goals / Accepted risks

- Non-goal: changing where normalization happens (ingress, model, AppKit).
- Non-goal: changing what a display line may contain.
- Accepted risk: text that does need rewriting pays one extra scan; such
  strings are short and rare, and nothing gets heavier in memory.

## 6. Implementation discretion

- Whether the rewrite path stays three passes or becomes one state-machine
  pass; either must satisfy I1 (the collapse-before-strip ordering and the
  final re-trim are observable through PO1).
- How the scan iterates (one combined pass or one over `Character`s for
  whitespace plus one over scalars for removed code points), provided the
  fast-path condition is an exact characterization of "the rewrite would
  return the input unchanged".

## Verification

1. `swift test --package-path lib/DanTermCore --filter DisplayLineTests` -- PO1-PO3a green.
2. `just test` -- the gate, including `scripts/core-purity-lint.sh`.
3. Optional diagnostic: `just benchmark-sample btop-scroll 20`, read per
   `agent-docs/measurement-discipline.md`.
