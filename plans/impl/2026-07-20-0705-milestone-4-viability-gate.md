# Milestone 4 slice 4: viability harness and gate closure

Milestone 4 (the interactive viability slice, plan-terminal-engine/14-roadmap.md:117-130)
lands in four slices (plans/impl/2026-07-19-1837-deterministic-render-planning.md:8-12);
slices 1-3 shipped. This plan covers slice 4 only: the evidence, automation, and
roadmap closure for the experiment viability gate
(plan-terminal-engine/02-migration-and-boundary.md:36-58). It adds no terminal
features; Milestone 5+ stays untouched.

## Problem

A real Swift-engine pane works behind `DANTERM_TERMINAL_BACKEND=swift`, but the
milestone's four checkboxes remain open:

- Nothing reproducibly demonstrates the gate workflow (interactive zsh,
  dead-key composition, Spanish/Chinese/emoji, `ls`/`cat`/`less`, reflow
  through a real window resize) end to end; slice 3's bar was a one-off manual
  smoke run.
- No DanTerm-owned recording of the workflow exists or replays headlessly,
  though docs/research/1-external-tests.md:123-132 pins Milestone 4 as the
  point to capture one from the first complete Swift pane.
- Idle, hidden-pane, sleep/wake, and teardown behavior of the real app under
  the swift backend has only headless package proofs plus that smoke run.
- The last-pane exit behavior (shell exit -> pane close path -> DanTerm's
  normal quit confirmation) is core-tested but has no recorded app-level
  evidence.

Load-bearing evidence (verified):

- The characterization harness pattern does almost everything the viability
  harness needs: scripts/terminal-characterization.sh builds an isolated
  `-DDANTERM_TERMINAL_CHARACTERIZATION` bundle with isolated HOME/TMPDIR,
  drives panes via the bundled `danterm` CLI (`pane read`/`input`/`split`/
  `info` are backend-agnostic seams: app/AppRuntime.swift:487-494, :561-572
  -> `any TerminalSession`), resizes the window and clicks the
  "Quit DanTerm?" confirmation via System Events, and asserts clean
  termination. The event log (app/AppRuntime.swift:25-91) is compile-gated
  and extensible.
- Last-pane exit: `.surfaceClosed` -> `.closePane` (Update.swift:783-784);
  closing the last pane of the last tab sets
  `pendingConfirmation = .terminate` WITHOUT removing the leaf
  (Update.swift:204-217), and nothing tears the session down before process
  exit (app/AppDelegate.swift:747-752). Core test:
  `UpdateGhosttyTests.testSurfaceClosed`. Consequence: a capture hook keyed
  on pane teardown would never fire for the last pane; the recording must be
  written at child session end.
- Capture plumbing exists but is unreachable from the app:
  `TerminalPTYHost` `captureTransitions`/`transitions()` are internal
  (TerminalPTYHost.swift:111-143, :240); `TerminalPaneSessionController`'s
  public init cannot enable them. `NeutralTerminalRecording` (a shipped
  library product) already validates "danterm" provenance and replays
  headlessly; `recordingRoundTrip` proves capture -> replay == snapshot at
  the host layer.
- TerminalCore has no alternate screen (deferred to Milestone 6 in the
  libvterm manifest), so `less` pages on the primary screen and leaves its
  output in history. The gate does not require altscreen; the divergence
  must be recorded, not fixed.
- The renderer is event-driven with no timers or display link; hidden panes
  consume output without planning (`hiddenOutputAndReveal`); the host census
  counters are package-internal, so app-level quiescence evidence needs its
  own trace.

## Decision

Evidence and automation, with one narrow engine seam. All names below are
working names (discretion).

- D1 Harness. An opt-in `just test-terminal-viability` recipe runs
  scripts/terminal-viability.sh, adapted from the characterization pattern:
  isolated characterization-flag bundle including `PTYSessionBootstrap`,
  launched with `DANTERM_TERMINAL_BACKEND=swift`, isolated HOME/ZDOTDIR with
  a fixed minimal zsh prompt and `LANG=en_US.UTF-8`, and a controlled corpus
  directory. It drives the full gate workflow in order: prompt; ordinary
  typing and dead-key composition (option-e, e -> e-acute) through real
  synthesized keyboard events; Spanish/Chinese/emoji echoes and command
  lines through the CLI seam; a cursor-movement line edit; a job-control
  probe (Ctrl-C on a foreground sleep, one background job); `ls`; `cat` of a
  Unicode corpus file; `less` paging and quit; a window-resize reflow walk
  (narrow -> wide -> narrow); hidden/reveal, idle, and power-assertion
  checks; at least one selected external recording replayed through the live
  pane (below); a second pane exited to prove single-pane close; then
  last-pane exit -> quit confirmation -> confirmed quit -> teardown checks.
  Artifacts are preserved on success and failure.
- D1a External replay through the interactive slice. The roadmap criterion
  (14-roadmap.md:126-130) requires selected external recordings to replay
  through the headless core *and* the interactive slice; the existing corpus
  tests stop at the headless core. The harness therefore emits one selected
  libvterm-derived fixture's feed bytes into a live Swift-engine pane through
  the pane's own child process -- no app-side injection seam is added -- and
  asserts the pane read equals the headless replay of the same fixture at the
  same dimensions. Only this cross-check may be cited for that checkbox.
- D2 Capture seam. `TerminalPaneSessionController` gains an opt-in capture
  flag and an accessor returning the session's `NeutralTerminalRecording`
  (danterm provenance). The app-facing (public) form of both exists only in
  `DANTERM_TERMINAL_CHARACTERIZATION` builds -- the flag the characterization
  build already passes to the whole dependency graph; a `package`-visible
  seam, ungated, serves the engine package's own tests. Host transition
  plumbing widens from internal to `package` visibility only. The app enables
  capture solely in characterization builds when `DANTERM_PTY_RECORDING_DIR`
  is set. Child session end is the sole capture-and-write trigger: one
  recording per pane whose child ends, and none for a pane torn down with a
  live child. Capture off is behaviorally inert.
- D3 Fixture. One harness-captured recording is deliberately checked in
  under lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/danterm/ and
  replayed by a new TerminalCore test in the default `just test`: danterm
  provenance validation, authored/bytewise/split chunk invariance, and
  final-history marker assertions. The harness never compares live output to
  the fixture; refresh is a deliberate human act.
- D4 Power evidence. Two new compile-gated trace events -- plan delivery and
  pane visibility change -- make the hidden-pane and idle proofs
  event-ordered rather than timed; idle CPU deltas and a `pmset` power-
  assertion check corroborate. Sleep/wake evidence is the automated
  no-power-assertions check plus one manual observation that is behavioral,
  not merely "it still ran": a pre-sleep marker is established in the pane,
  the machine sleeps and wakes, then a post-wake marker is sent and read back
  and the current frame is confirmed on screen, with the pre-sleep content
  neither lost nor duplicated, before quiescence is rechecked. The procedure
  and its result are written into the evidence doc.
- D5 Closure. A dated evidence record at docs/evidence/ captures the
  environment (macOS, hardware, zsh version, input source), harness summary,
  manual observations (sleep/wake, visual prompt/color/cursor quality),
  divergences (`less` on the primary screen; no OSC title/cwd), and artifact
  pointers. The four Milestone 4 boxes in plan-terminal-engine/14-roadmap.md
  are checked with "Slice 4 judgment:" lines in the Milestone 2/3 style,
  citing the harness recipe, the named headless tests, the danterm replay
  test, the external cross-check (D1a), and the evidence doc.
- D6 Fix policy. A failure the workflow exposes gets a failing-test-first
  fix at the lowest layer that reproduces it, preferentially reduced to a
  core fixture through the captured recording. No fix is pre-planned.

## Invariants

- I1 (reproducibility): the harness drives the complete gate workflow
  through the real app against an isolated HOME/ZDOTDIR and controlled
  corpus; every assertion is a marker read, an event-ordered trace, or an
  engine-contract invariant -- never a byte comparison against live shell
  output and never a bare timing sleep. It refuses to run without the
  explicit opt-in (`DANTERM_TERMINAL_ENGINE_TEST_ALLOW_APP_CONTROL=1`), a
  zsh account shell, and a U.S./ABC input source.
- I2 (input honesty): dead-key evidence enters through synthesized keyboard
  events into the real `NSTextInputClient` path; deterministic corpus text
  may enter through the CLI seam; every asserted input is read back through
  the pane.
- I3 (reflow): a marker-bounded logical corpus extracted from full-history
  reads is byte-identical across the narrow -> wide -> narrow walk,
  including the reflowed long line and hard line breaks.
- I4 (quiescence): with the pane hidden, injected output refreshes pane
  reads while the trace records zero plan deliveries; reveal delivers a plan
  and the final text; an idle window adds zero plan deliveries and
  effectively zero CPU; the app holds no power assertions.
- I5 (exit/teardown): exiting a non-last pane closes exactly that pane;
  exiting the last pane raises DanTerm's normal quit confirmation;
  confirming leaves no app process, shell or bootstrap descendants, control
  socket, or session lock.
- I6 (capture): an enabled session's recording replays through `Terminal` to
  exactly the state served by the pane's synchronous read at the extraction
  fence; a pane writes exactly one recording when its child ends and none
  otherwise; capture disabled changes no behavior, and no app-facing capture
  surface exists in default builds.
- I7 (fixture determinism): the checked-in recording validates danterm
  provenance and replays identically under authored, bytewise, and split
  chunking with the workflow markers present in final history.
- I8 (no product surface): capture and trace additions are dev/test
  facilities; default builds, the Ghostty backend, and `just test` behavior
  are unchanged, with the new engine-module import lint-confined to the
  adapter files.
- I9 (external cross-check): a selected external recording's bytes, driven
  through a live Swift-engine pane, leave that pane serving the same read
  text the headless core serves replaying the same recording at the same
  dimensions. The claim is over that text projection only.

## Proof obligations

- PO1 (I6): controller tests on a live PTY -- extraction at child end
  replays equal to the fenced read; a pane torn down with a live child
  produces no recording; capture off yields no recording and leaves existing
  suites untouched.
- PO2 (I1, I5): a harness self-test in the default gate proves the opt-in
  and prerequisite refusals happen before any build or app control, plus the
  marker-extract helper behavior (template:
  scripts/tests/terminal-characterization-harness_test.sh).
- PO3 (I7): the new TerminalCore replay test over Fixtures/danterm/ runs
  inside the default `just test`.
- PO4 (I1-I5, I9, the interactive bar): one green
  `just test-terminal-viability` run on the development machine, its summary
  and artifacts recorded in the evidence doc, plus the executed sleep/wake
  procedure and its result. The run also asserts I6's app-level leg: the
  recording artifacts it produced correspond exactly to the panes whose child
  ended, and each decodes and replays.
- PO5 (I6, I8): a default-build check proves the capture entry points are
  unreachable from an app-layer client while the characterization build
  proves they are reachable; the boundary-lint self-test covers the new
  module confinement in both directions; full `just test` stays green with
  the Ghostty default unchanged.

## Non-goals

- Alternate screen, OSC title/cwd events, scrollback UI, mouse, or any other
  Milestone 5+ terminal feature; the less-on-primary divergence is recorded,
  not fixed.
- vttest or Termless steps in the harness (research doc: non-gating).
- Byte-exact characterization of live zsh output; running the harness in CI.
- Automated true system sleep; gating screenshot automation.
- Refactoring the characterization script into a shared library.

## Accepted risks

- AR1: synthesized dead-key events may not traverse composition identically
  on every macOS build; the pane-read assertion arbitrates, and the input
  source guard plus evidence record pin the environment.
- AR2: idle-CPU thresholds vary by machine; the trace assertion is primary
  and the recipe is opt-in.
- AR3: zsh prompt redraw on SIGWINCH could disturb history near resizes; the
  fixed minimal prompt and marker-bounded comparison region contain it.
- AR4: the checked-in fixture embeds one machine's session; replay
  determinism does not depend on the environment that produced it, and
  refresh is deliberate.
- AR5: the external cross-check compares read text, so cursor position,
  styles, and wrap boundaries are not cross-checked through the live pane;
  those are already covered headlessly by the libvterm corpus, and the pane
  exposes no richer read seam worth adding for this gate.

## Rejected ideas

- RI1: byte-exact fixture comparison of live session output -- real zsh
  varies by version and host; the characterization script's `cmp` pattern
  worked only because its child was a scripted driver.
- RI2: headless-only capture -- the research doc pins capture to the first
  complete Swift pane, and dead-key-composed bytes exist only through the
  real input seam.
- RI3: public host transitions API -- `package` visibility suffices; the
  public surface is the controller's.
- RI4: extending `TerminalFixtureTests.replayFixtures` provenance handling
  in place -- a separate danterm replay test keeps the libvterm ledger
  intact.
- RI5: hand-authored per-checkpoint cell expectations for the fixture --
  refresh-hostile; chunk invariance plus final-state markers carry the
  proof.
- RI6: capture keyed on pane teardown only -- the last pane is never torn
  down before process exit, so the main workflow recording would never be
  written.

## Implementation discretion

- The extraction fence shape, recording file naming, corpus composition
  beyond the required marker families, which external fixture D1a selects,
  and CPU threshold constants.
- Harness helper reuse (sourcing the characterization script vs copying) and
  all working names.

## Verification

`just test` is the headless gate: PO1 controller tests, PO3 fixture replay,
PO2 harness self-test, PO5 lint self-test. `just test-terminal-viability`
(GUI + Accessibility, opt-in) is the interactive bar; its green run, the
manual sleep/wake observation, and the visual quality check are recorded in
the evidence doc before the roadmap boxes are checked.

## Commit progress

- [x] 1. Add the pane-session capture seam (engine)
- [ ] 2. Record viability sessions and scheduling traces (app, lint)
- [ ] 3. Add the terminal viability harness (script, justfile)
- [ ] 4. Narrow fixes exposed by the workflow (conditional, repeatable)
- [ ] 5. Replay the captured viability session headlessly (fixture, test)
- [ ] 6. Record milestone 4 evidence and close the gate (docs, roadmap)
