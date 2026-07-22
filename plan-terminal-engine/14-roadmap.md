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

- [ ] **7. Reach shell and baseline application compatibility**
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
    [harness](../scripts/tests/terminal-workflows-harness_test.sh) and
    [TerminalPTY](../lib/TerminalPTY/Tests) regressions.
  - [x] **Slice 3b: Asciinema nested-PTY compatibility.** Flake-pinned
    asciinema 2.4.0 records stdin, output, job control, and resize through an
    intermediate PTY, then replays the v2 cast locally with prompt and style
    recovery. See the
    [implementation plan](../plans/impl/2026-07-21-2138-asciinema-nested-pty-compatibility.md)
    and [dated evidence](../docs/evidence/2026-07-21-asciinema-nested-pty-compatibility.md).
  - [ ] [Protocols and shell integration](10-protocols-shell-integration.md) proves
    the advertised terminal environment, current DanTerm shell events, title,
    cwd, notifications, progress, links, clipboard policy, capability manifest,
    bell behavior, and cross-component protocol limits.
  - [ ] The supported black-box protocol and capability tranche in
    [External terminal test research](../docs/research/1-external-tests.md)
    passes against the real pane, and failures reduce to native deterministic
    fixtures where practical.

- [ ] **8. Reach tmux, editor, and advanced TUI compatibility**
  - [ ] tmux, vim, neovim, btop, htop, lazygit, Claude Code, and Codex complete the
    minimum workflows in [Testing and conformance](12-testing-conformance.md).
  - [ ] Relevant workflows pass both directly and through tmux or ssh where those
    layers materially change terminal behavior.
  - [ ] External and DanTerm-owned recordings identified in
    [External terminal test research](../docs/research/1-external-tests.md)
    cover the supported tmux, editor, and advanced-TUI behaviors without making
    another emulator's output normative.

- [ ] **9. Pass the replacement quality gates**
  - [ ] Every required component invariant has the behavioral proof required by
    [Testing and conformance](12-testing-conformance.md).
  - [ ] [Power and performance](13-power-performance.md) passes idle, hidden-pane,
    visible-output, recovery-freshness, sleep/wake, responsiveness, and teardown
    gates.
  - [ ] The Swift backend is suitable for sustained daily use without a required
    fallback to Ghostty.
  - [ ] The complete pinned evidence package from
    [External terminal test research](../docs/research/1-external-tests.md) is
    reproducible and gating; upstream updates cannot silently change expected
    behavior.

- [ ] **10. Remove libghostty**
  - [ ] No required runtime, build, config, test, documentation, or release path
    depends on Ghostty.
  - [ ] The Swift engine is the sole terminal backend and the full DanTerm test gate
    remains green.

## Deferred post-milestone work

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
