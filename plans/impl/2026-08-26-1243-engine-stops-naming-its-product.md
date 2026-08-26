# The engine stops naming its product

## Problem

The terminal engine hardcodes "DanTerm" in the two places it answers the
question "what terminal am I?", so an embedder cannot answer it differently:

- `assembleTerminalPaneLaunch` advertises `TERM_PROGRAM=DanTerm` as a literal,
  and requires a `shellIntegrationDirectory` string it never opens -- it exists
  only to set `DANTERM_SHELL_INTEGRATION_DIR`, which the *user's own rc file*
  reads (`README.md:152`).
- `Terminal` builds the XTVERSION reply as `ESC P >|DanTerm <version> ESC \`
  (`lib/TerminalCore/Sources/TerminalCore/Terminal.swift:6436`), taking only a
  `programVersion: String`.

Evidence that this is a defect and not a preference: `examples/MiniTerm`, the
smallest real embedding, passes `programVersion: "MiniTerm"` and
`terminalProgramVersion: "MiniTerm"` -- stuffing its *name* into the *version*
field because no name field exists -- and passes its working directory as the
shell-integration directory. The resulting shell reports `TERM_PROGRAM=DanTerm`,
`TERM_PROGRAM_VERSION=MiniTerm`, an XTVERSION reply of `DanTerm MiniTerm`, and
prints `DanTerm shell integration is unreadable: .../examples/MiniTerm` as its
first line of output.

Load-bearing premises, both verified in the tree:

- The engine never consumes the shell-integration directory. It sets one
  variable; nothing in `lib/` reads it back.
- `TerminalPaneLaunchConfiguration.terminalProgramVersion` already exists so
  that the advertised environment and the XTVERSION reply share one value
  (`app/SwiftTerminalBackend.swift:82`, `:96`). The name half was simply left
  behind as a literal.

## Decision

Complete the design that `terminalProgramVersion` already started: make the
product's identity a value the embedder supplies, covering both channels.

- `TerminalProductIdentity { name, version }` replaces the `programVersion:
  String` parameter on `Terminal` and `TerminalPTYHost`, and replaces
  `terminalProgramVersion` on `TerminalPaneLaunchFacts` and
  `TerminalPaneLaunchConfiguration`. It is one declaration shared by the query
  reply and launch assembly, never two mirror types.
- The `programVersion: String = "dev"` defaults go away. A default that
  fabricates an identity is how a hardcoded name survives a refactor.
- `productEnvironment: [EnvironmentEntry]` replaces
  `TerminalPaneLaunchFacts.shellIntegrationDirectory`. The engine carries the
  embedder's variables without knowing any of their names.
- The advertised list is composed with the same resolution the launch
  environment already uses -- first occurrence keeps its position, last
  occurrence supplies the value (`LaunchPolicy.swift:231`) -- with the identity
  entries applied last. A product environment that restates `TERM_PROGRAM` or
  `TERM_PROGRAM_VERSION` is therefore overwritten in place: identity is the sole
  writer of those two names by construction, with no key filter, no rejected
  input, and no change to where the entries sit.
- The `DANTERM_SHELL_INTEGRATION_DIR` name literal leaves the engine and joins
  its siblings in DanTerm's own `EnvVars`
  (`lib/DanTermProtocol/Sources/DanTermProtocol/EnvVars.swift`). DanTerm builds
  the entry where it already computes the path
  (`app/SwiftTerminalBackend.swift:204`).

Every caller states an identity, including the ones that bypass launch
assembly: the two `TestSupport` runners, which today hand-build a
`LaunchPolicyInput` with a literal `TERM_PROGRAM` entry beside an unrelated
`programVersion`, derive both from one identity value like everyone else.
MiniTerm's identity is name `MiniTerm`, version `dev` -- stated at its call
site, which is the point of deleting the fabricated default.

Rejected in favor of this: an optional `shellIntegration: ShellIntegration?`
field. It still teaches the engine DanTerm's variable name and asset layout,
just behind a nil check.

Scope is these two channels, and a sweep of the engine confirms there is no
third: DA1 answers with a fixed VT100 identity carrying no product name, there
is no DA2 or DA3 handler, and XTGETTCAP's terminal-name capabilities are
`xterm-256color`. The engine's remaining "DanTerm" literals are doc-comment
prose, the private OSC dialect selector, and recording provenance -- none of
them a reply that names the product (see Non-goals).

## Invariants

- **I1** The engine names no product. Every product name reaching a child
  process or a terminal query comes from a caller-supplied value.
- **I2** One identity, both channels: `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`,
  and the XTVERSION reply derive from the same value and cannot disagree. No
  other source can write those two names into the advertised list.
- **I3** Launch assembly adds no product-specific variable the embedder did not
  supply. This is a claim about what assembly writes, not about what the
  embedder inherits: entries the caller puts in `inheritedEnvironment` survive,
  and sanitizing them is the caller's business.
- **I4** DanTerm's behavior is unchanged on the wire: the advertised entries,
  their order, their ownership tier against hostile inherited values, and the
  XTVERSION reply bytes are all identical to today. `TERM_PROGRAM` and XTVERSION
  are external-compatibility surface under the AGENTS.md carve-out.

## Proof obligations

- **PO1** (I1, I2) A terminal and a launch built from a non-DanTerm identity
  report both that identity's name and its version over both channels, and a
  product environment that restates either identity name loses to the identity
  without moving it. Extends the existing XTVERSION test
  (`lib/TerminalCore/Tests/TerminalCoreTests/TerminalQueryTests.swift:287`) and
  the launch-assembly test
  (`lib/TerminalPTY/Tests/TerminalPaneSessionTests/TerminalPaneSessionPolicyTests.swift:59`),
  both of which currently pin the literal.
- **PO2** (I3) Assembling with an empty product environment adds no
  DanTerm-named entry to the advertised list.
- **PO3** (I4) The existing advertised-list order pin and the hostile-inheritance
  ownership test (`TerminalPaneSessionPolicyTests.swift:160`) pass with their
  expected values unchanged; only their construction changes.
- **PO4** (I4) The end-to-end bundle-derived directory pin
  (`app-tests/SwiftTerminalBackendLaunchTests.swift:41`) passes unchanged.
- **PO5** (I3) MiniTerm launches a shell that reports MiniTerm's own identity
  over both channels and prints no shell-integration warning, with its first
  line of output the shell's own. This is the defect that started this plan, so
  it is proved by running MiniTerm, not only by a unit test. Run it with
  `DANTERM_SHELL_INTEGRATION_DIR` absent from its inherited environment: an
  inherited value is outside I3 and can raise or silence the warning on its own,
  so leaving it in place proves nothing either way.

## Non-goals

- The private shell-integration dialect (`OSC 1337;DanTermShell=3`,
  `Terminal.swift:2297`) keeps its name. It is a wire protocol paired with the
  shipped shell-integration scripts, so renaming it is an external break with a
  separate rationale.
- Recording provenance (`NeutralTerminalRecording`'s `author: "DanTerm"`) is
  evidence metadata no child process observes.
- The other snags in
  `docs/scratch/2026-08-26-terminal-engine-reusability.md` -- the PTY bootstrap
  helper, render-metrics rescaling, launch-facts ergonomics, `unsafeFlags`, the
  platform floor, the published mirror, and `TerminalPTY`'s `DanTermProtocol`
  dependency.

## Accepted risks

- **AR1** Pane environment still outranks advertised identity: overrides resolve
  as `inherited + advertised + pane` with last-wins
  (`lib/TerminalPTY/Sources/PaneProcessLifecycle/LaunchPolicy.swift:177`, `:231`),
  so a pane-supplied `TERM_PROGRAM` would desync I2's two channels. DanTerm
  supplies none, and protecting identity keys from the pane layer is a distinct
  change with its own behavioral question.

## Implementation discretion

- Which module declares `TerminalProductIdentity`, subject to the Decision's
  constraint that there is exactly one declaration.
- Which identity name and version each `TestSupport` runner advertises, subject
  to the Decision's constraint that both halves come from one identity value.

## Verification

- `swift test --package-path lib/TerminalPTY` and
  `swift test --package-path lib/TerminalCore` during the loop, plus `just lint`.
- `just test` before the commit -- the app tests in PO4 live outside the two
  packages.
- `swift build --package-path examples/MiniTerm`, then run it and query the
  child for its identity for PO5.
- Update the child-environment table in `docs/terminal-capabilities.md` if the
  ownership column's meaning changes; the intent is that it does not.

## Close-out

The last step, in the same commit as the change, is to settle snag 3 in
`docs/scratch/2026-08-26-terminal-engine-reusability.md`: mark it done, record
that the shipped fix is a required product identity plus an opaque product
environment rather than the `ShellIntegration?` field that snag proposed, and
note the second leak it missed -- the XTVERSION reply. The remaining snags stay
open, so the file keeps its scratch status.

## Implementation notes

- `Terminal` takes `productIdentity: TerminalProductIdentity? = nil` rather than a
  required value. The Decision's "the defaults go away" is applied in full to
  `TerminalPTYHost` (18 call sites, every one now states an identity), but
  `Terminal.init` has 1103 call sites in this tree and 1102 of them never query
  XTVERSION. A terminal given no identity now answers XTVERSION with nothing at
  all, which keeps I1 exactly -- the engine still names no product, and no default
  fabricates one -- without 1100 mechanical test edits burying the change. The user
  chose this over the literal reading. `xtversionWithoutIdentity` pins the silence.
- `TerminalProductIdentity` lives in `TerminalCore`, the one module every consumer
  of both channels already depends on.
- `mergedEnvironment` in `LaunchPolicy.swift` became public rather than being
  copied: the advertised list is now composed by the same function that composes
  the launch environment, so "first occurrence keeps its position, last occurrence
  supplies the value" cannot drift between the two.
- The PTY tests that construct a host but are about lifecycle or geometry share
  `TerminalProductIdentity.test` from `TerminalPTYTestSupport`, so 13 unrelated
  tests neither invent a name each nor reintroduce "DanTerm".
- `docs/terminal-capabilities.md` is unchanged: the ownership column's meaning did
  not move. `DANTERM_SHELL_INTEGRATION_DIR` is still an advertised entry that
  inherited values cannot override -- only its author changed, from the engine to
  DanTerm.
- Two call-side changes the plan did not name, both forced by the identity move.
  `NeutralTerminalRecording.replay` gained a `productIdentity` parameter beside the
  `machineHostname` one it already had: identity is terminal configuration, so a
  replay compared against a live pane's snapshot must be built with the pane's
  identity or the two differ on configuration alone. And the probe source inside
  `scripts/tests/terminal-capture-api-gate_test.sh` states an identity, because it
  typechecks the characterization initializer.
- PO5 was proved by running MiniTerm against a scratch `ZDOTDIR` holding the
  README's own rc snippet, with `DANTERM_SHELL_INTEGRATION_DIR` unset in the
  inherited environment. The child reported `TERM_PROGRAM=MiniTerm`,
  `TERM_PROGRAM_VERSION=dev`, an XTVERSION reply of `ESC P >|MiniTerm dev ESC \`,
  no `DANTERM_SHELL_INTEGRATION_DIR`, and the snippet printed nothing.
