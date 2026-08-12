# Simplification audit: ranked findings

Produced 2026-08-11 by a 13-agent fan-out: twelve read-only auditors, each
scoped to one narrow area, plus a cross-cutting pass over their combined
output. As written, nothing here had been implemented, built, or run --
every claim was a source reading of the tree at that date, and the
confidence score is the auditor's own estimate of how checkable the claim
is from the code.

**The Status column is authoritative for what is stale.** A row carrying a
commit sha has landed, which means its `### SNN` section below now
describes code that no longer exists -- read the commit, not the finding.
A blank status means the finding is untouched, and its prose is only as
current as 2026-08-11; re-read the cited code before acting on it. `n/a`
means the finding was dropped, with the reason noted in its section.

**How to use this.** The findings are individually actionable, but the
themes below are the real units of work: eight root causes account for
most of the 61 findings, and fixing a theme retires its symptoms together.
Start at "Themes", not at the table. Then read "Settle these first":
seven of these fixes contradict another fix or a recorded ADR, and picking
them up in the wrong order wastes the work.

Scores are impact (1-5) x confidence (1-5). Impact 5 means the fix removes
a whole class of problem; confidence 5 means the claim is verifiable by
reading the cited code. Every finding states the ideal fix first, per the
design bar in AGENTS.md, with the cheaper fallback named as a trade-off
rather than a default.

Two findings are live defects rather than cleanups, both consequences of
the missing-registry theme (T3): DEC private mode 12 and ANSI mode 12
(SRM) are unreachable though the state they set exists, and anchored
ranges carry mismatched eviction policy.

## Themes

Ranked by the impact the synthesis pass assigned to the combined fix.

### T1. One fact, two stores: parallel state kept in sync by hand

_Impact 5/5 -- 14 findings are symptoms._

**Root cause.** Across every layer the same value is held in two places that must be moved together -- a loose field beside a boxed copy, a model slot beside an AppKit handle, a mirror beside the authority. Nothing in the types couples the writes, so correctness is a convention each mutation site must re-honour, and the failure is always silent divergence rather than a compile error. This is the single most common root cause in the corpus (14+ findings, every audited area).

**Combined fix.** Adopt one rule and apply it per subsystem: the owner of a fact owns everything that dies or moves with it, and every derived value is computed, not stored. Concretely -- collapse mirrors into the owning type (screens into two ScreenStates, sessions into PaneHost, swapchain inputs into the swapchain, follow token/notice/socket into a per-subscription stream value, focus/zoom into PaneTree), replace stored totals and caches with computed accessors over their source (grand row totals, metadataBytes charge, pointer clamp state), and make presentation existence a projection reconciled from a single model slot rather than a command pushed at a handle. Sequence it as one pass per area so each lands with its own tests; the shared payoff is that 'the two disagreed' stops being expressible.

Symptoms: S02, S05, S14, S18, S19, S22, S24, S31, S38, S40, S42, S45, S46, S54

### T2. Tests re-implement production because production has no seam to drive

_Impact 5/5 -- 8 findings are symptoms._

**Root cause.** Where a production path cannot be constructed or driven from a test, the test grows a copy of it -- a shim reimplementation, a mirrored pipeline, a reference implementation, a prototype arena, or a fault-injection branch inside the shipping code. The copies then pin behavior the app does not have (shim geometry lacks production floors; UI-test pipelines omit the guard step; probes measure a prototype), so the tests are green about the wrong artifact, and in the PTY host the seams actually change shipping control flow on the teardown ladder they are meant to verify.

**Combined fix.** Make the production object drivable and delete the copy. Extract the collaborator each copy is secretly standing in for -- a PTY transport witness, an AppRuntime `Ports` value, a `SidebarReconcileDriver`, the two pure geometry sources compiled into the UI-test target -- inject it at construction, and have tests assert against real behavior rather than against a second implementation. Note the distinction this theme turns on: constructor injection of collaborators is the fix; conditional test-only branches inside production paths are the disease. Doing the AppRuntime `Ports` split also retires the `#if DANTERM_UI_TEST` substitution machinery, closing two holes with one refactor.

Symptoms: S12, S20, S21, S33, S35, S36, S37, S49

### T3. No registry: membership lists enumerated by hand in N places

_Impact 4/5 -- 5 findings are symptoms._

**Root cause.** Several concepts are represented as a set of members (terminal modes, anchored ranges, preference fields, per-screen fields, TODO owners) with no single declaration. Each lifecycle pass over the set is a separately hand-written enumeration, so adding a member means editing 4-6 disjoint lists and omitting one produces a member that can be set but not reported, or created but not cleaned up. Two of these gaps are already live defects (DEC mode 12 / SRM unreachable; anchored ranges with mismatched eviction policy).

**Combined fix.** For each set, declare it once as data -- a static table of (code, keypath) for modes, a policy table for anchored ranges, an enum of preference fields with a draft/config codec, one `TodoOwner` enum -- and make every pass (set, report, reset, capture, restate, clean up, project) a fold over that table. The one-off members that genuinely differ (modes 6/1047/1048/1049, hover-vs-arm damage recording, fontSize's String mapping) stay as explicit arms layered on top, which is the correct residue rather than a reason to keep the enumerations.

Symptoms: S07, S14, S15, S26, S34

### T4. Missing parameterization: the same algorithm written twice, differing by one type or key

_Impact 4/5 -- 12 findings are symptoms._

**Root cause.** Where two callers need one algorithm over two types (or two keys, or two output shapes), the codebase copies the algorithm rather than parameterizing it. The copies then drift -- and in three cases the drift is already a defect, not a hypothetical (missing debouncer cancel in the teardown copy, missing pane-exists guard in deleteTodo, missing guard step in one test-side pipeline copy).

**Combined fix.** Parameterize instead of copying: one generic `NeedleWindow<Position>` for search, one instrument enum for the seven counters, one `TodoOwner`-parameterized handler set, one teardown body, one line reader in DanTermProtocol, one `assemble-app-bundle.sh`, one generic counted `fence<T>`, one reduce loop in the PTY host, one `ScheduledTimer`. Where the second copy exists because the first is unreachable from the caller (the CLI's framer, the PTY reduce loop), the fix is to publish the shared one, not to keep both. Prioritize the four copies that have already diverged, since those are bug reports, not cleanups.

Symptoms: S03, S07, S16, S17, S23, S24, S28, S30, S32, S34, S44, S56

### T5. Frozen and dead artifacts still compiled, tracked, and read as authoritative

_Impact 4/5 -- 10 findings are symptoms._

**Root cause.** The project retires things by gating them off rather than removing them, so obsolete code and documents stay in the build and in the reader's path. Each one taxes exactly the refactors the rest of this report proposes (probes compile against `@testable` internals; the CLI compiles the whole app core) or actively misinforms (a self-declared normative plan directory for a finished migration; ADRs marked Accepted above their own supersession banner).

**Combined fix.** Establish one retirement rule -- a thing is either reachable and maintained, or it is deleted and git holds it; 'gated off but compiled' is not a third state. Apply it: probes to their own non-gate target (or deleted where their finding is written down), prototype arenas and `BudgetEnforcedRowStore` deleted, senderless Msg cases and unused lifecycle API deleted, `plan-terminal-engine/` deleted after auditing for unmigrated contracts, the CLI's core/support symlinks dropped once doctor moves to a shared module. Back it with the two checks that make recurrence impossible: a doc status/citation lint (the repo already runs eleven such gates) and a rule that a probe target is not in the default test target.

Symptoms: S07, S08, S09, S11, S37, S39, S59, S60, S61

### T6. Presentation state pushed by commands instead of projected, against the reconcile model the app already uses elsewhere

_Impact 4/5 -- 4 findings are symptoms._

**Root cause.** The Elm loop's reconcile passes are the app's stated model for view existence -- `reconcileQuitConfirmation` and `reconcilePreferencesPanel` create, show, refresh and tear down from a single optional projection with no command. Popovers and two of three confirmation sheets instead push existence through Commands while also writing model state, which yields two truths, stranding paths, and a documented double-press bug. Both findings reverse the same recorded ADR decision.

**Combined fix.** Treat 'a view exists' as a projection everywhere, matching the quit-confirmation shape: model slot carries the full payload, the reconcile pass owns create/show/refresh/teardown, and the only view-to-model edge is genuine user input (click-away closing a popover). Delete the six show/dismiss Commands, the stranding sweeps, and the second derivations. This requires amending the 2026-05-27 ADR in the same change, and the one real constraint to settle first is whether a modal NSAlert may be run inside the reconcile sweep -- if not, that is the honest argument for keeping the two close sheets command-driven, and it should be written into the ADR rather than left implicit.

Symptoms: S02, S42, S44, S45

### T7. Cross-artifact inventories duplicated in prose and YAML with no generator or checker

_Impact 4/5 -- 8 findings are symptoms._

**Root cause.** Lists that describe the system to humans and CI -- the CLI command surface, bundle layout assertions, the gate's step list, clean paths, doc statuses and citations -- are hand-copied across 2-5 artifacts and guarded only by prose rules ('keep this synced') or by meta-tests that grep for literals, which pass on a list that is present but wrong. Two are already out of sync (`just clean` misses two build trees; seven doc citations dangle, one misstating a layer boundary).

**Combined fix.** Convert each inventory from prose into a single declaration plus a check that executes rather than pattern-matches: a command descriptor table in the parser rendering both `danterm help` and SKILL.md's synopsis block (generate-and-compare, the shape build-app.sh already uses for SKILL.md itself); one `scripts/verify-bundle-layout.sh` called from all four workflow sites and from the gate; STEPS derived from the manifests and `scripts/tests/*` with explicit justified exclusions; pattern-based `just clean`; and a docs lint for statuses and citations alongside the existing research-index-lint. Each of these lets a prose rule in AGENTS.md be deleted rather than trusted.

Symptoms: S04, S08, S10, S43, S47, S48, S52

### T8. Grown subsystems never got a file or module boundary

_Impact 3/5 -- 6 findings are symptoms._

**Root cause.** Four files hold multiple unrelated subsystems with headers that no longer describe their contents: Terminal.swift (7,778 lines, including ~250 lines of pure byte decoders and ~1,000 lines of search), Update.swift (420 of 2,162 lines are the entire external IPC API), LogicalLineStore.swift (215 lines of instruments before the subject starts), ModelOperationsTests.swift (3,371 lines, over half testing Projections.swift). The cost is not aesthetic: pure helpers sit in scope for code that must never call them, the reader cannot locate coverage, and the CLI's target boundary is so loose it links the whole app core.

**Combined fix.** Cut each file at the seam it already has and make the header a true claim about what belongs there and what does not, per the project's own code-style rule: pure OSC decoders as free functions, search as its own type, instruments in their own file, IPC dispatch in IpcDispatch.swift, ProjectionsTests alongside ModelOperationsTests, and the CLI target's source set reduced to `cli/*.swift` once doctor moves to a shared module. These are same-module moves with no visibility or specialization change, so they are cheap -- but sequence the Terminal.swift split against the screens/modes/anchors/search restructures, since all five rewrite the same file.

Symptoms: S11, S16, S32, S50, S53, S55

## Settle these first

Conflicts and ordering constraints found by the synthesis pass. Each is a
decision to make before the affected findings are picked up, not a finding
in itself.

- Probe files: the scrollback auditor recommends deleting LogicalLineArena, BudgetEnforcedRowStore and four probe files outright; the test-suite auditor recommends moving all nine probes to a separate non-gate target specifically so a probe that must be re-run still can be. Both also note research/31/D4 freezes these files against edits, which deletion violates. One decision is needed: delete the prototype-driven probes (they can no longer re-derive anything about the shipped store) and relocate only those that drive production code.

- DanTermProtocolTests ownership: the build-tooling auditor recommends keeping the root test target and deleting the nested package's, but its own cheaper fix recommends the reverse, and the test-suite auditor's 'derive STEPS from the manifests' assumes the duplicate is already resolved. Deriving STEPS from manifests while both declarations exist would re-create the double run, so the ownership call must land first.

- Test seams in production: 'Move test-only state and fault injection out of the production PTY actor' argues test-driven branches in shipping paths are the defect, while 'Stop forking a PTY child...' wants deliverOutputForTesting to become the normal way to drive a host, and 'The Command interpreter... has no automated coverage' wants a Ports seam threaded through AppRuntime. These reconcile only under an explicit rule -- constructor-injected collaborators yes, conditional test-only branches no -- which should be stated before any of the three is implemented, or the PTY cleanup and the AppRuntime refactor will be argued against each other.

- Sidebar data flow: 'Drop SidebarView.currentModel; read the runtime's model' has the view reach into the runtime's authoritative model on the interaction path, while 'Give the sidebar reconcile pipeline one implementation the UI tests drive' and 'Delete applyGroupCollapseState' push toward the view being a pure renderer fed only by projections. Both cannot be the target shape; the driver-owns-the-pipeline direction argues the interaction path should read its own projection, not a whole AppModel from either source.

- Recorded decisions are contradicted without being amended: 'Make TODO/alerts popover existence a reconcile pass' reverses the 2026-05-27 ADR listing popover presentation as a legitimate Command, and 'Nest per-pane search and notification state in PaneModel' reverses D2 of the 2026-08-10 session-owned-facts ADR. Both auditors flag it; neither fix is safe to land without the ADR edit in the same change, and the docs-status theme shows the register is already unreliable about supersession.

- Terminal.swift restructuring order: the screens (ScreenState), modes (registry), anchors (registry), search (lift out), and file-split findings all rewrite overlapping regions of one 7,778-line file. They are individually sound and jointly a merge conflict; the search lift should go first (it removes ~1,000 lines and eight nested types), then the storage changes, then the file split, or the split's file boundaries will be drawn around the old shape.

- Perf-versus-derivation tension: 'Derive the grand row/content totals from the block index' turns a hot per-call read into a ring subscript, and 'Let the swapchain own its construction inputs' proposes an identity token to avoid a deep CoreText comparison on the publish path. Both are structural wins that touch measured paths, so per agent-docs/measurement-discipline.md neither may be asserted as free; if the benchmark rejects the derived total, the assert-only fallback is the stopping point and should be written into the plan rather than discovered later.

## Ranked findings

| Status | #           | Score | I   | C   | Area           | Effort | Finding                                                                                                                 |
| ------ | ----------- | ----- | --- | --- | -------------- | ------ | ----------------------------------------------------------------------------------------------------------------------- |
|        | [S01](#s01) | 25    | 5   | 5   | build          | small  | Make CI run the local gate instead of running no tests at all                                                           |
|        | [S02](#s02) | 20    | 4   | 5   | app-runtime    | medium | Make TODO/alerts popover existence a reconcile pass, not four commands                                                  |
|        | [S03](#s03) | 20    | 4   | 5   | build          | medium | Collapse the duplicated bundle assembly in dev-build.sh and build-app.sh                                                |
|        | [S04](#s04) | 20    | 4   | 5   | build          | small  | Replace the four hand-copied bundle-layout assertion lists with one script                                              |
|        | [S05](#s05) | 20    | 4   | 5   | core-model     | medium | Make a tab's focus and zoom part of its tree, not two loose fields                                                      |
|        | [S06](#s06) | 20    | 4   | 5   | core-model     | small  | Give sessions one tree-walking mutator instead of five whole-model traversals per report                                |
|        | [S07](#s07) | 20    | 4   | 5   | core-reducer   | large  | Collapse the duplicated pane/tab TODO surface onto one owner type                                                       |
|        | [S08](#s08) | 20    | 4   | 5   | docs           | small  | Design-doc statuses lie: superseded notes say `Status: Accepted` and the index shows no status                          |
|        | [S09](#s09) | 20    | 4   | 5   | docs           | medium | Delete plan-terminal-engine/: 2,232 tracked lines that declare themselves normative and the engine ADR says it replaced |
|        | [S10](#s10) | 20    | 4   | 5   | docs           | medium | Lint doc-to-code citations: seven cited paths no longer exist, one of them misstating a layer                           |
|        | [S11](#s11) | 20    | 4   | 5   | ipc-cli        | medium | Stop compiling the entire app core into the danterm CLI binary                                                          |
|        | [S12](#s12) | 20    | 4   | 5   | pty            | large  | Move test-only state and fault injection out of the production PTY actor                                                |
|        | [S13](#s13) | 20    | 4   | 5   | sidebar        | medium | Give sidebar cells typed subviews instead of string-identifier lookups                                                  |
|        | [S14](#s14) | 20    | 4   | 5   | terminal-core  | medium | Store both screens as ScreenState instead of one boxed and one loose                                                    |
|        | [S15](#s15) | 20    | 4   | 5   | terminal-core  | medium | Replace the four hand-branched mode switches with one mode registry                                                     |
|        | [S16](#s16) | 20    | 4   | 5   | terminal-core  | large  | Unify the two search matchers and lift search out of Terminal                                                           |
|        | [S17](#s17) | 16    | 4   | 4   | pty            | medium | Model master-close asynchrony in the reducer instead of deferring a command tail                                        |
|        | [S18](#s18) | 16    | 4   | 4   | scrollback     | medium | Derive the grand row/content totals from the block index instead of storing them                                        |
|        | [S19](#s19) | 16    | 4   | 4   | terminal-views | small  | Collapse the two presentation-input change detectors into one entry point                                               |
|        | [S20](#s20) | 16    | 4   | 4   | tests          | medium | Stop forking a PTY child for tests that only exercise engine policy                                                     |
|        | [S21](#s21) | 16    | 4   | 4   | tests          | large  | The Command interpreter, the app's highest-churn logic, has no automated coverage                                       |
|        | [S22](#s22) | 15    | 3   | 5   | app-runtime    | medium | Collapse the parallel `sessions` and `paneHosts` maps into one pane map                                                 |
|        | [S23](#s23) | 15    | 3   | 5   | app-runtime    | small  | Delete the divergent inline copy of tearDownSession in tearDownCurrentSession                                           |
|        | [S24](#s24) | 15    | 3   | 5   | app-runtime    | medium | Give scheduled work one handle instead of a handle plus a shadow token                                                  |
|        | [S25](#s25) | 15    | 3   | 5   | core-model     | small  | Compute a tab's chrome once instead of four times per sidebar row                                                       |
|        | [S26](#s26) | 15    | 3   | 5   | core-reducer   | medium | Derive preferences-draft sync instead of enumerating the six fields in five places                                      |
|        | [S27](#s27) | 15    | 3   | 5   | ipc-cli        | small  | Make --socket work for `doctor` instead of intercepting local commands before the flag parser                           |
|        | [S28](#s28) | 15    | 3   | 5   | ipc-cli        | small  | Replace the CLI's two hand-rolled per-byte line readers with the shared framer                                          |
|        | [S29](#s29) | 15    | 3   | 5   | pty            | medium | Record transitions once: fold TerminalPTYAppliedTransition into the flight recorder                                     |
|        | [S30](#s30) | 15    | 3   | 5   | pty            | small  | Replace the fence operation/output enum pair with typed fence methods                                                   |
|        | [S31](#s31) | 15    | 3   | 5   | scrollback     | medium | Give the record side tables one owner that maintains its own byte charge                                                |
|        | [S32](#s32) | 15    | 3   | 5   | scrollback     | small  | Collapse the seven copy-pasted task-local counters and move them out of the store file                                  |
|        | [S33](#s33) | 15    | 3   | 5   | sidebar        | medium | Give the sidebar reconcile pipeline one implementation the UI tests drive                                               |
|        | [S34](#s34) | 15    | 3   | 5   | terminal-core  | medium | Give anchored ranges one registry instead of six hand-written enumerations                                              |
|        | [S35](#s35) | 15    | 3   | 5   | terminal-views | medium | Stop re-implementing grid and cell geometry in the UI-test shim                                                         |
|        | [S36](#s36) | 15    | 3   | 5   | tests          | small  | Retire the whole-AppModel golden snapshot; it ratchets on behavior-preserving refactors                                 |
|        | [S37](#s37) | 15    | 3   | 5   | tests          | small  | Move the nine frozen research probes out of the default TerminalCore test target                                        |
|        | [S38](#s38) | 12    | 3   | 4   | app-runtime    | medium | Key pane-tape follow state once, by subscription, instead of four sidecar maps                                          |
|        | [S39](#s39) | 12    | 3   | 4   | build          | small  | Drop .build-gate by deleting the unenforced -warn-long-function-bodies flag                                             |
|        | [S40](#s40) | 12    | 3   | 4   | core-model     | medium | Nest per-pane search and notification state in PaneModel so cleanup is structural                                       |
|        | [S41](#s41) | 12    | 3   | 4   | core-reducer   | small  | Drop @discardableResult from update() so nested calls cannot silently swallow commands                                  |
|        | [S42](#s42) | 12    | 3   | 4   | core-reducer   | medium | Give all three confirmations one representation instead of half-model, half-command                                     |
|        | [S43](#s43) | 12    | 3   | 4   | docs           | small  | AGENTS.md maps three of the seven places a document can live                                                            |
|        | [S44](#s44) | 12    | 3   | 4   | sidebar        | small  | Delete applyGroupCollapseState; paint the group row from its own projection                                             |
|        | [S45](#s45) | 12    | 3   | 4   | sidebar        | small  | Drop SidebarView.currentModel; read the runtime's model                                                                 |
|        | [S46](#s46) | 12    | 3   | 4   | terminal-views | medium | Let the swapchain own its construction inputs instead of mirroring them in the view                                     |
|        | [S47](#s47) | 10    | 2   | 5   | build          | small  | `just clean` misses two of the five build trees it is supposed to remove                                                |
|        | [S48](#s48) | 10    | 2   | 5   | build          | small  | Stop running DanTermProtocolTests twice in the gate                                                                     |
|        | [S49](#s49) | 10    | 2   | 5   | core-model     | small  | Delete the three unread-alert reference implementations no render path calls                                            |
|        | [S50](#s50) | 10    | 2   | 5   | core-reducer   | small  | Move the IPC dispatcher out of Update.swift; the file is two subsystems                                                 |
|        | [S51](#s51) | 10    | 2   | 5   | ipc-cli        | small  | Give todo ids the same phantom-typed treatment as every other entity id                                                 |
|        | [S52](#s52) | 10    | 2   | 5   | ipc-cli        | medium | Derive the CLI help text from the parser instead of hand-syncing three copies                                           |
|        | [S53](#s53) | 10    | 2   | 5   | terminal-core  | small  | Move the pure OSC byte helpers off Terminal and split the file at its seams                                             |
|        | [S54](#s54) | 10    | 2   | 5   | terminal-views | small  | Return the clamp state from terminalCell so the view stops re-deriving grid extents                                     |
|        | [S55](#s55) | 10    | 2   | 5   | tests          | small  | Split ModelOperationsTests along the boundary its name claims                                                           |
|        | [S56](#s56) | 8     | 2   | 4   | core-model     | small  | Unify the three divergent "the selected tab died" fixups                                                                |
|        | [S57](#s57) | 8     | 2   | 4   | pty            | medium | Read into one reusable buffer through a single read loop                                                                |
|        | [S58](#s58) | 8     | 2   | 4   | sidebar        | medium | Make SidebarItemStore return the outline mutation instead of a Bool the executor re-switches on                         |
|        | [S59](#s59) | 8     | 2   | 4   | terminal-views | small  | Drop the vestigial optionality in TerminalSessionState.scrollPosition                                                   |
|        | [S60](#s60) | 5     | 1   | 5   | app-runtime    | small  | Drop the unused runRepeating and captureOwnerCensus lifecycle API                                                       |
|        | [S61](#s61) | 5     | 1   | 5   | build          | small  | Delete the unreferenced scripts/cursor-color-rainbow.sh                                                                 |

## Findings in detail

### S01. Make CI run the local gate instead of running no tests at all

`build` &middot; tooling &middot; impact 5, confidence 5 &middot; effort small

`.github/workflows/ci.yml`, `scripts/run-test-suite.sh`, `docs/design/2026-05-28-core-module-via-symlink.md`

**Problem.** CI on pull requests runs four jobs: a git-cliff changelog smoke test, two Nix checks for shell integration and the home-manager module, a theme-freshness check, and two macOS jobs that both just build the release bundle. Not one of them runs a Swift test, a lint, or any step from scripts/run-test-suite.sh. A pull request that breaks every TerminalCore test, every core-purity lint, and the whole app test suite goes green. The gate exists and is well built; it simply is not connected to the only automated place it would catch something the author did not already run locally.

**Evidence.** .github/workflows/ci.yml defines exactly four jobs (cliff-smoke, theme-freshness, build, release-build-check); grepping the file for `run-test-suite`, `just test`, or `swift test` returns nothing. release-stable.yml likewise runs no tests. The flake's checks are the three hook packages plus shell-integration and home-manager-shell-integration, none of which touch Swift. docs/design/2026-05-28-core-module-via-symlink.md states this outright under Consequences: "CI gating is a follow-up. This migration kept GitHub Actions changes out of scope" -- a follow-up that never landed.

**Ideal fix.** Add a `gate` job on macos-26 that runs `./scripts/run-test-suite.sh` (the same entry point `just test` uses, so there is one step list and no second copy to drift). The steps are already declared independent and pool-parallel, so a runner just picks a job count. If the full suite is too slow for every PR, split it by the same script with a step-filter argument rather than by re-listing steps in YAML.

**Cheaper fallback.** Add a job running only the fast, high-signal subset (`swift test --package-path lib/DanTermCore`, the core-purity lints) -- cheaper in minutes but reintroduces a second, divergable list of what CI considers important.

**Risk.** CI minutes and the possibility that a GUI/WindowServer-dependent step fails on a hosted runner; run-test-suite.sh already excludes test-ui for exactly that reason, so the risk is bounded to discovering one or two steps that need a skip.

### S02. Make TODO/alerts popover existence a reconcile pass, not four commands

`app-runtime` &middot; structural &middot; impact 4, confidence 5 &middot; effort medium

`app/AppRuntime.swift#perform`, `app/Reconcile.swift#reconcilePaneTodoPopover`, `app/Reconcile.swift#reconcileTabTodoPopover`, `app/Reconcile.swift#reconcileQuitConfirmation`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#update`, `lib/DanTermCore/Sources/DanTermCore/Command.swift#Command`

**Problem.** Whether a TODO popover is open is stored twice: in `model.todoPopover` and in the runtime's `todoPopover` / `tabTodoPopover` NSPopover handles. Four commands (`showTodoPopover`, `dismissTodoPopover`, `showTodoPopoverForTab`, `dismissTodoPopoverForTab`) push one onto the other, delegate adapters push messages back the other way, a pure `reconcileTodoPopover(&model, previous:)` stranding pass and an AppKit-side `dismissStrandedPopovers()` keep the two halves from drifting when a tab disappears, and the two content passes then gate on `handle?.isShown` rather than on the model. When the two disagree nothing repairs it: the `.showTodoPopover` arm early-returns if `findPaneWrapper(for:)` or `desiredPaneTodoPopover` returns nil, leaving `model.todoPopover == .pane(paneId)` with no popover on screen, so the next Cmd-Shift-' is consumed as a "dismiss" and the user has to press it twice. The alerts popover is the mirror image: no model state at all, an imperative `toggleAlertsPopover()`, plus a `.dismissAlertsPopover` command to poke it from the core.

**Evidence.** Read `perform`'s `.showTodoPopover` / `.showTodoPopoverForTab` arms (both `guard ... else { return }` after `update()` already committed `model.todoPopover`), the `TodoPopoverDelegateAdapter` / `TabTodoPopoverDelegateAdapter` round trip, `Update.swift`'s `.toggleTodoPopover` / `.todoPopoverClosed` cases and the tab-close path that emits `.dismissTodoPopoverForTab` "even though no `todoPopoverForTabClosed` will fire", and `reconcilePaneTodoPopover`, whose desired value is `(handle?.isShown == true) ? projection : nil`. `reconcileQuitConfirmation` and `reconcilePreferencesPanel` already do the opposite and correct thing: they lazily create, show, refresh and order out a host purely from a single-optional projection, with no command.

**Ideal fix.** Extend the two TODO passes (and an alerts pass) to own existence as well as content, using the `reconcileQuitConfirmation` shape: desired = projection derived from `model.todoPopover` (and a new model field for the alerts popover); nil -> `performClose` + drop the handle; non-nil with no handle -> build the VC, resolve the anchor, show; non-nil with a handle -> apply. Anchor resolution failing then simply leaves the projection unapplied and retries on the next reconcile instead of stranding the model. Delete the four popover Command cases, their perform arms, `dismissStrandedPopovers` / `dismissStrandedTabPopover`, and the `.dismissAlertsPopover` command; keep only the delegate -> `send(.todoPopoverClosed)` edge, which is a genuine view-to-model input for AppKit-owned click-away.

**Cheaper fallback.** Have the `.showTodoPopover` arms send the matching `*Closed` message on their failure paths so the model cannot stay stuck open. Fixes the stuck-toggle symptom, keeps the double truth.

**Risk.** The 2026-05-27 ADR explicitly lists "popover presentation" as a legitimate command, so this reverses a recorded decision and the ADR text needs updating with it. Anchor timing must be checked: the pass has to run after `reconcilePaneChrome` so `wrapper.todoButtonView` exists, which the current reconcile order already satisfies.

### S03. Collapse the duplicated bundle assembly in dev-build.sh and build-app.sh

`build` &middot; duplication &middot; impact 4, confidence 5 &middot; effort medium

`dev-build.sh`, `build-app.sh`, `agent-docs/build-details.md`

**Problem.** dev-build.sh and build-app.sh each assemble the app bundle with their own copy of the same ~50 lines: the PTYSessionBootstrap second `swift build`, the SKILL.md copy plus cmp guard, the three-entry danterm-hooks loop with its executability assertions, the whole shell-integration tree copy with its six-asset readability assertions, and the bundle-theme-resources.sh call. Only four things actually differ (icon name, executable name, Info.plist patching, install step, plus the dev-only identity helper). The copies have already drifted: the comments above the hook loop and the shell-integration copy were reworded independently in each file, which is exactly how a substantive divergence gets introduced next. build-app.sh also carries an inode/content collision guard for the GUI-vs-CLI binaries that dev-build.sh lacks, so the dev path silently skips a check the release path treats as load-bearing.

**Evidence.** Diffing dev-build.sh lines 58-115 against build-app.sh lines 66-117 shows the hook loop, the shell-integration copy plus asset loop, the SKILL.md copy+cmp, and the bundle-theme-resources.sh invocation are byte-identical; the only diff hunks are the executable/icon names, the Info.plist patching blocks, and the two independently reworded comment blocks. agent-docs/build-details.md already describes them as one shared behavior ("Both scripts also stage Contents/Resources: ..."), which is the doc admitting there is one concept implemented twice.

**Ideal fix.** Extract a single `scripts/assemble-app-bundle.sh` that takes the bundle path, the executable name, the icon name, the bin paths, and an optional version, and does every staging step and every assertion once, including the inode/content collision guard. dev-build.sh becomes compile + assemble + dev Info.plist patch + codesign + install; build-app.sh becomes compile (release) + assemble + version stamp. There is then exactly one place where a new bundled resource is added and exactly one place where its presence is asserted, so a dev bundle cannot diverge from a release bundle by omission.

**Cheaper fallback.** Leave the two scripts and add a contract test that asserts the two Resources staging sections are structurally identical -- but this only detects drift after the fact and adds a third artifact to maintain.

**Risk.** Low. Both scripts already have shimmed-swift contract tests (scripts/tests/dev-build-configuration-contract_test.sh and scripts/tests/build-app-helpers-contract_test.sh) that assert the staged resources exist, so the extraction is covered end to end by the existing gate steps.

### S04. Replace the four hand-copied bundle-layout assertion lists with one script

`build` &middot; duplication &middot; impact 4, confidence 5 &middot; effort small

`.github/workflows/ci.yml`, `scripts/tests/build-app-helpers-contract_test.sh`

**Problem.** The same list of bundle-layout assertions (MacOS/DanTerm executable, Helpers/danterm, Helpers/PTYSessionBootstrap, SKILL.md cmp, the three danterm-hooks, the three shell integrations, vendor/bash-preexec.sh, GUI-vs-CLI byte comparison) is written out four separate times in YAML: ci.yml's release-build-check for the built bundle and again for the unzipped bundle, and release-stable.yml's "Verify release bundle layout" and again in "Verify ZIP round-trip signature". Because the lists are YAML text rather than a callable artifact, the project has had to defend them with grep-based meta-tests that assert the workflow files contain certain literal strings, which is a test of a copy rather than of a behavior and will pass on a list that is present but wrong. Adding one bundled resource means editing five places.

**Evidence.** ci.yml lines 141-185 contain the assertion list twice (once for `$APP_PATH`, once for `$ZIP_WORK/DanTerm.app`); release-stable.yml lines 41-63 and 115-131 contain it twice more. scripts/tests/build-app-helpers-contract_test.sh then greps both workflow files for 'Contents/Helpers/PTYSessionBootstrap' and 'Contents/Resources/danterm/SKILL.md' and fails if the literals are absent, and separately greps release-stable.yml line numbers to check signing order.

**Ideal fix.** Write `scripts/verify-bundle-layout.sh <app-path>` holding the assertions once, call it from all four workflow sites, and add it to the gate's STEPS against a freshly assembled bundle. The grep-for-a-literal meta-tests in build-app-helpers-contract_test.sh then delete themselves: the script is executed rather than pattern-matched, so a list that is wrong fails instead of a list that is missing.

**Cheaper fallback.** Factor the two per-workflow duplicates into a single composite action or a YAML anchor, halving the copies without removing the YAML-as-source-of-truth problem or the grep meta-tests.

**Risk.** Low. The assertions are pure `test -x` / `test -r` / `cmp` and move verbatim; the workflows keep their signing and notarization logic untouched.

### S05. Make a tab's focus and zoom part of its tree, not two loose fields

`core-model` &middot; structural &middot; impact 4, confidence 5 &middot; effort medium

`lib/DanTermCore/Sources/DanTermCore/Model.swift#TabModel`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#update`, `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#tabChrome`

**Problem.** TabModel stores `rootNode`, `focusedPaneId`, and `isZoomed` as three independent fields, so "the focused pane is a leaf of this tab's tree" and "zoom is off unless the tree changed shape" are conventions every tree-editing arm must re-honour by hand. Every structural edit in Update.swift repeats the same three-line ritual, and any arm that forgets it leaves a tab pointing at a pane that no longer exists. Read code then compensates: tabChrome falls back to ("Terminal", nil), tabChipKind falls back to `.none`, focusedPane returns nil, and validateAndBuild re-validates focusedPaneId at restore. That is four defensive sites paying for one missing type.

**Evidence.** Update.swift writes `tab.focusedPaneId` after a tree edit at lines 205, 262, 304, 328, 338, 407 and clears `tab.isZoomed = false` at 207, 260, 305, 329, 337, 406, 1975 -- each time as a separate statement inside the same `updateTab` closure that assigns `rootNode`. `removeLeaf` (ModelOperations.swift#removeLeaf) returns a `nextFocus` the caller is trusted to apply; nothing forces it. Model.swift#validateAndBuildDetailed re-checks `leafIds.contains(focusedPaneId)` and silently substitutes `firstLeafId`, which only makes sense because the field can dangle. ModelOperations.swift#tabChrome and #tabChipKind both guard against `paneInNode(tab.rootNode, id: tab.focusedPaneId)` returning nil.

**Ideal fix.** Replace the three fields with one `PaneTree` value owning `rootNode`, `private(set) var focused: PaneId`, and `private(set) var isZoomed: Bool`. Its only mutators are the structural operations (`split`, `remove`, `move`, `swap`, `setRatio`, `focus`, `toggleZoom`), each of which re-establishes focus from the operation's own result and clears zoom when the shape changed. `focused` then has no setter that can name a non-leaf, so a dangling focus is unrepresentable and the defensive fallbacks in tabChrome/tabChipKind/focusedPane become unreachable and can be deleted. Give it a non-optional `focusedPane: PaneModel` accessor so callers stop handling a nil that cannot occur.

**Cheaper fallback.** Keep the fields but funnel every structural edit through one `mutating func replaceTree(_:focusHint:)` on TabModel that applies rootNode, re-anchors focus to the hint or the first leaf, and clears zoom -- one place to get right instead of seven, though the invariant is still enforced by using the right function.

**Risk.** Touches every tree-editing arm of update(). Behavioral risk is low because the existing arms all already perform the ritual; the migration is mechanical and the existing tree/focus tests in ModelOperationsTests and UpdatePaneTests pin the outcomes.

### S06. Give sessions one tree-walking mutator instead of five whole-model traversals per report

`core-model` &middot; accidental-complexity &middot; impact 4, confidence 5 &middot; effort small

`lib/DanTermCore/Sources/DanTermCore/Model.swift#updateSession`, `lib/DanTermCore/Sources/DanTermCore/Model.swift#pane(owning:)`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#update`

**Problem.** `AppModel.updateSession` is written on top of the two generic whole-model helpers, so mutating one nested session walks the entire model several times and materializes every PaneModel in the app twice. `pane(owning:)` is `allPanes.first { ... }`, and `allPanes` eagerly builds an array of every pane (each a full struct copy carrying its session and todos array) before searching it. The `.sessionReport` arm then repeats the lookup three more times to answer "which pane" and "did it change". This is the hot path for terminal-reported title, cwd, and progress, and the cost is pure bookkeeping: nothing about the operation needs more than one walk.

**Evidence.** Model.swift#updateSession calls `pane(owning: id)` (which builds `allPanes` = `groups.flatMap { $0.tabs.flatMap { panesInNode($0.rootNode) } }`, itself allocating at every recursion level via `+`) and then `updatePane(paneId)`, which walks the trees again. Update.swift lines 531-537 add three more traversals for one report: `model.pane(owning: sessionId)?.id`, `model.pane(paneId)?.session` for `previous`, `model.updateSession(...)`, then `model.pane(paneId)?.session != previous`. Five traversals and two whole-model array materializations per admitted report.

**Ideal fix.** Add a single session-keyed tree mutator: `mutating func updateSession(_ id: SessionId, _ body: (inout SessionModel) -> Void) -> SessionMutation?` that recurses the trees once, finds the leaf whose `pane.session?.id == id`, rebuilds only that spine, and returns the owning `PaneId` plus whether the value actually changed. The `.sessionReport` arm then reads `guard let m = model.updateSession(sessionId, { reduceSession(&$0, report: report) })` and uses `m.paneId` / `m.didChange` directly -- one walk, no array materialization, and no way for the four lookups to disagree with each other. Also make `pane(owning:)` walk the tree directly rather than through `allPanes`.

**Cheaper fallback.** Make `pane(owning:)` a direct tree walk (no `allPanes` materialization) and have the `.sessionReport` arm hoist a single `paneId` lookup, passing it to a `updatePane(paneId)`-based mutation instead of re-resolving. Drops two traversals and both materializations without changing the API shape.

**Risk.** low

### S07. Collapse the duplicated pane/tab TODO surface onto one owner type

`core-reducer` &middot; duplication &middot; impact 4, confidence 5 &middot; effort large

`lib/DanTermCore/Sources/DanTermCore/Msg.swift#Msg`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#update`, `lib/DanTermCore/Sources/DanTermCore/Command.swift#Command`, `lib/DanTermCore/Sources/DanTermCore/Model.swift#TodoPopoverScope`

**Problem.** TODO editing exists twice, once keyed by PaneId and once by TabId, differing only in which accessor writes the array. There are 9 mirrored Msg pairs (addTodo/addTabTodo, toggleTodoDone/toggleTabTodoDone, setTodoDone/setTabTodoDone, editTodoText/editTabTodoText, deleteTodo/deleteTabTodo, reorderTodo/reorderTabTodo, clearCompletedTodos/clearCompletedTabTodos, toggleTodoPopover/toggleTodoPopoverForTab, todoPopoverClosed/todoPopoverForTabClosed), 2 mirrored Command pairs, and 3 structurally identical two-case enums naming the same thing. That is 18 of the 108 Msg cases and roughly 200 lines of Update.swift. Every new TODO behavior has to be written, wired, and tested twice, and the two halves have already drifted: deleteTodo skips the pane-exists guard that deleteTabTodo has, and toggleTodoPopover/toggleTodoPopoverForTab each hand-code the "dismiss the other kind first" mutual exclusion.

**Evidence.** Read Update.swift lines 1152-1351: the pane and tab handlers are line-for-line equivalent modulo `model.updatePane(paneId){...}` vs `updateTab(tabId, in:&model){...}`, and both reorder arms call the same `reorderedTodos` helper. Read Msg.swift lines 34-42 (`TodoSource`, `TodoDestination`) and Model.swift line 155 (`TodoPopoverScope`) -- three declarations of `case tab(TabId) / case pane(PaneId)`. Read Command.swift lines 78-81 for showTodoPopover/showTodoPopoverForTab/dismissTodoPopover/dismissTodoPopoverForTab, and AppRuntime.swift:1185-1210 where all four are interpreted. `.moveTodo` (Update.swift:1241) already proves the unified shape works: it takes source and destination as owner enums and switches on them at the two mutation points.

**Ideal fix.** One `TodoOwner { case pane(PaneId); case tab(TabId) }` used everywhere -- replacing TodoSource, TodoDestination, and TodoPopoverScope -- plus one accessor pair on AppModel (`todos(of: TodoOwner) -> [TodoItem]?` and `updateTodos(of: TodoOwner, _ body:)`). The 18 Msg cases become 9 taking `owner: TodoOwner`, the 4 popover Commands become `showTodoPopover(TodoOwner)` / `dismissTodoPopover`, and the ~200 lines become one handler per verb. Divergence between the two halves stops being expressible.

**Cheaper fallback.** Keep the split Msg cases but route both arms of each pair through shared `func applyTodoEdit(_ model: inout AppModel, owner: TodoOwner, _ edit: TodoEdit)` helpers. Removes the body duplication but leaves 18 Msg cases, 4 Commands, and 3 enums to keep in sync.

**Risk.** Low behavioral risk: the mutations are equivalent today, so the merge is mostly mechanical. The real risk is churn in the two popover views and the two large test suites (UpdateTodoTests, UpdateTabTodoTests), which currently pin the same behavior twice and would merge into one parameterized suite.

> Folded in from `core-reducer`: Delete the eight Msg cases no production code can send. Eight Msg cases have no sender outside the test suite: the six prefReset\* cases, markAlertRead, and setTabTodoDone. They carry ~35 lines of reducer code and four test files' worth of assertions that pin behavior no user or script can reach, which makes the Msg surface read as larger and more capable than it is and makes the preferences panel look like it has revert controls it does not have.

### S08. Design-doc statuses lie: superseded notes say `Status: Accepted` and the index shows no status

`docs` &middot; clarity &middot; impact 4, confidence 5 &middot; effort small

`docs/design/index.md`, `docs/design/2026-05-27-terminal-focus-display-link.md`, `docs/design/2026-03-05-display-scaling.md`, `docs/design/2026-08-10-terminal-reported-pane-facts.md`, `docs/design/2026-06-09-appkit-lifetime-safety.md`, `docs/design/2026-05-28-core-module-via-symlink.md`

**Problem.** index.md defines the ADR contract -- every note carries a `Status` from {Accepted, Superseded, Draft} -- and then lists all sixteen notes as an undifferentiated bullet list with no status shown. Meanwhile the notes contradict their own status line: 2026-05-27-terminal-focus-display-link.md reads `Status: Accepted` on line 3 and, four lines later, "superseded by the libghostty removal. Every mechanism below ... no longer exists." 2026-08-10-terminal-reported-pane-facts.md reads `Status: Accepted` immediately above a `Superseded by:` field pointing at its replacement. Five notes carry no `Status` field at all. So the only reliable way to learn that a note is a historical record is to open it and read the banner, which is exactly the cost the index exists to remove -- and an agent following AGENTS.md's "Read before you touch it" table lands on 2026-03-05-display-scaling.md (mechanism superseded) with nothing at the pointer warning it.

**Evidence.** Read index.md in full (48 lines: it mandates Status and lists 16 notes with no status annotation). Grepped `^Status|^- Status` across docs/design/2026-\*.md: 11 files have it, 5 (core-module-via-symlink, pure-core-support-split, appkit-lifetime-safety, ui-harness-whole-module-substitution, both 2026-08-10 session-owned) do not. Read the first 14 lines of terminal-focus-display-link.md and display-scaling.md and the first 30 of both 2026-08-10 notes, confirming the Accepted-plus-superseded-banner contradiction in each.

**Ideal fix.** Make the status machine-checked and single-sourced: fix a required front-matter block (`Status`, `Date`, optional `Superseded by`) on every note, generate the `## Notes` list in index.md from those fields so each row shows its status and its successor link, and add a docs lint to scripts/run-test-suite.sh (alongside research-index-lint.sh, which already enforces exactly this shape for docs/research/) that fails when a note has a supersession banner or `Superseded by` field while its `Status` still reads `Accepted`, when a note lacks the required fields, or when the index and the directory disagree. Then a status cannot be wrong without the gate going red.

**Cheaper fallback.** Hand-edit the five superseded notes to `Status: Superseded` with a successor link, add the missing Status fields, and append the status to each index row -- no lint, so it drifts again on the next removal.

**Risk.** low

### S09. Delete plan-terminal-engine/: 2,232 tracked lines that declare themselves normative and the engine ADR says it replaced

`docs` &middot; dead-code &middot; impact 4, confidence 5 &middot; effort medium

`plan-terminal-engine/README.md`, `plan-terminal-engine/14-roadmap.md`, `docs/design/2026-08-06-swift-terminal-engine.md`, `AGENTS.md`

**Problem.** Two tracked documents make opposite claims about the same directory. docs/design/2026-08-06-swift-terminal-engine.md says of itself: "It replaced the `plan-terminal-engine/` planning directory when the engine left the plan state ahead of 0.1.0 ... the milestone roadmap it grew out of is not preserved -- see git history for that." But the directory is still tracked with 16 files and 2,232 lines, and its README says "The documents here are still normative for ongoing engine work." The roadmap it supposedly did not preserve is right there in 14-roadmap.md, calling itself "the canonical high-level progress checklist," full of migration-era criteria about the Ghostty backend running through the boundary. AGENTS.md points engine work only at the ADR and never mentions this tree, so an agent that finds it by listing the repo root gets a self-declared normative plan for a migration that finished, competing with the live decision register.

**Evidence.** Read plan-terminal-engine/README.md lines 1-25 and 14-roadmap.md lines 1-25; `git ls-files plan-terminal-engine` returns 16 tracked files, `wc -l` totals 2,232. Read docs/design/2026-08-06-swift-terminal-engine.md lines 1-90 for the "It replaced the plan-terminal-engine/ planning directory" sentence and the id/status discipline it defines. Grepped AGENTS.md: no mention of plan-terminal-engine.

**Ideal fix.** Delete the directory. Anything in it still binding is a decision and belongs as a row in the engine register (which owns amend-in-place semantics and stable ids), and the history stays in git exactly as the ADR already says. Before deleting, re-point the handful of inbound links -- docs/design/2026-08-05-pane-session-lexicon.md references ../../plan-terminal-engine/02-migration-and-boundary.md -- at the register row that now owns each claim.

**Cheaper fallback.** Keep the tree but rewrite its README to say it is a frozen historical record superseded by the engine register, and delete the "still normative" sentence and the roadmap's "canonical" claim.

**Risk.** An engine contract that lives only in these files and was never migrated into a register row would be lost from the docs. Auditing the 16 files for such orphans is the real work; git history is the safety net.

### S10. Lint doc-to-code citations: seven cited paths no longer exist, one of them misstating a layer

`docs` &middot; clarity &middot; impact 4, confidence 5 &middot; effort medium

`docs/design/2026-05-27-model-driven-view-reconciliation.md`, `docs/design/2026-08-05-pane-session-lexicon.md`, `docs/design/2026-06-09-appkit-lifetime-safety.md`, `docs/design/2026-03-05-display-scaling.md`

**Problem.** Every file path cited in AGENTS.md, agent-docs/, and docs/\*.md resolves except seven, all pointing at deleted Ghostty-era files. The worst is in a note with no supersession banner and `Status: Accepted`: 2026-05-27-model-driven-view-reconciliation.md's References list `app/Projections.swift` and `app/ModelOperations.swift`, but both files now live in lib/DanTermCore/Sources/DanTermCore/. That is not a cosmetic path error -- it tells an agent that view projections and reconcile scheduling are app-layer code when they are pure core, which is the exact distinction AGENTS.md's three-layer section and core-purity-lint.sh exist to protect. Alongside it: the pane/session lexicon ADR's References are two deleted files (app/TerminalBackend.swift, app/TerminalView.swift) and its rule still carves out an exception for "Ghostty adapter identifiers, including ghostty_surface_t," which cannot occur; appkit-lifetime-safety.md links `../upgrading-ghostty.md#steps` as a normative step in its numbered invariant list while its own banner says that file was retired.

**Evidence.** Extracted every backticked `app|lib|scripts|docs|agent-docs|integrations`-rooted path from docs/design/_.md, agent-docs/_.md, AGENTS.md, docs/\*.md and tested each for existence: exactly seven missing (app/GhosttyApp.swift, app/ModelOperations.swift, app/Projections.swift, app/TerminalBackend.swift, app/TerminalView.swift, docs/upgrading-ghostty.md, lib/DanTermCore/Sources/DanTermCore/BackingGeometry.swift). Confirmed lib/DanTermCore/Sources/DanTermCore/ now holds both ModelOperations.swift and Projections.swift, and read the References block at the tail of model-driven-view-reconciliation.md (lines 200-217), which has no banner and Status: Accepted. Read the lexicon ADR in full (59 lines) and appkit-lifetime-safety.md lines 55-95, 150-160.

**Ideal fix.** Add a docs citation lint to scripts/run-test-suite.sh that resolves every repo-relative path (and, where the `file#identifier` form is used, the identifier) cited in tracked markdown outside references/ and git-history-only contexts, failing on a dangling target. The repo already runs eleven such gates; this one makes a rename that orphans a doc reference impossible to land silently, which is the structure in which this whole class -- including the layer-misstating citation -- cannot recur. Fix the seven current hits in the same change, and drop the now-impossible ghostty_surface_t carve-out from the lexicon ADR.

**Cheaper fallback.** Fix the seven paths by hand and delete the dead upgrading-ghostty link; drift resumes at the next rename.

**Risk.** The lint needs an escape hatch for paths deliberately cited as deleted (the supersession banners name gone files on purpose) -- an inline allow marker, or restricting the check to References sections and links.

### S11. Stop compiling the entire app core into the danterm CLI binary

`ipc-cli` &middot; layering &middot; impact 4, confidence 5 &middot; effort medium

`Package.swift#DanTermCLI`, `cli/main.swift#DanTermCLI.runDoctor`, `lib/DanTermCore/Sources/DanTermCore/Doctor.swift#evaluateDoctor`, `lib/DanTermSupport/Sources/DanTermSupport/DoctorProber.swift#gatherDoctorFacts`

**Problem.** The `DanTermCLI` target has `path: "cli"`, and `cli/` holds tracked symlinks to both `lib/DanTermCore/Sources/DanTermCore` and `lib/DanTermSupport/Sources/DanTermSupport` with no `exclude:`. So the shell client compiles and links the whole Elm core -- Update, Model, Persistence, RecoveryStore, IpcEntityEncoder, SidebarItemStore, ScrollbarMath, TodoPopoverState, DragDropInput, DropZone -- plus all of DanTermSupport. The only reason is `danterm doctor`: `evaluateDoctor`/`renderDoctorReport`/`doctorExitCode` are internal to DanTermCore and `gatherDoctorFacts` is internal to DanTermSupport, so same-module compilation is the only way the CLI can call them. Every core edit rebuilds the CLI, every core compile error breaks it, and a bug in app state code can only be ruled out of the CLI by reading, not by the dependency graph.

**Evidence.** `Package.swift` lines 51-63 define the target over `cli/` with dependency `DanTermProtocol` only; `ls -la cli` shows the two symlinks. `.build/debug/DanTermCLI.build/` contains object files for Update.swift, Model.swift, Persistence.swift, RecoveryStore.swift, IpcEntityEncoder.swift, ScrollbarMath.swift, DropZone.swift and the rest of core/support, and `.build/debug/danterm` is 13M. `grep` confirms the CLI's only core/support entry points are the four doctor functions.

**Ideal fix.** Move the doctor decision table and renderer to where both clients can import it: `DoctorFacts` already lives in DanTermProtocol, so put `DoctorCheck`/`evaluateDoctor`/`renderDoctorReport`/`doctorExitCode` next to it (or in a small `DanTermDoctor` module) as public API, and give `gatherDoctorFacts` a public entry point in DanTermSupport. Then drop both symlinks from `cli/` so the CLI target's source set is exactly `cli/*.swift` and its dependencies are exactly the modules it uses. The layering claim in AGENTS.md then holds by construction rather than by convention.

**Cheaper fallback.** Add `exclude:` for the DanTermCore symlink and keep only DanTermSupport -- this halves the problem but leaves the same coupling in kind, and DanTermCore is where the doctor evaluator lives, so it does not actually work without moving that file first.

**Risk.** Doctor evaluation moves module, so `lib/DanTermCore/Tests/DanTermCoreTests/DoctorEvaluatorTests.swift` moves with it and the app's own doctor-permissions path needs the new import. No wire or CLI behavior changes.

### S12. Move test-only state and fault injection out of the production PTY actor

`pty` &middot; accidental-complexity &middot; impact 4, confidence 5 &middot; effort large

`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#TerminalPTYHost`, `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#receiveSpawn`, `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#childExited`, `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#completeMasterCloseIfPossible`, `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#sourceCancellationHandlerRan`

**Problem.** About a third of the actor's stored properties exist only for tests, and several of them add branches to the exact production paths whose correctness those tests are meant to establish. The seams are not inert observers: they change control flow. `receiveSpawn` can stop before `process(.spawnSucceeded)` and park it in `hasDeferredSpawnSuccess`; `childExited` can be told to fake a transient `waitid`; `completeMasterCloseIfPossible` can `dup2` a probe descriptor instead of closing; `sourceCancellationHandlerRan` can queue acknowledgements instead of applying them. So the shipping teardown ladder carries a parallel, test-driven variant of itself, and a reader auditing quiescence has to hold both versions in mind at once.

**Evidence.** Test-only stored state I counted in the actor: `spawnReportDelay`, `spawnDeliveryDelay`, `lastIssuedLaunch`, `holdsSourceCancellationAcknowledgements`, `heldSourceCancellationIDs`, `sourceCancellationHeldObserver`, `holdsInstalledSourcesBeforeActivation`, `installedSourcesObserver`, `hasDeferredSpawnSuccess`, `descriptorReuseReplacementFD`, `reusedDescriptor`, `transientChildWaitInjections`, `callbacksAfterTeardown`, `forcedQuiescenceCount`, `emittedUpdateSignalCount`, `updateSignalsAfterTermination`, `testUpdateHandler`, `capturedOutput`, `appliedTransitions`, `capturedSubmittedTransitions`, `capturedInputWrites`, `capturedReplyWrites`, plus the DEBUG trio `testOutputWindow` / `testOutputDiscardedByteCount` / `testOutputObservers` -- 25 of the 74 declared properties in the file. Their entry points (`injectSpawnReportDelay`, `injectSpawnDeliveryDelay`, `injectTransientChildWaits`, `holdSourceCancellationAcknowledgements`, `releaseSourceCancellationAcknowledgements`, `forceExitBoundForTesting`, `holdInstalledSourcesBeforeActivation`, `releaseInstalledSourcesForActivation`, `installDescriptorReuseProbe`, `reusedDescriptorForTesting`, `lastLaunchedLeaderPID`, `lastLaunchHasPendingDelivery`, `setTestUpdateHandler`, `observeTestOutput`, `deliverOutputForTesting`, `outputBytes`, `inputWrites`, `replyWrites`, `submittedTransitions`, `transitions`, `resourceSnapshot`) account for a large share of the file's 2075 lines.

**Ideal fix.** Extract the collaborators the seams are secretly standing in for and inject them at init: a `PTYSpawning` witness (production spawns, the test one delays or withholds), a `ChildWaiting` witness (production `waitid`, the test one injects the transient), and a `SourceJoining`/`DescriptorClosing` witness for the cancellation barrier and the `dup2` probe. The host then holds no test-only mutable state and no test-only branch: it always calls the witness. The pure counters that are genuinely evidence (`callbacksAfterTeardown`, `forcedQuiescenceCount`, `updateSignalsAfterTermination`) collapse into one `TerminalPTYResourceSnapshot`-shaped struct field so the census is one property rather than six.

**Cheaper fallback.** Gather every injection field into a single `private var seams: HostSeams?` (nil in production) so each hot path has one `if let seams` branch instead of a dozen scattered flags, and the census counters move into one struct.

**Risk.** Wide but mechanical; the existing lifecycle tests are the gate, and they are exactly the callers being rewired, so a mistake shows up as a failing test rather than a shipped regression.

### S13. Give sidebar cells typed subviews instead of string-identifier lookups

`sidebar` &middot; structural &middot; impact 4, confidence 5 &middot; effort medium

`app/SidebarView.swift#makeTabCell`, `app/SidebarView.swift#configureTabCell`, `app/SidebarView.swift#makeGroupCell`, `app/SidebarView.swift#configureGroupCell`, `app/SidebarView.swift#applyGroupCollapseState`, `app/SidebarView.swift#SidebarRowView.refreshHostedPaneStrips`, `app/BadgeLabel.swift#visibleAlertBadge`, `tests-ui/SidebarBadgeTests.swift#sidebarBadgeTests`

**Problem.** Every sidebar cell is a bare NSTableCellView whose children are found again at paint time by matching NSUserInterfaceItemIdentifier strings against `cell.subviews`. Each lookup is an `if let ... as? T` whose failure path is silence: a renamed or restructured subview does not fail to compile and does not throw, it just stops painting that part of the row. The same string constants are re-declared in makeTabCell and configureTabCell and appear again in applyGroupCollapseState, in SidebarRowView's subview walk, and in BadgeLabel's hit test. This is the substrate that produced the incidents already commented in this file (the blank 2pt title from a recycled editable field, the dropped badge repaints).

**Evidence.** makeTabCell declares subtitleId/bellDotId/colorStripeId/accessoryStackId/leadingStackId/chipId/paneStripId and configureTabCell declares the same seven plus jumpBadgeId; configureTabCell then does five separate `cell.subviews.first(where: { $0.identifier == ... }) as? X` chains, each silently skipping its paint on nil. configureGroupCell and applyGroupCollapseState both dig for "groupAccessoryStack" -> "groupCaretButton"/"groupBellBadge"/"groupTabCountBadge". SidebarRowView.refreshHostedPaneStrips walks subviews twice with compactMap casts to reach the PaneStripView. BadgeLabel.swift#visibleAlertBadge hard-codes "tabAccessoryStack" and "bellDot" -- and tests-ui/SidebarBadgeTests.swift builds its own NSTableCellView with those literals rather than a real sidebar cell, so renaming the ids in SidebarView would break alert-badge clicks with the test still green.

**Ideal fix.** Replace NSTableCellView with two final subclasses, SidebarTabCellView and SidebarGroupCellView, each owning its children as stored `let` properties (chip, title, subtitle, paneStrip, bellBadge, jumpBadge, colorStripe / caret, bellBadge, tabCountBadge, separator) and exposing `apply(_ projection:skipTitle:)`. The configurators become straight-line assignments with no optionals, the duplicated identifier constants disappear, visibleAlertBadge becomes `cell.bellBadge` on the typed cell, and refreshHostedPaneStrips becomes `cell.paneStrip.rowBackground = background`. A missing or misnamed subview stops being representable.

**Cheaper fallback.** Hoist the identifier strings into one private enum shared by SidebarView and BadgeLabel so the six sites cannot drift apart, and make the lookups assert in debug builds. This keeps the silent-nil paint path, it only makes the strings agree.

**Risk.** Low and mechanical, but it touches the reuse path: the typed cells must keep the makeView(withIdentifier:) recycling and resetRecycledRenameState behavior, and the UI harness tests that fish rows out by identifier need updating to the typed accessors.

### S14. Store both screens as ScreenState instead of one boxed and one loose

`terminal-core` &middot; structural &middot; impact 4, confidence 5 &middot; effort medium

`lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.liveScreenState`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.swapActiveScreen`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.resetControlState`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.clampCursorStateToActiveGrid`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.clampScreenCursorState`

**Problem.** Per-screen state exists in two incompatible shapes at once. The live screen's seven fields (`rows`, `cursor`, `isPendingWrap`, `savedCursor`, `semanticContent`, `semanticContentClearsAtEndOfLine`, `kittyKeyboardStack`) are loose stored properties on `Terminal`, while the inactive screen is a boxed `ScreenState`. A hand-written computed property, `liveScreenState`, marshals between them with a get list and a set list that must be kept identical by hand, and `swapActiveScreen` is a three-way dance through that property. Every operation that must touch both screens then has to be written twice, once against loose fields and once against the box.

**Evidence.** `liveScreenState`'s getter names all seven fields and its setter names the same seven again -- adding an eighth per-screen field and forgetting either half compiles fine and silently drops that field on every alt-screen switch. The asymmetry has already leaked twice in the current code: `resetControlState` clears `kittyKeyboardStack` for the live screen and then needs a separate `if var inactive = inactiveScreen { inactive.kittyKeyboardStack.removeAll(...); inactiveScreen = inactive }` block for the other one; and `clampCursorStateToActiveGrid` and `clampScreenCursorState` are line-for-line the same three operations (clamp cursor, clamp saved cursor, recompute the pending-wrap latch) written once for the loose fields and once for a `ScreenState` parameter.

**Ideal fix.** Store `private var primary: ScreenState` and `private var alternate: ScreenState?` and make the live screen a computed accessor selected by `activeScreen`. Switching screens becomes flipping the enum -- no marshalling pair, no carried-cursor dance -- and every both-screens operation (`resetControlState`, cursor clamping, a future per-screen field) is written once and applied to each element of a two-element sequence. `clampScreenCursorState` becomes the only clamp, and `liveScreenState`'s duplicated get/set lists disappear entirely.

**Cheaper fallback.** Keep the loose fields but derive both directions of `liveScreenState` from a single list of `WritableKeyPath` pairs, and delete `clampCursorStateToActiveGrid` in favor of applying `clampScreenCursorState` through the accessor. This removes the two duplicated enumerations without moving storage, but leaves the shape that allows a per-screen field to be added loose and never boxed.

**Risk.** Screen switching, DECSC/DECRC across screens, and reflow all read these fields directly on `self`; moving storage behind an accessor is mechanical but touches many call sites and must not change exclusivity behavior in the hot print path. Behavior is pinned by the alternate-screen and kitty-keyboard test suites, so regressions surface fast.

### S15. Replace the four hand-branched mode switches with one mode registry

`terminal-core` &middot; duplication &middot; impact 4, confidence 5 &middot; effort medium

`lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.applyDECPrivateModes`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.decPrivateModeStatus`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.applyANSIModes`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.ansiModeStatus`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.resetControlState`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.inputModes`

**Problem.** The same set of terminal modes is enumerated by hand in five places: fourteen loose stored properties, the setter switches (`applyDECPrivateModes`, `applyANSIModes`), the DECRQM reporting switches (`decPrivateModeStatus`, `ansiModeStatus`), the reset list (`resetControlState`), and the `inputModes` projection. Nothing ties a mode number to its storage, so adding or changing a mode means correctly editing up to five disjoint lists, and omitting one produces a mode that can be set but not reported, or reported but not reset, with no compiler or type-level signal.

**Evidence.** I diffed the switch arms. `applyDECPrivateModes` handles 1, 6, 7, 25, 1000, 1002, 1003, 1004, 1006, 1047, 1048, 1049, 2004, 2026; `decPrivateModeStatus` handles the same set minus 1048; `resetControlState` restates all fourteen flags by hand. The gap this shape produces is already live: `isCursorBlinking` and `cursorShape` are stored and are set by DECSCUSR in `applyCursorStyle`, but there is no `case 12` in `applyDECPrivateModes` and no `case 12` in `decPrivateModeStatus`, so `CSI ?12h` / `CSI ?12l` (xterm's cursor-blink mode, present in references/ghostty/src/terminal/modes.zig as `cursor_blinking`, value 12) is silently dropped even though the state it targets exists; ANSI mode 12 (SRM) is likewise absent. `isApplicationKeypadMode` is settable via ESC = / ESC > and reset by `resetControlState` and projected by `inputModes`, but has no DECRQM entry either.

**Ideal fix.** Move the flags into a `TerminalModes` value type and define one static registry of `(code: UInt16, isPrivate: Bool, path: WritableKeyPath<TerminalModes, Bool>)` entries. Set and reset both become a registry lookup plus a keypath write; DECRQM reporting becomes the same lookup plus a read, so a mode that can be set is reportable by construction; a hard/soft reset becomes `modes = TerminalModes()` rather than fourteen assignments; and `inputModes` becomes a projection of the struct. Modes with side effects beyond a flag (6, 1047, 1048, 1049) stay as explicit arms layered on top of the registry, which is exactly the small set that genuinely differs.

**Cheaper fallback.** Keep the loose flags but drive `decPrivateModeStatus`/`ansiModeStatus` and `resetControlState` from one static array of `(code, keypath)` so only the setter switch is hand-written. This closes the report-and-reset drift but still lets a new mode be added to the setter alone.

**Risk.** Low. The behaviors are pinned by TerminalMouseModeTests, the fixture-driven `state-mode` cases, and the DECRQM tests; the mouse-tracking enum collapse (1000/1002/1003 into one `TerminalMouseTrackingMode`) is a deliberate, test-pinned simplification and should be carried across as-is rather than expanded into separate bits.

### S16. Unify the two search matchers and lift search out of Terminal

`terminal-core` &middot; duplication &middot; impact 4, confidence 5 &middot; effort large

`lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.scanClosedRecordSearchUnits`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.scanSearchUnits`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.RecordSearchProjectionUnit`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.SearchProjectionUnit`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.SearchMatchIndex`

**Problem.** Search is implemented twice: once over closed history records and once over the display projection. The two scanners carry byte-for-byte identical sliding-window match logic, and the two unit types differ only in the coordinate they carry. A fix to the matcher -- an off-by-one at the window wrap, a change to how the trailing seed is retained -- has to be made in both, and the two can silently disagree, which is precisely the failure the `scannedSearchMatchRanges` test oracle exists to catch after the fact rather than prevent.

**Evidence.** `scanClosedRecordSearchUnits` and `scanSearchUnits` each declare `var window = [Unit?](repeating: nil, count: needleKeys.count)`, `var unitCount = 0`, and a nested `consume(_:recordsMatch:)` whose body is the same ring-buffer write, the same `unitCount >= needleKeys.count` guard, the same modular comparison loop over `needleKeys.indices`, and the same trailing-unit extraction via `(trailingStart..<unitCount).compactMap { window[$0 % needleKeys.count] }`. The only differences are the position type (`LogicalLineStore.RecordTextPosition` vs `TextAnchor`) and one extra `range(match, intersects: matchRows)` filter in the projection version. `RecordSearchProjectionUnit` and `SearchProjectionUnit` are the same three fields (`key`, `start`, `end`) with different position types.

**Ideal fix.** Extract one generic `NeedleWindow<Position>` matcher that owns the ring buffer, the comparison, and the trailing-unit tail, parameterized only by the position type and an admit predicate; the two producers (`forEachClosedRecordCell` and `forEachSearchUnit`) feed it. Then lift the whole search subsystem -- `SearchState`, `SearchMatchIndex`, the two producers, the matcher, and the resolution helpers -- into its own type and file, since none of that code mutates the grid: it reads `history`, `rows`, `evictedRowCount`, and `columnCount`, and writes only search state and `viewportState`. That removes roughly a thousand lines and eight nested types from `Terminal`, and makes the search index's inputs an explicit parameter rather than ambient access to every field of the terminal.

**Cheaper fallback.** Unify only the matcher into a generic `NeedleWindow<Position>` and leave the state where it is. That removes the duplicated correctness-critical logic, which is most of the risk, without paying for the file move.

**Risk.** The search index is performance-sensitive and its costs are pinned by ProjectionRowCounter/SearchIndexMaintenanceCounter assertions in TerminalSearchTests; a generic matcher must stay specializable same-module so those bounds hold. Behavior is well covered by both the indexed path and the `scannedSearchMatchRanges` oracle, so a divergence would be caught.

### S17. Model master-close asynchrony in the reducer instead of deferring a command tail

`pty` &middot; structural &middot; impact 4, confidence 4 &middot; effort medium

`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#execute(_:)`, `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#resumeCommandsAfterMasterClose`, `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#completeMasterCloseIfPossible`, `lib/TerminalPTY/Sources/PaneProcessLifecycle/PaneProcessLifecycle.swift#beginTeardown`

**Problem.** The reducer emits `[.reapLeader, .closeMaster, .signalSession(.hangup), .scheduleGrace(.hangup)]` as one atomic list, but closing the PTY master is not atomic: the host must wait for every descriptor-backed dispatch source's cancel handler to run. So `execute(_ commands:)` splits the list, parks the tail in `deferredCommandsAfterMasterClose`, and a later cancellation acknowledgement replays it through `resumeCommandsAfterMasterClose`. That resume path is a hand-copied second reduce loop -- it re-implements the `isReducing` bracket, the `publishPendingUpdate()` defer, and the `while pendingEvents.isEmpty == false { execute(reducer.handle(next)) }` drain from `process(_:)`. Two reduce loops means any future change to reduction ordering has to be made twice, and the split makes command order depend on how long a cancel handler takes rather than on the state machine.

**Evidence.** `execute(_ commands:)` special-cases `.closeMaster`, and on `masterFD >= 0` appends `commands.dropFirst(index + 1)` to `deferredCommandsAfterMasterClose` and returns early; `execute(_ command:)` even carries a `preconditionFailure` for `.closeMaster` because the single-command form must never see it. `resumeCommandsAfterMasterClose` then repeats `process(_:)`'s body verbatim, down to its own `precondition(isReducing == false)` and its own copy of the pendingEvents drain. `completeMasterCloseIfPossible` is the only caller, reached from `acknowledgeSourceCancellation`, i.e. from a libdispatch cancel handler.

**Ideal fix.** Give the reducer the event it is missing. `.closeMaster` becomes a request; the host replies with a new `PaneProcessLifecycleEvent.masterClosed` once the descriptor barrier drains, and `beginTeardown` returns `[.reapLeader, .closeMaster]` with `.signalSession`/`.scheduleGrace` emitted from the `.masterClosed` transition in `handleTeardown`. Every asynchronous step in this lifecycle already crosses the boundary as an event (`spawnSucceeded`, `childExited`, `sessionDrained`, `graceElapsed`); close is the one exception, and making it the rule deletes `deferredCommandsAfterMasterClose`, `resumeCommandsAfterMasterClose`, the two-arity `execute` split, and its `preconditionFailure`, leaving exactly one reduce loop whose command order cannot depend on cancel-handler timing.

**Cheaper fallback.** Keep the deferral but make `resumeCommandsAfterMasterClose` call one shared `runReduction(startingWith:)` helper that `process(_:)` also uses, so the drain loop exists once.

**Risk.** Teardown ordering is the most safety-critical path in this file (I2 / forced quiescence). The new event has to be emitted on the forced-cleanup path too, or `performForcedCleanupAfterMasterClose` would leave the reducer waiting. The existing teardown-convergence tests in TerminalPTYHostTests are the gate.

### S18. Derive the grand row/content totals from the block index instead of storing them

`scrollback` &middot; duplication &middot; impact 4, confidence 4 &middot; effort medium

`lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#LogicalLineStore.grandDisplayRowTotal`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#LogicalLineStore.evictOneDisplayRow`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#LogicalLineStore.removeLastDisplayRow`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#LogicalLineStore.wrapWriteCursorAtSeam`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#LogicalLineStore.recomputeIndex`

**Problem.** `grandDisplayRowTotal` and `grandContentUnitTotal` hold numbers the block index already holds. Because block `rowStart`/`contentStart` are absolute against `evictedRowCount`/`evictedContentUnitCount`, the totals are exactly `blocks.last.rowStart + rowCount - evictedRowCount` and the content analogue -- O(1) reads off the ring. Storing them separately means every mutation must move two representations of one quantity in the right order, and the file already carries scar tissue from getting that wrong: two sites have multi-line comments explaining that the totals must move _before_ a block can retire or the row is subtracted twice. `firstBlockNumber` is the same shape of redundancy: while `offsets` is non-empty it is always `firstRecordSequence / blockSize`, and `retireEmptyHeadBlocks` exists only to re-establish that.

**Evidence.** Read the maintenance pair at every mutation site: `addDisplayRowsToTail` and `addContentUnitsToTail` update grand-then-block together; `removeContentUnitsFromHead` and `addContentUnits(_:toBlockContaining:)` likewise; `evictOneDisplayRow` (line ~1031) and `removeLastDisplayRow` (line ~1213) update `grandDisplayRowTotal` and `blocks[...]` inline with comments naming the double-subtract hazard; `wrapWriteCursorAtSeam` (line ~3004) does it a fourth time inline; `recomputeIndex` re-accumulates both. `appendRecordOffset` sets `firstBlockNumber = sequence / Self.blockSize` on the first record, and `retireEmptyHeadBlocks` loops `while firstBlockNumber < firstRecordSequence / Self.blockSize`, so the two can only differ when `blocks` is empty, which is exactly when the store is empty.

**Ideal fix.** Make the grand totals computed properties over the block ring (`blocks.count == 0 ? 0 : blocks[blocks.count-1].rowStart + rowCount - evictedRowCount`, same for content) and delete the stored fields, so a block update and a total update cannot disagree because there is only one update. Make `firstBlockNumber` a computed `firstRecordSequence / Self.blockSize` and let `dropHeadRecord` drop one block when that quotient changes across its `firstRecordSequence += 1`, which retires `retireEmptyHeadBlocks`. `independentDisplayRowRecount` stays as the oracle against the arena, which is the comparison that actually catches a bug.

**Cheaper fallback.** Keep the fields but funnel every write through the existing `addDisplayRowsToTail` / `removeContentUnitsFromHead` helpers so the four inline sites cannot order the two updates differently, and add a debug assert that the stored total equals the block-derived one on every mutation.

**Risk.** Low correctness risk, and the read cost is one ring subscript, but `locate` and the hot read paths consult `grandDisplayRowTotal` per call, so the change should be checked against the browse benchmark before it is called free. If the property proves measurable, the assert-only fallback is the honest stopping point.

### S19. Collapse the two presentation-input change detectors into one entry point

`terminal-views` &middot; structural &middot; impact 4, confidence 4 &middot; effort small

`app/SwiftTerminalSessionView.swift#synchronizeGeometry`, `app/SwiftTerminalSessionView.swift#rerenderIfSurfaceInputsChanged`, `app/SwiftTerminalSessionView.swift#refreshBackingProperties`, `app/AppRuntime.swift#refreshSessionsForScreenChange`

**Problem.** The view answers "did a presentation input move?" twice with two different tests. `synchronizeGeometry` compares `metrics != currentMetrics` and re-renders on that; `rerenderIfSurfaceInputsChanged` compares the full `SurfaceInputs` tuple (columns, rows, metrics, colorSpace) and re-renders on that. `metrics` is a _field_ of `SurfaceInputs`, so the first test is a strict subset of the second, and correctness now depends on each AppKit hook calling the right combination in the right order. `viewDidMoveToWindow` and `viewDidChangeBackingProperties` call both; `setFrameSize` and `refreshBackingProperties` call only `synchronizeGeometry`. That asymmetry is a live defect on the very path the second detector exists for: `AppRuntime.refreshSessionsForScreenChange` exists because AppKit can skip `viewDidChangeBackingProperties` on a screen change, and it calls `refreshBackingProperties`, which cannot see a color-space move.

**Evidence.** `refreshBackingProperties()` is literally `{ synchronizeGeometry() }` (SwiftTerminalSessionView.swift:781-783), while `viewDidChangeBackingProperties` (line 540) calls `synchronizeGeometry()` _and_ `rerenderIfSurfaceInputsChanged()` with the comment "a color-space move at unchanged scale changes no metric -- so the surface inputs are checked directly rather than inferred from a geometry change." `SurfaceInputs` (line 255) includes `colorSpace: NSColorSpace?`, and `surfaceSwapchain` (line 313) reads `window?.colorSpace`. AppRuntime.swift:477-482 documents the screen-change path as existing precisely because the backing-properties callback may not fire.

**Ideal fix.** One method -- `synchronizePresentation()` -- that recomputes metrics and grid dimensions, pushes dimensions to the controller, calls `emitStateIfNeeded()` (already idempotent via `lastEmittedState`), and then re-renders the current plan if and only if the full `SurfaceInputs` tuple differs from the live swapchain's. `metricsChanged` disappears because metrics are already inside the tuple. Every AppKit hook and `refreshBackingProperties` call that one method, so no caller can pick a partial check.

**Cheaper fallback.** Add `rerenderIfSurfaceInputsChanged()` to `refreshBackingProperties` (and `setFrameSize`). This closes the current hole but leaves the two-detector shape that produced it.

**Risk.** Low. The only behavioral change is that a color-space-only move now re-renders on the screen-change path; today it self-heals on the next publish, so a quiet pane is the failing case. Watch that unifying the render trigger does not lose the first-geometry case where `swapchainInputs` is still nil (a plan published before any swapchain exists) -- keep the "no swapchain yet" branch rendering, as `applyResolvedTheme` already does.

### S20. Stop forking a PTY child for tests that only exercise engine policy

`tests` &middot; testing &middot; impact 4, confidence 4 &middot; effort medium

`lib/TerminalPTY/Tests/TerminalPTYHostTests/TerminalPTYHostTests.swift#TerminalPTYHostTests`, `lib/TerminalPTY/Tests/TerminalPTYHostTests/TerminalPTYHostTests.swift#capturedShiftSelectionReplays`, `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#TerminalPTYHost`, `lib/TerminalCore/Tests/TerminalCoreTests/TerminalInteractionPolicyTests.swift`, `scripts/test-terminal-pty.sh`

**Problem.** TerminalPTYHostTests is a single `@Suite(.serialized)` of 61 tests; 58 of them call `await host.start(...)` and fork a real `/bin/sh` plus a probe child, several with literal `sleep 0.1`/`sleep 0.2`/`sleep 30` in the child command. A large block of those tests (wheel routing, Shift-extension selection, SGR pointer reports, click granularity, OSC 52, OSC 8 link hover/open, search begin/navigate/clear) asserts behavior that TerminalCore already covers headlessly and exhaustively. Because the suite is serialized and every case pays fork + child-readiness latency, it is the second-listed long pole in the gate and it runs as two separate `swift test` invocations. The result is that the slowest gate step spends most of its wall clock re-proving engine policy through a process boundary that contributes no extra signal.

**Evidence.** `@Suite(.serialized)` at TerminalPTYHostTests.swift:12 with 61 `@Test` declarations and 58 `await host.start(` calls. `capturedShiftSelectionReplays` forks a real child via `exec \(try probeExecutable()) hold`, waits for `__READY__`, and then calls `host.deliverOutputForTesting(Array("\u{1B}[2J...alpha beta".utf8))` -- it injects the bytes itself and never uses the child again, so the fork is pure cost. The same policy is asserted headlessly in TerminalInteractionPolicyTests.swift: "wheel routes captured alternate and primary input in priority order", "Shift extension inherits token granularity and excludes an adjacent unit boundary", "Cmd link ownership suppresses reports and revalidates the originating run", 39 tests in all. scripts/test-terminal-pty.sh runs the package twice (once `--skip rapidCloseStressLeavesNoResources`, once `--filter` it) because only that one test needs a process to itself -- yet the whole suite is serialized.

**Ideal fix.** Make the host's PTY transport a seam rather than a hard `forkpty`: give TerminalPTYHost an injectable transport whose in-memory implementation feeds bytes and reports a synthetic exit, so `deliverOutputForTesting` stops being a back door and becomes the normal way to drive a host. Then the tests split cleanly by what they actually prove -- lifecycle, descriptor ownership, teardown, and exit convergence keep the real fork and the `.serialized` trait; frame/damage/wheel/pointer/search/OSC cases run against the in-memory transport, unserialized, and the ones that are purely engine policy move to TerminalCore where their siblings already live. Serialization then applies only to the fd-census test that documents needing it.

**Cheaper fallback.** Drop `.serialized` from the suite and instead mark only the descriptor-census and teardown-bound tests serialized via a nested suite, and delete the PTY-level duplicates of policy already covered in TerminalInteractionPolicyTests and TerminalSearchTests. This recovers most of the wall clock without touching production code.

**Risk.** An injectable transport adds a production seam to an actor that is deliberately tight about ownership; done carelessly it could let a test-only path diverge from the real read loop. Mitigate by keeping the real transport the default and keeping every teardown/fd test on it. De-serializing risks flakiness in tests that implicitly assumed exclusive machine access -- those should be identified by what they assert, not by trial and error.

### S21. The Command interpreter, the app's highest-churn logic, has no automated coverage

`tests` &middot; testing &middot; impact 4, confidence 4 &middot; effort large

`app/AppRuntime.swift#perform`, `app/AppRuntime.swift#init`, `lib/DanTermCore/Sources/DanTermCore/Command.swift`, `app-tests/`, `docs/design/2026-08-06-ui-harness-whole-module-substitution.md`

**Problem.** The Elm loop is `update -> [Command] -> AppRuntime.perform(command)`. The pure half is tested to the tune of ~27k lines. The effectful half -- a 35-arm `private func perform(_ command: Command)` interpreting all 31 `Command` cases -- has zero tests, and cannot have any, because `AppRuntime.init` reads config from disk, installs a process-global NSEvent monitor, and binds the live IPC control socket. app/AppRuntime.swift is the second-most-churned file in the repo over the last four months (109 commits, behind only TerminalCore/Terminal.swift at 153), while all of app-tests/ is 700 lines and received 19 commits in the same window. Every regression in that file is found by hand.

**Evidence.** `private func perform(_ command: Command)` at app/AppRuntime.swift:865; 35 `case` arms in its switch against 31 `case` declarations in Command.swift. `git log --oneline --since="4 months ago" -- app/AppRuntime.swift | wc -l` returns 109; the same query over app-tests/ returns 19. app-tests/ totals 935 lines across 12 files, none of which constructs an AppRuntime. The 2026-08-06 ADR independently documents why one cannot be constructed in a test ("reads the user's config file from disk, installs a process-global NSEvent monitor, constructs a SwiftTerminalBackend, and binds the live IPC control socket").

**Ideal fix.** Split AppRuntime into the interpreter and its resources. Give the runtime a `Ports` value holding the handful of effect capabilities perform() actually reaches for -- session creation, IPC write, checkpoint write, clipboard, notification, timer scheduling -- and construct it from the caller rather than in `init`. `perform` then becomes a function of (model, command, ports) that a test can drive with recording ports, and the 31 cases become 31 assertable command-to-effect mappings. This is the same production change the UI-harness ADR already named as "the way out", so it retires the hand-maintained test-ui.sh file list and the `#if DANTERM_UI_TEST` substitution seams at the same time -- one refactor closes two holes.

**Cheaper fallback.** Extract just the pure decision parts of the fattest perform arms (createSession argument assembly, checkpoint scheduling policy, tape-follow subscription bookkeeping) into free functions in app/ or DanTermCore and unit-test those, leaving the AppKit dispatch untested. This buys coverage of the logic without touching AppRuntime's lifetime, but leaves the command-to-effect mapping itself unpinned.

**Risk.** Threading ports through a 2188-line class touches every effect site, and getting AppKit object lifetimes wrong here is exactly the hazard docs/design/2026-06-09-appkit-lifetime-safety.md warns about. The mitigation is that the port protocols carry no AppKit types, so ownership stays where it is today.

### S22. Collapse the parallel `sessions` and `paneHosts` maps into one pane map

`app-runtime` &middot; duplication &middot; impact 3, confidence 5 &middot; effort medium

`app/AppRuntime.swift#sessions`, `app/AppRuntime.swift#paneHosts`, `app/AppRuntime.swift#paneHost`, `app/AppRuntime.swift#installTerminalSession`, `app/AppRuntime.swift#tearDownSession`, `app/PaneHost.swift#PaneHost`

**Problem.** The same session object lives in two dictionaries keyed by the same `PaneId`: `sessions[paneId]` and `paneHosts[paneId].session`. Every install, teardown, restore-commit and session-existence pass has to touch both and keep them in step by hand, and `reconcileSessionExistence` picks one of them (`Set(sessions.keys)`) as the authority. `paneHost(for:)` papers over the split with a lazy back-fill that constructs a host whenever `sessions` has a pane that `paneHosts` does not - a shim whose only real client is test code that assigns into `runtime.sessions` directly.

**Evidence.** `installTerminalSession` writes both maps; `tearDownSession` and the inline loop in `tearDownCurrentSession` remove from both; `commitRestoreSession` rebuilds `paneHosts` from `staged.sessions`; `paneHost(for:)`'s own comment says it exists "lazily covering test-injected sessions", and `tests-ui/SplitContainerViewTests.swift` and `tests-ui/AppPresentationLifecycleTests.swift` assign `runtime.sessions[paneId] = ...` with no host.

**Ideal fix.** Keep one `panes: [PaneId: PaneHost]` map. `PaneHost` already owns the session, so add a `session(for:)` accessor and let `reconcileSessionExistence` diff `panes.keys` against `model.allPaneIds`. Give tests a `func installTestSession(_:for:)` helper that builds a real host, and delete the lazy back-fill in `paneHost(for:)`.

**Cheaper fallback.** None -- the ideal fix is the only one on the table.

**Risk.** Low; mechanical. Every current `sessions[paneId]?.x` call site becomes `panes[paneId]?.session.x`, and the UI tests need the new install helper.

### S23. Delete the divergent inline copy of tearDownSession in tearDownCurrentSession

`app-runtime` &middot; duplication &middot; impact 3, confidence 5 &middot; effort small

`app/AppRuntime.swift#tearDownCurrentSession`, `app/AppRuntime.swift#tearDownSession`

**Problem.** `tearDownCurrentSession` open-codes `tearDownSession`'s body instead of calling it, and the copy has already lost a step: it does not cancel the pane's search debouncer or its scheduling token. So a restore or import performed while a search debounce is pending leaves the `Debouncer` and its armed `.debouncer` token alive for the process lifetime, and the pending closure still resolves `sessions[paneId]` - which, because restore and import reuse pane ids, can now be a brand-new session that receives a search needle from the discarded one.

**Evidence.** `tearDownSession` runs `endPaneTapeFollowers`, `cleanupReplayFile`, `schedulingLifecycle.cancel(searchDebouncerTokens.removeValue(forKey:))`, `searchDebouncers.removeValue(forKey:)`, `paneHosts.removeValue`, then `cancelSessionSubscriptions` + `session.tearDown()`. The loop in `tearDownCurrentSession` (`for paneId in Array(sessions.keys)`) repeats every one of those except the two debouncer lines. The `.sendSearchNeedle` arm in `perform` is what arms them, and its closure body is `self.sessions[paneId]?.setSearchNeedle(needle)`; the comment on `paneVisibility` in the same file records that "restore/import can reuse pane IDs for fresh sessions".

**Ideal fix.** Have `tearDownCurrentSession` call `tearDownSession(paneId)` for each live pane. One teardown body means a step added to per-pane teardown cannot be missed by the whole-session path.

**Cheaper fallback.** Add the two missing debouncer lines to the inline loop. Restores correctness, keeps the copy that will drift again.

**Risk.** Low. `tearDownSession` also mutates `sessions`, so iterate over a snapshot of the keys (the existing loop already does).

### S24. Give scheduled work one handle instead of a handle plus a shadow token

`app-runtime` &middot; accidental-complexity &middot; impact 3, confidence 5 &middot; effort medium

`app/AppRuntime.swift#scheduleLightCheckpointIfNeeded`, `app/AppRuntime.swift#scheduleCoalescedReconcile`, `app/AppRuntime.swift#applyRecoveryAction`, `app/AppRuntime.swift#shutdown`, `app/AppRuntime.swift#perform`, `app/AppRuntimeSchedulingLifecycle.swift#AppRuntimeSchedulingLifecycle`

**Problem.** `AppRuntimeSchedulingLifecycle` already stores, per token, the closure that retires an owner - yet AppRuntime keeps a second field beside every token holding the same owner: three `DispatchSourceTimer` + token pairs, `switcherEventMonitor` + token, and per-pane debouncer + token maps. Two fields per owner means the cancel triplet `cancel(token); token = nil; handle = nil` is written out at roughly ten sites, and the three timers repeat a near-identical twenty-line arm-schedule-guard-handler-resume block. It also breeds pure dead storage and a redundant teardown: `switcherEventMonitor` is assigned and nil'd but never read (the token's cancel closure owns `NSEvent.removeMonitor`), and the `.terminate` arm of `perform` re-implements a subset of `shutdown()` - pane-tape removal, light-timer cancel, enriched-timer cancel - purely to clear those shadow fields before `NSApp.terminate` reaches `applicationWillTerminate`, which calls `prepareRecoveryForApplicationExit` and `shutdown()` and does it all again.

**Evidence.** Grepped `switcherEventMonitor`: assignments at declaration, install and shutdown, no reads. Compared `perform`'s `.terminate` arm against `shutdown()`: both call `paneTapeFollowSubscriptions.removeAll()` + `removePaneTapeFollowNotice`, both clear `paneTapeFollowConnections` / tokens / notice registrations, and the enriched-timer cancel is repeated a third time in `prepareRecoveryForApplicationExit`. `scheduleLightCheckpointIfNeeded`, `scheduleCoalescedReconcile` and `applyRecoveryAction(.schedule)` are three copies of the same body differing only in deadline and event action. Only two of the three timer handles are ever read as a predicate (`lightCheckpointTimer == nil`, `coalescedReconcileTimer != nil`); `enrichedCheckpointTimer` is write-only apart from a `?.cancel()` its own token already performs.

**Ideal fix.** Introduce a `ScheduledTimer` value owned by the lifecycle: `arm(category:after:handler:)` returns it, it exposes `isArmed` and `cancel()`, and it holds the DispatchSource privately so there is no second field to nil. AppRuntime then has three `ScheduledTimer?` fields and no tokens, `shutdown()` shrinks to `schedulingLifecycle.shutdown()`, `switcherEventMonitor` disappears, and `.terminate` keeps only the work `shutdown()` genuinely does not do (cancel the coalesced reconcile, delete replay files).

**Cheaper fallback.** Delete the unread `switcherEventMonitor` field and strip the `.terminate` arm down to the two unique steps, leaving the handle/token pairs as they are.

**Risk.** Low, but the enriched-checkpoint timer's rearm-from-handler path (`applyRecoveryAction` calling itself) must keep cancelling the previous timer before arming the next, which the current token dance does explicitly.

### S25. Compute a tab's chrome once instead of four times per sidebar row

`core-model` &middot; duplication &middot; impact 3, confidence 5 &middot; effort small

`lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#tabChrome`, `lib/DanTermCore/Sources/DanTermCore/Projections.swift#desiredSidebar`, `lib/DanTermCore/Sources/DanTermCore/Projections.swift#desiredWindowChrome`, `lib/DanTermCore/Sources/DanTermCore/Projections.swift#desiredThemeBrowser`

**Problem.** `tabChrome` is the single derivation of a tab's title and subtitle, but it is exposed through three thin wrappers (`tabTitle`, `tabDisplayTitle`, `tabSubtitle`) that each re-run the whole derivation, and consumers call several of them on the same tab. The result is that the row projection walks each tab's tree four times to produce one row, and the window projection walks the selected tab's tree three times to produce two strings. Separately, two focused-pane lookups still search the whole window for a pane that can only be in one tab -- the exact shape commit cf3c4b00 removed from tabChrome.

**Evidence.** Projections.swift#desiredSidebar builds each row from `tabDisplayTitle(tab)` (-> tabTitle -> tabChrome -> paneInNode walk), `tabSubtitle(tab)` (-> tabChrome -> second walk), `tabChipKind(tab)` (third `paneInNode` walk, ModelOperations.swift:614), and `tabPaneChips(tab, ...)` (`panesInNode`, fourth walk). Projections.swift#windowTitle calls `tabDisplayTitle` and `tabSubtitle`, and #desiredWindowChrome then calls `tabDisplayTitle` again for `contentTitle` -- three walks. ModelOperations.swift#focusedPane (line 543), #currentCwd (line 551), and Projections.swift#desiredThemeBrowser (line 28) resolve the focused pane with `model.pane(...)`, which iterates every group and every tab, even though tabChrome's own doc comment (lines 578-581) explains why that is wrong for this question.

**Ideal fix.** Give `TabModel` one computed `chrome` value (`struct TabChrome { title, displayTitle, subtitle, chipKind, paneChips }`) resolved from a single `panesInNode` walk that also yields the focused pane, and have `desiredSidebar` and `desiredWindowChrome` each build one per tab and read fields off it. Delete `tabTitle`/`tabSubtitle`/`tabDisplayTitle` as separate entry points so no caller can re-derive. Add `TabModel.focusedPane` (resolved inside the tab's own tree) and route `focusedPane(in:)`, `currentCwd`, and `desiredThemeBrowser` through it, removing the last window-wide searches for a tab-local fact.

**Cheaper fallback.** Leave the wrappers but have `desiredSidebar` and `desiredWindowChrome` call `tabChrome(tab)` once and destructure it, and switch the three `model.pane(tab.focusedPaneId)` sites to `paneInNode(tab.rootNode, id: tab.focusedPaneId)`.

**Risk.** low

### S26. Derive preferences-draft sync instead of enumerating the six fields in five places

`core-reducer` &middot; duplication &middot; impact 3, confidence 5 &middot; effort medium

`lib/DanTermCore/Sources/DanTermCore/Update.swift#update`, `lib/DanTermCore/Sources/DanTermCore/Model.swift#PreferencesDraft`

**Problem.** The six preference fields (alertClearMode, remoteTheme, theme, fontSize, fontFamily, copyOnSelect) are listed by name in five separate places in the reducer: the twelve prefSet*/prefReset* cases, the `preferencesOpened` draft constructor, the `configLoaded` draft re-sync, and the `prefSave` commit. Adding a seventh preference means editing all five, and forgetting the `configLoaded` list produces a draft that silently diverges from the config it is supposed to mirror -- a bug with no compiler signal. The twelve setter/resetter cases are also 12 copies of the same three-line `guard model.preferencesDraft != nil ... model.preferencesDraft!.X = ...` body, over 11% of the Msg surface spent on one concept.

**Evidence.** Read Update.swift:559-572 (`configLoaded` re-assigning all six draft fields one by one), 581-601 (`preferencesOpened` constructing the same six), 603-661 (twelve near-identical prefSet/prefReset arms), and 663-697 (`prefSave` copying the same six back into the config). Read Model.swift:175-182 for `PreferencesDraft`. The reset arms are each literally `draft.X = model.config.X` with fontSize's `configFontSizeText` mapping as the only variation.

**Ideal fix.** Give `PreferencesDraft` an `init(from: DanTermConfig)` and a `mutating func reset(_ field: PreferenceField, to: DanTermConfig)`, then collapse the twelve Msg cases to `prefSet(PreferenceEdit)` and `prefReset(PreferenceField)`. `preferencesOpened` and `configLoaded` both become one `PreferencesDraft(from: newConfig)` call, and `prefSave` becomes the one place that maps draft to config. The six-field list then exists exactly twice (the draft's fields and the commit), and the compiler catches a missing field in a new enum case.

**Cheaper fallback.** Add only `PreferencesDraft(from:)` / `mutating func sync(to config:)` so `preferencesOpened` and `configLoaded` share one implementation, leaving the twelve setter cases as they are. Removes the highest-risk duplication (silent draft/config divergence) without touching the Msg surface.

**Risk.** Low. Behavior is fully pinned by UpdatePreferencesTests, ConfigCopyOnSelectTests, and PreferencesFontFamilyTests; the fontSize String-vs-Double asymmetry is the only field needing per-field handling and it is already isolated in `configFontSizeText`.

### S27. Make --socket work for `doctor` instead of intercepting local commands before the flag parser

`ipc-cli` &middot; structural &middot; impact 3, confidence 5 &middot; effort small

`cli/main.swift#DanTermCLI.main`, `cli/main.swift#DanTermCLI.gatherDoctorPermissions`, `lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift#parseCLIInvocation`, `integrations/danterm/SKILL.md`

**Problem.** `main()` checks `rawArgs.first == "skill"` / `== "doctor"` before calling `parseCLIInvocation`, which is the only place `--socket` is consumed. So `danterm --socket /path/to/slot.sock doctor` fails with `unknown command: doctor`, and plain `danterm doctor` resolves its socket with `selectControlSocketPath(explicit: nil, ...)`. An agent driving an isolated slot instance -- which SKILL.md tells it to do by passing `--socket` before every command -- cannot ask that instance about its permissions at all: the call either errors out or silently probes the user's slot-zero app or reports the app-owned rows as SKIP.

**Evidence.** cli/main.swift lines 109-121: help/skill/doctor are matched on `rawArgs.first` and returned before `parseCLIInvocation(rawArgs)`; CLIParser.swift lines 59-72 strip `--socket` only inside `parseCLIInvocation`, and `parseCLI` has no `doctor` case, so it falls to `throw CLIParseError("unknown command: \(head)")`. `gatherDoctorPermissions` (line 231) hardcodes `explicit: nil`. SKILL.md line 24 states the rule as intended behavior, and lines 80-82 tell agents to pass `--socket` before every command.

**Ideal fix.** Parse global options once, unconditionally: have `parseCLIInvocation` return the socket override plus a command that can be either a wire request or a local command (`help`, `skill`, `doctor`), and let `main()` switch on that. Local commands then get the parsed socket for free -- `doctor` passes it to `gatherDoctorPermissions` -- and there is no second, order-sensitive argument surface in `main()` that the parser and its tests do not cover.

**Cheaper fallback.** Hoist the leading `--socket <path>` strip in `main()` above the skill/doctor interception and thread the value into `gatherDoctorPermissions`. Fixes the symptom; leaves two argument parsers.

**Risk.** low -- `skill` and `help` would start accepting and ignoring `--socket`, which is the same tolerant behavior they have for no flags today.

### S28. Replace the CLI's two hand-rolled per-byte line readers with the shared framer

`ipc-cli` &middot; duplication &middot; impact 3, confidence 5 &middot; effort small

`cli/main.swift#DanTermCLI.readLine`, `cli/PaneTapeFollowStream.swift#readPaneTapeFollowLine`, `lib/DanTermProtocol/Sources/DanTermProtocol/IpcLineFramer.swift#IpcLineFramer`, `cli/main.swift#DanTermCLI.writeJSON`

**Problem.** The CLI contains two near-identical newline readers that each issue one `read(2)` per byte, with their own copies of the EINTR retry and the 16 MiB cap. DanTermProtocol already owns that contract in `IpcLineFramer` (same 16 MiB constant), and the server side uses it. A `pane tape` snapshot or `ls` on a busy app is a multi-megabyte single line, so the client pays a syscall per byte for the entire reply. The same file also re-implements `encodeIpcLine` in `writeJSON` -- but with a plain `JSONEncoder()`, so requests and responses do not even agree on slash escaping.

**Evidence.** cli/main.swift lines 353-378 and cli/PaneTapeFollowStream.swift lines 72-94 are the two readers: both call `Darwin.read(fd, buffer.baseAddress, 1)` in a loop and both bound at `16 * 1024 * 1024`, the same value as `IpcLineFramer.maxLineBytes`. IpcConnection.swift line 32 reads into a 4096-byte buffer and feeds `IpcLineFramer`. Envelope.swift `encodeIpcLine` sets `.withoutEscapingSlashes`; cli/main.swift `writeJSON` does not. `request` and `requestPaneTapeFollow` also both take an `environment` parameter neither body uses (lines 159, 185), and the usage-text comment at line 21 still claims `request(...)` uses the `EnvVars` constants.

**Ideal fix.** Put one buffered line reader beside the framer -- a small `IpcLineReader(fd:)` in DanTermProtocol that owns a chunk buffer and drives `IpcLineFramer`, returning `.line`/`.oversized`/EOF -- and have both CLI call sites use it. Both CLI writers go through `encodeIpcLine`. Delete the dead `environment` parameters and correct the stale comment. Framing then exists once for both directions and both processes, and the oversize limit cannot drift between three copies.

**Cheaper fallback.** Keep both readers but give them a 4-64 KiB buffer; that removes the syscall storm without removing the duplication or the encoder mismatch.

**Risk.** low -- the wire format is unchanged; the follow-stream reader has direct coverage in cli-tests/PaneTapeFollowStreamTests.swift.

### S29. Record transitions once: fold TerminalPTYAppliedTransition into the flight recorder

`pty` &middot; duplication &middot; impact 3, confidence 5 &middot; effort medium

`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#TerminalPTYAppliedTransition`, `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#applyOutput`, `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift#neutralEvents`, `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalFlightRecorder.swift#record`

**Problem.** The host runs two independent recorders over the same transition stream, in two different vocabularies. `TerminalPTYAppliedTransition` is case-for-case isomorphic to `NeutralTerminalRecordingEvent` (feed / input / paste / focus / mouse / resize, with three scroll cases against one `.viewport`), and the controller carries a 17-line hand-written mapping between them. Meanwhile the flight recorder already stores `NeutralTerminalRecordingEvent` with retention accounting, cursors, and follow notices -- but only ever receives `.feed` and `.resize`, so the production tape cannot show what the user typed, pasted, or clicked, which is precisely what a reproduction tape is for. On top of that, `applyOutput` writes every output chunk into three places at once in a characterization build: `capturedOutput`, `appliedTransitions` as `.feed`, and the DEBUG `testOutputWindow`.

**Evidence.** `NeutralTerminalRecordingEvent` (NeutralTerminalRecording.swift:216-225) lists feed, input, paste, focus, mouse, resize, viewport, checkpoint; `TerminalPTYAppliedTransition` lists feed, input, paste, focus, mouse, resize, scrollByRows, scrollToTopRow, scrollToBottom. `TerminalPaneSessionController#neutralEvents` maps one onto the other case by case. In the host, `flightTape?.record` appears at exactly two sites (`applyOutput` -> `.feed`, `applyResize` -> `.resize`), while `if captureTransitions { appliedTransitions.append(...) }` appears at seven sites covering the full set. `applyOutput` contains all three retentions in one body.

**Ideal fix.** Delete `TerminalPTYAppliedTransition` and record `NeutralTerminalRecordingEvent` directly into `TerminalFlightRecorder` from all seven sites, with `captureTransitions` becoming an unbounded recorder configuration rather than a second mechanism. The fence's `.consumptionState` / `.diagnosticState` then hand back a `NeutralTerminalRecording` the controller can use as-is, deleting `neutralEvents`, `neutralMouseEvent`'s transition arm, and the `capturedOutput` array (which is a strict projection of the `.feed` events the recorder already holds). Production gains input/paste/mouse/scroll in the tape as a side effect.

**Cheaper fallback.** Keep both enums but move `neutralEvents` into the host next to the capture sites, so the mapping lives beside the thing it mirrors and drift is visible in one file.

**Risk.** `capturedRecording`/`diagnosticCapture` feed characterization comparisons; the recording's event order and the `initial` dimensions must stay byte-identical or stored characterization fixtures will need regeneration.

### S30. Replace the fence operation/output enum pair with typed fence methods

`pty` &middot; clarity &middot; impact 3, confidence 5 &middot; effort small

`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#TerminalPTYProductionFenceOperation`, `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#performProductionFence`, `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift#performAccountedFence`, `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift#synchronizeState`

**Problem.** Every controller fence erases its result into `TerminalPTYProductionFenceOutput` and then immediately un-erases it with `guard case ... else { preconditionFailure("... returned the wrong payload") }`. There are seven such sites in the controller, all crashing on a mismatch the type system could have rejected. The erasure buys nothing: the generic `fence(countsAsProduction:)` is already generic over its return value, so each operation could return its own type and still go through the one counted path. Three of the seven sites are additionally the same three-line block verbatim (checkpoint frame-state fence, unwrap, `consume(frameState:result:nil,transitions:nil)`).

**Evidence.** `performProductionFence` switches on the operation only to re-wrap each branch's value in a matching output case, while `fence<Value: Sendable>` beneath it is already generic. In TerminalPaneSession.swift the unwrap-or-crash appears at lines 484, 592, 721, 741, 766, 821, and 975; the bodies of `setRenderingAvailable`, `synchronizeState`, and `readSelectedTextSynchronizing` are identical apart from their tails.

**Ideal fix.** Drop both enums. Give the host `fencedProductionFrameState()`, `fencedProductionConsumptionState()`, `fencedProductionDiagnosticState()`, `beginCloseAndSnapshot()`, and `installUpdateHandler(_:)`, each returning its own type paired with `entryCount` through the shared counted `fence`. In the controller, `performAccountedFence` becomes generic over the payload (`fenced<T>(kind:_ body:) -> T`), and the three checkpoint sites collapse into one `consumeCheckpoint()`. Result: zero `preconditionFailure`s and one place that knows what a checkpoint fence does.

**Cheaper fallback.** Keep the enums but add small unwrapping helpers (`frameState(from:)`, `consumption(from:)`) so the crash text and the `guard case` exist once each instead of seven times.

**Risk.** low

### S31. Give the record side tables one owner that maintains its own byte charge

`scrollback` &middot; accidental-complexity &middot; impact 3, confidence 5 &middot; effort medium

`lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#LogicalLineStore.refreshMetadataCharge`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#LogicalLineStore.dropHeadRecord`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#LogicalLineStore.dropTailRecord`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#LogicalLineStore.cutTail`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#LogicalLineStore.setTrailingFillOnTail`

**Problem.** Three pieces of state -- `spillsBySequence`, `fillStylesBySequence`, and the `spillBytes` accumulator -- plus the `metadataBytes` cache are maintained by hand at roughly fifteen scattered sites, and every record-removing path must remember to prune both dictionaries and then call `refreshMetadataCharge()`. The sites have already drifted into three different emptiness guards for the same question (`spillBytes > 0` in `dropHeadRecord`, `spillsBySequence.isEmpty == false` in `dropTailRecord`, `record.hasTrailingFill` for the fill table, `sideTablesGrew || spills.count != spillsBefore` in the arena writer). A missed prune leaks a dictionary entry keyed to a sequence that will never be read again; a missed refresh loosens the one bound `31/I2` rests on, and today only an `assert` inside `census` -- which the write path never reads -- catches it.

**Evidence.** Grepped every occurrence of `spillsBySequence`, `fillStylesBySequence`, `spillBytes`, and `refreshMetadataCharge()` in the file: mutation sites at lines 881-888, 958-972, 1112-1120, 1166-1170, 1255-1259, 1288-1292/1311, 1391, 2696-2770, 3066/3079, with `refreshMetadataCharge` called eleven times and conditionally in two of them. `census` (line ~635) carries the drift assert, and `chargedBytes` -- the value the write path actually tests -- reads the cached `metadataBytes` without it.

**Ideal fix.** Introduce one `RecordSideTables` value type inside the store that owns both dictionaries, the payload byte accumulator, and its own cached charge, exposing `remove(sequence:)`, `removeAll()`, `setFill(_:for:)`, `appendSpill(...)` and `charge`. The type recomputes its hash-table charge only when a dictionary's capacity changes, so `chargedBytes` becomes `bytesInUse + indexChargeBytes + sideTables.charge` with no `metadataBytes` field, no `refreshMetadataCharge()` calls, and no drift assert -- the charge cannot be stale because nothing outside the type can move it. Each record-removal path becomes a single `sideTables.remove(sequence:)`.

**Cheaper fallback.** Keep the current fields but add one private `forgetSideTables(sequence:)` that prunes both dictionaries and refreshes the charge, and call it from `dropHeadRecord`, `dropTailRecord` and `resetToEmptyArena`, so the divergent guards collapse to one.

**Risk.** The charge feeds the eviction loop, so an off-by-one in the new incremental charge changes retained depth. Mitigated by the existing recount-versus-maintained comparison, which should move into the new type's own invariant check rather than being deleted.

### S32. Collapse the seven copy-pasted task-local counters and move them out of the store file

`scrollback` &middot; duplication &middot; impact 3, confidence 5 &middot; effort small

`lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#LocateCounter`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#ProjectionRowCounter`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#WholeProjectionCounter`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#SearchDistanceWorkCounter`, `lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift#RecordCellMaterializationCounter`

**Problem.** Lines 31-245 of the store's file are seven enums that are character-for-character the same design -- a `final class Tally: @unchecked Sendable` with one Int field, an `@TaskLocal static var active`, an `@inline(__always) static func record`, and a `static func measure` -- differing only in the field's name and whether `record` takes an amount. That is 215 lines of boilerplate before the file's actual subject starts, and adding an eighth instrument means pasting the pattern again. They also are not the store's: `WholeProjectionCounter` and `SearchDistanceWorkCounter` are recorded from Terminal.swift, and the file header explicitly says what belongs here is the arena, its operations, the index, the side tables and the fold.

**Evidence.** Read all seven declarations at lines 39-245 and diffed them by eye; the only variation is `count` / `units` / `cells` / `rows` and the `record` arity. Grepped every call site: all recording happens in LogicalLineStore.swift and Terminal.swift (lines 3609 and 4615), and all measuring happens in test targets including TerminalRenderPlanningTests and lib/TerminalPTY's session tests, so nothing about them is store-local.

**Ideal fix.** One `TerminalInstruments.swift` holding a single `enum Instrument` case list and one task-local tally that carries a value per instrument, with `Instruments.record(_:_ n: Int = 1)` and `Instruments.measure(_:_ body:) -> Int`. Seven types and seven task-locals become one of each, an eighth instrument is one enum case, and the store's file starts at the store.

**Cheaper fallback.** Leave the seven types as they are but move them verbatim into their own file, so the file-boundary claim in the store's header becomes true even if the duplication stays.

**Risk.** A single shared tally changes nesting semantics: today two different counters can be measured in nested scopes independently. `measure` must therefore reuse an already-active tally by snapshotting the field it returns rather than installing a fresh tally, or a nested measure will silently zero its parent. Test call sites that nest (TerminalSearchTests measures locates around a projection measure) are the ones to check.

### S33. Give the sidebar reconcile pipeline one implementation the UI tests drive

`sidebar` &middot; duplication &middot; impact 3, confidence 5 &middot; effort medium

`app/Reconcile.swift#reconcileSidebar`, `tests-ui/SidebarProjectionRowTests.swift#applyProjectionRowTransition`, `tests-ui/SidebarRenameRecycleTests.swift#applyRenameRecycleTransitionResult`, `tests-ui/SidebarSelectionCacheTests.swift#applySidebarTransitionResult`

**Problem.** Three UI test files each re-implement reconcileSidebar's five-step pipeline -- desiredSidebar, computeSidebarRowOps, guardSidebarRenameOps, clear the sidecar, applySidebarOps, advanceSidebarCache -- as their own private helper, and each carries its own byte-identical materialize-rows and row-lookup helpers. The pipeline's step order and its cache-retention wiring are exactly what the recent rework changed, and they are the part most likely to change again. If production's ordering changes, all three copies keep testing the old pipeline and stay green.

**Evidence.** app/Reconcile.swift#reconcileSidebar (lines 247-271) is mirrored by SidebarProjectionRowTests.swift#applyProjectionRowTransition, SidebarRenameRecycleTests.swift#applyRenameRecycleTransitionResult (whose doc comment says outright "Mirror reconcileSidebar's production pipeline"), and SidebarSelectionCacheTests.swift#applySidebarTransitionResult -- which notably omits the guard step entirely, so the three copies already differ. materializeProjectionRows, materializeRenameRecycleRows, and materializeSidebarRows are three copies of the same four-line loop; renameRecycleRow and sidebarRow are two copies of the same row lookup. SidebarContextMenuTests adds a fourth partial copy of the initial apply.

**Ideal fix.** Extract the pipeline into one value the production reconciler and the tests both call -- e.g. a `SidebarReconcileDriver` holding the projection cache and reading the rename sidecar, with a single `apply(model:tally:to sidebarView:)`. reconcileSidebar shrinks to constructing/holding the driver, and each test does `driver.apply(model:to:)` and then asserts on real rows. The test helpers reduce to shared materialize/lookup utilities in one file.

**Cheaper fallback.** Move the three transition helpers plus materialize and row-lookup into one shared tests-ui helper file that calls the same sequence, so there is one test-side copy instead of three (still a copy of production, but a single one that is obvious when it drifts).

**Risk.** Low. The driver has to keep the exact ordering (guard before apply, sidecar cleared before advance) or the rename-guard tests will legitimately fail.

### S34. Give anchored ranges one registry instead of six hand-written enumerations

`terminal-core` &middot; duplication &middot; impact 3, confidence 5 &middot; effort medium

`lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.capturedAnchorAddresses`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.restateAnchors`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.handleEviction`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.invalidateInspection`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.clearInspection`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.setHoveredLink`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.setArmedLink`

**Problem.** Five anchored positions -- selection, hovered link, armed link, search position, browsing viewport top -- hold absolute stream coordinates that every content-moving event has to fix up. Each of the six lifecycle passes over them is written by hand as its own list, and each list is a different subset with a different policy. Missing one entry produces a stale anchor pointing at evicted or refolded rows, which is the whole class of bug the pinned/epoch machinery exists to prevent, but nothing checks that the six lists agree on membership.

**Evidence.** `capturedAnchorAddresses` and `restateAnchors` enumerate eight `WidthChangeAnchor` slots each; `handleEviction(of:)` writes three separate blocks (selection clamps to first retained, hovered and armed each drop if they start before it); `invalidateInspection(inAbsoluteRows:)` writes two more blocks for hovered and armed with a comment explaining why selection and search are excluded; `clearInspection()` names four plus `viewportState`; `refreshHasContentInspectionState()` names three; `clampSelectionToRetainedStream()` names one. Separately, `setHoveredLink` and `setArmedLink` are near-copies -- same `isActivatableWebURI` and byte-cost guard, same `admittedHyperlinkTargets` admission, same `textPositionPrecedes` ordering, same `normalizedSelectionBoundary` pair -- differing only in the destination slot and whether damage is recorded, and `canAdmitArmedLink` restates the guard prefix a third time.

**Ideal fix.** Model the interaction links as one `InteractionLinkState?` array or dictionary keyed by an `InteractionLinkSlot` (the enum already exists for admission accounting) with a single `setInteractionLink(_:slot:)` writer, and give every anchored range one registry entry declaring its policies: does an overwrite of its rows retire it, does eviction clamp it or drop it, is it restated by width reflow. Then each of the six passes iterates the registry once instead of restating membership, and adding a seventh anchored range is one entry rather than six edits.

**Cheaper fallback.** Collapse just the hover/arm pair -- one storage keyed by slot, one setter, and one loop in each of `handleEviction`, `invalidateInspection(inAbsoluteRows:)`, `clearInspection`, and `refreshHasContentInspectionState`. That removes the copy-pasted half without disturbing selection, search, or the reflow anchor register.

**Risk.** Selection and hover damage accounting is subtle: `setHoveredLink` records damage and `setArmedLink` deliberately does not, and the hover revision counter must keep advancing on every write. A unified setter has to preserve both, and the reflow anchor register's explicit `WidthChangeAnchor` cases are load-bearing for capture/restate symmetry, so they should become registry-derived rather than disappear.

### S35. Stop re-implementing grid and cell geometry in the UI-test shim

`terminal-views` &middot; testing &middot; impact 3, confidence 5 &middot; effort medium

`tests-ui/SwiftTerminalSessionViewTestShim.swift#terminalGridDimensions`, `tests-ui/SwiftTerminalSessionViewTestShim.swift#terminalCell`, `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalGridSizing.swift#terminalGridDimensions`, `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift#terminalCell`

**Problem.** The `DANTERM_UI_TEST` build compiles the real `SwiftTerminalSessionView` against a 611-line shim that re-declares two pure geometry functions rather than importing them. The copies are not equivalent: the shim's `terminalGridDimensions` omits the production `max(2, columns)` / `max(1, rows)` floors and all finiteness/overflow guards, and the shim's `terminalCell` omits the finiteness and Int-range guards. Every UI test that asserts a reported grid size, or drives a pointer into a very narrow pane, is therefore pinning behavior the shipped app does not have -- and a change to the real floors would not fail a single UI test.

**Evidence.** Shim `terminalGridDimensions` (SwiftTerminalSessionViewTestShim.swift:293-305) returns `Int(size.width / cellSize.width)` with no clamp; production (TerminalGridSizing.swift:19-42) returns `max(2, Int(columns))` and `max(1, Int(rows))` after finiteness and `< Double(Int.max)` guards. Shim `terminalCell` (line 395) has no `point.x.isFinite` guard and no Int-range guard, unlike TerminalInteractionPolicy.swift's `terminalCell`. test-ui.sh is the only place `-DDANTERM_UI_TEST` is set (confirmed by grepping the tree), and the shim's header says it exists "to compile the real Swift pane view".

**Ideal fix.** These two functions are pure, dependency-free, and already live in modules the UI-test target could link (`TerminalGridSizing.swift` imports only PaneProcessLifecycle; `TerminalInteractionPolicy.swift` imports nothing). Compile those two source files into the UI-test target -- the way `app/DanTermCore` is a tracked symlink -- and delete the shim copies along with the shim's `TerminalPoint`/`TerminalCellSize`/`TerminalRenderExecutionSize`/`TerminalViewportCell` stand-ins. The shim keeps standing in only for what actually needs the engine (the session controller, frame plans, IOSurface stores).

**Cheaper fallback.** Leave the shim but make the two copies byte-identical to production and add a comment binding them, the way `spriteClassificationMinimumScalar` is bound to the sprite families by `SpriteRoutingGuardTests`.

**Risk.** Low-to-medium: pulling real sources into the UI-test build may drag transitive imports (PaneProcessLifecycle), and adding the production floors will change the grid a few existing UI tests observe for small panes -- those expectations are the ones that were wrong.

### S36. Retire the whole-AppModel golden snapshot; it ratchets on behavior-preserving refactors

`tests` &middot; testing &middot; impact 3, confidence 5 &middot; effort small

`lib/DanTermCore/Tests/DanTermCoreTests/GoldenMasterTests.swift#deterministicEnvProducesDeterministicAppModelAcrossUpdatePaths`, `lib/DanTermCore/Tests/DanTermCoreTests/__Snapshots__/GoldenMasterTests/deterministicEnvProducesDeterministicAppModelAcrossUpdatePaths.1.txt`, `lib/DanTermCore/Tests/DanTermCoreTests/DeterminismSeamTests.swift`

**Problem.** GoldenMasterTests drives a fixed Msg sequence under a deterministic CoreEnv and then `assertSnapshot(of: model, as: .customDump)` on the entire AppModel. Its stated purpose is to pin the CoreEnv seam, but what it actually pins is the field-by-field shape of AppModel, PaneModel, and SessionModel. Any pure data-model move breaks it and the fix is always to re-record, so the test never fails for the reason it exists and trains the reader to accept a re-record as routine. Meanwhile the property it claims -- ids, time, and home come from the injected env -- is asserted directly and readably next door.

**Evidence.** The snapshot file has been rewritten by five commits in a row that are labelled as refactors: 3d8f1226 "refactor(semantics): remove pane semantic mirrors", 01a3e22c "refactor(core): nest terminal session identity in panes", 2a040cc1 "refactor(core)!: reduce terminal lifecycles in sessions", 856760c4 "refactor(core)!: move terminal values into sessions". The 3d8f1226 diff to the snapshot is nothing but removed field lines (`- lastCommand: nil`, `- isRemote: false`, `- remoteSession: nil`, `- agentSession: nil`) repeated per pane. DeterminismSeamTests.swift already covers the same seam with targeted assertions against a fake home (`resolveLaunchExpandsTildeAgainstInjectedHome`, `restoreExpandsTildeThroughEnvHome`, `snapshotAbbreviatesAgainstInjectedHome`) and its header states exactly which axes it pins.

**Ideal fix.** Delete GoldenMasterTests and its snapshot. Where the golden run covers a path DeterminismSeamTests does not -- recursive update() forwarding, IPC-dispatched mints, navigateToPane, the alert notification-throttle clock read -- add one explicit assertion per path that names the value it expects (the minted id, the recorded createdAt) instead of comparing the whole model. Determinism is a property of specific fields, so the test should read those fields.

**Cheaper fallback.** Keep the golden run but snapshot a projection instead of the model -- the list of minted ids and read timestamps in order. That is stable under field moves and still fails if a mint or a clock read is added, removed, or reordered.

**Risk.** low

### S37. Move the nine frozen research probes out of the default TerminalCore test target

`tests` &middot; dead-code &middot; impact 3, confidence 5 &middot; effort small

`lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLineEvictionProbe.swift`, `lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLineReadProbe.swift`, `lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLineAdmissionProbe.swift`, `lib/TerminalCore/Tests/TerminalCoreTests/TerminalLogicalLineWideIndexProbe.swift`, `lib/TerminalCore/Tests/TerminalCoreTests/TerminalHistoryTailCostProbe.swift`, `lib/TerminalCore/Tests/TerminalCoreTests/TerminalWiredHistoryAttributionProbe.swift`

**Problem.** Nine `*Probe.swift` files totalling 4,803 lines -- 15.5% of the TerminalCore test target's 30,945 lines -- are research instruments gated behind `DANTERM_LOGICAL_LINE_PROBE`, so they never execute in the gate. They are frozen artifacts of completed findings and, by their own admission, hand-reproduce private production internals rather than calling them. That means they compile against the engine on every run of the gate's longest step and have to be edited whenever the engine changes, while producing no signal when they are edited wrong -- a maintenance tax with the verification switched off.

**Evidence.** `wc -l lib/TerminalCore/Tests/TerminalCoreTests/*Probe.swift` = 4803; the whole target is 30945. Every `@Test` in them carries `.enabled(if: probeIsEnabled)` and each file defines `probeIsEnabled = ProcessInfo.processInfo.environment["DANTERM_LOGICAL_LINE_PROBE"] != nil`. TerminalLogicalLineEvictionProbe.swift's header says arm A "reproduces `Terminal.swift#enforceScrollbackBudget`" because "those members are `private` to `Terminal`, so the arm reproduces them rather than calling them, which is this probe's stated fidelity limit". `git log` shows they are still being dragged by production edits: 5391260b "refactor(terminal): rename the scrollback budget constant to scrollbackByteLimit" and 9ad7cc55 "refactor(terminal): store retained history as logical-line records" both touch them.

**Ideal fix.** Give the probes their own SwiftPM target (say `TerminalCoreProbes`) that is not the gate's test target, and drop the env-variable gate -- membership in that target is the gate. The default `swift test --package-path lib/TerminalCore` then stops compiling them, and the `.enabled(if:)` scaffolding disappears. For the ones whose findings are already recorded in docs/research and are not expected to be re-run, delete the file and let git hold the history; a probe that will never be re-run is a document, and it is already written down as one.

**Cheaper fallback.** Leave them in place but stop maintaining them mechanically: mark each with the revision it was valid at and let it fail to compile, then delete it, the next time the engine moves under it. This costs nothing now but keeps the compile time.

**Risk.** A probe that is genuinely re-run to defend a future performance decision would need its target rebuilt on demand. Keeping them as a separate target rather than deleting removes that risk entirely.

> Folded in from `scrollback`: Retire the prototype arenas in the probe tests now that the decisions they fed have shipped. The test target still carries three separate re-implementations of history storage: `LogicalLineArena`, a Phase-1 prototype of the logical-line store whose own header says prototypes live in the test target "until research/31/D1 answers go"; `GranularityArena`, a second partial arena with its own header/fold/eviction; and `BudgetEnforcedRowStore`, a reproduction of the deleted display-row scrollback (`ScrollbackBuffer`, `scrollbackByteCost`, `isHistoryHeadTruncated`, `compactIfNeeded`) that no longer exists in production. Four probe files -- read, index, wide index, blank index -- measure only the prototype and never touch `Terminal.LogicalLineStore` at all, so any number they now produce describes a structure the app does not run. Meanwhile they compile on every test build against `@testable` internals (`PackedRetainedRow.pack`, `LogicalLineRecord`, `LogicalLineFold`, cell-word bit layout), which quietly taxes exactly the refactors the other findings here propose.

### S38. Key pane-tape follow state once, by subscription, instead of four sidecar maps

`app-runtime` &middot; structural &middot; impact 3, confidence 4 &middot; effort medium

`app/AppRuntime.swift#discardPaneTapeFollow`, `app/AppRuntime.swift#endPaneTapeFollowers`, `app/AppRuntime.swift#finishPaneTapeFollowStart`, `app/AppRuntime.swift#ipcConnectionClosed`, `lib/DanTermSupport/Sources/DanTermSupport/PaneTapeFollow.swift#PaneTapeFollowSubscriptions`

**Problem.** One follow stream's state is spread over four containers: `PaneTapeFollowSubscriptions` (keyed by subscription, and the only one that knows the subscription -> connection mapping), `paneTapeFollowSubscriptionTokens` and `paneTapeFollowNoticeRegistrations` (keyed by subscription), and `paneTapeFollowConnections` (keyed by _connection_). Because the connection map is keyed one level up but removed one entry at a time, retiring a single subscription deletes the connection entry shared by its siblings. A second stream on that same socket then fails its next `paneTapeFollowConnections[fetch.connectionId]` lookup and is silently dropped via `discardPaneTapeFollow(..., closeConnection: false)` - no `end` record, no error, the client just stops receiving. `endPaneTapeFollowers` has the same shape and `continue`s past siblings whose connection entry was already consumed, skipping their promised terminator.

**Evidence.** `discardPaneTapeFollow` ends with `paneTapeFollowConnections.removeValue(forKey: removal.connectionId)`; `endPaneTapeFollowers` does the same inside a `for end in ... paneClosed(...)` loop. That many-subscriptions-per-connection case is not hypothetical to the design: `PaneTapeFollowSubscriptions.connectionClosed` returns an _array_ of removals and `ipcConnectionClosed` iterates it, so the support layer explicitly models several streams sharing a connection while the runtime's connection map cannot represent it.

**Ideal fix.** Store one `PaneTapeFollowStream` per subscription id holding its `IpcConnection`, scheduling token and notice registration together, so removing a subscription removes exactly that stream's resources and can never reach a sibling's. The connection then needs no separate map, and `endPaneTapeFollowers` / `discardPaneTapeFollow` / `ipcConnectionClosed` each become a filter over one dictionary.

**Cheaper fallback.** Refcount the connection map, or only remove a connection entry when `PaneTapeFollowSubscriptions` reports no remaining subscription on that connection.

**Risk.** Low. The support-layer `PaneTapeFollowSubscriptions` and its tests are unaffected; this is entirely runtime-side bookkeeping.

> Folded in from `ipc-cli`: Store a follow subscription's socket on the subscription, not in a connection-keyed side table. `PaneTapeFollowSubscriptions` is keyed by subscription id and explicitly allows many subscriptions per connection (each `Subscription` stores its `connectionId`). But the runtime keeps the actual socket in `paneTapeFollowConnections`, keyed by _connection_ id, and removes that entry when any single subscription ends. Two follows on one socket therefore break each other: ending the first deletes the shared connection entry, after which `fetchPaneTapeFollow` finds no connection for the survivor and silently discards it, and `endPaneTapeFollowers` `continue`s past the second subscription without ever writing its `end` record. Four parallel dictionaries (`paneTapeFollowSubscriptions`, `paneTapeFollowConnections`, `paneTapeFollowSubscriptionTokens`, `paneTapeFollowNoticeRegistrations`) must be kept consistent by hand at five separate teardown sites, and one of them is keyed differently from the other three.

### S39. Drop .build-gate by deleting the unenforced -warn-long-function-bodies flag

`build` &middot; accidental-complexity &middot; impact 3, confidence 4 &middot; effort small

`scripts/run-test-suite.sh`, `.gitignore`

**Problem.** The gate builds TerminalCore into its own scratch path purely because it passes `-Xswiftc -Xfrontend -Xswiftc -warn-long-function-bodies=500`, which changes SwiftPM's build-argument hash and would otherwise thrash the shared .build tree. That flag only emits warnings, and nothing in the project turns warnings into errors, so its output scrolls past inside a captured per-step log that is discarded unless the step fails. The project pays a full duplicate build tree of the engine -- the largest package in the repo -- for a signal nobody reads and nothing gates on.

**Evidence.** scripts/run-test-suite.sh STEPS entry 1 carries the flag with `--scratch-path lib/TerminalCore/.build-gate`; .gitignore documents the split explicitly ("the gate builds lib/TerminalCore with extra -Xswiftc args, which change SwiftPM's build-argument hash ... the gate gets its own scratch path instead"). No `warningsAsErrors` or `unsafeFlags` appears in any Package.swift. On this checkout `lib/TerminalCore/.build-gate` is 556 MB alongside `lib/TerminalCore/.build` at 956 MB. run-test-suite.sh's worker only replays a step's captured output when the step fails, so a passing step's warnings are never printed.

**Ideal fix.** Delete the flag from the STEPS entry and the .build-gate scratch path with it, so the gate's TerminalCore step shares the same build tree as a targeted `swift test --package-path lib/TerminalCore` and a developer's warm tree makes the gate's longest step incremental. If long type-check times are worth guarding, guard them for real: a dedicated opt-in recipe that runs the flag and fails on any warning above the threshold, rather than an always-on flag whose only lasting effect is a second build tree.

**Cheaper fallback.** Keep the flag but have the worker echo captured output for passing steps too, so someone at least sees the warnings -- this preserves the duplicate tree and still enforces nothing.

**Risk.** Losing a passive slow-type-check signal. Given nothing consumes it today, the loss is nominal; the opt-in recipe recovers it on demand.

### S40. Nest per-pane search and notification state in PaneModel so cleanup is structural

`core-model` &middot; structural &middot; impact 3, confidence 4 &middot; effort medium

`lib/DanTermCore/Sources/DanTermCore/Model.swift#AppModel`, `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#clearPaneSideTables`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#update`

**Problem.** `searchState` and `lastNotificationTime` are pane-keyed dictionaries hanging off AppModel while panes themselves live in the tree. Nothing removes their entries when a leaf disappears, so a manual `clearPaneSideTables` call must be remembered at every pane-removal site -- the same dual-write hazard the tree-owns-panes refactor eliminated for panes and the session ADR eliminated for sessions, left in place for the last two tables. It also runs the other way: `.searchStarted` writes `searchState[paneId]` without checking the pane exists, so a late search event for a torn-down pane silently re-creates a key that no cleanup will ever remove and that `desiredSearchOverlays` will then hand to the reconciler.

**Evidence.** Model.swift#AppModel declares `searchState: [PaneId: SearchModel]` and `lastNotificationTime: [PaneId: [AlertKind: Date]]`. ModelOperations.swift#clearPaneSideTables is the chokepoint, called from Update.swift at lines 239 (closePane), 766 and 783 (sessionCreationFailed), 946 (deleteGroup), and 2067 (closeTabBody) -- five hand-placed sites. Update.swift lines 1096-1097 create `model.searchState[paneId] = SearchModel()` with no liveness guard. `UnreadAlertTally`'s own doc comment (ModelOperations.swift:869-871) records that stale-pane entries are an accepted state for the alert feed, confirming the staleness is real rather than hypothetical. The session ADR (docs/design/2026-08-10-session-owned-terminal-reported-facts.md, D2) notes these stay pane-keyed because the user/view owns them, but its P1 argument -- removing the leaf removes the state atomically -- applies to them unchanged.

**Ideal fix.** Move both onto `PaneModel` (`var search: SearchModel?`, `var lastNotified: [AlertKind: Date]`). Neither is written to `PaneSnapshot`, so the ephemeral/persisted split is preserved by the explicit codec in Persistence.swift#toPaneSnapshot. Removing the leaf then removes them in the same mutation, `clearPaneSideTables` shrinks to alert pruning alone, and a search report for a dead pane cannot find a pane to write to -- so the resurrection path disappears rather than being guarded.

**Cheaper fallback.** Keep the dictionaries but add a liveness guard to `.searchStarted` and prune both tables against `model.allPaneIds` inside the same reconcile pass that runs `sessionsToTearDown`, so a missed call site self-heals instead of leaking.

**Risk.** Search overlay and notification-throttle behaviour must stay identical; both are covered by existing search and alert tests. The one real change is that a search event for a nonexistent pane becomes a no-op instead of creating state, which is the intended behaviour.

### S41. Drop @discardableResult from update() so nested calls cannot silently swallow commands

`core-reducer` &middot; structural &middot; impact 3, confidence 4 &middot; effort small

`lib/DanTermCore/Sources/DanTermCore/Update.swift#update`

**Problem.** `update()` composes with itself: fifteen handlers re-enter the reducer to reuse another case's logic. Because the function is `@discardableResult`, two of those call sites discard the returned commands with `_ =`, so any side effect the nested message emits is dropped without a compiler warning. Both are safe only by coincidence -- the nested messages happen to return `[]` today. The moment `.moveTabs` or `.toggleZoomPane` gains a command (a focus move, a checkpoint, an IPC-visible effect), the bug is a silent no-op at a call site nobody will revisit.

**Evidence.** Read Update.swift:5-10 (`@discardableResult func update`). Read line 1040 in `.extractTabsToNewGroup`: `_ = update(&model, .moveTabs(...), env: env)` with the comment "Discard nested commands; the sidebar updates via reconcileSidebar" -- true only because `.moveTabs` (line 971-1018) returns `[]` on every path. Read line 1658 in the IPC `.paneZoom` arm: `_ = update(&model, .toggleZoomPane(paneId: paneId), env: env)`, and `.toggleZoomPane` (line 1055-1075) likewise returns `[]` on all three paths. Every other nested call at lines 45, 120, 139, 145, 168, 247, 752, 893, 927, 1121, 1371, 1377, 1481-1738, 1967 does propagate its result.

**Ideal fix.** Remove `@discardableResult` from `update()`. Every call site then has to say what it does with the commands, and the two discards become explicit, reviewable decisions instead of invisible ones. Tests that call `update(&model, msg)` for its mutation add `_ =`, which is the point: dropping side effects should be spelled out.

**Cheaper fallback.** Leave the attribute and make the two sites `commands.append(contentsOf: update(...))`. Fixes today's two instances but not the class -- the next nested call can discard again for free.

**Risk.** Low; the change is compile-error-driven and the fix at each new error site is mechanical. Touches many test lines.

### S42. Give all three confirmations one representation instead of half-model, half-command

`core-reducer` &middot; structural &middot; impact 3, confidence 4 &middot; effort medium

`lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#emitTerminateConfirmation`, `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#emitCloseTabConfirmation`, `lib/DanTermCore/Sources/DanTermCore/Projections.swift#desiredQuitConfirmation`, `lib/DanTermCore/Sources/DanTermCore/Model.swift#PendingConfirmation`

**Problem.** `PendingConfirmation` is a mutex slot for three sheets, but only one of the three is actually driven by it. The terminate case sets the slot and returns no command -- the panel is a projection. The two close cases set the slot AND emit a `.showClose*Confirmation` command carrying a second copy of the same pending state plus its display payload. So the model can say a close-tab sheet is pending while the view knows nothing, and the invariant "the slot is nil again" depends entirely on the AppKit alert callback always sending confirm-or-cancel. If any dismissal path ever bypasses that callback the slot strands at `.closeTab` and every future confirmation -- including quit -- is silently swallowed by the `guard model.pendingConfirmation == nil` at the top of all three emitters. The IPC `tabClose` arm already had to special-case this hazard.

**Evidence.** Read ModelOperations.swift:699-704 (`emitTerminateConfirmation` sets `.terminate`, returns `[]`) against 708-723 and 725-745 (`emitCloseTabConfirmation`/`emitCloseTabsConfirmation` set `.closeTab` and also return a command). Read Projections.swift:1048-1059: `desiredQuitConfirmation` explicitly returns nil for `.closeTab` with the comment "close-tab confirmation is driven by modal NSAlert commands instead." Read Update.swift:1523-1530, whose comment says routing the last tab through `.closeTab` would "leave the tab open, and strand pendingConfirmation" -- the hazard named in the source. Read AppRuntime.swift:1065-1090: both alert handlers do currently always send a response.

**Ideal fix.** Make `PendingConfirmation` carry each sheet's full payload (`.terminate(paneCount:)`, `.closeTab(tabId:title:paneCount:isLastTab:uncompletedTodoCount:)`, `.closeTabs(...)`) and project all three from it, the way the quit panel already is. The show-confirmation Commands disappear, the payload exists once, and "model says pending but nothing is on screen" stops being representable -- the reconciler tears the sheet down whenever the slot clears, whatever cleared it.

**Cheaper fallback.** Keep the commands but store the payload in `PendingConfirmation` and have the reconciler assert/repair agreement, or have AppRuntime clear the slot on any alert dismissal. Narrows the stranding window without removing the duplicate representation.

**Risk.** Moderate: the two close sheets are modal NSAlerts run imperatively, so projecting them means moving modal presentation into the reconcile sweep, which runs inside send(). Confirm that a modal run loop inside reconcile is acceptable before committing to the ideal -- if not, that is the constraint that argues for the fallback.

### S43. AGENTS.md maps three of the seven places a document can live

`docs` &middot; docs &middot; impact 3, confidence 4 &middot; effort small

`AGENTS.md`, `docs/research/README.md`, `docs/scratch/2026-08-11-agent-hook-contract.md`, `plans/impl`

**Problem.** A document in this repo can live in docs/design/, docs/research/, docs/evidence/, docs/scratch/, agent-docs/, plans/wip/, plans/impl/, or plan-terminal-engine/. AGENTS.md names only docs/design/ (via the read-before-you-touch table), docs/research/ (via the citation rule), and agent-docs/ files individually; it never says what docs/evidence/ or docs/scratch/ are, never mentions plans/ except to forbid citing plan ids, and never states the taxonomy. The one place the taxonomy is written down is docs/research/README.md ("not an ADR and not a plan: design decisions that are settled graduate to docs/design/, and work that is ready to implement graduates to a plan file") -- a file an agent only opens when it already knows it wants research. The result is an agent that cannot answer "where does this note go" or "is this file binding on me" without reading the tree, and 294 files in plans/impl/ make guessing expensive.

**Evidence.** Grepped AGENTS.md for scratch/agent-docs/docs\/research/plans/evidence: hits are the reference-sources, perf-granularity, worktree, terminal-performance, measurement-discipline, build-details links, the research citation rule, and nothing else. Listed docs/scratch (7 files, e.g. 2026-08-11-agent-hook-contract.md dated today) and docs/evidence (7 files) -- neither directory has a README or any inbound reference from AGENTS.md. `ls plans/impl | wc -l` is 294; plans/wip holds 2. Read docs/research/README.md lines 1-22 for the only written taxonomy.

**Ideal fix.** Put one short table in AGENTS.md -- one row per document home -- giving for each: what goes there, whether it is binding on an agent, and what its retention is (durable / living / disposable). Give docs/scratch/ and docs/evidence/ a one-paragraph README each stating the same thing locally, the way docs/research/README.md already does, so the answer is reachable from either direction.

**Cheaper fallback.** Add the table to AGENTS.md only, skipping the per-directory READMEs.

**Risk.** low

### S44. Delete applyGroupCollapseState; paint the group row from its own projection

`sidebar` &middot; duplication &middot; impact 3, confidence 4 &middot; effort small

`app/SidebarView.swift#applyGroupCollapseState`, `app/SidebarView.swift#configureGroupCell`, `app/SidebarView.swift#applyRowOp`, `app/SidebarView.swift#outlineViewItemDidCollapse`, `app/SidebarView.swift#outlineViewItemDidExpand`

**Problem.** applyGroupCollapseState repaints the caret glyph, the bell badge, and the tab-count badge from a `collapsed: Bool` parameter -- the same three assignments configureGroupCell already makes from `group.isCollapsed`. This is exactly the second derivation that commit 247f8dc8 removed for tab and group cells, left standing for collapse chrome. It is also redundant work: on the delegate path the `.toggleGroupCollapse` send reconciles synchronously, emits a setGroupCollapsed op, and applyRowOp has already repainted the row before the delegate's own call runs.

**Evidence.** configureGroupCell (lines ~1363-1377) and applyGroupCollapseState (lines ~801-820) contain the same three arranged-subview lookups and the same body, differing only in whether `collapsed` comes from the parameter or from the projection. applyRowOp's `.setGroupCollapsed` case calls store.apply (which sets item.kind to the new projection, via SidebarItemStore.updateGroupItem) and then calls applyGroupCollapseState, so the projection on the item already carries the same isCollapsed. Update.swift:1050 `.toggleGroupCollapse` flips model.groups[idx].isCollapsed, so the delegate's send guarantees a setGroupCollapsed op and a paint before the delegate line runs.

**Ideal fix.** Delete applyGroupCollapseState. In applyRowOp's `.setGroupCollapsed` case, after collapseItem/expandItem, call the one render entry point -- configureGroupCell with the group taken off the updated item's projection (the same shape as updateGroupRow). Drop the calls in outlineViewItemDidCollapse/DidExpand entirely: the send they already make reconciles and repaints. Group chrome then has exactly one painter, fed only by the projection.

**Cheaper fallback.** Keep the delegate calls but reimplement applyGroupCollapseState's body as `configureGroupCell(cell, group: group)`, ignoring the `collapsed` parameter. Removes the duplicated assignments but leaves the redundant second paint.

**Risk.** Low. The one thing to confirm is the caret-button path (caretClicked -> collapseItem -> delegate -> send): if any collapse route ever fails to produce a model change, the row would keep a stale caret. Update.swift's unconditional toggle makes that unreachable today.

### S45. Drop SidebarView.currentModel; read the runtime's model

`sidebar` &middot; duplication &middot; impact 3, confidence 4 &middot; effort small

`app/SidebarView.swift#applySidebarOps`, `app/SidebarView.swift#contextMenu(forTabId:clickedRow:)`, `app/SidebarView.swift#contextSetTabColors`, `app/SidebarView.swift#contextExtractTabs`, `app/SidebarView.swift#outlineViewSelectionDidChange`

**Problem.** SidebarView keeps a whole AppModel copy refreshed on every applySidebarOps, purely to serve the interaction path. The runtime already holds the authoritative model and the view already holds a reference to the runtime, so this is a second copy of the app state whose freshness depends on reconcileSidebar having run. The file itself is inconsistent about which one to read, and one handler's correctness is documented in terms of the mirror being refreshed mid-send rather than in terms of the model being current.

**Evidence.** `private var currentModel: AppModel?` is assigned only in applySidebarOps (line 311) and read at lines 310, 759, 780, 923, 956, 993, 1047, 1188, 1265, 1268. contextSetTabColors (line 1226) instead reads `runtime?.model` for the same kind of decision. contextExtractTabs' doc comment justifies itself with "diffed via group-id snapshot against currentModel, which reconcileSidebar refreshed during send" -- correct only because the mirror is refreshed as a side effect. The only value applySidebarOps needs that the runtime cannot supply is `priorFocusedTabId`, a single TabId? captured before the assignment.

**Ideal fix.** Delete `currentModel`. Replace every read with `runtime?.model`, and keep one small stored field `lastFocusedTabId: TabId?` for the reveal-on-focus-change comparison in applySidebarOps. The interaction path then reads the same model the update loop just produced, and no reader can be one reconcile behind.

**Cheaper fallback.** Keep currentModel but make it the single source for the interaction path -- change contextSetTabColors to read it too -- so at least the two readers cannot disagree.

**Risk.** Low, with one thing to check: the UI harness's AppRuntime shim (tests-ui/SidebarViewTestShim.swift) exposes `var model`, and several harness tests call applySidebarOps without setting runtime.model, so those tests would need to set it.

### S46. Let the swapchain own its construction inputs instead of mirroring them in the view

`terminal-views` &middot; duplication &middot; impact 3, confidence 4 &middot; effort medium

`app/SwiftTerminalSessionView.swift#SurfaceInputs`, `app/SwiftTerminalSessionView.swift#surfaceSwapchain`, `app/SwiftTerminalSessionView.swift#discardSwapchain`, `lib/TerminalCore/Sources/TerminalRenderExecution/TerminalFrameSwapchain.swift#TerminalFrameSwapchain`

**Problem.** `TerminalFrameSwapchain.init` already takes columns, rows, metrics and colorSpace, but stores none of them and exposes none of them. The view therefore keeps a parallel copy in `swapchainInputs` that must be nilled and reassigned in lockstep with `swapchain` in three places, and a mismatch between the two is silent -- the view would keep buffers built for the wrong geometry. Comparing that mirror also runs `TerminalRenderMetrics ==` once per publish, which is a deep CoreText comparison (four `CFEqual` calls plus, when the packaged symbols face is present, two `CTFontCopyPostScriptName` allocations) in service of a question the swapchain could answer by identity.

**Evidence.** `swapchain` and `swapchainInputs` are separate stored properties (lines 84-88), assigned together in `surfaceSwapchain` (lines 324-332) and cleared together in `discardSwapchain` (lines 338-341). `TerminalFrameSwapchain.init` (TerminalFrameSwapchain.swift:57-76) consumes columns/rows/metrics/colorSpace only to build stores. `TerminalFontSet.==` (TerminalRenderExecution.swift:367-374) compares four faces with `CFEqual` and calls `optionalFontsEqual` (line 379), which copies PostScript names; `TerminalRenderMetrics` is `Equatable` with `fonts` as a stored member (line 45), so this runs inside `swapchainInputs == inputs` on the publish path (`present` -> `surfaceSwapchain`).

**Ideal fix.** Move the inputs into the swapchain: store the four values it is constructed from and expose `func matches(columns:rows:metrics:colorSpace:) -> Bool`. The view then holds one optional (`swapchain`) and asks it whether it is still valid; there is no second value to keep in sync and no drift to reason about. If the comparison is worth making cheap, give `TerminalRenderMetrics` a construction-order identity token and compare that inside `matches`, since a metrics value is only ever produced whole by `resolvedMetrics`.

**Cheaper fallback.** Keep the mirror but make it one optional -- store `(swapchain, inputs)` as a single tuple/struct property so they cannot be assigned apart.

**Risk.** Low; `matches` must compare exactly the fields the constructor consumes, which a test asserting swapchain replacement on each of the four inputs pins down. The theme case must keep its explicit `discardSwapchain`, since theme is deliberately not one of the compared inputs.

### S47. `just clean` misses two of the five build trees it is supposed to remove

`build` &middot; tooling &middot; impact 2, confidence 5 &middot; effort small

`justfile#clean`, `.gitignore`

**Problem.** The clean recipe removes .spm-build, .build, and each lib/\*/.build, but not .build-app-tests or lib/TerminalCore/.build-gate -- the two scratch paths the gate itself creates. A developer who runs `just clean` to recover disk or to force a cold rebuild gets neither: on this checkout those two directories hold about 1.0 GB and survive untouched, and the gate keeps reusing a tree the user believes they deleted. The failure mode is structural: the recipe hardcodes a list of paths that has to be kept in sync with paths chosen elsewhere (run-test-suite.sh) and it already fell out of sync.

**Evidence.** justfile line 9 is `rm -rf .spm-build .build lib/DanTermProtocol/.build lib/DanTermCore/.build lib/DanTermSupport/.build lib/TerminalCore/.build lib/TerminalPTY/.build`. .gitignore separately lists `.build-gate/` and `.build-app-tests/`, and both directories exist in the working tree (449 MB and 556 MB respectively per `du -sh`). scripts/run-test-suite.sh is where those two paths are chosen (`--scratch-path .build-app-tests`, `--scratch-path lib/TerminalCore/.build-gate`).

**Ideal fix.** Have clean delete by pattern rather than by list: `find . -name '.build' -o -name '.build-gate' -o -name '.build-app-tests' -o -name '.spm-build' -maxdepth 3 -prune -exec rm -rf {} +`, or equivalent. A new scratch path added in run-test-suite.sh is then cleaned automatically and the two lists cannot diverge again.

**Cheaper fallback.** Append the two missing paths to the existing literal list -- correct today, and free to rot again the next time a step picks a new scratch path.

**Risk.** Low; a pattern-based clean must be scoped so it cannot reach into references/ or a user's unrelated directories.

### S48. Stop running DanTermProtocolTests twice in the gate

`build` &middot; duplication &middot; impact 2, confidence 5 &middot; effort small

`scripts/run-test-suite.sh`, `Package.swift`

**Problem.** The root package declares a DanTermProtocolTests test target pointing at lib/DanTermProtocol/Tests/DanTermProtocolTests, and the nested lib/DanTermProtocol package declares the same test target over the same path. The gate runs both: `swift test --scratch-path .build-app-tests` at the root executes DanTermProtocolTests as one of its targets, and a separate STEPS entry runs `swift test --package-path lib/DanTermProtocol --filter DanTermProtocolTests`. The same assertions run twice, and the second run requires SwiftPM to resolve and compile the protocol package a third time in its own tree. Unlike DanTermCore and DanTermSupport, DanTermProtocol is a real imported module in the root build, so the nested package buys no isolation the root build does not already have.

**Evidence.** Package.swift declares `.testTarget(name: "DanTermProtocolTests", path: "lib/DanTermProtocol/Tests/DanTermProtocolTests")`; lib/DanTermProtocol/Package.swift declares a test target of the same name over `Tests/DanTermProtocolTests`, i.e. the identical directory. scripts/run-test-suite.sh STEPS contains both `'swift test --package-path lib/DanTermProtocol --filter DanTermProtocolTests'` and `'swift test --scratch-path .build-app-tests'`.

**Ideal fix.** Pick one owner. Since the root build imports DanTermProtocol as an ordinary module (no symlink, no purity claim to isolate), keep the root test target and delete both the nested package's test target and the gate step that invokes it -- one compile, one run, one place to add a protocol test. The nested Package.swift stays only if something outside the root build consumes the library standalone.

**Cheaper fallback.** Drop the root test target instead and keep the nested step, if standalone buildability of DanTermProtocol is a property worth pinning; either direction removes the duplicate, but only one of them should be chosen deliberately.

**Risk.** Low. If the nested test target is removed, the nested package still compiles as a library, so any standalone-buildability claim is preserved by the app build itself.

> Folded in from `tests`: The gate's step list has no completeness check, and one test target runs twice. The gate is a hand-written array of 73 command strings. Its self-test verifies only the pool's mechanics -- a failing step fails the run, output is replayed, the queue is not aborted -- and never verifies that the array covers the test estate. A new script under scripts/tests/ or a new SwiftPM test target is therefore silently unrun until someone notices. The same hand-maintenance also produced a duplicate: DanTermProtocolTests is declared twice, in lib/DanTermProtocol/Package.swift and again as a testTarget in the root Package.swift over the identical path, and the gate runs both declarations, so those 43 tests are compiled and executed twice per gate.

### S49. Delete the three unread-alert reference implementations no render path calls

`core-model` &middot; duplication &middot; impact 2, confidence 5 &middot; effort small

`lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#unreadAlertTally`, `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#groupUnreadAlertCount`, `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#totalUnreadAlertCount`, `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift#paneHasUnreadAlert`

**Problem.** Unread alerts are counted five different ways, and the file carries a comment instructing future readers to keep them numerically equivalent by hand. Three of the five have no production caller at all -- they exist only so tests can compare the tally against them, which means the test suite is checking one implementation against three others rather than against the behaviour. A comment that says "these must agree" is the signature of a duplication the types should have prevented.

**Evidence.** ModelOperations.swift lines 860-865 state outright that `unreadAlertTally` "must stay numerically equivalent to `paneHasUnreadAlert`, `unreadAlertCount`, `groupUnreadAlertCount`, and `totalUnreadAlertCount`", and `groupUnreadAlertCount`'s own doc says "Reference implementation only: no render path calls this." Grepping app/ and lib/ for callers outside ModelOperations.swift: `paneHasUnreadAlert` -> only UnreadAlertTallyTests; `totalUnreadAlertCount` -> only UnreadAlertTallyTests; `groupUnreadAlertCount` -> only ModelOperationsTests and UnreadAlertTallyTests; `unreadAlertCount(for:alerts:)` -> exactly one production site, app/SidebarView.swift:1131 (context-menu "Clear Alerts" visibility).

**Ideal fix.** Keep `unreadAlertTally` as the single definition, delete the three test-only functions, and change SidebarView.swift:1131 to read `tally.byTab[tab.id] ?? 0 > 0` from the tally the reconciler already computes -- then delete `unreadAlertCount` too. Rewrite the tally tests to assert against stated behaviour (counts for a hand-built model with known alerts) rather than against a second implementation, which is what makes the equivalence comment unnecessary.

**Cheaper fallback.** Delete only `paneHasUnreadAlert`, `totalUnreadAlertCount`, and `groupUnreadAlertCount` and fold their assertions into direct expected-value checks on the tally, leaving `unreadAlertCount` for the one sidebar caller.

**Risk.** low

### S50. Move the IPC dispatcher out of Update.swift; the file is two subsystems

`core-reducer` &middot; clarity &middot; impact 2, confidence 5 &middot; effort small

`lib/DanTermCore/Sources/DanTermCore/Update.swift#dispatchIpc`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#update`

**Problem.** Update.swift opens with the one-line header "Pure update function for DanTerm's Elm-style state machine", but 420 of its 2162 lines are the complete IPC method dispatcher plus its ten private helpers (validation throwers, JSON result builders, todo encoders). That is the app's whole external API surface -- the thing AGENTS.md points at SKILL.md for -- living inside the file named after the reducer, with no header line saying so. Someone changing a CLI command has no reason to open Update.swift, and someone reading the reducer scrolls past the JSON layer to reach the helpers the reducer actually uses.

**Evidence.** Read Update.swift line 1 (the header) and lines 1421-1843: `handleIpcRequest`, `dispatchIpc` (a ~290-line switch over every IPC method), `ipcInvalidParams`, `IpcParamsError`, `agentSession`, `agentActivity`, `requirePane`/`requireTab`/`requireGroup`, `newestTabId`, `tabRenameResult`, `tabFocusResult`, `todoResult`, `todoListResult`, `okResult`, `appendTodo`, `todoExists`, `todoJSON`. Only `appendTodo` is shared with the reducer proper (called from the `.addTodo` arm at line 1317). The codebase already has the right home for these -- IpcEntityEncoder.swift -- and an established precedent for domain sub-reducers in PaneLifecycleReducer.swift.

**Ideal fix.** Split IpcDispatch.swift out with `handleIpcRequest`, `dispatchIpc`, and every helper except `appendTodo` (which moves next to the todo handlers), and give both files real headers stating what belongs in each. The reducer's `.ipcRequest` arm stays a one-line delegation, exactly as it is now, so nothing changes structurally -- the file boundary just stops lying.

**Cheaper fallback.** Leave the code in place and rewrite the file header to say the file holds both the reducer and the IPC dispatcher. Cheap, but keeps the 2162-line file and the misleading name.

**Risk.** Low. Same-module file move with no visibility changes; the `private` helpers stay private to the new file and only `appendTodo` needs to move with the reducer.

### S51. Give todo ids the same phantom-typed treatment as every other entity id

`ipc-cli` &middot; structural &middot; impact 2, confidence 5 &middot; effort small

`lib/DanTermProtocol/Sources/DanTermProtocol/IpcRequest.swift#IpcRequest`, `lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift#parseTodoIdCommand`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#dispatchIpc`, `lib/DanTermProtocol/Sources/DanTermProtocol/TypedId.swift`

**Problem.** Panes, tabs, and groups cross the IPC boundary as `TypedId`; todos cross as a bare `String`. The consequences show up in all three layers: the CLI validates pane and tab ids at parse time but ships any string as a todo id, `IpcRequest.decode` re-checks it with `UUID(uuidString:)` while still storing a `String`, and `dispatchIpc` then parses it a fourth time in four separate cases -- guards that are unreachable, since the only producer of an `IpcRequest` is the decoder that already rejected non-UUIDs. AGENTS.md states every entity id is a phantom-typed wrapper; this is the one exception, and it costs a parse-and-guard at every hop.

**Evidence.** IpcRequest.swift lines 202-208 declare `todoEdit/todoDone/todoOpen/todoDelete` with `todoId: String`; decode at lines 421-439 validates `UUID(uuidString: todoId) != nil`. Update.swift lines 1697, 1709, 1727 each re-run `guard let todoId = UUID(uuidString: rawTodoId) else { throw IpcParamsError("invalid todo") }`. CLIParser.swift `parseTodoIdCommand` (line 596) passes `rest[0]` through untouched, while `paneId`/`tabId`/`groupId` (lines 609-622) reject a malformed UUID locally. TypedId.swift defines only Tab/Pane/Group tags.

**Ideal fix.** Add `TodoTag`/`TodoId = TypedId<TodoTag>` and use it in the four todo cases of `IpcRequest`, in the CLI parser (so a malformed id fails locally like every other id), and in `dispatchIpc`. The four unreachable UUID guards in Update.swift disappear because the type carries the proof, leaving only the real check -- that the todo exists in that pane.

**Cheaper fallback.** Delete the four unreachable guards in `dispatchIpc` and add UUID validation to `parseTodoIdCommand`. Removes the dead code and the client-side gap but keeps the untyped id and the invariant unenforced.

**Risk.** low -- the wire encoding stays a UUID string, so nothing external changes; the `todo` cases in the catalog round-trip test cover the change.

### S52. Derive the CLI help text from the parser instead of hand-syncing three copies

`ipc-cli` &middot; docs &middot; impact 2, confidence 5 &middot; effort medium

`cli/main.swift#DanTermCLI.usageText`, `lib/DanTermProtocol/Sources/DanTermProtocol/CLIParser.swift#parseCLI`, `integrations/danterm/SKILL.md`

**Problem.** The command surface is written out three times: the usage strings inside `parseCLI`'s per-command parsers, the 75-line `usageText` blob in the CLI, and the SKILL.md table. Both the code comment and SKILL.md admit the sync is manual and unchecked. AGENTS.md requires SKILL.md to change in the same commit as any CLI surface change, so the cost of a miss lands on agents reading a stale contract. I diffed all three today: they currently agree, apart from the `--socket doctor` gap filed above -- so this is about the mechanism, not a present error.

**Evidence.** cli/main.swift lines 19-21: "Kept in sync by hand with `parseCLI` and the `EnvVars` constants used in `request(...)` -- there is no automated check" (and the `EnvVars` half of that sentence is already stale: `request` does not read the environment). SKILL.md lines 17-18: "Keep this section synced with `danterm help` and the parser". Each parser function additionally carries its own `let usage = "usage: danterm ..."` string, e.g. `parseTabRenameCommand`, `parsePaneZoomCommand`, `parsePaneRowsCommand`.

**Ideal fix.** Make the parser the single source: give each command a small descriptor (name, usage line, one-line summary) that both `parseCLI` uses for its error messages and a renderer turns into `danterm help`. Then add a test that the SKILL.md fenced command block equals the rendered synopsis, so the doc cannot drift silently -- the CLI surface becomes data with one definition and one checked copy.

**Cheaper fallback.** Skip the descriptor refactor and just add a test asserting that every usage line in SKILL.md's command block appears in `usageText`. Catches drift without unifying the three sources.

**Risk.** low -- error message wording may shift slightly where a hand-written usage string is replaced by a generated one; CLIParserTests pins several of those strings and would need updating with them.

> Folded in from `docs`: The danterm command inventory is written out three times, guarded only by a prose rule. The list of danterm commands and their argument shapes exists in three hand-maintained copies: the synopsis block in SKILL.md (lines 28-53), the `usageText` string literal in cli/main.swift (lines 22-97), and a run of ~18 `grep -qF` assertions in danterm-cli_test.sh that spell out individual usage lines. They agree today -- I diffed the command sets and they match item for item -- but nothing makes them agree. The only guard is AGENTS.md's prose instruction that changing the CLI surface "means updating that file in the same change," which is a rule an agent must remember rather than a structure that fails. The grep list is the worst of the three: it silently passes when a command is added and never described, so it verifies the copies it was written against and nothing since.

### S53. Move the pure OSC byte helpers off Terminal and split the file at its seams

`terminal-core` &middot; clarity &middot; impact 2, confidence 5 &middot; effort small

`lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.decodeBase64`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.percentDecoded`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.parseOSCSelector`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.hexadecimalValue`, `lib/TerminalCore/Sources/TerminalCore/Terminal.swift#Terminal.dispatchOSC`

**Problem.** `Terminal` is a single 7,778-line struct body with no extensions and no file split, and roughly 250 lines of it are byte-level decoders that have nothing to do with a terminal at all -- base64, percent-decoding, hex digits, decimal selector parsing, hostname normalization, ConEmu selector canonicalization. Declaring them as instance methods on the struct hides that they are pure functions, puts them in scope for the thousands of lines of grid code that must never call them, and means a reader cannot tell from the file where the parser ends and grid mutation begins.

**Evidence.** `decodeBase64`, `appendDecodedBase64Quartet`, `base64Value`, `percentDecoded`, `hexadecimalValue`, `parseOSCSelector`, `canonicalConEmuSelector`, `progressPercent`, `canonicalExitStatus`, `oscColorComponent`, and `osc8ExplicitId` are all `private func` (non-mutating) and none reads any stored property -- their only tie to `self` is calling each other and reading `Self.maximum*Bytes` constants. The OSC region as a whole (`dispatchOSC` through `base64Value`) is about 700 contiguous lines whose only writes are to semantic events, hyperlink tables, title/CWD, and the semantic-prompt row stamp.

**Ideal fix.** Make the pure decoders free functions in an `OSCPayload` enum in its own file, taking their byte limits as parameters, and move the OSC dispatch region into `TerminalOSC.swift` as an extension on `Terminal`. Do the same for the other natural seams the file already has -- search (see the search finding), width reflow and its anchor machinery, and damage snapshotting -- so each file's header can state what belongs in it and what does not, as the project's code-style rule asks.

**Cheaper fallback.** Extract only the eleven pure decoders into a free-function file and leave `Terminal.swift` otherwise intact. That is a small, zero-risk change that makes the pure/impure boundary visible and unit-testable on its own.

**Risk.** Low. The decoders have no state and same-module extensions do not change access or specialization; the byte caps must be passed explicitly rather than read from `Self` so the limits stay exactly the ones the bound tests assert.

### S54. Return the clamp state from terminalCell so the view stops re-deriving grid extents

`terminal-views` &middot; duplication &middot; impact 2, confidence 5 &middot; effort small

`app/SwiftTerminalSessionView.swift#pointerIsOutsideGrid`, `app/SwiftTerminalSessionView.swift#normalizedCell(at:)`, `app/SwiftTerminalSessionView.swift#forwardPointerDown`, `lib/TerminalCore/Sources/TerminalCore/TerminalInteractionPolicy.swift#terminalCell`

**Problem.** `terminalCell` computes whether a point falls inside the grid -- that is exactly what its clamp does -- and then throws the answer away, returning only the clamped cell. The view recovers it by recomputing the grid rectangle from `metrics.cellSize` and `dimensions` in `pointerIsOutsideGrid`. So the same grid-extent math lives in a pure, tested core function and again in an AppKit view, and the two can disagree (the core clamps against `columns - 1` after flooring; the view tests `point.x >= columns * cellWidth`). Because the answer is not carried, the view also converts the same window point and redoes the same arithmetic up to three times per pointer event.

**Evidence.** `pointerIsOutsideGrid` (SwiftTerminalSessionView.swift:1277-1283) converts the window point and compares against `CGFloat(dimensions.columns) * metrics.cellSize.width` / rows\*height; `normalizedCell(at:)` (line 1209) converts the same point and calls `terminalCell`, whose doc comment (TerminalInteractionPolicy.swift, above `terminalCell`) says clamping "moves the remainder with the column" -- i.e. it already knows the point was off-grid. `forwardPointerDown` (line 1223) calls `normalizedCell(for:)` and then `pointerIsOutsideGrid(event.locationInWindow)` twice.

**Ideal fix.** Give `TerminalViewportCell` (or `terminalCell`'s return) a `wasClamped` / `isInsideGrid` flag set by the clamp that already happens, and delete `pointerIsOutsideGrid`. The view then converts the point once, calls `terminalCell` once, and reads both the cell and its insideness from one value -- there is no second copy of the grid rectangle to keep in agreement.

**Cheaper fallback.** Keep `pointerIsOutsideGrid` but call it once per event and pass the boolean down, removing the repeated conversions while leaving the duplicated math.

**Risk.** Low. `TerminalViewportCell` is `Equatable` and appears in engine tests and in the UI-test shim, so adding a field touches those construction sites; give the flag a default so existing literals keep compiling.

### S55. Split ModelOperationsTests along the boundary its name claims

`tests` &middot; clarity &middot; impact 2, confidence 5 &middot; effort small

`lib/DanTermCore/Tests/DanTermCoreTests/ModelOperationsTests.swift#ModelOperationsTests`, `lib/DanTermCore/Sources/DanTermCore/Projections.swift`, `lib/DanTermCore/Sources/DanTermCore/ModelOperations.swift`

**Problem.** ModelOperationsTests is one 3,371-line `@Suite` with 159 tests spanning roughly 37 unrelated subjects, and more than half of them test Projections.swift rather than ModelOperations.swift -- desiredAlertsPopover, desiredSwitcher, desiredThemeBrowser, desiredFocusBorders, desiredPaneToolbar, desiredSearchOverlays, desiredPaneConfig, desiredSidebar, desiredWindowChrome, plus the whole TODO-popover projection block. Meanwhile the directory already has dedicated files for several of those same subjects (AlertPresentationTests, PaneToolbarTests, SidebarItemStoreTests, SwitcherEventTests, TodoPopoverStateTests), so a reader looking for a projection's coverage has to guess which of two plausible files it is in. Several MARK headings still carry stage numbers from a finished migration ("Stage 3", "Stage 7"), which date the file rather than describe it.

**Evidence.** Section headers in ModelOperationsTests.swift run from `// MARK: - allPaneIds` at line 36 to `// MARK: - desiredWindowChrome (window title / badges / tab-todo projection, Stage 6)` at line 3272; the projection blocks begin around line 1364 and run to the end. `grep` locates `func desiredAlertsPopover`, `desiredPaneToolbar`, `desiredSidebar`, and `desiredSwitcher` all in Projections.swift:188/289/552/1020, not ModelOperations.swift. `desiredPaneToolbar` is referenced from both ModelOperationsTests.swift and ChipKindTests.swift.

**Ideal fix.** One test file per source file it covers: ProjectionsTests.swift for everything named desired\*, and ModelOperationsTests.swift for the tree/MRU/pane-side-table operations that actually live in ModelOperations.swift. Fold the existing subject-specific files into whichever of the two owns their subject, and drop the stage numbers from the MARK headings since the stages are finished.

**Cheaper fallback.** Keep one file but convert the MARK sections into nested `@Suite` types named for what they cover, so the test IDs and failure output say `ProjectionsTests/desiredSidebar` instead of `ModelOperationsTests/...`. Cheaper, and it fixes the misleading label at the point a reader actually sees it.

**Risk.** low

### S56. Unify the three divergent "the selected tab died" fixups

`core-model` &middot; duplication &middot; impact 2, confidence 4 &middot; effort small

`lib/DanTermCore/Sources/DanTermCore/Update.swift#closeTabBody`, `lib/DanTermCore/Sources/DanTermCore/Update.swift#update`, `lib/DanTermCore/Sources/DanTermCore/Model.swift#AppModel`

**Problem.** `AppModel.selectedTabId` is an optional that must name a live tab, and three separate removal paths repair it with three separately written policies -- two of which disagree with the third about which tab the user lands on. A fourth path (deleteGroup with moveTabs) does not repair it at all, relying on the moved tabs staying live. Nothing in the type prevents a future removal path from forgetting the repair entirely.

**Evidence.** Update.swift#closeTabBody (lines 2053-2061, 2086-2088) picks the predecessor tab in flattened order, falling back to the successor. The `.sessionCreationFailed` arm (lines 772-774) instead sets `model.selectedTabId = model.groups.flatMap(\.tabs).first?.id`. The `.deleteGroup` non-move arm (lines 954-957) repeats that same first-tab rule as a third copy, guarded by its own `contains(where:)` liveness check. Model.swift#validateAndBuildDetailed does a fourth version at restore, defaulting to `parsedGroups.first?.tabs.first?.id`.

**Ideal fix.** Make selection repair impossible to skip: give AppModel `private(set) var selectedTabId` plus the removal primitives (`removeTab(_:)`, `removeGroup(_:)`) that perform the removal and re-anchor selection with one policy (predecessor, then successor, then nil-only-when-no-tabs-remain). Every removal path then goes through a call that cannot leave a stale or arbitrarily-relocated selection, and the three ad-hoc blocks disappear.

**Cheaper fallback.** Extract one `reanchorSelection(&model)` helper implementing the predecessor/successor rule and call it after each removal, leaving `selectedTabId` settable.

**Risk.** The two first-tab sites change which tab is selected after a group deletion or a session-creation failure. That is a deliberate behaviour unification; confirm the predecessor rule is the one wanted before applying, since no test currently pins the first-tab behaviour.

### S57. Read into one reusable buffer through a single read loop

`pty` &middot; performance &middot; impact 2, confidence 4 &middot; effort medium

`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#readReady`, `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#drainCommittedOutput`, `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift#applyOutput`

**Problem.** `readReady` allocates and zero-fills a fresh 16 KiB array on every read-source firing, then copies each chunk out with `Array(buffer.prefix(result))` so it can travel as a `[UInt8]` payload through `.output` and `.deliverOutput` before reaching `terminal.feed`. `drainCommittedOutput` repeats the same loop, the same 16 KiB literal, and the same per-chunk copy with a different termination condition. In a release build with the flight tape off (the shipping configuration -- the tape is Info.plist gated) nothing retains those bytes: `Terminal.feed` immediately re-borrows them as an `UnsafeBufferPointer`, so both the per-firing allocation and the per-chunk copy are pure overhead on the hottest path in the engine.

**Evidence.** Both `readReady` and `drainCommittedOutput` contain `var buffer = [UInt8](repeating: 0, count: 16 * 1024)` as a local and `process(.output(Array(buffer.prefix(result))))`. `Terminal.feed(_ bytes: [UInt8])` does nothing but `bytes.withUnsafeBufferPointer { feedBuffer(buffer) }`, so the array form is not required by the consumer. `applyOutput`'s only other consumers of the array are `flightTape?.record`, `recordTestOutput` (DEBUG), and `capturedOutput` (capture builds) -- all optional. `recordsFlightTape` comes from `DanTermBundleCapabilities.recordsFlightTape(infoDictionary:)`, so it is off in the shipping bundle.

**Ideal fix.** Hold one `readBuffer` on the actor, factor the two loops into a single `readAvailable(limit:) -> Bool` helper, and stop routing bytes through the reducer's payload at all: ask the reducer whether output is currently accepted (a `var acceptsOutput: Bool` derived from `Storage`) and feed the `UnsafeBufferPointer` straight into `terminal.feed`, copying only when a retaining consumer (tape or capture) is actually installed. The reducer keeps deciding, but the bytes stop making a round trip through an event enum and a command array on their way to the parser.

**Cheaper fallback.** Promote the 16 KiB buffer to a stored property shared by both loops and keep the existing `[UInt8]` event payload; that removes the per-firing allocation and the duplicated loop while leaving the copy.

**Risk.** A reusable buffer must not be aliased across a reentrant `process(...)` call that could read again before the previous chunk is consumed; feeding synchronously inside the loop keeps that safe, but the change belongs behind the benchmark harness in agent-docs/terminal-performance.md rather than being asserted as a win.

### S58. Make SidebarItemStore return the outline mutation instead of a Bool the executor re-switches on

`sidebar` &middot; accidental-complexity &middot; impact 2, confidence 4 &middot; effort medium

`lib/DanTermCore/Sources/DanTermCore/SidebarItemStore.swift#apply`, `app/SidebarView.swift#applyRowOp`, `app/SidebarView.swift#updateTabRow`, `app/SidebarView.swift#updateGroupRow`

**Problem.** The row-op executor switches over all eight SidebarRowOp cases, and SidebarItemStore.apply switches over the same eight again. The store answers only "should the AppKit mutation run?" as a Bool, so the executor has to re-derive the parent item, the index, and the single-vs-multi-group branch that the store already decided with. The reload cases also update the store twice: applyRowOp calls store.apply, which calls updateTabItem, and then updateTabRow calls store.updateTabItem for the same id.

**Evidence.** SidebarItemStore.apply's `.insertTab` branch consults projection.isSingleGroupMode and picks rootItems vs childItems[groupId]; app/SidebarView.swift#applyRowOp's `.insertTab` branch then re-picks the same branch from its own stored `isSingleGroupMode` and re-fetches `groupItemCache[groupId]` as the parent. `.reloadTab` in applyRowOp calls `store.apply(op, projection:)` (SidebarItemStore.apply -> updateTabItem) and then updateTabRow, whose first line is `store.updateTabItem(tabId:projection:)`.

**Ideal fix.** Have apply return an enum describing the AppKit work -- `.none`, `.insertRows(IndexSet, parent: SidebarItem?)`, `.removeRows(IndexSet, parent: SidebarItem?)`, `.setCollapsed(SidebarItem, Bool)`, `.repaint(SidebarItem)` -- built from the same guards that decided it. applyRowOp becomes a switch over that result with no re-derivation of parent, index, or group mode, and the reload cases update the store exactly once.

**Cheaper fallback.** Leave the Bool, but delete the `store.apply(op:)` call in the two reload cases so updateTabRow/updateGroupRow remain the single updater for those ops.

**Risk.** Low; the store's tests already cover the applied-state invariants and would carry over. The mutation enum has to keep the exact index semantics the sequential op script relies on, since inconsistent NSOutlineView batch indices crash hard.

### S59. Drop the vestigial optionality in TerminalSessionState.scrollPosition

`terminal-views` &middot; dead-code &middot; impact 2, confidence 4 &middot; effort small

`app/TerminalSession.swift#TerminalSessionState`, `app/SwiftTerminalSessionView.swift#state`, `app/ScrollableTerminalView.swift#synchronizeScrollView`

**Problem.** `TerminalSessionState.scrollPosition` is optional, but the single production implementation always builds a non-nil value from the viewport projection. The optionality is a leftover from the era when the backend reported scrollbar state as "present or not", and it costs three branches in the scroll chrome, one of which (`documentView.frame.size.height = contentHeight`) can never run in the app. Alongside it, `cellHeight` uses `0` as a "no geometry yet" sentinel, so the same absence is encoded two different ways in one struct and the code has to test both.

**Evidence.** `SwiftTerminalSessionView.state` (SwiftTerminalSessionView.swift:130-143) constructs `TerminalScrollPosition(...)` unconditionally from `viewport.projection`; grepping for conformances shows `SwiftTerminalSessionView` is the only non-test `TerminalSession`. `ScrollableTerminalView` branches on it three times: line 72 (`state.cellHeight > 0 || state.scrollPosition != nil`, which is therefore always true), line 188's `if let ... else`, and line 198.

**Ideal fix.** Make `scrollPosition` non-optional and replace the `cellHeight` zero-sentinel with a single optional geometry value, so "the pane has geometry" is one question with one answer. `synchronizeScrollView` then reads `guard let geometry = state.geometry` once and the unreachable fallback branch disappears; the `if` at line 72 becomes an unconditional call.

**Cheaper fallback.** Make `scrollPosition` non-optional only, deleting the else-branch and the always-true guard while leaving the `cellHeight == 0` sentinel alone.

**Risk.** Low. Test doubles in tests-ui construct `scrollPosition: nil` (ScrollableTerminalViewTests.swift:111,151; SidebarViewTestShim.swift:81; TerminalBackendBoundaryTests.swift:43) and would need updating -- which is the point, since those doubles are currently exercising a state the app cannot produce.

### S60. Drop the unused runRepeating and captureOwnerCensus lifecycle API

`app-runtime` &middot; dead-code &middot; impact 1, confidence 5 &middot; effort small

`app/AppRuntimeSchedulingLifecycle.swift#runRepeating`, `app/AppRuntimeSchedulingLifecycle.swift#captureOwnerCensus`

**Problem.** `AppRuntimeSchedulingLifecycle` exposes two entry points nothing in the app uses. `runRepeating` has no call site anywhere, including tests, and `captureOwnerCensus` is called only by its own unit test even though its doc comment justifies it as being "for termination assertions and diagnostics" - there is no termination assertion. Both make the gate look like it supports a repeating-callback mode and a live diagnostics surface that do not exist, which is a misleading map of the shutdown contract.

**Evidence.** Grepped the whole tree for `runRepeating`: one hit, the definition. Grepped `captureOwnerCensus`: the definition plus three uses inside `app-tests/AppRuntimeSchedulingLifecycleTests.swift`. Every real callback in AppRuntime goes through the one-shot `run(_:action:)`.

**Ideal fix.** Delete `runRepeating` and its category assumptions. Either delete `captureOwnerCensus` with its tests, or make it earn its comment by asserting an empty census at the end of `shutdown()` under debug so a newly added owner that skips the lifecycle is caught.

**Cheaper fallback.** None -- the ideal fix is the only one on the table.

**Risk.** low

### S61. Delete the unreferenced scripts/cursor-color-rainbow.sh

`build` &middot; dead-code &middot; impact 1, confidence 5 &middot; effort small

`scripts/cursor-color-rainbow.sh`

**Problem.** This is the only script under scripts/ with zero inbound references anywhere in the tracked tree: no justfile recipe, no gate step, no doc, no other script. It is an interactive true-color painter for eyeballing cursor contrast, so it is a one-off manual probe that was committed and then never wired up. It shows up in every listing of scripts/ as if it were part of the tooling.

**Evidence.** I counted inbound references for every scripts/_.sh, _.py, _.swift and _.patch by grepping the tree for each basename excluding the file itself, .git, references/, .cmux-ref, and the build trees. cursor-color-rainbow.sh is the sole entry with a count of zero; the next lowest are at one (their justfile recipe or owning doc).

**Ideal fix.** Delete it. Git preserves it, and the surrounding scripts/ directory is otherwise entirely reachable from the justfile, run-test-suite.sh, or a doc -- so "everything here is wired up" becomes an invariant a reader can trust.

**Cheaper fallback.** Keep it and give it a justfile recipe plus a one-line note saying it is a manual visual probe, which makes it discoverable at the cost of another recipe.

**Risk.** Low; the file is standalone and nothing invokes it.

## Area notes

Each auditor's read on the overall health of its area.

**app-runtime.** I read AppRuntime.swift end to end, AppDelegate.swift, Reconcile.swift, AppRuntimeSchedulingLifecycle.swift, AppPresentationLifecycle.swift, PaneHost.swift, IpcServer.swift, DanTermSupport/PaneTapeFollow.swift, Command.swift's `isPostReconcile`, the TODO-popover arms of Update.swift, and the two governing ADRs (2026-05-27 model-driven view reconciliation, 2026-06-09 AppKit lifetime safety). Overall health is good: `perform(command)` is a flat switch but most arms are one or two lines that forward to a session or an IpcConnection, the genuinely long arms (export, pane-tape follow) already delegate their pure halves to DanTermSupport, and the libghostty removal left no vestigial code in this area at all (the only "Ghostty" string left in app/ is a prose comment in LinkPreviewView). Lifetime discipline is strong and is now enforced structurally by `AppRuntimeSchedulingLifecycle`: every timer, monitor, debouncer, subscription and deferred callback is armed with a cancel closure and gated through a token, and I found no escaping closure capturing `self` strongly, no observer without a `deinit` path, and no NSEvent monitor without a stored token. The remaining problems are all about _duplicated truth_: the same fact stored in two places that must be kept in step by hand (session vs. host maps, timer handle vs. token, popover model state vs. NSPopover handle, follow subscription vs. its connection/token/notice sidecars), and one copy-pasted teardown that has already diverged. Two things I noticed just outside this area and am not filing: `send()`'s comment claims only `.focusSearchField` is post-reconcile while `Command.isPostReconcile` also returns true for `.makeFirstResponder`, and `perform` re-enters `send()` from inside the command loop (`.createSession` failure, `.saveDanTermConfig`), so a nested update+reconcile can run in the middle of the outer command phase.

**build.** I read the justfile end to end, dev-build.sh, build-app.sh, dev-build-run.sh, test-ui.sh, scripts/run-test-suite.sh, scripts/core-purity-lint.sh, the two build-contract self-tests (scripts/tests/dev-build-configuration-contract_test.sh, scripts/tests/build-app-helpers-contract_test.sh), both GitHub workflows, the root and lib/DanTermProtocol Package.swift manifests, package.nix, the flake's check list, .gitignore, docs/design/2026-05-28-core-module-via-symlink.md, and agent-docs/build-details.md; I also enumerated scripts/ and counted inbound references to every script. Overall health is high for a one-person project: the gate is well-engineered (parallel pool, per-step capture, an explicit independence contract with its own self-test), the lints are self-tested in both directions, and the symlink/nested-package arrangement is clean with no Zig or xcframework residue anywhere in the tooling (the only "Ghostty" string in the tree outside references/ is one comment in test-ui.sh that explicitly labels itself obsolete, plus .cmux-ref, a locally-excluded unrelated checkout). The real problems are all duplication and divergence at the edges: two bundle-assembly scripts that were copy-pasted and have already drifted in their comments, four hand-maintained copies of the bundle-layout assertion list across the two workflows, and a CI that never runs the local gate at all. The multiple build directories are individually justified in .gitignore comments but total ~3.8 GB across five trees, and one of them (.build-gate) exists solely to isolate a compiler flag nothing enforces. Outside my area I noticed test-ui.sh hand-enumerates ~90 source paths, which is the known cost of the whole-module-substitution harness and is documented in its own ADR, so I left it alone.

**core-model.** I read AGENTS.md, docs/design/index.md, the session-owned-terminal-reported-facts ADR, and then the whole of lib/DanTermCore/Sources/DanTermCore/{Model,ModelOperations,Projections,Persistence}.swift plus the tree/selection/session-report handlers in Update.swift and the TypedId definition in lib/DanTermProtocol. The area is in good shape overall: the "tree owns panes" refactor genuinely removed the dict/tree drift class, SessionModel nesting removed the orphan-session class, SearchMatchStatus and TodoPopoverScope are textbook illegal-state-removal, and the projection layer is clean, pure, and diff-driven with no AppKit leakage. TypedId needs nothing. The remaining problems are all of one shape: invariants that the last refactor left enforced by convention rather than by type. TabModel still lets focus and zoom dangle from its own tree; per-pane side tables still need a manual cleanup chokepoint; the session-report hot path re-derives the pane four extra times because the only session mutator is written in terms of the two whole-model walkers. Two smaller items: four parallel unread-alert implementations of which three have no production caller, and three different "the selected tab died, pick another" policies. Outside this area I noticed only that Persistence.graftScrollback rebuilds GroupSnapshot/TabSnapshot field-by-field (all snapshot stored properties are `let`), so a future snapshot field would be silently dropped by the graft rather than failing to compile -- making those fields `var` and mutating in place would remove the hazard.

**core-reducer.** I read AGENTS.md, docs/design/index.md, and then all of lib/DanTermCore/Sources/DanTermCore/Update.swift (2162 lines), Msg.swift, Command.swift, CoreEnvironment.swift, PaneLifecycleReducer.swift, the relevant parts of Model.swift, ModelOperations.swift (confirmation/MRU/popover reconcile helpers), Projections.swift (desiredQuitConfirmation), TabTodo.swift, plus the app-side senders (PreferencesPanel.swift, TodoPopoverView.swift, TabTodoPopoverView.swift, AlertsPopoverView.swift, AppRuntime.swift command interpreter). Overall health is good: the Command enum is genuinely well-factored with no grab-bag case and an exhaustive isPostReconcile classifier; the "no projection cases in Command" invariant is documented and held; CoreEnv injection is consistent with the SAVED/SENT/ASSERTED rule (every IpcEntityEncoder, toSnapshot, and tabNew cwd path threads env.homeDirectory(); only abbreviateHome/expandTilde leaf renderers use the ambient default, correctly tagged `core-purity: ambient-seam`); and the reducer already delegates real domain work to helpers (reduceSession, mruCycle*, jumpMode*, dispatchIpc, closeTabBody, desktopAlertCommands). The 108 Msg cases are not intrinsically 108 concepts, though: 18 of them are the pane/tab TODO surface written twice, 12 are one preferences field-setter written twelve times, and 8 have no production sender at all. Two smaller things sit just outside this area and I am not filing them: `TabTodoPopoverView.swift` already branches per-row between the pane and tab Msg families (evidence for finding 1 but a view-layer change), and `AppModel.pane(_:)` walks every tab's tree per lookup with several handlers doing three or four such walks per message (a perf question for the model-ops area, and the file already argues the case explicitly).

**docs.** I read AGENTS.md and CLAUDE.md end to end, every file in docs/design/ (headers, banners, References sections) plus index.md, all six agent-docs/ files, docs/research/README.md and FORMAT-adjacent lint (scripts/research-index-lint.sh), the seven docs/scratch/ files by name, plan-terminal-engine/README.md and 14-roadmap.md, integrations/danterm/SKILL.md, and root TODO.md. I spot-checked the claims against code: symlink status of app/DanTermCore and app/DanTermSupport (`git ls-files -s` shows mode 120000), DanTermSupport's manifest (depends only on DanTermProtocol, comment says "Support depends on NOTHING in DanTermCore"), scripts/core-purity-lint.sh and its invocations in scripts/run-test-suite.sh, swift-collections pinned at 1.6.0 in both lib packages, `just fetch-references --list` (11 trees under "terminals", matching AGENTS.md's "ten terminal emulators, libvterm"), and every `just <recipe>` and `path/to/file.ext` cited anywhere in AGENTS.md, agent-docs/, and docs/*.md. Overall health is high: the guidance is unusually disciplined -- superseded ADRs carry dated banners that name the replacement code, the perf docs cross-link rather than duplicate, and the project already lints its research index and its layer purity. Every recipe named in the docs exists. The problems that remain are all of one kind: the *machine-checkable\* parts of the docs (statuses, file citations, command inventories) are maintained by hand and have drifted, while the prose around them is current. Out of scope but noticed: the repo root carries untracked stale checkout dirs (.cmux-src, .cmux-ref, .refs) that AGENTS.md's "Boundaries" section does not cover, and the untracked root TODO.md is a 526-line pasted Claude transcript whose lead item reasons from `.surfaceCwd` and Ghostty's OSC 7 handling -- code that only survives in an old worktree -- so it will mislead any agent that opens it.

**ipc-cli.** I read the whole IPC/CLI surface: `lib/DanTermProtocol/` (CLIParser, IpcRequest, Envelope, IpcLineFramer, Methods, TypedId, SocketPath, EnvVars), `lib/DanTermSupport/IpcConnection.swift` and `PaneTapeFollow.swift`, `app/IpcServer.swift`, the IPC handler block of `lib/DanTermCore/Sources/DanTermCore/Update.swift` (`dispatchIpc`, lines ~1425-1740), the follow-subscription bookkeeping in `app/AppRuntime.swift` (lines 180-200, 505-545, 600-800), the CLI executable (`cli/main.swift`, `cli/PaneTapeFollowStream.swift`, `cli/SkillCommand.swift`, `cli/DoctorConfigFont.swift`), `Package.swift`, and `integrations/danterm/SKILL.md`. The method surface itself is in good shape: `IpcRequestMethod`/`IpcRequest` is one exhaustive typed catalog, encode and decode are pinned against each other by a round-trip test over every method (`lib/DanTermProtocol/Tests/DanTermProtocolTests/IpcRequestTests.swift#everyCLIRequestRoundTripsThroughCatalog`), and I found no one-off or duplicate method -- `pane read`, `pane rows`, and `pane tape` are three genuinely different projections, not three spellings of one. SKILL.md's command table matches `parseCLI` line for line; the only mismatch I found is the `--socket`/`doctor` interaction below. The real weight sits in the CLI process and the app-side follow bookkeeping, not the protocol. Outside my area I noticed only that `Update.swift` is a ~1700-line file whose IPC handler section is a third of the switch, which the ipc-core boundary owner may want to look at.

**pty.** I read `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift` end to end, `lib/TerminalPTY/Sources/TerminalPaneSession/TerminalPaneSession.swift` end to end, plus `PaneProcessLifecycle/PaneProcessLifecycle.swift`, `TerminalPTYHost/InFlightLaunch.swift`, `TerminalPTYHost/ResizeCoalescer.swift`, `TerminalPTYHost/TerminalFlightRecorder.swift` (record/slot path), `TerminalCoreRecording/NeutralTerminalRecording.swift#NeutralTerminalRecordingEvent`, and `TerminalCore/Terminal.swift#feed`, plus the design docs `2026-08-05-pane-session-lexicon.md` and the AGENTS layering/design-bar sections. Overall health is high: the lifecycle policy _is_ an explicit pure state machine (`PaneProcessLifecycleReducer#Storage`), concurrency is consistent (one `DispatchSerialQueue` doubling as the actor's `unownedExecutor`, so dispatch sources, actor jobs, and `queue.sync` fences all share one FIFO -- no ad-hoc second queue, and the two `Mutex`-bearing helpers are deliberately the submitting side of a queue hop and are well argued in their own file headers), and the ownership/quiescence invariants are unusually carefully reasoned. What is not clean is the boundary between that explicit reducer and the host: the host holds a second, implicit machine in booleans, and one of those (`deferredCommandsAfterMasterClose`) exists purely because the reducer models an asynchronous close as synchronous. Roughly a third of the host's stored state and its exported surface is test scaffolding living in the production actor, and the transition-capture half of that scaffolding duplicates the flight recorder it sits next to. Out of scope but noticed in one clause: `PaneProcessLifecycleReducer.phase` and `PaneProcessLifecyclePhase` are public API with no non-test caller anywhere in `lib/` or `app/`, and the same `guard isTornDown == false else { return }; host.x()` forwarder shape repeats about fifteen times in the controller, which is idiomatic rather than a defect.

**scrollback.** I read all 3,399 lines of lib/TerminalCore/Sources/TerminalCore/LogicalLineStore.swift (nested types and stored state, census/charge, all five mutating operations, the width change, the reads, the fold, arena writing, ring discipline, index maintenance, and the trailing `RingBuffer`), plus the relevant slices of Terminal.swift (`enforceScrollbackBudget`, `syncHistoryEvictions`, counter record sites), lib/TerminalCore/Package.swift, and the seven `TerminalLogicalLine*` probe/test files. The core data model is in good shape: history is one arena of width-free logical-line records, the index is genuinely derived, and the hand-rolled `RingBuffer` is well justified against `Deque` in its own doc comment (it must report allocated capacity and never shrink, which is what makes the 8 B/record charge and `research/31/DD11`'s "capacity does not grow" checkable -- `Deque` exposes neither), so I do not think swift-collections belongs here. The problems are all around the model rather than in it: derived totals kept as a second copy, side-table bookkeeping and its byte charge smeared over ~15 call sites with three different emptiness guards, seven copy-pasted instrumentation enums squatting at the top of the file, and roughly 3,000 lines of pre-decision prototype arenas still compiled into the test target. Two smaller things I am not filing: `paintedRow(at:)` and `gridRow(recordIndex:rowWithinRecord:)` are the same nine lines differing only in `includeFill`, and the "prompt becomes `.continuation` on a non-first row" rule is written out three times (lines 1072, 1664, 2327) -- one `row(at:includeFill:)` collapses both. Outside my area, `Terminal.swift` is the only other place these task-local counters are recorded from, which is part of why they do not belong in the store's file.

**sidebar.** I read app/SidebarView.swift end to end, app/PaneStripView.swift, app/BadgeLabel.swift#visibleAlertBadge, app/Reconcile.swift#reconcileSidebar, lib/DanTermCore/Sources/DanTermCore/SidebarItemStore.swift, the sidebar section of lib/DanTermCore/Sources/DanTermCore/Projections.swift (SidebarTabProjection through advanceSidebarCache), and all five tests-ui/Sidebar\*Tests.swift plus SidebarViewTestShim.swift, alongside `git show` of the two recent reworks (247f8dc8 "paint every row from its own projection", cf3c4b00 "resolve tab chrome inside the tab's own tree"). The projection rework landed cleanly: the store, the row-op executor, and both cell configurators really do read only SidebarTabProjection/SidebarGroupProjection, the retained-cache retry (advanceSidebarCache + unapplied ids) is coherent, and I found no leftover model re-derivation in the render path and no libghostty residue. What the rework did leave behind is a second, parameter-driven paint path for group collapse chrome (applyGroupCollapseState), an AppModel snapshot in the view that is now only used by the interaction path, and the untyped cell layer underneath everything: six sites reach into cells by string identifier, which is where the remaining sidebar bugs (blank titles, dropped badge repaints) historically came from. The test tree mirrors reconcileSidebar's pipeline in three independent copies. One out-of-area note: SidebarItemStore.displayedTabItem is production code with no production caller (tests only), and the same string-identifier coupling exists in the pane toolbar chrome, which I did not audit.

**terminal-core.** I read all of lib/TerminalCore/Sources/TerminalCore/Terminal.swift (7,894 lines: the full declaration list, the CSI/ESC/OSC dispatch block, mode application and reporting, save/restore and screen swapping, the print/bulk-ASCII path, damage snapshotting, the width-reflow anchor machinery, the search index and its two scanners, and the eviction/invalidation paths), plus TerminalInputStream.swift, EscapeAbsorber.swift, the counter preludes in LogicalLineStore.swift, and references/ghostty/src/terminal/modes.zig for mode-table compatibility only. Overall health is high: this is unusually well-reasoned code, nearly every cache and counter carries a measured justification and a named research citation, and the hot paths (bulk ASCII, style interning, damage shifts) are argued from evidence rather than habit. I found no vestiges of the removed libghostty backend anywhere in lib/ sources -- the only "Ghostty" strings left are in test names and a recorded replay corpus, which are legitimate evidence artifacts. The problems that remain are all the same species: the file is one 7,778-line struct body with no extensions and no internal seams, and several logically-single concepts (a screen, a mode, an anchored range, a link interaction) are spelled out as parallel hand-maintained lists at four to six sites each, so correctness depends on a human enumerating the same set correctly every time. Two of those have already produced observable consequences (private mode 12 is unimplemented while the state it would set exists; `resetControlState` needs a special-case reach into the inactive screen). Out of scope but worth one clause: `LogicalLineStore.swift` carries four near-identical task-local tally counters (`LocateCounter`, `ProjectionRowCounter`, `WholeProjectionCounter`, and `SearchIndexMaintenanceCounter` over in Terminal.swift) that one generic type would collapse.

**terminal-views.** I read app/SwiftTerminalSessionView.swift in full, app/ScrollableTerminalView.swift in full, app/PaneWrapperView.swift in full, lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift in full, plus TerminalFrameSwapchain.swift (head), app/TerminalSession.swift, lib/TerminalPTY/.../TerminalGridSizing.swift, lib/TerminalCore/.../TerminalInteractionPolicy.swift, tests-ui/SwiftTerminalSessionViewTestShim.swift, and the AppRuntime.refreshSessionsForScreenChange caller, and read docs/design/2026-03-05-display-scaling.md. Overall the engine/AppKit boundary here is in good shape and the T25 surface work clearly paid off: there is exactly one render path (`present`), `updateLayer()` is deliberately empty, `draw(_:)` is gone, and there is no second dirty-tracking layer in the view -- damage lives only in the swapchain. Pixel geometry is derived in exactly one place (`TerminalRenderMetrics.init`) and every drawing site goes through `cellRect`/`glyphOrigin`, so the display-scaling invariant is structurally held rather than restated. The problems I did find are all at the _edges_ of that boundary: the view keeps its own mirror of the swapchain's construction inputs and has two overlapping detectors for "a presentation input moved", one of which a real caller skips; the pointer path re-derives grid extents the clamping helper already computed; the UI-test shim re-implements two pieces of geometry policy with weaker semantics; and one session-state field carries optionality no producer uses. Outside my area I noticed only that `terminalRows(intersecting:)` is now a GlyphPreview/test-only entry point rather than a pane one (still legitimately used, so not filed), and that PaneWrapperView's `hasSplits`/`isZoomed` are cached copies of model facts the menu builder could read from `runtime.model` directly.

**tests.** I read AGENTS.md, docs/design/2026-08-06-ui-harness-whole-module-substitution.md, scripts/run-test-suite.sh and its self-test scripts/tests/run-test-suite_test.sh, test-ui.sh, both Package.swift manifests (root and lib/DanTermProtocol), the full test inventory (lib/DanTermCore/Tests 26.8k lines, lib/TerminalCore/Tests 42.7k, lib/TerminalPTY/Tests 6.5k, lib/DanTermSupport/Tests 1.8k, lib/DanTermProtocol/Tests 1.6k, tests-ui 9.7k, app-tests + cli-tests 0.9k), and then read in detail TerminalPTYHostTests.swift, TerminalInteractionPolicyTests.swift, TerminalSearchTests.swift, GoldenMasterTests.swift plus its committed snapshot, DeterminismSeamTests.swift, TestSupport.swift, ModelOperationsTests.swift section headers, both TerminalBackendBoundaryTests, and the nine TerminalLogicalLine*/History* probe files. I also used `git log` to establish churn and to show which tests changed under behavior-preserving refactors. Overall health is high: the pure-core suite is large, behavioral, and genuinely structure-insensitive (the ReconcileTests preamble explicitly calls out its "structure-insensitive model-apply gauntlet"), TerminalCore's coverage of the engine is exceptional, and the gate script is thoughtfully built as a bounded pool with its own contract test. The problems are concentrated at the edges: real-PTY tests doing work the headless engine suite already does, a whole-model snapshot that ratchets on refactors, a large body of frozen research probes carried in the default test target, and the app/ runtime layer -- the second-highest-churn file in the repo -- having essentially no automated coverage at all. One thing outside my area that I noticed while reading app/Reconcile.swift: its header describes an in-progress migration whose step 4 is "delete the matching Command case + its perform arm", which suggests some Command cases may now be vestigial -- worth a look by whoever audits app/.

## Not audited

The twelve areas were chosen from a file-size and churn survey, so coverage
is uneven by construction. These parts of the system got no owner, and the
absence of findings about them means nothing. Several are large: rendering
and the VT parser are two of the biggest engine subsystems in the repo.

- Rendering and the frame pipeline: TerminalRenderExecution, frame planning, damage-to-draw translation, the glyph atlas, sprite classification and geometry (docs/terminal-sprites.md), and Metal/IOSurface resource lifetime. Only incidental mentions via TerminalFrameSwapchain; no auditor owned this area, and it is one of the two largest engine subsystems.

- The VT parser and grid data model proper: the escape-sequence state machine, UTF-8 and charset handling, Cell/Style/attribute storage and packing, and the width-change reflow algorithm. The terminal-core auditor audited Terminal.swift's structure (modes, screens, search, OSC) but not the parsing or cell-storage code beneath it.

- Keyboard input: key encoding, the kitty keyboard protocol implementation, modifier and dead-key handling, IME / marked text, and the input path from NSEvent to PTY write. Kitty state appeared only as a per-screen field to be boxed.

- Persistence and recovery: the pure snapshot/restore codec, RecoveryStore path resolution and file IO, the session lock, checkpoint scheduling policy and crash-recovery correctness. Touched only as a Command arm and a scratch-path detail.

- DanTermSupport as a layer: socket lifecycle and IpcConnection, the CLI-path installer, timer utilities. Only PaneTapeFollow.swift was examined, and only from the runtime side.

- Configuration and theming: config file parsing and validation, the theme format and resolution, bundle-theme-resources.sh outputs, the theme browser, and the preferences panel view (the reducer's preference handling was audited; the config and view halves were not).

- Remaining AppKit views: PreferencesPanel, the pane/tab TODO popovers, AlertsPopoverView, the switcher, window and tab chrome, menus, drag-and-drop (DragDropInput, DropZone) and ScrollbarMath. Only SidebarView and the terminal views were audited, and several findings assume changes in these unaudited views.

- Concurrency correctness as a class: actor boundary discipline in TerminalPTYHost, the `@unchecked Sendable` tally classes, main-thread assumptions in the runtime, reentrancy in send()/reconcile, and Swift 6 strict-concurrency readiness. No auditor covered it, yet several proposed fixes (reusable read buffer, modal alert inside reconcile, unified task-local instrument) turn on exactly these questions.

- Error handling and failure policy as a class: where the code returns silent nil versus throws versus crashes. Individual instances surfaced (seven preconditionFailures in fence unwrapping, silent nil paints in sidebar cells, silently dropped follow subscriptions) but nobody audited the policy, and the pattern 'failure path is silence' recurs across at least four areas.

- Security and permissions: IPC socket permissions and authentication, notification-permission handling, what an arbitrary local process can do over the control socket, and the doctor's permission model. Nothing in the corpus.

- Shell integration and Nix packaging: the bash/zsh/fish integration scripts, danterm-hooks, vendor/bash-preexec.sh, the flake, and the home-manager module. The build-tooling auditor covered the scripts that stage these and the CI that checks them, but not their contents -- and CI's only real checks today are the Nix ones.

- Public API surface of the lib/ packages: what is `public` and why, and whether the module boundaries hold as designed. The CLI finding shows one boundary failing by construction; nobody checked the others.

- Terminal compatibility as a behavioral class: conformance against the reference emulators and terminfo, beyond the two mode gaps found incidentally. No auditor was assigned to compare behavior against references/.

Two of these gaps are worth a second pass on their own terms. Concurrency
correctness is not just uncovered -- several proposed fixes here (the
reusable read buffer, running a modal alert inside a reconcile sweep, one
shared task-local instrument) turn on questions only that audit answers.
And "failure path is silence" surfaced independently in four areas without
anyone auditing error policy as a class.
