# Autosplit: creating a pane without naming one

## Problem

The iOS app can attach to a pane, send input, and read its tape stream. It
cannot create one. A phone cannot show a split layout, so the iOS paradigm is
a flat pane list and a single "New pane" action: no pane to point at, no
direction to choose.

Nothing in the current surface accepts that request. `pane.split` requires an
explicit pane and an explicit direction, so a caller holding neither cannot
ask for a pane at all.

The Mac can supply both, because it has the geometry. The obstacle is that the
decision needs two inputs living in two layers: the split tree and its ratios
(model) and the container rectangle (AppKit). The governing rule, D1/D2 of
[docs/design/2026-08-16-model-owned-pane-geometry.md](../../docs/design/2026-08-16-model-owned-pane-geometry.md),
is that pane geometry flows model -> AppKit and never back, and that the model
holds no pixels.

## Decision

Add **autosplit**: a split whose target is a tab, where the Mac chooses the
pane and the axis.

**The rule.** Among the panes of the tab that are large enough to split, pick
the one with the greatest area and cut it along its longer dimension -- wider
than tall gives side-by-side, taller than wide gives stacked, an exact square
gives side-by-side. There is no special case for a one-pane tab; the general
rule already yields side-by-side in a normally wide window.

**Where the decision lives.** Under D2 there is one structure in which a pure
decision may use a pixel fact the core is forbidden to hold: the core asks,
AppKit answers, and the answer re-enters as an ordinary message. So a
tab-targeted split mutates nothing in dispatch; it asks the runtime to measure
the tab. The runtime measures, a pure resolver decides, and the decision
re-enters as an ordinary pane-targeted split carrying the original request id.
This is the shape pane drag already uses: the runtime holds the geometry, a
pure function over the layout decides, the decision becomes a message.

Everything downstream is reused unchanged -- split creation, cwd/theme/font
inheritance, focus policy, and the reply that is deferred until the new pane's
process starts.

**Behavioral scope.**

- CLI: `danterm pane split (--pane <pane-id> -h|-v | --tab <tab-id>)`, with the
  existing launch and foreground flags on both forms. Targeting a tab is the
  autosplit request.
- Wire: one `pane.split` method whose target is either a pane with a direction
  or a tab alone.
- iOS: a "New pane" item in the bottom bar's menu, which autosplits the tab
  owning the attached pane and then attaches the phone to the new pane.

## Invariants

- **I1.** A tab-targeted split names no pane and no direction. The Mac's answer
  is the largest splittable pane, cut along its longer dimension.
- **I2.** The choice is measured from the tab the caller named as that tab is
  arranged -- whether or not it is the selected tab -- ignoring zoom, and
  leaves the tab's zoom and the window's selection untouched.
- **I3.** A pane is splittable only if its extent along the chosen axis can
  hold two panes at the layout's own minimum plus its divider. The threshold is
  derived from the layout metrics, never restated as a literal.
- **I4.** Among candidates the choice is total and reproducible: equal areas
  resolve toward the top-left, and no answer depends on dictionary iteration
  order.
- **I5.** A tab with nothing splittable is refused with a message naming that
  reason, and creates nothing.
- **I6.** An autosplit is answered on the request id the caller sent, exactly
  once, with the same deferred-until-started guarantee a pane-targeted split
  has. It produces one audit record, describing the tab the caller named.
- **I7.** A malformed target -- naming both a pane and a tab, naming neither,
  giving a direction with a tab, or omitting the direction with a pane -- is
  unrepresentable past the wire and CLI boundaries. Existence is separate: a
  well-formed target naming a tab that is not open is refused in dispatch,
  before anything is measured.
- **I8.** An autosplit inherits the ordinary split's behavior for the launch
  values the caller passed, for cwd, theme, and font, and for Mac focus, which
  still follows the foreground flag. The phone asks for the background form, so
  it never moves Mac keyboard focus.
- **I9.** The phone offers "New pane" only while its connection serves and it
  knows the attached pane's tab, and withholds it while a split it asked for is
  unanswered, so a second tap cannot open a second pane.
- **I10.** A refused autosplit is reported to the phone user with the Mac's own
  reason, leaves the connection serving, and re-offers the affordance.
- **I11.** On success the phone lands on the pane the Mac created, through the
  same attach path a pane picked from the list uses.

## Proof obligations

- **PO1** (I1, I2): the resolver's answer for a single wide pane, a tall pane,
  a square pane, and a zoomed tab measured as arranged.
- **PO2** (I3): a tab whose largest pane is one point under the threshold and
  whose second largest is above it resolves to the second.
- **PO3** (I4): repeated resolution of an equal-area layout yields one
  identical answer, and that answer is the top-left pane.
- **PO4** (I5): a tab with every pane under the threshold refuses, and the pane
  set is unchanged.
- **PO5** (I6): a tab-targeted split mutates no model state and registers no
  pending creation; the synthesized pane-targeted split answers the original
  request id once the process starts; the audit record names the tab.
- **PO6** (I7): each malformed target is rejected at its boundary with a
  distinguishable message, and a well-formed target naming an unknown tab is
  refused in dispatch without issuing the measurement.
- **PO7** (I8): across the measurement bridge, the caller's launch values reach
  the new pane; a background autosplit leaves the tab's focused pane where it
  was and a foreground one focuses the new pane; the phone's request is the
  background form.
- **PO8** (I9): the phone's affordance is absent without a serving connection
  or a known tab; a second request while one is unanswered leaves the phone
  silent; a connection that ends under an unanswered split re-offers it.
- **PO9** (I10): a refusal surfaces the Mac's reason and the connection keeps
  serving.
- **PO10** (I11): the deferred reply drives the attach, and a reply naming no
  readable pane attaches to nothing and reports instead.

PO1-PO7 are provable in `lib/DanTermCore` and `lib/DanTermProtocol` except the
measuring step, which needs the app-tests target: containers built with known,
different frames for two tabs, and the autosplit aimed at the tab that is not
selected -- so measuring the visible tab or the visible container fails the
test. PO8-PO10 are pure-model tests in `ios/DanTermMobileKit`.

## Non-goals

- A direction argument for autosplit. A caller that wants a direction names a
  pane.
- A tab picker on the phone. "New pane" targets the tab owning the attached
  pane and nothing else.
- Changing what an explicit pane-targeted split does.

## Accepted risks

- **AR1.** Landing on the new pane costs a reconnect, because attaching to any
  other pane does today. The ideal is a session that re-subscribes its tape
  stream on the live connection, which would also remove the reconnect from
  every pane pick in the list; it is out of scope here because it changes the
  connection lifecycle for paths this feature does not touch. If the reconnect
  reads badly in use, the fix is the live re-subscribe, not a workaround.
- **AR2.** Autosplit refuses in a tab too crowded to split even though the
  layout itself would clamp rather than refuse. This is deliberate: creating a
  pane below the minimum the layout defines as usable is a worse answer than
  saying no.

## Rejected ideas

- **RI1.** Store the container size in the model so dispatch can decide alone.
  It is the upward geometry flow D2 exists to forbid, it would run an update
  and a reconcile sweep on every frame of a live window resize, and it would
  put a display-dependent value into a snapshot that outlives the window.
- **RI2.** Decide without any pixels. Area and longer-dimension are
  scale-invariant, so only the splittability threshold needs real points --
  but dropping the threshold is what makes the feature dishonest.
- **RI3.** A separate wire method for autosplit. One method with a target that
  makes an illegal combination unrepresentable keeps a single split path.

## Critical files

- `lib/DanTermCore` -- the pure resolver, the split dispatch arm, and the
  command that asks the runtime to measure.
- `lib/DanTermProtocol` -- the split target type, its decoding, its audit
  description, and the CLI surface. The pane-or-tab alternation already exists
  for todos; follow it.
- `app/` -- the measuring step and an arranged-layout accessor. Autosplit
  measures the arranged layout; drop targeting keeps using the zoom-aware one.
- `ios/DanTermMobileKit` -- the request vocabulary, the affordance projection,
  and the session model's request/reply/attach path.
- `ios/DanTermMobileApp` -- the menu item and its disabled state.
- `integrations/danterm/SKILL.md` -- the CLI surface changes in the same
  change, including guidance that currently says a split always names a pane.
- `docs/design/2026-08-16-model-owned-pane-geometry.md` -- record the rule this
  feature establishes: a pixel question the core must answer travels out as a
  command and returns as a message. Without it the next such feature reads D2
  as a dead end and reaches for RI1.

## Verification

Beyond the proof obligations: launch a slot, and from a second shell run
`danterm --socket <slot> pane split --tab <tab-id>` against a one-pane tab, a
tab with an obvious largest pane, a zoomed tab, and a tab split until nothing
fits. Confirm the pane lands where the rule says, that zoom survives, and that
the crowded tab is refused without creating anything. Then drive the same
action from the phone and confirm it lands on the new pane.

## Implementation discretion

- The spelling of the target type and its cases, and the exact refusal wording.
- Whether the phone's "creating pane" wait gets its own status fact or is shown
  only on the menu item.

## Commit progress

- [x] 1. Add Mac autosplit protocol, resolution, measurement, and CLI support
- [ ] 2. Add the iOS New pane request, state flow, and menu item

## Implementation notes

- The resolved request re-enters ordinary pane-split dispatch, then restores
  zoom through `PaneTree.zoom`. A background autosplit keeps the prior zoomed
  pane; a foreground autosplit moves both focus and zoom to the new pane.
