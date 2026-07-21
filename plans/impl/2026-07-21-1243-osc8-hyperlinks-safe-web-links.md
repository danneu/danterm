# Milestone 6 slice 10: OSC 8 hyperlinks and safe web-link interaction

## Context

[plan-terminal-engine/08-input-interaction.md](../../plan-terminal-engine/08-input-interaction.md):75-79
fixes the link contract: "OSC 8 hyperlinks and automatic `http://` and
`https://` detection are supported. Both explicit and detected links are
activatable only when the resolved URL uses `http` or `https`; other schemes
remain inert text. Cmd-hover exposes allowed link interaction and Cmd-click
opens the resolved URL. File path and source-location navigation are
deferred." Standing invariants (:94-96): "Link activation is an explicit user
action and malformed links do not launch." and "Terminal output cannot
activate file URLs or custom URL handlers through an OSC 8 target." Proof
obligations (:117-121): "Explicit and detected hyperlinks have correct hover,
selection, and opening behavior, and non-HTTP schemes never become
activatable." and "Input-policy tests run without AppKit; focused integration
tests prove ... URL opening at the system boundary." The URL detector itself
is implementation discretion (:134-135). Mouse invariants that link
interaction must not violate (:86, :89-90): local selection never emits
mouse-report bytes, and report capture and its Shift override cannot both
consume one gesture.
[plan-terminal-engine/03-engine-architecture.md](../../plan-terminal-engine/03-engine-architecture.md):40
fixes the effect boundary: "Links | Terminal data determines a validated link
target | System URL opening"; :44 permits a direct system operation with no
meaningful policy to skip an artificial abstraction.
[plan-terminal-engine/10-protocols-shell-integration.md](../../plan-terminal-engine/10-protocols-shell-integration.md):36
lists OSC 8 hyperlinks as recognized protocol behavior; :57-59 bounds one
retained link target at 64 KiB and all terminal-originated metadata at 1 MiB
aggregate per pane; :77-80 requires an over-limit sequence to apply none of
itself, consume through termination, retain nothing, and resume parsing.
[plan-terminal-engine/09-renderer.md](../../plan-terminal-engine/09-renderer.md):29
includes hyperlink presentation among supported cell decoration.
[docs/research/1-external-tests.md](../../docs/research/1-external-tests.md):32
names the Alacritty reference recordings (which include a hyperlinks session)
as the Milestone 6 adoption source, converted "to a DanTerm-neutral fixture
format rather than depending on Alacritty's serialized Rust grid"; :161
assigns the links recordings to Milestone 6. libvterm's pinned commit has no
OSC 8 coverage, so the external evidence for this slice is the Alacritty
hyperlinks recording plus DanTerm-native tests.

Slice-map note: this is the links slice that slice 7
([plans/impl/2026-07-21-0730-mouse-reporting-selection-copy.md](../impl/2026-07-21-0730-mouse-reporting-selection-copy.md):402-403)
and slice 9
([plans/impl/2026-07-21-1123-bounded-osc-52-clipboard-writes.md](../impl/2026-07-21-1123-bounded-osc-52-clipboard-writes.md):41-45)
deferred in their non-goals: "OSC 8 hyperlinks, automatic URL detection,
hover, and Cmd-click form a distinct future slice with different state and
AppKit concerns." Links are the last named missing item in the Milestone 6
input/renderer gate bullet (14-roadmap.md:235-239); whether that bullet
closes is decided by a follow-up Milestone 6 closure audit, not by this
slice.

### Verified premises (against the working tree)

- The absorber already delivers what OSC 8 needs: `EscapeAbsorber` emits
  bounded `.osc([UInt8])` payloads (2 MiB encoded cap, C0-stripped, all
  three terminators normalized, cancellation discards) and
  `TerminalInputStream` forwards them. No absorber or stream changes are
  required.
- `Terminal.dispatchOSC` (Terminal.swift:485-504) is the single OSC entry
  point and currently guards `selector == 52`; `parseOSCSelector` (:506) is
  reusable. The OSC 52 handler's shape -- strict validation, apply-none on
  any violation, UTF-8 round-trip check (:501-502) -- is the template.
- Cells are `GridCell {kind, scalars, style}` (Terminal.swift:36) stamped
  from the SGR pen `currentStyle` (:307) at `printNarrow` (:3141),
  `printWide` (:3161 plus wide-tail), and `upgradeClusterToWide`
  (:3079-3107). REP re-prints through `print(scalar)` and inherits the pen;
  DECALN (:2712-2714) stamps fresh cells. All three SGR reset sites
  (:2406, :2468, :2919) assign `currentStyle = TerminalStyle()`; erase and
  blank paths build default cells. There is no interning pool anywhere in
  the engine; `Terminal` is a pure `Equatable, Sendable` value and
  TerminalCore has zero imports, enforced by `scripts/core-purity-lint.sh
  --forbid-imports` -- Foundation `URL` cannot be used in the core.
- Reflow moves whole `GridCell` values (`ReflowUnit.cells` through `pack`,
  :1982-2004); wide tails are resynthesized at :1906 from the head's style.
  `resizeHeight` moves whole rows. Scrollback eviction is byte-budgeted
  (`scrollbackByteCost` :1435, formula `32 + 8 * scalars.count` with slack
  for a small optional per-cell field; the cost literals pinned at
  :753-756 need not change).
- Damage is recorded by diffing `DamageActionSnapshot` (:49) around each
  action (`recordDamage` :395); selection is the existing analog for
  interaction-driven, non-byte-feed, damage-tracked state (`setSelection`
  :815-825). The planner reads selection directly off the terminal
  (`selectionRuns`, RenderFramePlanner.swift:101-130), so terminal-owned
  hover state needs no `RenderPresentation` change; `decorationRuns`
  (:302-351) and the executor's `drawDecorationRuns` already render
  underlines.
- Public text APIs suffice for detection: `logicalLineRange(at:)`
  (Terminal.swift:857) and `characterRange(at:)` (:875) traverse
  soft-wrapped logical lines over viewport and history.
- Pointer precedence is pure and centralized: `decideTerminalPointer`
  (TerminalInteractionPolicy.swift:222-320) latches per-button ownership;
  `pointerOwner` (:378-390) arms locally iff `shift || tracking == .off`.
  The paneMenu arm is the effect-closure precedent: ownership latched at
  down, payload delivered at up, closure threaded through
  `sendPointer(_:onPaneMenu:)` (TerminalPTYHost.swift:276-279) and invoked
  in `applyPointer` (:471-472).
- `TerminalKeyModifiers` (TerminalInputEncoding.swift:68-83) has
  shift/alt/control only; bit `1 << 3` is free. `mouseModifierBits`
  (:253-257) maps only those three, so a new bit is inert in mouse reports
  by construction. The view drops Cmd today: `terminalModifiers`
  (SwiftTerminalSessionView.swift:677-683) omits `.command`, `keyDown`
  (:219) early-returns on Cmd, and there is no `flagsChanged` override. The
  tracking area (:129-135) has `.mouseMoved` but not
  `.mouseEnteredAndExited`. The injectable-seam precedent is
  `selectionPasteboard` (:31); existing direct `NSWorkspace.shared.open`
  precedent is the Ghostty-era OPEN_URL handler (app/GhosttyApp.swift:558).
- `app/LinkPreviewView.swift` is the existing non-interactive Cmd-hover URL
  pill (`hitTest` returns nil) and is already compiled into `test-ui.sh`
  (:60) with its own tests (:76). tests-ui mouse events take
  `modifierFlags` directly (`makeMouseEvent`), so Cmd-click tests need no
  CGEvent changes; the controller shim
  (tests-ui/SwiftTerminalSessionViewTestShim.swift) must mirror any new
  controller callback.
- The external fixture:
  `references/alacritty/alacritty_terminal/tests/ref/hyperlinks/` holds a
  1,175-byte raw recording (140x32 per `size.json`) exercising anonymous
  opens, `id=42` reuse, ESC-backslash termination, an empty-URI-with-params
  close, and a URI containing a literal `;`
  (`http://example.com/naoheu;ntahoeu`). The neutral fixture runner
  currently enumerates only `Fixtures/libvterm`, and
  `NeutralTerminalProvenance` validates only danTerm/libvterm sources; the
  libvterm manifest count ("thirty-six") is unaffected by adding an
  Alacritty directory.

User-settled toggles: hover indication ships the full UX -- pointing-hand
cursor, hovered-run underline, and the existing `LinkPreviewView` URL pill
wired to the engine pane. Cmd-click always wins over application mouse
reporting: a Cmd-modified left-down over an activatable link takes the link
arm regardless of tracking mode and the gesture is never reported
(Ghostty/iTerm2 behavior); the condition is kept isolated in the pointer
policy so the conservative alternative is a one-line change.

## Decision

**Scope:** the core parses bounded OSC 8 open/close sequences into a
budgeted per-terminal link-target table and a link pen separate from SGR
state; printed cells carry link identity through erase, reflow, scrollback,
and eviction; pure resolution combines explicit cell links with hover-time
`http`/`https` detection behind one activation-validation gate; hover and
Cmd-click flow through the existing pointer-policy owner path via a new link
arm and a damage-tracked hover state; the view forwards Cmd, drives hover
indication (cursor, underline, pill), and opens click-time-revalidated URLs
through an injectable opener seam; the Alacritty hyperlinks recording joins
the neutral corpus; core, policy, owner, fixture, and UI-harness tests pin
the behavior; the roadmap gains the Slice 10 entry. Nothing else.

- **D1 -- OSC 8 grammar and bounded dispatch.** `dispatchOSC` becomes a
  selector switch; selector 8 splits the payload at its first two
  semicolons into params and URI, with everything after the second `;`
  (including further semicolons) part of the URI. Params are
  colon-separated `key=value` pairs; only `id` is meaningful; unknown or
  malformed params are ignored without rejecting the sequence. The URI must
  round-trip UTF-8 (the OSC 52 shape). An empty URI closes the pen
  regardless of params. Every other selector keeps today's inert
  consumption; OSC 52 is untouched.
- **D2 -- Link identity separate from SGR state.** Cells carry an optional
  small link id distinct from `TerminalStyle`, stamped from a link pen that
  is a sibling of, not a member of, the SGR pen. SGR resets (including
  SGR 0) never touch the link pen; only an OSC 8 close, soft reset, and
  hard reset clear it. DECSC/DECRC do not save or restore it (recorded
  deviation from Alacritty, whose cursor template carries the hyperlink).
  Erased, blanked, DECALN, and resize-fill cells never carry a link. Wide
  tails and reflow-resynthesized cells carry their head's id so hit-testing
  any column of a glyph resolves. `TerminalStyle`, its equality, and
  fixture `cellStyles` are untouched.
- **D3 -- Budgeted link-target table.** The terminal owns a value-type
  table from link id to target (URI plus optional explicit id string) with
  a byte-count cache. Minting: an open matching the current pen's target
  reuses the pen's id; an open with `id=` reuses the existing id for the
  same (id, URI) pair -- one logical link across non-contiguous cells, per
  the OSC 8 convention; otherwise a fresh id is minted. A target whose
  URI-plus-id bytes exceed 64 KiB is not applied: pen unchanged, nothing
  retained, parsing resumes (10-protocols :57-59, :77-80). An accepted
  open that would push retained link metadata past 1 MiB evaluates one
  mark-and-sweep over live ids (viewport, scrollback, inactive screen and
  pen) and admission on a candidate value. The sweep, new target, and pen
  commit atomically only if admission succeeds; refusal commits none of the
  candidate. The same 64 KiB per-target and 1 MiB per-pane envelope includes
  targets retained for hover, an armed click, and owner-to-view handoff; a
  target that cannot fit is not retained or armed. The table and retained
  interaction state participate in `Terminal` equality.
- **D4 -- Resolution and activation validation.** The engine exposes the
  per-cell hyperlink (URI, optional explicit id) on its inspection surface
  and a pure activatable-link query for a text position: an explicit cell
  link resolves to the contiguous same-id run across the soft-wrapped
  logical line; otherwise the detector (D5) is consulted; either result
  passes one conservative scalar-level HTTP(S) URI gate -- a
  case-insensitive `http` or `https` scheme, a syntactically valid authority
  with a non-empty RFC 3986 host, a decimal port in `1...65535` when present,
  and no whitespace or control scalars -- or resolves to nothing. Non-HTTP(S)
  and malformed explicit targets are retained as inert cell metadata (the
  parser stays policy-free and bounded-only); they never resolve to an
  activatable link.
- **D5 -- Hover-time automatic detection.** `http`/`https` runs are
  detected on demand over a bounded window of the logical line containing
  the queried position, using the existing logical-line traversal. Detection
  itself creates no cache or table entry; only a target admitted under D3 may
  be retained as current interaction state. Detected targets share D3's
  64 KiB per-target limit. Detector grammar (window size, delimiters,
  trailing-punctuation trimming) is discretion under 08:134-135.
- **D6 -- Hover state in the terminal, damage-tracked.** The terminal
  gains a hovered-link state (anchored range plus target) mutated only
  through set/clear entry points that record damage for exactly the
  affected viewport rows, the `setSelection` shape. Hover is set by
  Cmd-modified pointer moves that resolve an activatable link, cleared by
  moves that do not, by Cmd release, pointer exit, and resets. The anchored
  range follows its logical text like selection anchors; indication under a
  stationary pointer may go stale until the next move or modifier change,
  which is safe because activation always re-resolves at click time (D7).
- **D7 -- Pointer policy: local-only Cmd and the link arm.**
  `TerminalKeyModifiers` gains `.command` (bit 3). Mouse and key encoding
  normalize modifiers to the protocol-relevant Shift/Alt/Control subset
  before modifier emptiness, parameter, mode, and keypad decisions, so Cmd
  is byte-inert. `decideTerminalPointer` gains a link ownership
  arm: a left-down whose modifiers contain `.command` and whose position
  resolves to an activatable link latches link ownership regardless of
  tracking mode (the settled toggle, isolated in one condition), emits zero
  report bytes for the whole gesture, and stores an admitted activation token
  for the originating contiguous run. The token is invalidated by pointer
  exit or any out-of-bounds move/release; matching up must be in bounds and
  re-resolve to the same originating run, not merely an equal target. Drags
  within a link-armed gesture neither report nor select. While the link arm
  is live it has byte precedence over every simultaneously report-owned
  button for move handling and its own release. Cmd-modified events not over an
  activatable link fall through to today's ownership rules unchanged, so
  every pre-slice gesture's bytes and decisions are identical. Hover
  mutations ride pointer-move decisions as presentation-only outputs:
  indication may coexist with reported motion, and report bytes remain
  governed solely by existing ownership rules.
- **D8 -- Owner and session plumbing.** The pane owner applies hover
  mutations through the terminal's entry points (publication rides the
  existing terminal-inequality update path) and invokes a new open-link
  closure threaded through `sendPointer`, the paneMenu shape. The
  controller gains an open-link callback (nilled at teardown with its
  peers), a pointer-exit/out-of-bounds cancellation entry point, and a
  hovered-target reader for the pill. Neutral-recording replay applies hover
  mutations but never performs an open -- effects are recomputed, not
  executed, the slice 9 containment shape.
- **D9 -- View boundary.** The session view maps `.command` into forwarded
  pointer modifiers; adds a `flagsChanged` override that replays the
  last-known pointer position as a synthesized move so hover appears and
  disappears with the Cmd key while stationary; adds
  `.mouseEnteredAndExited` tracking and forwards exit/out-of-bounds movement
  to invalidate any link arm as well as clear hover; shows the
  pointing-hand cursor and the existing `LinkPreviewView` pill (view-local
  chrome driven by the hovered target, with its existing dodge behavior)
  while a hovered link exists. On the open-link callback it constructs a
  Foundation URL and enforces D4's equivalent scheme, authority, non-empty
  host, and optional-port checks -- defense in depth at the boundary -- then
  calls an injectable opener seam defaulting to `NSWorkspace.shared.open`,
  the `selectionPasteboard` shape. No Elm `Msg`, no `Command`, no
  `TerminalSessionEvent`; the Ghostty-era link path is untouched.
- **D10 -- Renderer hover underline.** The frame planner underlines the
  hovered run by forcing single underline on hovered viewport cells that
  have no underline (existing double/curly decoration is preserved),
  feeding the existing decoration-run and execution paths unchanged.
  `RenderPresentation` is unchanged; the planner reads hover off the
  terminal like selection.
- **D11 -- Fixture schema and the Alacritty corpus entry.** Fixture
  expectations gain a per-cell hyperlink assertion (position, URI, optional
  explicit id, nullable for explicit no-link). `NeutralTerminalProvenance`
  gains an Alacritty source (upstream URL, pinned commit of the vendored
  checkout, Apache-2.0, license notice file), and the runner enumerates an
  `Fixtures/alacritty` directory beside libvterm. The hyperlinks recording
  is converted offline into one neutral fixture with DanTerm-authored
  expectations (viewport text, link cells, no-link prompt cells),
  consulting Alacritty's `grid.json` while authoring but not
  machine-translating it. The libvterm manifest and its "thirty-six"
  ledger are untouched.
- **D12 -- Roadmap.** Add the checked Slice 10 sub-bullet under
  Milestone 6 linking the promoted plan. The input/renderer gate bullet
  (14-roadmap.md:235-239) and the external-families bullet (:243-246) are
  not checked by this slice; links were the gate's last named missing item,
  and closure is adjudicated by the follow-up Milestone 6 closure audit.

## Invariants

- **I1 (bounded retention).** At most 64 KiB per explicit or detected link
  target and 1 MiB aggregate retained link metadata per pane across the table,
  hover, armed click, and owner-to-view handoff, always; an over-limit open
  applies none of itself,
  retains nothing, and parsing resumes; the absorber's existing caps are
  unchanged.
- **I2 (pen semantics).** SGR changes and SGR resets never open, close, or
  alter the link pen; only OSC 8 (open/close), soft reset, and hard reset
  do; erased, blanked, DECALN, and resize-fill cells carry no link;
  DECSC/DECRC do not capture the pen.
- **I3 (identity carry).** Cells of one logical link keep that identity
  unchanged through wide-cluster printing, scrollback push, viewport
  projection, width and height resize with reflow (including wide-tail and
  spacer resynthesis), and eviction -- never retargeted to unrelated text.
- **I4 (activation safety).** Opening requires an explicit Cmd-click that
  re-resolves at click time to a target passing the engine's http/https
  validation and the view's Foundation-URL scheme re-check; every other
  scheme and every malformed target is inert at hover and at click; the
  injectable opener is the only URL-opening touchpoint.
- **I5 (byte exclusivity).** A link-armed gesture emits zero mouse-report
  bytes at down, drag, and up, including while another button has report
  ownership; `.command` never changes any encoded mouse or key bytes; every
  gesture not taken by the link arm produces bytes and decisions identical
  to before this slice.
- **I6 (hover honesty).** Hover indication exists only after a
  Cmd-modified pointer event resolved an activatable link; it is
  damage-tracked, cleared on Cmd release, pointer exit, and reset; stale
  indication can never cause an activation (I4 re-resolution).
- **I7 (determinism).** Identical byte streams under any chunking produce
  identical `Terminal` values including the link table and minted ids; a
  rejected sequence leaves the terminal whole-value equal to never having
  received it.
- **I8 (containment and purity).** Link targets flow only terminal ->
  pane owner -> controller -> view; nothing link-shaped enters the Elm
  model, the `TerminalSessionEvent` vocabulary, or the recording schema;
  TerminalCore stays import-free.

## Proof obligations

- **PO1 (I1, I7).** Core OSC 8 parser proofs, the OSC 52 suite's shape:
  three-terminator equivalence, every-split-point invariance, the params
  matrix (id reuse, unknown keys, malformed params, empty-URI close with
  and without params, semicolons inside the URI), UTF-8 rejection, the
  64 KiB accept/reject boundary pair for explicit and detected targets,
  aggregate-budget sweep-then-refusal with apply-none observables, combined
  table/hover/arm pressure, and whole-value rejection purity against a
  baseline terminal including a refusal whose candidate sweep found dead
  entries.
- **PO2 (I2).** Pen-semantics proofs: the pen survives SGR 0 in all its
  spellings, is cleared by soft and hard reset, is not captured by
  DECSC/DECRC; erase, blank, DECALN, alt-screen, and resize-fill cells
  expose no hyperlink; REP-printed cells inherit the pen.
- **PO3 (I3).** Identity-carry proofs over the existing resize and
  scrollback suites: links spanning soft wraps and wide glyphs through
  width shrink and grow, hyperlink exposure on scrollback rows, eviction,
  and alt-screen isolation.
- **PO4 (I4).** Resolution proofs without AppKit: detector positive and
  negative positions including wrapped URLs and window bounds; the
  validation gate rejects `javascript:`, `file:`, `data:`, `mailto:`, and
  every non-http(s) scheme, plus hostless, empty-host, whitespace/control,
  and invalid-port HTTP-shaped values, while accepting valid authorities
  with mixed-case http/https schemes; explicit links take precedence over
  detection; an inert explicit link resolves to nothing while remaining
  visible cell metadata.
- **PO5 (I5, I6).** Policy proofs across all tracking modes: the link-arm
  lifecycle emits zero input bytes while reporting-owned and
  selection-owned gestures are byte-identical to pre-slice decisions;
  out-of-bounds movement/release, pointer exit, and release over a separate
  run with the same target yield no open effect; a report-owned button held
  throughout a Cmd-left link gesture cannot cause that link gesture's motion
  or release to emit bytes; hover set/clear decisions on Cmd and non-Cmd
  moves; `.command` produces byte-identical legacy, application-cursor,
  application-keypad, Kitty-keyboard, and mouse-report encodings.
- **PO6 (I6).** Damage and render proofs: hover set/clear damages exactly
  the affected rows; the planner underlines exactly the hovered viewport
  run, preserves existing decorations, and carries hover decoration
  through damage clipping; the anchored range follows its logical text
  through width reflow and height migration, and disappears rather than
  attaching to unrelated cells after overwrite or eviction; soft and hard
  reset clear hover and damage its previously visible rows.
- **PO7 (I4, I8; discharges 08's system-boundary obligation with PO9).**
  Owner and session proofs: a Cmd-click pointer sequence delivers exactly
  one open-link effect with no input writes; hover mutation publishes an
  update; pointer-exit cancellation clears hover and invalidates the arm;
  table/interaction/handoff pressure stays inside I1's shared envelope; no
  delivery after teardown; recording replay applies hover and never opens.
- **PO8 (I3, I7; discharges the research-doc Alacritty links
  assignment).** The converted hyperlinks fixture passes under authored,
  bytewise, and every-split-point chunkings with its provenance validated;
  all existing fixtures replay unchanged.
- **PO9 (I4, I8).** UI-harness proofs: Cmd-click forwards
  `.command`-bearing pointer events; valid `http`, `https`, and mixed-case
  scheme targets reach the injected opener as URLs; `file`, unparsable,
  hostless, empty-host, and invalid-port targets never reach it; Cmd
  `flagsChanged` synthesizes a hover move; pointer exit clears hover and
  invalidates an arm through the controller; hovered-link state installs the
  pointing-hand cursor; the pill shows the hovered target and hides on clear.
- **PO10 (I8).** The core-purity lint (`--forbid-imports` on TerminalCore)
  and the existing boundary lints in `just test` stay green.

**Slice exit gate:** `just test` green, `just build` green, `just test-ui`
green; roadmap Slice 10 sub-bullet added linking the promoted plan. Live
sanity check, non-gating: in a Swift-engine pane,
`printf '\e]8;;https://example.com\e\\example\e]8;;\e\\\n'` -- Cmd-hover
shows the pointing hand, underline, and pill, Cmd-click opens the browser;
`printf '\e]8;;file:///etc/hosts\e\\nope\e]8;;\e\\\n'` stays fully inert;
`echo https://example.com` Cmd-hovers via detection; `cat` a multi-MiB
stream of distinct OSC 8 opens and confirm the pane stays responsive.

## Non-goals

- File path, source location, or custom-scheme link targets
  (08-input-interaction.md:127; 15-open-questions.md defers file/source
  links).
- Any other OSC selector's semantics: title, OSC 7 cwd, notifications,
  progress -- still consumed inertly; their slices come later.
- Broader shell integration.
- A general Alacritty replay adapter or the wider Alacritty recording
  family; those stay with the Milestone 6 external-families roadmap
  bullet.
- Highlighting non-contiguous same-id regions on hover (the OSC 8 spec's
  suggestion); this slice highlights the contiguous run.
- Plain-click, middle-click, or keyboard link activation; copy-link-address
  UI.
- Config knobs for schemes or detection.

## Accepted risks

- **AR1.** Hover indication can go stale under a stationary pointer while
  output scrolls; safe by I4/I6 (click-time re-resolution), refreshed on
  the next move or Cmd transition.
- **AR2.** Dead link-table entries persist below the 1 MiB budget until a
  breach-triggered sweep; bounded by the budget itself.
- **AR3.** Under the settled toggle, a mouse-capturing child never sees
  Cmd-clicks over links; deliberate, Ghostty/iTerm-consistent, and a
  one-condition change if revisited.
- **AR4.** The bounded detection window can miss URLs longer than the
  window or centered far from the pointer.
- **AR5.** Pathological streams minting distinct targets degrade to
  refusing new targets, never to unbounded memory; refused opens leave the
  prior pen active per apply-none, so following text continues any open
  link.
- **AR6.** DECSC/DECRC excluding the link pen is a recorded deviation from
  Alacritty's cursor template; xterm's DECSC attribute list excludes
  hyperlinks, which is the semantics adopted.

## Rejected ideas

- **RI1.** Link id inside `TerminalStyle` -- requires pen-preserving
  carve-outs at every SGR reset site, risks link leakage through
  background-erase fills, fragments renderer runs on link boundaries, and
  churns fixture `cellStyles` equality; a sibling field gets SGR
  independence and link-free erasure by constructor default.
- **RI2.** Reference-counted or Arc-interned link objects (Alacritty's
  shape) -- reference semantics have no place in a pure `Equatable,
  Sendable` value; refcounting touches every cell-overwrite site, while a
  breach-triggered sweep gives the same hard bound.
- **RI3.** Stored detected-link spans -- invalidation on every print,
  erase, and reflow; hover-time recomputation over logical lines is
  bounded and reflow-proof.
- **RI4.** Scheme rejection at parse time -- the contract's inertness is
  activation-level (08:76-78); a policy-free bounded parser retains
  non-HTTP targets as inert metadata without re-parsing history if policy
  ever widens.
- **RI5.** Routing opens through the Elm model, `AppRuntime.perform`, or
  the drained frame-state channel -- opening is user-gesture-driven, not
  output-driven; the paneMenu closure path exists for exactly this shape,
  and slice 9 already established the containment argument at the view
  seam.
- **RI6.** Foundation `URL`/`NSDataDetector` in the core -- forbidden by
  the import lint; the scalar-level validator keeps resolution
  deterministic and AppKit-free, with Foundation validation repeated only
  at the boundary.
- **RI7.** Threading hover through `RenderPresentation` -- the planner
  already reads terminal-owned interaction state (selection) directly;
  terminal-owned hover gets damage tracking and engine-level testability
  for free.

## Implementation discretion

- Detector grammar details (window size, delimiter set, and
  trailing-punctuation trimming), per 08:134-135.
- Table representation, dedup lookup structure, per-entry cost constant,
  and sweep mechanics, provided I1/I7 observables hold.
- All new spellings: the cell field, pen, hover entry points, decision
  fields, callbacks, opener seam, fixture JSON fields, and whether
  resolution helpers live in Terminal.swift or a sibling file.
- Hover cursor mechanics and last-pointer-location representation in the
  view.

## Commit progress

- [x] 1. Add bounded OSC 8 hyperlink state and pure link resolution
- [ ] 2. Add hover, activation policy, renderer, and pane-owner plumbing
- [ ] 3. Add AppKit Cmd-hover and safe URL opening
- [ ] 4. Add Alacritty hyperlink fixture provenance and roadmap entry
