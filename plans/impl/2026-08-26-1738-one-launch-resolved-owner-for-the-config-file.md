# One launch-resolved owner for the config file

## Problem

Which config file a DanTerm process owns is derivable from ambient state
anywhere in the tree, so config isolation is a property of who remembers to
override rather than a property of the structure.

Evidence:

- `DanTermConfigPaths.configFilePath()`
  (`lib/DanTermSupport/Sources/DanTermSupport/DanTermConfigPaths.swift:11`)
  builds the path from `NSHomeDirectory()` and any leaf may call it.
- `DanTermConfigStore.init` (`app/DanTermConfigStore.swift:46`) defaults `url:`
  to that call, and `AppRuntime.init` (`app/AppRuntime.swift:264`) defaults
  `configStore` to a store built that way. `AppDelegate.swift:59-70` never
  passes one, so the app's live config path is reached only through a defaulted
  argument and is never named at launch. The same initializer documents
  `dialogSurfaces` and `instancePaths` as having no default because "a runtime
  built without naming them does not exist" (`app/AppRuntime.swift:255-259`).

Three defects follow from that one property:

- **A dev slot is not isolated.** `DanTermInstancePaths` namespaces the control
  socket, both checkpoint tiers, the session lock, the IPC audit log, and the
  replay directory per instance; config sits outside it, so all eight pool
  slots, the canonical dev app, and production share one file. A Preferences
  save in a slot rewrites it (`app/AppRuntime.swift:1001`) and Open Config seeds
  it (`app/AppRuntime.swift:1408`). `scripts/dev-slot-launcher.py:2`,
  `justfile:312`, `agent-docs/dev-loop.md:9`, and `SKILL.md:182` all call slots
  isolated without qualification. The one place the sharing is admitted is the
  tailnet carve-out (`app/AppLaunchPolicy.swift:36-38`, `SKILL.md:209`), which
  exists only to stop eight slots from acting on one inherited endpoint.
- **No hermetic config for a harness.** Setting DanTerm's font family or size
  for a benchmark means mutating the user's file and restarting, and two
  variants cannot run at once. `scripts/terminal-benchmark.sh:225` and
  `scripts/terminal-viability.sh:309` work around this by overriding `HOME`
  *and* `CFFIXED_USER_HOME`; the config lands in the runtime root only because
  the second variable happens to steer `NSHomeDirectory()`. Both then assert the
  launch probe's `config` key stays inside that root, and that key is the one
  entry in the probe not taken from a launch-resolved value
  (`app/main.swift:44-53`).
- **One doctor run has two homes.** `DoctorProbeEnv.live` resolves
  `homeDirectory` from `$HOME` but `configFilePath` from `NSHomeDirectory()`,
  which ignores `$HOME` on macOS, so a doctor run under an overridden home
  probes agent files in the fixture home and the config file in the developer's
  real home -- which is what `scripts/tests/danterm-cli_test.sh`'s doctor block
  does today. Recorded as SUPPORT-2 in
  `docs/scratch/2026-08-26-improvement-audit.md`; this change subsumes it.

Load-bearing premise: the seams this needs mostly exist and are unused.
`DanTermConfigStore` already takes its URL as an argument and every store test
injects one; `DoctorProbeEnv.configFilePath`
(`lib/DanTermSupport/Sources/DanTermSupport/DoctorProber.swift:14`) is already
an injectable input and only `.live` re-derives; and
`app-tests/TemporaryInstancePaths.swift:26` already carries an `absentConfigURL`
beside the instance paths so no test writes the user's config. Only three
non-test callers of `configFilePath()` exist.

## Decision

The config file becomes an explicit launch-resolved value, threaded down the
channel that already carries the instance paths, and re-deriving it becomes a
lint failure.

- **A value of its own, beside `DanTermInstancePaths`, not a field on it.**
  That type is a derivation -- identity plus three roots in, seven paths out --
  and its invariant is that everything it yields is identity-keyed. The config
  file is not: production and the canonical dev app are two identities that
  deliberately read one file, and that stays true after this change. Only pool
  slots diverge, and that is launcher policy, not a function of identity. A
  stored field that is both a bare input and a final output would make the
  derivation a bag and make the type's name false.
- `DanTermConfigStore.init` loses its defaulted `url:`, and `AppRuntime.init`
  loses its defaulted `configStore:`. A store that was not told which file it
  means cannot be constructed.
- The app accepts a `--config <path>` launch argument, resolved before the
  launch path probe reads it. Absent, launch resolves the standard per-user
  file. Present but unusable -- no value, or given more than once -- launch
  fails instead of falling back: a silent fallback would point a harness or a
  slot at the user's file, which is the defect this change removes.
- `scripts/ambient-identity-lint.sh` gains two rules, each with **its own**
  allowlist rather than an extension of the existing one (appending would
  license the config seam to resolve user-domain roots, and the paths seam to
  spell config strings): one rejecting the `DanTermConfigPaths` symbol, one
  rejecting the literal `.config/danterm` path fragment. The `NSHomeDirectory()`
  seams in `DanTermCore` are untouched; the rules name the config resolver, not
  the home directory.
- **The CLI becomes a fourth named seam.** `DoctorProbeEnv.configFilePath`
  loses its default and `cli/main.swift` resolves it once, from the same home
  the rest of its probes use -- the same carve-out `userControlSocketPath`
  already has for bare executables that own no launch-resolved value. Doctor's
  own probe file is not allowlisted; it is the re-derivation being removed.
- **Each slot is launched against a config file of its own, starting from
  defaults.** The launcher passes `--config` at a path under the slot root it
  already owns, alongside `locks/`, `logs/`, and `apps/`, and clears any file
  left there. A slot number is an allocation nobody chose, so slot state that
  persists across claims would hand one agent whatever another left behind; the
  checkpoints already work that way and do not need a second instance of it.
  An absent file already loads defaults, so the ordinary case writes nothing.
  The clear belongs to the launch path, after a claim succeeds -- never to the
  lock acquisition that `--list` also performs, which would let a survey delete
  a running slot's config.
- **The tailnet launch opt-in is deleted** -- `AppLaunchPolicy.tailnetOptIn`,
  the app's `--tailnet` argument, and `optedIn` on
  `DanTermTailnetActivation.resolve`. Its only rationale is the shared file, and
  a slot whose config names no endpoint already falls out of `resolve` at the
  first guard. `just launch-slot --tailnet` becomes the launcher writing the
  user's tailnet endpoint and admitted nodes into that slot's config as a
  regular file -- never a symlink to the user's config, which would undo the
  isolation. The launcher's flag, its status fetch, and the handle's `tailnet`
  object are unchanged, so `scripts/ios-app.sh` keeps working as written.
  **Ordering constraint:** the launcher must seed the endpoint before the gate
  is deleted, or `just ios-app --slot <n>` breaks in between.
- **The launcher is told the standard config path; it never spells it.** The
  seed has to read the user's config, and a `~/.config/danterm` literal in
  Python is a second resolution no Swift lint can see. The launcher already
  delegates every identity-derived fact to the bundled identity tool
  (`scripts/dev-slot-launcher.py:236-253`), and that tool is the natural
  carrier: it resolves the standard path through the allowlisted seam and
  reports it in the JSON the launcher already parses. Its role widens from
  identity to launch facts, and its name should follow.
- **`danterm doctor` learns the config path from the running app** rather than
  from a flag: the app is the only authority on which file it read, and a flag
  would be a third answer. The existing `doctor.permissions` method and its
  `DoctorFacts.Permissions` payload become an app-facts reply carrying the
  permissions and the resolved config path together, rather than a path bolted
  onto a type named for permissions. Doctor probes the path it is given and
  names it in its messages instead of hardcoding `~/.config/danterm/config.json`
  (`cli/Doctor.swift:329,336`). With no app answering, doctor probes and reports
  its own resolved standard file.

Why not a plain `--config` argument with the ambient default left callable: it
unblocks the harness and leaves the defect. The static stays reachable, the
store keeps a default that resolves it, and slot isolation stays a convention
the next reader can forget.

## Invariants

- **I1.** No component resolves which config file the process owns. The location
  is an input, resolved once at launch and handed down; a config store that was
  not told which file it means cannot be constructed.
- **I2.** The standard per-user config path is named in exactly one place, and
  reached only through the launch seams. A second resolution -- through the
  symbol or by spelling the path -- fails the lint, and no process outside the
  swept trees spells it either.
- **I3.** A launcher pool slot reads and writes only its own config file. No
  slot operation -- launch, reload, Preferences save, Open Config -- can modify
  the user's config file, and no slot inherits config another claim left behind.
- **I4.** An instance opens a tailnet listener exactly when activation yields an
  endpoint from the config it was given and its own identity. Every existing
  refusal reason survives; being a pool slot is no longer one of them.
- **I5.** `danterm doctor` reports on the config file the targeted instance
  read, and names that path in its messages. With no instance answering it
  reports on the standard file derived from the same home as its other probes.
- **I6.** Production behavior is unchanged: launched with no config argument, an
  instance reads and writes `~/.config/danterm/config.json`, including when that
  path is a symlink managed outside DanTerm.

## Proof obligations

One entry per invariant or load-bearing premise; one test may discharge several.

- **PO1 (I1, I6).** Launch resolution: given a config argument the process owns
  that file; given none, it owns the standard per-user file; given a malformed
  or repeated argument, it fails rather than owning either.
- **PO2 (I2).** The lint rejects both a symbol re-derivation and a hand-spelled
  config path added anywhere in the swept trees, and accepts each allowlisted
  seam; its self-test proves both verdicts on a fixture tree, and a rename of
  the config seam fails the stale-entry check.
- **PO3 (I3).** A store pointed at one file leaves another untouched across
  seed, save, and reload.
- **PO4 (I3).** Two instances given different config files resolve different
  fonts from them, with no interference.
- **PO5 (I4).** Tailnet activation depends only on the given config and the
  identity: a pool slot with a usable endpoint activates, one without does not,
  and each existing refusal reason still reaches its case. This replaces the
  opt-in coverage in `AppLaunchPolicyTests` and `TailnetActivationTests`.
- **PO6 (I5).** Doctor reads and reports the file the app named, not the
  standard one, when the two differ and an app answers; it reads and reports the
  standard one when none does -- including under an overridden home, where the
  probed config and the probed agent files now share one home.
- **PO9 (I2, I3).** The launcher reads the standard config only as the seed
  source the seam reported, and clears and writes only the slot destination it
  derived itself: the source stays byte-identical across an ordinary launch and
  a `--tailnet` launch, a seeded destination carries the tailnet settings and
  nothing else from the source, and a slot survey touches no slot's config.
- **PO7 (I6).** The existing symlinked-config transaction behavior survives: a
  save through a symlinked config updates its target and preserves the link.
- **PO8 (I3, end to end).** A slot launched with no config argument leaves the
  user's config file byte-identical after a config-writing operation.

## Non-goals / Accepted risks / Rejected ideas

- Non-goal: changing the config schema or which settings exist.
- Non-goal: a live IPC command to set config values on a running instance. This
  change makes one safe to add later; it does not add one.
- Non-goal: umask-default creation of config artifacts. A slot's config is the
  same hand-editable class and keeps that exemption, so
  `scripts/private-file-mode-lint.sh` is untouched.
- Non-goal: the home-manager module, which manages the standard per-user path
  and is unaffected by a default that still resolves to it.
- Non-goal: converting the benchmark harnesses off their `HOME` override. They
  gain the ability to name a config; relocating home still does what it does.
- AR1: a slot starts from default settings, so it no longer looks like the
  user's terminal, and `Open Config` in a slot opens that slot's file. This is
  the behavior change the isolation is made of, and `just launch-slot` offers no
  opt-out: a slot's config path is the launcher's, not a caller's.
- AR2: a slot's tailnet endpoint is a snapshot taken at claim time. Editing the
  real config's tailnet block does not reach a running slot -- which was already
  true, since config is read at launch.
- AR3: the config path becomes a required field on the app-facts IPC reply, so a
  new CLI against an older app reports those facts as unavailable. One user, who
  upgrades by replacing the app.
- RI1: a plain `--config` argument with the ambient default left callable. See
  the Decision.
- RI2: folding the config URL into `DanTermInstancePaths`. It would make one
  value own every path, but the config file is not identity-keyed, and the field
  would be a stored input that is also a final output -- the first pass-through
  in a type whose whole claim is that its outputs are derived. If a second
  user-keyed path ever appears, the honest move is renaming the type to a launch
  paths value, not smuggling one in.
- RI3: isolating a slot's config by relocating `HOME`, as the benchmark
  harnesses do. It isolates config only as a side effect of moving the whole
  home directory, and changes what the panes' shells see.
- RI4: seeding a slot's config as a copy of the user's. It keeps a slot looking
  familiar, but adds a third answer to "which config is this" and goes stale
  silently.
- RI5: a `--config` opt-out on `just launch-slot`, handing a slot a
  caller-named file. It would make I3 conditional on a flag, which is the
  property the change exists to establish; a harness that wants a chosen config
  launches the app directly, as the benchmark scripts already do.

## Critical files

- `app/LaunchInstancePaths.swift`, `app/main.swift` -- the new resolver and
  argument, and the launch path probe's `config` key.
- `lib/DanTermSupport/Sources/DanTermSupport/DanTermConfigPaths.swift` -- reduced
  to a home-taking standard default.
- `lib/DanTermSupport/Sources/DanTermSupport/InstancePaths.swift` -- the header
  clause that names `DanTermConfigPaths` as the owner of user-keyed paths.
- `app/DanTermConfigStore.swift`, `app/AppRuntime.swift`, `app/AppDelegate.swift`
  -- defaulted arguments removed.
- `app/AppLaunchPolicy.swift`, `app/IpcServer.swift`,
  `lib/DanTermProtocol/Sources/DanTermProtocol/TailnetActivation.swift` -- the
  opt-in gate and its plumbing, deleted.
- `scripts/ambient-identity-lint.sh`, `scripts/tests/ambient-identity-lint_test.sh`
  -- rule/allowlist pairs and their fixtures.
- `scripts/dev-slot-launcher.py` -- the per-slot config path in `app_arguments`,
  the clear on the launch path, and the `--tailnet` seed; its docstrings
  currently explain `--tailnet` in terms of the shared config.
- `tools/DanTermInstanceIdentityTool` -- the standard config path added to the
  facts it reports, and its widened role.
- `Package.swift` -- the tool imports only `DanTermProtocol` today, so reporting
  the standard path adds a `DanTermSupport` dependency on its target; the edit is
  governed by
  [docs/design/2026-08-17-package-owns-its-targets.md](docs/design/2026-08-17-package-owns-its-targets.md).
- `lib/DanTermSupport/Sources/DanTermSupport/DoctorProber.swift`,
  `cli/main.swift`, `cli/Doctor.swift`, and the app-facts IPC payload in
  `lib/DanTermProtocol` -- the reported path.
- Tests: `tests-ui/DanTermConfigStoreTests.swift` (symlink transaction),
  `app-tests/TemporaryInstancePaths.swift` and the call sites that build a store
  from `absentConfigURL`,
  `lib/DanTermSupport/Tests/.../DoctorProberTests.swift`,
  `cli-tests/DoctorEvaluatorTests.swift` (asserts the hardcoded path strings),
  `scripts/tests/danterm-cli_test.sh` (its doctor block changes for two
  independent reasons), `scripts/tests/dev-slot-launcher_test.py` (asserts
  `--tailnet` adds one argument and nothing else),
  `app-tests/AppLaunchPolicyTests.swift`, `app-tests/IpcServerRemoteTests.swift`,
  `lib/DanTermProtocol/Tests/.../TailnetActivationTests.swift`.
- Docs: `docs/design/2026-05-28-pure-core-support-split.md` (the section
  recording config as outside the one-owner rule, and the seam count in the
  identity-lint discussion), `AGENTS.md` (the "one value derives every
  filesystem path" sentence, which must name both values),
  `agent-docs/dev-loop.md`, `integrations/danterm/SKILL.md` (the isolation
  section, the tailnet carve-out at :209, the doctor font row at :922), the
  `justfile` comments, and `docs/scratch/2026-08-26-improvement-audit.md`
  (SUPPORT-2, subsumed).

## Verification

1. TDD per proof obligation. Targeted suites during the loop:
   `swift test --package-path lib/DanTermSupport`,
   `--package-path lib/DanTermProtocol`, and `just lint` (which runs both lint
   self-tests and the launcher's Python suite).
2. `just test` before each commit.
3. I3 end to end (PO8): hash the user's config, `just launch-slot`, change a
   setting through that slot's Preferences, confirm the slot's own file changed
   and the user's hash did not, then `just stop-slot`.
4. I4 end to end: `just launch-slot --tailnet`, confirm the handle reports a
   listening endpoint, and confirm `just ios-app --slot <n>` still connects.
5. The original motivation: launch the app directly twice, as a harness does,
   with two `--config` files naming different font sizes, and confirm each
   renders at its own size. Not through `just launch-slot`, which owns its
   slot's config path.

## Commit progress
- [x] 1. feat(config): resolve the config file once at launch
- [x] 2. refactor(cli): give the CLI its own config seam and lint the rest
- [x] 3. feat(dev): give every launcher slot its own config file
- [x] 4. refactor(tailnet): delete the launch opt-in gate
- [ ] 5. feat(cli): report the config file the instance actually read

## Implementation notes

- Commit 1. `--config` takes its path as the next token. An empty value, or one
  starting with `--`, counts as no value, so a launcher whose path expanded to
  nothing fails instead of owning a file named `--fresh`.
- Commit 1. `DoctorProbeEnv.live` still resolves the standard path from
  `NSHomeDirectory()`, now through the home-taking spelling. The `$HOME` fix and
  the lint rules belong to commit 2, which makes the CLI a named seam.
- Commit 1. `tests-ui` gained `uiTestAbsentConfigURL()`: `AppDelegate` now needs
  a config file, and `AppRuntime.configStore` is private, so the three delegate
  call sites name a path that deliberately does not exist.
- Commit 2. `DoctorProbeEnv.live` became `live(home:configFilePath:)`, and the
  private `$HOME` resolver became the public `danTermProcessHomeDirectory`. The
  CLI resolves the home once and derives the config file from it, so the two
  cannot drift apart again; deriving the file inside the prober would have been
  the re-derivation the rule rejects.
- Commit 2. `cli/Doctor.swift` is allowlisted against the config-path rule
  because its report text names the standard file. That entry goes away in
  commit 5, when doctor names the path the instance reported instead.
- Commit 2. `docs/scratch/2026-08-26-improvement-audit.md` is untracked in this
  worktree, so SUPPORT-2 is not marked subsumed here.
- Commit 3. The tool's widened role took the name `DanTermLaunchFactsTool`, and
  its bundled helper `Contents/Helpers/danterm-launch-facts`. The bundle-layout
  entry, the launcher's resolver, and the docs follow.
- Commit 3. A slot's config lives at
  `<slot root>/config/slot-<n>.json`, and `launch_slot_app` derives it from the
  slot root it already holds. Neither `main()` nor any flag can name it, which is
  RI5 made structural rather than documented.
- Commit 3. `app_arguments` takes `config_path` as a required keyword. A slot app
  that was not told which file it means cannot be spawned -- the launcher's half
  of I1.
- Commit 3. The `--tailnet` seed carries `schemaVersion` over from the user's
  config rather than writing the constant, so the launcher is not a second author
  of the config format. A source that names no version, holds no tailnet block, or
  does not parse seeds nothing, and the slot then reports the app's own refusal.
- Commit 3. The `justfile` comments still call a slot isolated without
  qualification. That reads as a defect in the plan's evidence, but the sentence
  is now simply true, so nothing there needed changing.
- Commit 4. `IpcServerRemoteTests` had two tests whose only disabled reason was the
  deleted gate. One becomes the pool-slot activation proof; the other, which pins
  the seeded disabled reason in the model, now uses a bundle outside the offset
  table, the remaining refusal the fixture's config can reach.
- Commit 4. The launcher keeps its own `--tailnet` flag and drops only the app
  argument it forwarded, so `app_arguments` no longer takes `tailnet`. Its test
  now asserts no launch argument mentions the tailnet at all.
