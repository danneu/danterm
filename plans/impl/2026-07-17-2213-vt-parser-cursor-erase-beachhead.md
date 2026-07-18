# VT parser and cursor/erase beachhead (Milestone 2, slice 2)

Second implementation slice of
[plan-terminal-engine/14-roadmap.md](../../plan-terminal-engine/14-roadmap.md)
Milestone 2. Governing contracts:
[04-terminal-core.md](../../plan-terminal-engine/04-terminal-core.md) and the
per-pane resource policy in
[10-protocols-shell-integration.md](../../plan-terminal-engine/10-protocols-shell-integration.md).

## Problem

Slice 1 proved the grid, streaming ingestion, and discard-only sequence
recognition; no escape sequence is interpreted, so no terminal application
can position the cursor or erase. The slice-1 plan pins this slice's
contract: "The parser slice adds param collection and dispatch to this
recognizer in place," dropping into the absorber "without touching the
decoder or the loop."

Load-bearing evidence (verified): the full VT500 state graph already in
`EscapeAbsorber.swift`; the two pre-staged internal grid primitives in
`Terminal.swift` (`moveCursor`, doc-commented "Positions future parser
actions", clamping and clearing pending-wrap/attach state, and
`eraseCells`, which widens ranges across wide pairs and clears to
padding); and the reference behavior in `.ghostty-src/src/terminal/`
(`Parser.zig` collection/dispatch plus its test corpus, `parse_table.zig`
transitions, `stream.zig` CSI semantic decoding, `Terminal.zig`
cursor/erase semantics under default modes).

## Decision

Evolve the escape absorber in place into a collecting, dispatching VT
parser, and interpret a cursor-movement/erase beachhead in the terminal:
the sequence table below, built on the pre-staged `moveCursor` and
`eraseCells` primitives.
Every other sequence continues to be consumed safely, now as an explicitly
dispatched-and-ignored value rather than silent absorption.

- **Syntax machine ported from the reference parser, one surfaced event
  per byte.** The absorber collects numeric parameters, the per-parameter
  colon-separator record, intermediates (private markers 0x3C-0x3F
  included, in arrival order), and the final byte, and dispatches one
  complete CSI value on the final. Collection state clears on sequence
  entry, so an aborted sequence (CAN/SUB, ESC restart, C1 introducer)
  leaves no residue in the next one. ESC-final, OSC, DCS, SOS, PM, and
  APC recognition is unchanged and stays silent: no consumer exists this
  slice, and slice 1 already rejected speculative empty effects. With
  those families silent no byte can surface more than one event
  (verified against the reference table: the only exit/entry actions
  belong to OSC/DCS/APC). The UTF-8 decoder and the per-byte stream loop
  are untouched; the stream layer only maps the absorber's event into
  the action stream the terminal already drains. Slice-1 stream-level
  absorption tests change intent from "absorbed silently" to
  "dispatched, uninterpreted"; slice-1 Terminal-level fixtures are the
  unchanged regression anchor.
- **Ported collection limits.** At most 24 parameters, each accumulated
  with 16-bit saturating arithmetic; a sequence that overflows the
  parameter list is consumed whole and dispatches nothing. Colon
  separators are recorded per parameter; a leading colon still enters
  the ignore state, and a colon-bearing sequence whose final is not `m`
  is dropped whole (the reference's SGR-only colon rule, kept now so the
  Terminal-level guard is structural and future SGR work inherits
  lossless subparameters). At most 4 intermediates are collected;
  further intermediates are discarded while the sequence still
  dispatches -- the reference deviates from vt100.net here and does not
  enter the ignore state. The reference's DCS parameter-overflow fuzz
  regression is ported as a no-trap recovery fixture.
- **Beachhead interpretation, gated.** A dispatched CSI mutates state
  only when its final is in the beachhead set, it collected no
  intermediates (private markers included), and its parameters are
  valid for that sequence -- both arity and value domain (for EL/ED,
  the mode lists in the table). Any other dispatch -- unknown final,
  private marker, bad arity, out-of-domain mode such as EL 3, ED 4, or
  ED 22 -- leaves terminal state bit-identical, pending wrap and attach
  target included. Semantics are ported from the reference's
  default-mode paths (wraparound on, reverse-wrap off, no margins or
  origin mode). Missing and zero parameters default to 1; coordinates
  are 1-based and clamp to the grid; movement never scrolls; every valid
  movement dispatch resets pending wrap and the zero-width attach
  target.

  | Sequence | Finals | Arity | Behavior |
  |---|---|---|---|
  | CUU / CUD | `A` (alias `k`) / `B` | 0-1 params | cursor up/down n, clamped |
  | CUF / CUB | `C` / `D` (alias `j`) | 0-1 | cursor right/left n, clamped |
  | CNL / CPL | `E` / `F` | 0-1 | cursor down/up n, then column 0 |
  | CHA / HPA | `G` / `` ` `` | 0-1 | absolute column, row unchanged |
  | VPA | `d` | 0-1 | absolute row, column unchanged |
  | CUP / HVP | `H` / `f` | 0-2 | absolute row;column, both clamped |
  | EL | `K` | 0-1, modes 0/1/2 | erase in line |
  | ED | `J` | 0-1, modes 0/1/2/3 | erase in display |
  | ECH | `X` | 0-1 | erase n cells at cursor, cursor unmoved |

- **Erase semantics.** Erased cells become padding -- observably
  never-written through the geometry view, spaces in screen text -- and
  erase ranges widen across wide pairs so no half-cell survives. Erases
  never move the cursor. Soft-wrap
  flags follow the reference's pinned asymmetry: EL 0 and ECH reset the
  cursor row's flag (ECH even when it stops mid-row, also clearing a
  trailing spacer head); EL 1 and EL 2 preserve it; rows fully cleared
  by ED reset theirs, with ED 0 resetting the cursor row's via its EL-0
  component and ED 1 preserving it. Every interpreted erase except
  ED 3 clears the attach target and resets pending wrap; ED 3 targets
  only scrollback, which does not exist, so it leaves terminal state
  bit-identical -- pending wrap and attach target included.
- **Strings stay retention-free.** OSC/DCS/APC/PM/SOS payload bytes are
  still discarded as they stream; pending parser memory is a small
  structural constant for arbitrary input, a strictly stronger property
  than 10's 2 MiB pending-string cap. That cap becomes binding with the
  first slice that retains a string payload, per the roadmap's rule that
  security limits land with a behavior's first support.
- **Recorded deviations from Ghostty** (differential traces must carve
  these out): D1 -- DECSEL/DECSED (`CSI ? K`, `CSI ? J`) are recognized
  and ignored rather than erasing unprotected cells; deferred to
  protected attributes. D2 -- ED 22 (kitty scroll-and-clear) recognized,
  ignored; needs scrollback. D3 -- every other reference-interpreted CSI
  (SGR, `h`/`l` modes, `r`, `@`, `P`, `L`, `M`, `S`, `T`, `g`, `c`,
  `n`, `s`, `u`, `b`, `I`, `Z`, ...) is dispatch-and-ignore this slice:
  a scope carve-out, not a semantic deviation. Slice-1 deviations stand
  unchanged.

## Invariants

- I1. Chunk invariance extends to dispatch: identical bytes produce
  identical terminal state and identical dispatched sequences regardless
  of chunking; collection state participates in value equality.
- I2. Purity is unchanged: no IO, no imports, no callbacks; dispatch is
  a value flowing through the existing synchronous reduction.
- I3. Dispatch syntax fidelity: dispatched CSI values (parameters with
  saturation, colon record, intermediates, final) and the drop rules
  (parameter overflow, colon with non-`m` final, entry colon) match the
  ported reference behavior.
- I4. Bounded parser state: pending-sequence memory is a small
  structural constant for arbitrary input; string payload bytes are
  never retained (absorber state after k payload bytes equals state
  after one).
- I5. Interpretation gate: only intermediate-free instances of beachhead
  finals with valid arity and in-domain parameter values (the mode lists
  in the sequence table) mutate state; every other dispatch leaves
  terminal state bit-identical, pending wrap and attach target included.
- I6. Movement semantics: missing/zero parameters default to 1, 1-based
  coordinates clamp to the grid, movement never scrolls, and every valid
  movement dispatch resets pending wrap and the attach target.
- I7. Erase semantics: erased cells are observably padding, wide pairs
  never split, soft-wrap flags follow the pinned asymmetry, every
  interpreted erase except ED 3 clears the attach target and resets
  pending wrap, ED 3 leaves terminal state bit-identical, and erases
  never move the cursor.
- I8. Recovery: aborted sequences leave no collection residue; arbitrary
  byte input cannot crash, hang, or prevent later valid input from
  being processed correctly.
- I9. The slice-1 grid validity invariants (wide-cell integrity, cursor,
  pending wrap) hold after every new mutation path.

## Proof obligations

- PO1 (I1). The stream- and Terminal-level chunk-invariance corpora
  extend with dispatching sequences: multi-digit parameters split
  mid-parameter, colon sequences, private markers, a parameter-overflow
  sequence, and an aborted sequence -- every 2-way and 3-way split point
  and byte-at-a-time, equal to single-chunk ingestion.
- PO2 (I2). The existing purity denylist and import gate stay green over
  the changed sources.
- PO3 (I3). The ported reference fixture set asserts exact dispatch
  payloads and exact non-dispatches: no-parameter and multi-parameter
  CUP, colon SGR payloads with recorded separators, the mixed-separator
  Kakoune fixtures, colon-with-non-`m` dropped, private-marker and
  intermediate collection (`ESC[?2026$p`, `ESC[3 q`), the 24-parameter
  boundary dispatching and the 25-parameter drop, parameter saturation
  at 65535, an entry-colon sequence dispatching nothing while the
  following sequence dispatches normally, and the 4-versus-5
  intermediate boundary (fifth discarded, the sequence still
  dispatching with the first four).
- PO4 (I4). String statelessness by equality: absorber state mid-payload
  is identical after one and after many payload bytes for each string
  family; the DCS parameter-overflow regression cannot trap.
- PO5 (I5). Guard negatives: invalid arity, out-of-domain mode (EL 3,
  ED 4, ED 22), private-marker, colon-dropped, and unknown-final
  dispatches each leave terminal state bit-identical, asserted with
  pending wrap set beforehand.
- PO6 (I6). A movement matrix per sequence: defaults, zero-as-one, alias
  finals, clamping at all four edges, CNL/CPL column reset, pending-wrap
  reset, and a combining mark after a dispatched move failing to attach
  to the pre-move cell.
- PO7 (I7). An erase matrix: EL 0/1/2 regions with wide-pair widening at
  both boundaries, EL 0 from a pending-wrap cursor, the soft-wrap
  asymmetry, ED 0/1/2 regions with row-flag resets and cursor
  immobility (including the canonical `ESC[H ESC[2J` pair), ED 3
  leaving state bit-identical, ECH clamping/widening and its mid-row
  wrap and spacer-head reset, padding-versus-written-space geometry
  after erasure, and both combining-mark outcomes (no attach across a
  cell-mutating erase; still attaching across ED 3).
- PO8 (I8). Abort/restart residue fixtures (CAN mid-parameter, ESC
  restart mid-parameter dispatching only the second sequence); both
  slice-1 fuzz harnesses stay green; a new seeded CSI-biased fuzz
  (escape/bracket/digit/separator/final-heavy alphabet) at Terminal
  level ends with CAN plus a printing sentinel and a full grid validity
  sweep.
- PO9 (I9). The `expectValidGrid` sweep runs after every matrix
  mutation, including on the minimal 2-column grid.
- PO10 (I1, I2). Slice-1 Terminal-level fixtures pass unchanged,
  pinning that surfacing dispatch alone -- absent beachhead
  interpretation -- changes no screen text or geometry.

Slice exit gate: `just test` green with the extended corpora. Left open
for later slices: SGR and styles, modes (DECSET/DECRST), margins and
scrolling regions, alternate screen, saved cursor, string-protocol
semantics and the 2 MiB cap, query replies/output bytes/semantic
events/damage, scrollback, and tab-stop manipulation.

## Non-goals

- SGR interpretation: colon payloads dispatch losslessly and are
  ignored.
- Mode changes (DECSET/DECRST, SM/RM), margins, scrolling regions,
  origin mode, alternate screen, and saved cursor.
- Tab-stop manipulation (HTS/TBC) and tab-motion finals CHT/CBT, which
  would bake fixed-8 stops into dispatch semantics the tab-stop work
  will change.
- Insert/delete/scroll finals (ICH/DCH/IL/DL/SU/SD/REP) and VPR/HPR.
- Device attribute and status queries (DA/DSR) or any output-byte
  channel -- slice-1 AR1 stands.
- OSC/DCS/APC/PM/SOS semantics or retention, and the 2 MiB
  pending-string cap (lands with first retention).
- Protected-attribute erasure semantics (DECSEL/DECSED), ED 22, and
  scrollback (ED 3 is a no-op).
- ESC-final sequence semantics (IND/NEL/RI/DECSC/RIS/...) and any C1
  execute semantics beyond slice-1 behavior.
- Damage tracking and semantic events.

## Accepted risks

- AR1 (carried from slice 1). Ingestion signatures change when query
  replies, semantic events, and damage arrive; additionally the
  absorber's single-event return widens when string-family dispatch
  surfaces. In-repo mechanical change, no external consumers.
- AR2. The dispatched CSI value's parameter representation may evolve
  when SGR interprets colon subparameters. Contained: internal type,
  no external consumers.
- AR3. The dispatch-and-ignore deviations (D1-D3) will surface in future
  differential traces against live Ghostty; carved out by name above.

## Implementation discretion

- Whether the absorber keeps its name; the internal event and
  dispatched-value type shapes; parameter/intermediate storage and the
  colon-record encoding.
- Decomposition of the terminal's dispatch handling and grid helpers.
- Fixture organization and reference-porting mechanics.
- Commit slicing and TDD sequencing (repo rule: each commit lands
  green).

## Commit progress

- [x] 1. Surface bounded, chunk-invariant CSI dispatch values
- [ ] 2. Interpret cursor movement and positioning dispatches
- [ ] 3. Implement erase semantics and integrated recovery proofs

## Implementation notes

- Completed and ignored sequences canonicalize collection state when they
  return to ground. The surfaced CSI owns its copied payload, while a Terminal
  that ignores the dispatch remains bit-identical, including pending wrap and
  the combining-mark attachment target.
