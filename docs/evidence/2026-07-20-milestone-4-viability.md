# Milestone 4 interactive viability evidence

Date: 2026-07-20

Verdict: pass. The Swift terminal engine satisfies the Milestone 4 interactive
viability gate on the development machine. This establishes that the current
architecture is credible enough to take to the explicit Milestone 5 experiment
decision; it does not authorize replacement cutover.

## Environment

- macOS 26.5.2 (25F84)
- MacBook Pro (MacBookPro18,1), Apple M1 Pro, 10 CPU cores, 32 GB memory
- zsh 5.9 (arm64-apple-darwin25.0)
- U.S. keyboard layout (`com.apple.keylayout.US`)
- `LANG=en_US.UTF-8` and `LC_ALL=en_US.UTF-8` in the isolated session
- Swift terminal backend selected with `DANTERM_TERMINAL_BACKEND=swift`

## Automated app run

The opt-in command was:

```sh
DANTERM_TERMINAL_ENGINE_TEST_ALLOW_APP_CONTROL=1 just test-terminal-viability
```

The green run is preserved at
`.build/terminal-viability-runs/2026-07-20-083423-89488/`. Its
`artifacts/summary.txt` records:

```text
result=pass
backend=swift
account_shell=/bin/zsh
input_source=com.apple.keylayout.US
locale=en_US.UTF-8
reflow=56x25->90x25->56x25
external_fixture=state-movecursor.json
external_grid=80x25
recordings=2
```

The run exercised a real zsh PTY and the AppKit input/rendering path. It proved
ordinary typing, macOS dead-key composition, Spanish/Chinese/emoji output,
cursor-movement editing, foreground Ctrl-C and a background job, `ls`, `cat`,
`less`, narrow/wide/narrow reflow, hidden-pane output and reveal, idle
quiescence, a selected external recording, non-last-pane exit, last-pane quit
confirmation, and process/socket/session-lock teardown.

The marker-bounded reflow region remained byte-identical at 56x25, 90x25, and
56x25. The hidden trace records no plan delivery while hidden and one after
reveal. The idle window records CPU time `0:01.55 -> 0:01.56` (0.01 seconds,
below the 0.08-second limit), no render-plan events, and no DanTerm-owned power
assertion. The foreground probe identifies `/bin/sleep 30` in the pane's
process ancestry. Both child-ended panes produced recordings; both recordings
decoded and replayed, and teardown left no owned descendants or runtime files.

The selected external fixture was
`Fixtures/libvterm/state-movecursor.json` at 80x25. Its feed bytes traveled
through the live pane's child process, and the pane-read text matched the
headless `Terminal` replay text exactly. The supporting files are
`artifacts/external-live-screen.txt` and
`artifacts/external-headless-screen.txt`.

## Manual visual and sleep/wake observation

A separate disposable characterization session established
`SLEEP-WAKE-PRE` through the pane input CLI and read it back before sleep. The
visible frame showed a recognizable `DANTERM-MANUAL>` prompt, correctly colored
red/green/blue ANSI samples, and a visible block cursor aligned after the
prompt. The observer reported that these looked correct.

The machine then slept by closing the MacBook lid for more than 10 seconds and
woke when the lid reopened. The current frame was still visible with exactly
one exact pre-sleep output line and no visual corruption. After wake,
`SLEEP-WAKE-POST` was sent through the same pane input path and read back; the
full read contained each marker as an exact output line once and returned to
the live prompt. A fresh two-second idle window held the app at `0:00.60` CPU
time and the event log at 13 lines, with no DanTerm-owned `pmset` assertion.
The pane therefore preserved content without loss or duplication, remained
interactive, redrew the current frame, and returned to quiescence after a real
sleep/wake.

## Deterministic and default-gate evidence

- `DanTermRecordingFixtureTests.milestone4ViabilityRecording` replays the
  checked-in app capture with valid DanTerm provenance under authored,
  bytewise, and split feed chunking and asserts every workflow marker.
- `TerminalPaneSessionControllerTests.childSessionEndExposesRecording`,
  `liveChildTeardownDoesNotExposeRecording`, and
  `captureDisabledExposesNoRecording` pin capture eligibility and inertness.
- `TerminalPaneSessionControllerTests.hiddenOutputAndReveal` pins hidden-pane
  reads and event-driven reveal planning.
- `TerminalPaneSessionControllerTests.applicationTerminationHandlesLiveAndMidCloseHosts`
  and `UpdateGhosttyTests.testSurfaceClosed` pin application and last-pane
  lifecycle policy at their lowest practical layers.
- `TerminalFixtureTests.replayFixtures` supplies authored/bytewise/split replay
  proof for the selected libvterm corpus, including the fixture used by the
  live external cross-check.
- `just test` includes these suites, the viability harness self-test, capture
  API/boundary gates, and the existing headless lifecycle and renderer suites;
  it passed before this evidence-only closure.

The checked-in recording is
`lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/danterm/milestone-4-viability.json`.
It is a deliberate copy of the primary recording under the preserved run's
`artifacts/recordings/` directory, not a live-output golden comparison.

## Known divergences and scope

- `less` uses the primary screen because alternate-screen support remains
  deferred to Milestone 6. Pager output therefore remains in history.
- OSC title and current-working-directory events are not implemented in this
  slice. The prompt and tab title are not evidence of OSC integration.
- Scrollback UI, mouse protocols, tmux/editors, OSC 52, hyperlinks, and broad
  xterm compatibility remain outside the experiment viability gate.

These are recorded limitations, not failures of the Milestone 4 contract.
