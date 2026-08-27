# Declare the split-direction vocabulary once

## Context

The closed two-case vocabulary `{horizontal, vertical}` for a pane split is
declared twice and hand-written nine times across the tree. Adding a third
direction today means finding nine sites by hand; missing one is a silent
disagreement between what the model holds, what the disk stores, and what a
client is told.

Declarations:

- `SplitNodeModel.Direction` -- `lib/DanTermCore/Sources/DanTermCore/Model.swift`
- `PaneSplitDirection` -- `lib/DanTermProtocol/Sources/DanTermProtocol/PaneSplitArgs.swift`

The same two cases, in two modules, with two hand-written conversions between
them (`Update.swift`, `IpcDispatch.swift`). Beside them, `SplitNodeSnapshot.split`
carries the direction as a bare `String`, mapped by hand in four more places:
a switch to encode a checkpoint, a switch to decode one, a ternary to encode an
IPC request, a switch to decode one, and a ternary in the IPC entity encoder.
The decode switch ends in `print("[init] Unknown direction:")` + `return nil`,
which rejects the whole state file.

A second closed vocabulary is stated the same way: the `"leaf"` / `"split"` node
tag appears as six bare string literals, four in `SplitNodeSnapshot`'s
hand-rolled `Codable` and two more in the IPC entity encoder.

Outcome: one declaration, as data. A direction the model does not have stops
being constructible in memory, so the disk, the wire, and the model cannot
disagree about the vocabulary.

## Decision

Declare the vocabulary once in `DanTermProtocol` as a `String`-raw-valued
`Codable` enum, and let every layer use it directly:

- `DanTermProtocol` is the base layer -- it has no package dependencies, and
  both `DanTermCore` (which already imports it) and `app/` reach it. It is the
  only module in which one declaration can serve the model, the checkpoint, and
  both IPC directions.
- `SplitNodeModel.split` and `SplitNodeSnapshot.split` both carry that type.
  `PaneSplitDirection` is deleted rather than aliased -- backwards compatibility
  is not a constraint here, so a shim would only preserve the second name.
- Both persistence switches, both IPC string mappings, the entity-encoder
  ternary, and both enum-to-enum conversions are deleted. The synthesized
  raw-value conformance replaces all of them.
- The `"leaf"` / `"split"` tag becomes a raw-valued enum in the same series. Its
  decode switch stays -- it deliberately admits a bare `{"type": "leaf"}` with
  no `pane` key -- but all six literals go. This one stays internal to
  `DanTermCore`: both its consumers live there, so promoting it to the base
  layer would buy nothing.
- The CLI's `-h` / `-v` mapping stays. It maps a genuinely different vocabulary
  (flags) onto this one, which is a real translation, not a second declaration.

### Rejected: a snapshot-owned DTO enum

The codebase does split model values from checkpoint DTOs (`PaneGridOverride`
vs `PaneGridOverrideSnapshot`; `AgentSession`'s doc states the rule). That split
earns its place where the two types differ: `PaneGridOverride` has a failable
init over a bounded range and its snapshot is genuinely wider -- two unvalidated
`Int`s. A direction DTO would be case-for-case identical to the model enum, so
it would be a third declaration of the same vocabulary plus a conversion
function -- the exact failure this change removes. The DTO rule is about
validation asymmetry, not about never sharing a type.

### Rejected: degrading a bad direction locally

A sibling item argues a corrupt `agentSession` should drop that field rather
than fail the file. A direction has no such answer: every substitute is a
layout the user never wrote, applied silently. Failing is correct.

## Invariants

- **I1.** The on-disk checkpoint and the IPC JSON keep the tokens `"horizontal"`,
  `"vertical"`, `"leaf"`, `"split"` exactly. This is external compatibility:
  hand-authored `--init` files, exported state files, and `danterm` clients read
  them.
- **I2.** A `SplitNodeModel` or `SplitNodeSnapshot` naming a direction outside
  the declared vocabulary is not constructible.
- **I3.** A state file whose split names an unknown direction does not restore.
  It fails at the field, as `AppInitFileLoadError.decodeFailed`.
- **I4.** The failure names the offending field. Today `parseSplitNode` prints
  the bad token; moving the check into the decoder must not cost the diagnostic,
  so `decodeFailed` carries the decoder's description and both consumers
  (`--init` startup and Import State) surface it.
- **I5.** A load failure has one stated reason, not one per consumer. Both
  consumers read that reason and add only their own framing, so neither can
  discard the field name while the other keeps it.
- **I6.** `danterm pane split -h` / `-v` still produce the same IPC request and
  the same resulting layout.

## Proof obligations

- **PO1 (I1).** The existing byte-for-byte v3 fixture round trip
  (`TypedSnapshotIdentityTests`) pins `"horizontal"`, `"leaf"` and `"split"`.
  The obligation is that this test passes unedited. It does **not** cover
  `"vertical"`, which no persistence test asserts on either side -- so add one
  encode-side assertion that a saved vertical split writes the `"vertical"`
  token, read out of the encoded JSON text rather than the Swift value. Write it
  before the retype so it is green on both sides; that is what proves the change
  did not move the wire.
- **PO2 (I1, IPC half).** The entity encoder and the request decoder keep their
  tokens for both directions. Existing `UpdateIpcTests` assertions already cover
  all four combinations, so the obligation is that they pass unedited. No new
  IPC test.
- **PO3 (I3, I4, I5).** New: a v3 state file whose split names an unknown
  direction fails to load with the named error case, and the one stated reason
  for that failure names the direction field. Asserting the shared reason
  discharges both consumers, because neither writes its own. No test covers any
  of this today.
- **PO4 (I3, IPC half).** New: an IPC `pane split` request with an unknown
  direction is still rejected with the existing parameter error, verbatim. The
  request decoder's two rejection paths (non-string value, unknown token)
  already carry the same message, so collapsing them into the raw-value init
  changes no wire text.
- **PO5 (I6).** Existing CLI parser assertions on the params `-h`/`-v` produce
  must pass unedited.
- **PO6 (I2).** The exhaustive `switch` over the direction in the layout tests
  keeps compiling without a `default` -- a third case breaks the build there
  first.

## Non-goals

- Renaming the wire tokens, the JSON keys, or the CLI flags.
- The other `[init]` diagnostics in `parseSplitNode`. Only the direction one is
  deleted by this change; the rest keep their current shape.
- The split ratio's missing bound and the fatal `agentSession` guard. Both
  rewrite the same function and are tracked separately; this change lands first
  so the split arm they contend over is already clean.

## Accepted risks

- **AR1.** A bad direction moves from "bad value" (`invalidSnapshot`) to
  "bad type" (`decodeFailed`), changing the user-facing message. Both mean no
  restore. No DanTerm-written checkpoint can produce the state, so the reachable
  inputs are a hand-authored `--init` file, an imported state file, and
  well-formed on-disk corruption. I4 keeps those surfaces diagnosable.
- **AR2.** Giving `decodeFailed` a payload edits two existing error-equality
  assertions in the snapshot tests.
- **AR3.** Neither consumer's own output is asserted end to end. `--init`'s
  mapping is top-level script code printing to stdout, and Import State's is an
  `NSAlert` behind a file picker in the WindowServer lane; covering either at
  that level costs more structure than it protects. I5 is what makes a
  single-reason assertion sufficient -- with one shared reason there is no
  second mapping left to drift.

## Implementation discretion

- The enum's name. It also serves pane navigation (`Msg.focusDirection`) as an
  axis, so "axis" reads better there -- but the on-disk key, the IPC param key
  and `SKILL.md` all say "direction", and AGENTS.md asks for one consistent word
  per thing. `SplitNodeModel.Side` stays where it is; it crosses no wire.
- The shape of the `decodeFailed` payload and of the stated reason, provided
  both consumers read one reason rather than formatting their own, and the
  `--init` log keeps a line distinct from the import alert's text.

## Commit progress

Ordering against the two items that share `parseSplitNode`: this plan lands
first, then MODEL-4 (the bounded split ratio, same arm), then PERSIST-2 (the
lossy agent session, neighbouring arm). This change *deletes* lines from the
split arm, so landing it first gives MODEL-4 a settled arm to edit instead of a
diff that has to be rewritten.

- [x] 1. Declare the shared `String`-raw-valued direction enum in its own file
      in `DanTermProtocol`, delete `PaneSplitDirection` and
      `SplitNodeModel.Direction`, and adopt it at every model, IPC and CLI site
      -- deleting both enum-to-enum conversions and both IPC string mappings.
      Persistence still compiles against the `String` field. No behavior change,
      and no new tests -- PO2's existing IPC and CLI assertions passing unedited
      is the proof.
- [x] 2. Retype `SplitNodeSnapshot.split`'s direction field, deleting both
      persistence switches and the `print`/`return nil` arm; in the same commit,
      give `decodeFailed` its diagnostic payload and fold the two consumers'
      hand-written message switches into the single stated reason (I4, I5). The
      diagnostic must not be absent from the tree for even one commit, so the
      repair rides with the loss that causes it. The one commit with a behavior
      change; PO1's and PO3's tests are written before it. Note the fifth
      construction site is under `app-tests/`, which a targeted
      `--package-path lib/DanTermCore` run does not compile -- `just test` is
      the gate here.
- [ ] 3. Collapse the `"leaf"`/`"split"` tag into a `DanTermCore`-internal
      raw-valued enum across both files. No behavior change -- an unknown tag
      already throws from the decoder.

## Implementation notes

- PO4's unknown IPC direction assertion lands in commit 2 because commit 1
  explicitly allowed no new tests and no later slice owned this plan-wide proof
  obligation.
