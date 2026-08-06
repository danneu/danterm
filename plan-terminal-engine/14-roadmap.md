# Incremental Roadmap

## Status

This is the canonical high-level progress checklist for the terminal-engine
replacement. Check a milestone only when its behavioral exit criteria are met;
component proof obligations remain the source of truth for what those behaviors
mean.

## Roadmap

- [x] **1. Isolate the experiment and establish the terminal backend boundary**
  - [x] Engine work begins on `experiment/swift-terminal-engine`; normal DanTerm
    development does not depend on the experiment before its viability decision.
  - [x] The DanTerm-facing contract in
    [Migration and app boundary](02-migration-and-boundary.md) covers the
    lifecycle, input, output, inspection, config, and event capabilities the app
    consumes.
  - [x] The ownership and effect boundaries in
    [Engine architecture and testability](03-engine-architecture.md) are in
    place without routing PTY bytes, grid state, or render damage through the
    top-level DanTerm model.
  - [x] The existing Ghostty backend runs through that boundary without changing
    DanTerm pane, tab, split, alert, persistence, or IPC behavior.
  - [x] Characterization fixtures record the current inspection and recovery
    behavior in [Inspection, search, and recovery](06-inspection-recovery.md)
    before the Swift backend replaces runtime text extraction.

- [x] **2. Build the foundational headless terminal core and Unicode model**
  - [x] **Slice 1: Headless terminal core foundation.** Establishes the pure
    terminal value, streaming UTF-8 ingestion, Unicode width policy, fixed
    viewport grid, wide-cell invariants, and baseline controls. See the
    [implementation plan](../plans/impl/2026-07-17-2054-headless-terminal-core-foundation.md).
  - [x] **Slice 2: VT parser and cursor/erase beachhead.** Adds bounded,
    chunk-invariant CSI dispatch plus cursor movement, positioning, erase
    semantics, and integrated recovery proofs. See the
    [implementation plan](../plans/impl/2026-07-17-2213-vt-parser-cursor-erase-beachhead.md).
  - [x] **Slice 3: Grapheme cluster assembly and emoji width.** Adds pinned
    Unicode grapheme segmentation, break-driven cluster cells, deterministic
    emoji width, and atomic width transitions. See the
    [implementation plan](../plans/impl/2026-07-17-2342-grapheme-cluster-assembly-emoji-width.md).
  - [x] **Slice 4: Primary-screen scrollback and resize reflow.** Retains exact
    visual rows and hard/soft identity, reflows the one-stream primary history
    with cursor attachment, and adopts neutral libvterm resize fixtures. See the
    [implementation plan](../plans/impl/2026-07-18-0119-primary-scrollback-reflow.md).
  - [x] **Slice 5: Terminal presentation state and SGR/reset behavior.** Adds a
    semantic pen, style-bearing cells, background-color erase semantics, and
    neutral libvterm pen fixtures. See the
    [implementation plan](../plans/impl/2026-07-18-0235-terminal-presentation-sgr.md).
  - [x] **Slice 6: Scrolling regions and editing operations.** Adds vertical
    margins, region-aware index and scroll controls, line and character edits,
    scrollback erase, and neutral libvterm scroll/edit fixtures. See the
    [implementation plan](../plans/impl/2026-07-18-0425-terminal-scroll-regions.md).
  - [x] **Slice 7: Terminal modes, tab stops, saved cursor, REP, and resets.**
    Adds persistent mode and tab state, saved-cursor aliases, repeat and reset
    semantics, and neutral libvterm state fixtures. See the
    [implementation plan](../plans/impl/2026-07-18-1751-terminal-modes-tabs-saved-cursor-reset.md).
  - [x] **Slice 8: Foundational fixture closure and exit audit.** Completes the
    early parser, encoding, Unicode, movement, and vttest provenance ledger;
    adds HPR, VPR, CHT, and CBT; and audits the Unicode and reflow gates. See
    the [implementation plan](../plans/impl/2026-07-19-1346-milestone-2-foundational-fixture-closure.md).
  - [x] The pure state machine in [Terminal core](04-terminal-core.md) handles the
    control, screen, mode, and style behavior required by the viability slice.
  - [x] Its behavior is deterministic, independent of input chunking, and proven
    without a PTY, AppKit, or renderer.
  - [x] The foundational contracts in
    [Unicode, grid, and scrollback](05-unicode-grid-scrollback.md) pass for
    Spanish text, Chinese wide text, basic emoji, wide-cell mutations, hard and
    soft line identity, and primary-screen resize reflow.
    Slice 8 judgment: `spanishCanonicalGeometry`, `wideCellGeometry`,
    `wideAtRightEdge`, and `clusteredWideCellAtomicity` prove the text and cell
    cases; `scrollbackRetention` and `fullHistoryEmptyLines` prove line identity;
    and `widthWalkConservesFullHistory`, `heightAndCombinedWalksConserveFullHistory`,
    and `spacerRoundTripAcrossWidths` prove primary reflow without losing the
    decomposed Spanish cluster, wide cells, or emoji.
  - [x] Reflow preserves logical content, hard line boundaries, cursor attachment,
    and live viewport behavior across the slice's width and height changes.
    Slice 8 judgment: logical content and hard boundaries are covered by
    `widthWalkConservesFullHistory`, `heightAndCombinedWalksConserveFullHistory`,
    and `heightTransferPreservesFlagsAndFillerIdentity`; cursor and live-viewport
    attachment are covered by `cellAnchorsFollowReflowedCells`,
    `heightShrinkClampsDisplacedCursor`, `heightGrowthEligibility`, and
    `widthGrowthPullsHistory`.
  - [x] The Milestone 2 tranche in
    [External terminal test research](../docs/research/1-external-tests.md)
    establishes structure-insensitive replay and adopts or classifies
    applicable parser, Unicode, grid, and reflow fixtures early enough to
    inform the core's public contracts.
    Slice 8 judgment: this gate closes. `TerminalFixtureTests.replayFixtures`
    proves every neutral fixture under authored, bytewise, and split replay;
    `TerminalFixtureTests.libvtermManifestCoverage` pins the upstream commit,
    seven declared deviations, and a disposition with rationale for every case
    heading in all 31 selected libvterm files, including the early parser,
    encoding, Unicode, movement, and vttest-derived families.

- [x] **3. Integrate PTY process lifecycle**
  - [x] [PTY and process lifecycle](07-pty-process-lifecycle.md) proves launch,
    ordered IO, environment, resize, EOF, exit, cancellation, and teardown with
    controlled child processes.
    Milestone 3 lifecycle judgment: `launchRecipeAndDuplexIO`,
    `realSpawnCwdFallback`, `orderedResize`, `largeFragmentedOutput`,
    `eofBeforeExit`, `exitBeforeEOFConverges`,
    `teardownLadderCoversSessionAndPreservesSibling`,
    `applicationTerminationClosesMultipleLivePanes`, and
    `initialInputSeamPreservesBytesAndRecoveryEnvironment` prove the controlled
    launch-through-teardown contract; the lifecycle trace and interleaving
    suites pin the same decisions independently of the system adapter.
  - [x] A headless pane can run a shell session without leaking resources or
    depending on rendering.
    Milestone 3 headless judgment: `recordingRoundTrip` proves PTY output and
    resize compose directly into `Terminal`, while
    `rapidCloseStressLeavesNoResources` proves create/close and resize/close
    races release descriptors, dispatch sources, child/session ownership, and
    host lifetimes. The complete default `just test` gate passes headlessly;
    `test-pty-external` adds opt-in ssh and tmux teardown evidence.

- [x] **4. Prove the interactive viability slice**
  - [x] One Swift-engine pane launches zsh, renders a recognizable prompt, accepts
    ordinary and dead-key-composed text, displays the required foundational
    Unicode cases, runs `ls`, `cat`, and `less`, and resizes with basic reflow.
    Slice 4 judgment: this gate closes. `just test-terminal-viability` exercises
    the complete live zsh/input/Unicode/command/reflow path, and the visual
    observations and run artifacts are recorded in
    [Milestone 4 interactive viability evidence](../docs/evidence/2026-07-20-milestone-4-viability.md).
  - [x] Shell exit and pane closure release resources; idle and sleep/wake behavior
    satisfy the experiment gate in
    [Migration and app boundary](02-migration-and-boundary.md).
    Slice 4 judgment: this gate closes. The viability recipe proves both pane
    exit paths, teardown, hidden/reveal ordering, idle CPU, and power assertions;
    `TerminalPaneSessionControllerTests.hiddenOutputAndReveal`,
    `applicationTerminationHandlesLiveAndMidCloseHosts`, and the evidence
    record pin the headless and real sleep/wake legs.
  - [x] The slice is reproducible and its terminal-core behavior has deterministic
    proof at the lowest practical layer.
    Slice 4 judgment: this gate closes. The opt-in recipe preserves every run's
    artifacts, `DanTermRecordingFixtureTests.milestone4ViabilityRecording`
    replays the first complete app capture in the default gate, and the named
    controller and lifecycle tests in the evidence record pin lower-layer
    contracts.
  - [x] Selected external recordings from
    [External terminal test research](../docs/research/1-external-tests.md)
    replay through the headless core and interactive slice; any optional
    differential or vttest experiment improves diagnostic evidence without
    becoming an unrecorded viability dependency.
    Slice 4 judgment: this gate closes. `TerminalFixtureTests.replayFixtures`
    proves the selected corpus headlessly, while `just test-terminal-viability`
    feeds `state-movecursor.json` through a live pane and asserts its pane-read
    text equals the headless replay; the exact artifacts are indexed by the
    evidence record.

- [x] **5. Make the experiment decision**
  - [x] Evidence from the viability slice records whether the architecture is
    pleasant to extend and whether Unicode/reflow, PTY ownership, rendering,
    concurrency, lifecycle, and power behavior are tractable.
    Milestone 5 judgment: this gate closes. The
    [experiment decision record](../docs/design/2026-07-20-terminal-engine-experiment-decision.md)
    evaluates each area against the Milestone 2-4 proof and the preserved
    viability run, finds all six tractable, and records that Milestones 2-4
    extended the architecture in sequential green slices without reworking
    lower-layer contracts.
  - [x] Explicitly choose to abandon the experiment, continue it, retain only
    independently useful infrastructure, or commit to the remaining replacement
    roadmap.
    Milestone 5 judgment: the decision record chooses to continue the
    experiment into Milestone 6 without committing to replacement cutover;
    the remaining risks it lists are the Milestone 6-9 work, and the
    replacement gate is unchanged.
  - [x] Decision evidence records what the staged corpora and tools in
    [External terminal test research](../docs/research/1-external-tests.md)
    revealed about architecture, diagnostic quality, and the value of retaining
    differential testing.
    Milestone 5 judgment: the decision record answers the research note's
    four testability questions: live failures reduce to the neutral
    byte-replay runner, public logical snapshots diagnosed the slice without
    pixel output, the pinned libvterm manifest absorbed all contract
    differences as seven declared deviations without private coupling, and
    differential replay showed no demonstrated value yet and gets an explicit
    evaluate-or-drop point during Milestone 6.

- [x] **6. Complete required terminal behavior and interaction**
  - [x] **Slice 1: Alternate screen and resize semantics.** Adds DEC 1047/1049
    screen switching, transient alternate-grid isolation, rectangular alternate
    resize with independent primary reflow, active and primary history
    projections, recovery routing, and neutral libvterm fixtures. See the
    [implementation plan](../plans/impl/2026-07-20-1014-alternate-screen-resize-semantics.md).
  - [x] **Slice 2: 10 MiB scrollback budget and eviction.** Adds deterministic
    retained-row accounting, amortized oldest-first eviction, truncated-head
    metadata, and enforcement across scrolling and primary resize. See the
    [implementation plan](../plans/impl/2026-07-20-1146-scrollback-budget-eviction.md).
  - [x] **Slice 3: Core queries and presentation modes.** Adds cursor appearance,
    synchronized frame gating, ordered DA/status/cursor/mode replies, PTY routing,
    and pinned query/save conformance fixtures. See the
    [implementation plan](../plans/impl/2026-07-20-1248-terminal-presentation-sync-modes.md).
  - [x] **Slice 4: Selection and search over the logical projection.** Adds
    engine-owned linear selection, literal history search, reflow-attached
    projection boundaries, row-intersection invalidation, and eviction clamps.
    See the
    [implementation plan](../plans/impl/2026-07-20-1440-selection-search-logical-projection.md).
  - [x] **Slice 5: Local viewport navigation and anchoring.** Adds stable
    reflow-attached browsing, logical viewport reads, owner-routed wheel policy,
    and native Swift-pane wheel and scrollbar interaction. See the
    [implementation plan](../plans/impl/2026-07-20-1659-local-viewport-navigation.md).
  - [x] **Slice 6: Mode-aware keyboard, focus, and safe-paste input.** Adds
    deterministic legacy and Kitty key encoding, authoritative owner-side mode
    decisions, native composition precedence, safe paste, and focus reporting.
    See the
    [implementation plan](../plans/impl/2026-07-20-2150-mode-aware-terminal-input.md).
  - [x] **Slice 7: Mouse reporting, native selection, and explicit copy.** Adds
    deterministic SGR mouse capture, owner-routed Shift overrides, selection
    highlighting, native pointer and wheel gestures, and fenced clipboard copy.
    See the
    [implementation plan](../plans/impl/2026-07-21-0730-mouse-reporting-selection-copy.md).
  - [x] **Slice 8: Logical damage and damage-aware redraw equivalence.** Adds
    bounded core-owned row damage, gated pane accumulation, partial AppKit
    invalidation, and corpus-wide retained-plan equivalence. See the
    [implementation plan](../plans/impl/2026-07-21-1005-logical-damage-redraw.md).
  - [x] **Slice 9: Bounded OSC 52 clipboard writes.** Adds bounded OSC
    accumulation, strict write-only decoding, owner-drained newest-wins
    delivery, and the direct AppKit pasteboard boundary. See the
    [implementation plan](../plans/impl/2026-07-21-1123-bounded-osc-52-clipboard-writes.md).
  - [x] **Slice 10: OSC 8 hyperlinks and safe web links.** Adds bounded OSC 8
    metadata, pure link resolution, Cmd-hover presentation, click-time safe
    web activation, and neutral Alacritty hyperlink evidence. See the
    [implementation plan](../plans/impl/2026-07-21-1243-osc8-hyperlinks-safe-web-links.md).
  - [x] **Slice 11: Application-requested cursor shapes.** Carries DECSCUSR
    block, underline, and bar shapes through semantic snapshots, render plans,
    damage-aware execution, and pixel containment proofs. See the
    [implementation plan](../plans/impl/2026-07-21-1433-milestone-6-cursor-behavior.md).
  - [x] **Slice 12: Semantic underline styles and colors.** Adds dotted and
    dashed shapes plus SGR 58/59 color through terminal state, saved state,
    cells, reflow, render planning, and scale-aware pixel execution. See the
    [Milestone 6 closure plan](../plans/impl/2026-07-21-1544-milestone-6-closure-audit.md).
  - [x] **Slice 13: Event-driven Swift enriched recovery.** Schedules bounded
    checkpoint attempts from primary-history mutations, retries failed writes
    to covering success, becomes quiescent when durable, and fences accepted
    output before the final clean-exit checkpoint. Ghostty alone retains the
    temporary periodic fallback. See the
    [Milestone 6 closure plan](../plans/impl/2026-07-21-1544-milestone-6-closure-audit.md).
  - [x] **Slice 14: Headless inspection/recovery characterization replay.**
    Reuses the real-Ghostty corpus as the single source of terminal bytes,
    resize checkpoints, and expected projections, proving exact Swift parity
    across primary reflow and recovery while documenting one adjudicated
    alternate-screen cursor-placement divergence. See the
    [Milestone 6 closure plan](../plans/impl/2026-07-21-1544-milestone-6-closure-audit.md).
  - [x] **Slice 15: Multi-stage Chinese IME composition.** Proves successive
    native marked-text replacements remain local and only the final Chinese
    commit reaches the terminal text path, without terminal key-encoded bytes.
    See the
    [Milestone 6 closure plan](../plans/impl/2026-07-21-1544-milestone-6-closure-audit.md).
  - [x] **Slice 16: Final libvterm Milestone 6 dispositions.** Classifies the
    remaining selected files against DanTerm's support matrix, preserves the
    terminal-property families for Milestone 7, and validates the complete
    pinned inventory. See the
    [Milestone 6 closure plan](../plans/impl/2026-07-21-1544-milestone-6-closure-audit.md).
  - [x] **Slice 17: Alacritty recording adoption and classification.** Validates
    all 45 pinned recording directories, replays all 15 Milestone 6 cases
    through neutral public seams, maps superseded cases to behavioral evidence,
    and leaves the Milestone 7 and 8 recordings visibly pending. See the
    [Milestone 6 closure plan](../plans/impl/2026-07-21-1544-milestone-6-closure-audit.md).
  - [x] **Slice 18: Milestone 6 external-source adjudication.** Confirms that
    the adopted native, libvterm, and Alacritty evidence covers the current
    support matrix; defers further source mining to Milestones 7 and 8 and
    differential replay until a real backend disagreement makes it useful.
    See the
    [Milestone 6 closure plan](../plans/impl/2026-07-21-1544-milestone-6-closure-audit.md).
  - [x] [Terminal core](04-terminal-core.md) completes the accepted baseline control,
    screen, mode, style, query, and recovery behavior.
    Closure-audit judgment: controls, primary and alternate screens, modes,
    queries, parser recovery, resets, synchronized output, and cursor
    presentation state are covered by the terminal, CSI, mode, query,
    presentation, reset, saved-cursor, and cursor-rendering suites. Slice 12
    closes the remaining style work with semantic and rendered proofs for every
    underline shape and SGR 58/59 color.
  - [x] [Unicode, grid, and scrollback](05-unicode-grid-scrollback.md) completes
    selection/search/viewport anchors, primary- and alternate-screen resize
    behavior, and the fixed 10 MiB scrollback contract.
    Closure-audit judgment: `resizeAttachment`,
    `resizePreservesBrowsingAnchor`, `outputPreservesBrowsingAnchorAndContent`,
    and `evictionClampsBrowsingAnchor` cover the logical and viewport anchors;
    the alternate-screen and resize suites cover both screen geometries; and
    `publicProductionBudgetCrossing` plus the budget oracle cover the fixed
    production limit and eviction behavior.
  - [x] Reflow preserves locally scrolled viewport anchoring across width and
    height changes once [Input and interaction](08-input-interaction.md) provides
    viewport-offset and interaction state. Audit judgment: existing
    `resizePreservesBrowsingAnchor`, `outputPreservesBrowsingAnchorAndContent`,
    and `evictionClampsBrowsingAnchor` tests cover resize, output, and eviction.
  - [x] [Inspection, search, and recovery](06-inspection-recovery.md) preserves the
    characterized viewport/full-history, logical-line, selection, search, pane
    read, export, recovery text, and event-driven recovery-freshness behavior
    across reflow.
    Closure-audit judgment: logical projection and invalidation, selection,
    search, pane reads, persistence limits, and primary-history capture while
    alternate screen is active are already covered. Slice 13 closes
    event-driven Swift enriched-checkpoint freshness. Slice 14 replays the
    checked-in Ghostty characterization through TerminalCore at 56/90/56
    columns and across alternate-screen entry/exit, with the only mismatch
    adjudicated in favor of TerminalCore's reflow-attached cursor contract.
  - [x] [Input and interaction](08-input-interaction.md) and
    [Renderer](09-renderer.md) provide an interactive pane with macOS text
    composition, terminal keys, mouse reporting, selection, safe paste,
    local wheel/scrollbar history navigation, clipboard writes, links, font
    fallback, colors, cursor behavior, and correct display scaling.
    Closure-audit judgment: keyboard, mouse, paste, OSC 52, links, colors,
    cursor shapes, damage, font fallback, display scaling, and the native text
    composition seam are covered. Slice 15 adds the named multi-stage Chinese
    IME proof. Timed cursor blinking is a post-milestone enhancement and does
    not gate the initial replacement.
  - [x] Logical damage and full redraw produce the same visible state. Slice 8
    proves every neutral event by retained-plan overlay and styled output at the
    executor-pixel seam, including resize and alternate-screen cases.
  - [x] Every external case family assigned through Milestone 6 in
    [External terminal test research](../docs/research/1-external-tests.md) has
    an adopted, adapted, superseded, or out-of-scope disposition; every
    applicable case passes through DanTerm's public behavioral seams.
    Closure-audit judgment: Slice 16 completes and validates the libvterm
    ledger. Slice 17 classifies the full pinned Alacritty inventory, replays all
    15 assigned Milestone 6 recordings, validates provenance, and maps every
    superseded recording to existing behavioral evidence. Slice 18 records
    that no additional Milestone 6 support-matrix behavior remains unique to
    the other researched sources.

- [x] **7. Reach shell and baseline application compatibility**
  - [x] **Slice 1: Bounded title, cwd, bell, and legacy-event isolation.** Add
    OSC 0/2 title semantics, local-host OSC 7 with cwd reset, BEL alerts, bounded
    pane-scoped delivery, and temporary recognition that carries current
    authenticated shell payloads as private events rather than titles. See the
    [slice plan](../plans/impl/2026-07-21-1810-title-cwd-bell-events.md).
  - [x] **Slice 2: Native shell-event protocol and title-shim retirement.** The
    authenticated OSC 1337 protocol now carries typed command and remote-session
    metadata. Bundled zsh, Bash, and fish integrations preserve prompt hooks and
    SSH/mosh behavior, while direct and real-PTY gates prove pane ownership and
    the old title-channel path is gone. See the
    [slice plan](../plans/impl/2026-07-21-1959-native-shell-events.md).
  - [x] zsh, bash, fish, ssh, fzf, more, and less complete the minimum workflows in
    [Testing and conformance](12-testing-conformance.md). The workflow recipe is
    backed by the
    [dated evidence](../docs/evidence/2026-07-21-terminal-workflow-compatibility.md)
    and deterministic
    [TerminalPTY](../lib/TerminalPTY/Tests) regressions.
  - [x] **Slice 3b: Asciinema nested-PTY compatibility.** Flake-pinned
    asciinema 2.4.0 records stdin, output, job control, and resize through an
    intermediate PTY, then replays the v2 cast locally with prompt and style
    recovery. See the
    [implementation plan](../plans/impl/2026-07-21-2138-asciinema-nested-pty-compatibility.md)
    and [dated evidence](../docs/evidence/2026-07-21-asciinema-nested-pty-compatibility.md).
  - [x] [Protocols and shell integration](10-protocols-shell-integration.md) proves
    the advertised terminal environment, current DanTerm shell events, title,
    cwd, notifications, progress, links, clipboard policy, capability contract,
    bell behavior, and cross-component protocol limits. See the
    [capability contract](../docs/terminal-capabilities.md),
    [dated evidence](../docs/evidence/2026-07-21-terminal-capability-contract.md),
    and [slice plan](../plans/impl/2026-07-21-2228-terminal-capability-contract.md).
  - [x] The supported black-box protocol and capability tranche in
    [External terminal test research](../docs/research/1-external-tests.md)
    passes against the real pane, and failures reduce to native deterministic
    fixtures where practical. See the
    [dated evidence](../docs/evidence/2026-07-21-real-pane-protocol-probes.md),
    [wraptest coverage comparison](../docs/research/2-wraptest-coverage.md), and
    [slice plan](../plans/impl/2026-07-21-2326-real-pane-protocol-probes.md).

- [x] **8. Reach tmux, editor, and advanced TUI compatibility**
  - [x] **Slice 1: Alacritty tmux and Vim recording adoption.** Replays the
    five pinned `tmux_git_log`, `tmux_htop`, and Vim application captures at
    their authored dimensions and chunking through public terminal
    projections, including styled cells, cursor and input modes, primary
    history, and alternate-screen state. Finalizes the six stale Milestone 7
    vttest ledger entries against native behavioral evidence without treating
    the imported headless captures as live workflow proof. See the
    [slice plan](../plans/impl/2026-07-22-0103-alacritty-tmux-vim-recordings.md).
  - [x] tmux, vim, neovim, btop, htop, lazygit, Claude Code, and Codex complete the
    DanTerm-owned minimum workflows in
    [Testing and conformance](12-testing-conformance.md).
    Milestone 8 probe judgment: closed by interactive live-pane probes on the
    Swift backend (2026-07-31) covering each application's minimum task,
    including mouse, copy-mode, resize, and clean exit/restore legs; scripted
    workflow automation and a dated evidence record were intentionally waived
    for this criterion by owner decision. vim was not probed separately;
    neovim stands in for it. One adjudicated deviation: tmux splits
    regional-indicator flag-emoji pairs during partial redraws under both the
    Swift and Ghostty backends (a full redraw restores them), so flag
    corruption inside tmux is tmux-layer behavior outside DanTerm's contract.
  - [x] Relevant workflows pass both directly and through tmux or ssh where those
    layers materially change terminal behavior.
    Milestone 8 probe judgment: closed by owner decision on interactive
    live-pane probes (2026-07-31). The tmux leg ran during the application
    probes themselves: neovim, lazygit, and Claude Code executed nested
    inside tmux, and tmux was probed directly. The ssh leg ran htop and an
    editor over a live ssh hop, including window-resize propagation to the
    remote application and clean disconnect with local prompt restoration.
    Scripted variant automation was intentionally waived.
  - [x] External and DanTerm-owned recordings identified in
    [External terminal test research](../docs/research/1-external-tests.md)
    cover the supported tmux, editor, and advanced-TUI behaviors without making
    another emulator's output normative.
    Milestone 8 probe judgment: the external leg was closed by Slice 1's five
    pinned Alacritty tmux/htop/Vim replays. Capturing DanTerm-owned workflow
    recordings via `DANTERM_PTY_RECORDING_DIR` was intentionally waived by
    owner decision; the 2026-07-31 interactive probes stand as the live
    workflow evidence without replayable captures. Kitty mining for supported
    protocols is adjudicated as already covered: Kitty keyboard encoding has
    native deterministic coverage from Milestone 6 Slice 6, and the Slice 18
    adjudication found no support-matrix behavior unique to the remaining
    researched sources.
  - [x] Live-pane evidence covers the PTY, input, renderer, teardown, and
    recording boundaries exercised by those workflows; headless core replay
    alone does not close this criterion.
    Milestone 8 probe judgment: closed by owner decision on the same
    2026-07-31 interactive live-pane session as the workflow criterion --
    real PTYs (including one ssh hop), live keyboard/mouse/copy-mode input,
    the real renderer, and observed teardown with prompt restoration. The
    recording boundary was not exercised; that leg inherits the waiver
    recorded on the recordings criterion above.

- [ ] **9. Pass the replacement quality gates**
  - [x] Every required component invariant has the behavioral proof required by
    [Testing and conformance](12-testing-conformance.md). Closed 2026-08-01 by
    an owner-adjudicated audit of every invariant and proof obligation in docs
    01-13 and 15. Six gaps were real and are closed: width-independent logical
    lines in full history, single process ownership against a duplicate launch,
    a released pane being unreachable by every controller callback, XTGETTCAP
    as a silent no-op, search navigation wrapping at both ends (doc 06
    corrected to match the shipped behavior), and cross-normalization search --
    the last of which was a behavior fix rather than a test, since search
    neither normalized nor case-folded outside ASCII and now compares canonical
    caseless graphemes. Sleep/wake is a real open gap carried to the
    power-and-performance criterion below, which names it explicitly. Of the
    low-yield remainder, three are not gaps and are accepted
    on construction or standing-decision grounds (theme presentation-only,
    the retired terminfo two-fixture gate, admission-process discipline); four
    are waived as real but low-value and self-announcing in daily use
    (transient power assertions, main-thread responsiveness under sustained
    output, machine-checked contrast, one settings value across simultaneous
    panes); one is waived with a named follow-up -- no test drives combined
    adversarial pressure across parser, metadata, events, replies, scrollback,
    and damage at once, which is the assumption here most likely to be wrong
    and the first thing to revisit.
  - [ ] [Power and performance](13-power-performance.md) passes idle, hidden-pane,
    visible-output, recovery-freshness, sleep/wake, responsiveness, and teardown
    gates.
  - [ ] The Swift backend is suitable for sustained daily use without a required
    fallback to Ghostty.
  - [x] The complete pinned evidence package from
    [External terminal test research](../docs/research/1-external-tests.md) is
    reproducible and gating; upstream updates cannot silently change expected
    behavior. Closed by the
    [2026-07-31 external terminal gate](../docs/evidence/2026-07-31-external-terminal-gate.md):
    the native gate, classified neutral fixtures, pinned 14-case esctest2 run,
    and pinned three-session vttest run are maintained gates.

- [x] **10. Remove libghostty**
  - [x] No required runtime, build, config, test, documentation, or release path
    depends on Ghostty.
    Milestone 10 judgment: this gate closes. Build and release: `build-lib.sh`,
    `load-ghostty-version.sh`, `.ghostty-version`, `build.zig.zon.nix`, the
    flake's zig-overlay input, the xcframework preflight checks, and the legacy
    theme bundling are deleted; `Package.swift` has no `GhosttyKit`
    `.binaryTarget` and the app target links only Cocoa, QuartzCore, CoreText,
    and UniformTypeIdentifiers. The release path instead builds, bundles, and
    signs `PTYSessionBootstrap` alongside `DanTerm` and `danterm`, and the CI
    and release layout checks require all three. CI: `cache-ghosttykit.yml` and
    every GhosttyKit version/cache/build step are gone, along with the
    validator-self-test job that existed to guard them. Config: the
    `GhosttyPrefs` shadow config is deleted and Preferences compares against
    `model.config` directly. Tests: the Ghostty characterization recorder and
    the Ghostty benchmark arm are retired, and the boundary lint now enforces
    only the app/engine import boundary. Docs: this pass rewrote `AGENTS.md`,
    `agent-docs/build-details.md`, `agent-docs/worktree-development.md`,
    `README.md`, and retired `docs/upgrading-ghostty.md`; superseded ADRs
    carry dated forward notes rather than edited bodies. What remains is not a
    dependency: `references/ghostty` is a gitignored, optional reference
    checkout pinned at v1.3.1 and fetched by `scripts/fetch-references.py`
    like every other reference tree, the recorded Ghostty characterization
    fixtures are captured data that still gate, and the theme importer's
    upstream archive is named `ghostty-themes.tgz` by iTerm2-Color-Schemes.
  - [x] The Swift engine is the sole terminal backend and the full DanTerm test gate
    remains green.
    Milestone 10 judgment: this gate closes on the backend claim by
    construction. The `TerminalBackend` protocol collapsed to the concrete
    `SwiftTerminalBackend`; `TerminalBackendEvent`,
    `TerminalRecoveryScheduling`, `Command.setAppFocus`, and the selection seam
    are deleted, and there is no `DANTERM_TERMINAL_BACKEND` variable or fallback
    left to select. One user-visible narrowing came with the deletion: Cmd-click
    opens `http`/`https` links only, so bare file paths are no longer clickable.
    The gate ran green on each landed commit; the end-to-end re-proof from a
    clean checkout (normal gate, UI gate, dev build, release build, and a live
    pane smoke test) is the final task of
    `plans/impl/2026-08-06-libghostty-removal-and-post-removal-simplification.md`
    and is the confirmation to point at if this milestone is ever questioned.
    Note that Milestone 9 is deliberately still open: its power-and-performance
    gate has not been run. Removal proceeded ahead of it by owner decision, and
    Milestone 9's "no required fallback to Ghostty" criterion is now closed by
    construction rather than by evidence.

## Deferred post-milestone work

- [ ] **Lone regional-indicator glyph fallback.** An unpaired regional
  indicator (e.g. half of a flag emoji split by tmux's partial redraws)
  renders as a solid black square; Ghostty and Apple text rendering show a
  legible letter-in-a-box instead. Cosmetic font-fallback polish observed
  during the 2026-07-31 Milestone 8 probes; does not gate replacement.
- [ ] **Application-requested cursor blinking.** Blink-capable DECSCUSR variants
  currently retain their semantic blink preference but render steadily. Add
  timed presentation after the replacement milestones, covering focus,
  visibility, app activation, teardown, redraw equivalence, and quiescent timer
  ownership. This enhancement does not gate Milestone 6 or Ghostty replacement.

## Direction

Implementation must remain incremental and green. The experiment first proves a
narrow vertical slice rather than completing isolated subsystems to parity.
Each slice proves behavior at its lowest layer and carries the integration
evidence needed for any boundary it crosses. Temporary Ghostty coexistence is
allowed so the Swift backend can receive real-use feedback before cutover.

## Dependency constraints

- The product support matrix and DanTerm-facing backend boundary precede
  replacement cutover.
- Pure terminal semantics remain independently testable before renderer or PTY
  integration can count as proof of those semantics.
- Deterministic policy and lifecycle decisions remain independently testable at
  every effectful boundary before its system integration counts as proof.
- Unicode width, wide-cell invariants, hard/soft line identity, and reflow are
  foundational contracts rather than late rendering polish.
- Security policies for clipboard, links, paste, and terminal string limits are
  part of their first supported behavior.
- Power and teardown proofs travel with the first runtime integration; they are
  not post-parity optimization work.
- Passing the experiment viability gate permits a continuation decision but
  does not satisfy any omitted replacement proof obligation.
- Ghostty is removed only after the Swift backend satisfies every replacement
  proof obligation and the prioritized application gate.

## Replacement gate

The Swift backend can replace Ghostty when:

- all component invariants have behavioral proof
- the required compatibility applications complete the minimum workflows in
  [Testing and conformance](12-testing-conformance.md)
- direct, tmux, and ssh use work where relevant
- DanTerm's existing pane, tab, split, alert, persistence format, and IPC routing
  are unchanged, and the inspection/recovery text and event-driven freshness
  contracts pass
- idle, visibility, sleep/wake, and teardown requirements pass
- no required behavior depends on Ghostty at runtime or build time

## Non-goals

- Low-level task checklists or commit sequencing in this roadmap.
- Calendar estimates.
- Treating line count or feature count as progress independent of behavioral
  proof.

## Implementation discretion

- The implementation slices and commit boundaries within each milestone.
- Which compatible application first becomes the daily-use development host.
