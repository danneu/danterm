# Per-instance tailnet endpoints, opt-in slot listeners, bind retry, visible status

## Context

The tailnet listener (config `tailnet.listen` + `tailnet.admittedNodeIds`) lets the
iOS client reach a DanTerm instance. Today every instance -- production, dev slot 0,
and all eight launcher pool slots -- reads the same config file and races to bind the
same address:port. The first wins; every other instance fails soft into an audit log
nobody reads. The iOS client persists host:port targets, so it cannot selectively
connect to a specific instance. And because the bind happens once at launch, a Mac
that starts DanTerm before Tailscale is up has a dead listener until someone at the
keyboard restarts it -- which defeats the remote use case exactly when the user is
away.

Desired outcome: every instance owns a stable, predictable tailnet endpoint the
phone can save once; pool slots open a listener only when explicitly asked; a failed
bind recovers on its own; and the listener's state is visible instead of silent.

## Decision

- **Derived ports, uniformly.** Config's `tailnet.listen` port becomes a *base*.
  Each instance binds base address : base port + a fixed offset from its
  `DanTermInstanceIdentity`: production +0, dev slot N (0-8) +1+N. Identities with
  no defined offset (harness bundles) open no listener. No instance ever
  auto-chooses a substitute port: a taken port likely means a zombie instance still
  listening with the user's admitted node ids, and that must surface, not be routed
  around. The phone saves "production = base, slot N = base+1+N" once.
- **Pool slots are opt-in.** `just launch-slot --tailnet` (and `-optimized`) passes
  a new `--tailnet` app argument through `AppLaunchPolicy`; a pool slot launched
  without it ignores the config's tailnet block entirely. Production and dev slot 0
  need no flag. The `launch-slot` justfile recipes gain argument passthrough.
- **Launch-frozen config, retrying bind.** Tailnet config still applies only at
  launch (upholding the existing "no live config reload for the listener" stance;
  the prefs pane is read-only for tailnet and says "applies at next launch"). New:
  a failed bind attempt is retried on a modest interval with the same launch-frozen
  config until it succeeds or the app quits, so a login-time race with Tailscale
  self-heals. Deterministic derivation errors (malformed base, port overflow past
  65535) disable the listener instead of retrying.
- **Status is observable in three places.** A status value
  (disabled-with-reason / waiting-with-reason / listening-on-endpoint) flows from
  the server into the Elm model and out through: (a) a read-only tailnet section in
  the preferences panel, showing the committed config, this instance's derived
  endpoint, and live status; (b) a new IPC method `tailnet.status` plus a
  `danterm tailnet status` CLI subcommand; (c) a new `tailnet` field in the slot
  launch handle JSON, fetched by the launcher over the control socket -- on
  `--tailnet` launches only. A slot launched without the flag gets no status query
  and no `tailnet` field, so the default launch path every agent uses keeps
  exactly today's reliability. The app is the sole deriver of endpoints and the
  sole author of status -- the launcher and CLI never compute ports or synthesize
  a status object.
- **`tailnet.status` is callable by remote peers.** It reveals only facts a
  connected remote peer has already proved by reaching the endpoint. It produces an
  audit record like every method except `ping`.
- This deliberately reverses the prior listener plan's "no UI surface" non-goal and
  answers its deferred "drive a listener on a dev slot without editing the shared
  config" item. Admission, cap, write-ahead audit, and refusal-shape invariants
  from that work are untouched.

## Invariants

- I1 **Closed by default.** An instance opens a tailnet listener only when config
  names a base endpoint with a non-empty admitted-node list, its identity has a
  defined port offset, and -- for launcher pool slots -- it was launched with
  `--tailnet`. Any other launch opens no network socket and the app is fully
  functional.
- I2 **One derivation rule.** Every listener binds exactly the derived endpoint for
  its identity (offset table above). No fallback, no substitute port, no wildcard.
- I3 **Bind failure never degrades the app and never gives up.** A failed attempt
  leaves local IPC and the whole app working, surfaces the reason, and retries the
  same launch-frozen config until bound or quit. Every attempt re-proves the
  tailnet-range and local-interface checks (the no-public-init contract of
  `TailnetBindAddress` is preserved); a listener that binds after launch serves
  remote connections identically to one bound at launch.
- I4 **Launch-frozen.** Config reload and preferences saves never change the
  running listener. The prefs pane shows the committed config and the active
  listener separately, so a post-launch edit is visible as "next launch" state.
- I5 **Status is a single truth, observable everywhere.** Prefs pane, the
  `tailnet.status` reply, and the handle of a `--tailnet` launch all report the
  same app-authored status value; a launch without the flag performs no status
  query and its handle omits `tailnet`. The handle reports the state at launch
  time without blocking on `listening` -- `waiting` is a legitimate handle value.
  A launcher whose reachable app cannot answer the status query (timeout,
  malformed reply, protocol mismatch) fails the launch loudly and, like every
  post-spawn launch failure today, terminates the launched session so the slot
  returns to the pool -- no failure path exits leaving a hidden app holding a
  slot.
- I6 **Audit records transitions, not attempts.** Repeated failures with an
  unchanged reason append one entry; a changed reason and a successful bind each
  append one.
- I7 **Existing remote-IPC invariants hold unchanged**: admission precedes service,
  connection cap at the accept boundary, write-ahead audit gate for connections and
  requests, stable refusal shapes, `quit` remains the only local-caller-only
  method.

## Proof obligations

- PO1 (I1) Activation matrix: no config / pool slot without and with `--tailnet` /
  offset-less identity / empty admitted list / derivation error -> disabled with a
  distinct reason; production, dev slot 0, and pool-slot-with-flag -> enabled.
- PO2 (I2) The offset table is pinned as an external constant: production +0, dev
  slot 0 -> +1, slot 8 -> +9; overflow past 65535 is refused.
- PO3 (I3) An attempt that fails inside address resolution -- the motivating case:
  the tailnet interface is absent, then appears -- moves waiting -> listening, and
  a remote peer is then admitted and served (proves the accept loop starts on a
  late bind and that resolution is re-proven per attempt, which forces an injected
  resolver seam). Retry ticks are test-driven, never wall-clock waits. Server stop
  during waiting ends the retry with no listener ever appearing.
- PO4 (I4) Reloading an edited config after launch changes the model's committed
  tailnet value but not the running listener, and the prefs projection shows the
  divergence.
- PO5 (I5) `tailnet.status` reply matches the frozen per-state object exactly; a
  `--tailnet` launch's handle carries the `tailnet` field verbatim including a
  `waiting` state, and its occupancy row (`just slots`) carries the same object; a
  launch without the flag performs no status query and its handle omits the field;
  `danterm tailnet status` requests the reply and prints it; a reachable app that
  never answers the one-shot query fails the launch within a bounded timeout AND
  leaves the slot reclaimable (the session is terminated); a status whose `reason`
  pushes the occupancy record past its fixed size still yields a successful launch
  and a printed handle carrying `tailnet` in full, with the occupancy row lacking
  only that object.
- PO6 (I6) N identical failures -> one audit entry; a reason change -> a second;
  success -> one bound entry.
- PO7 (I7) The existing closed-by-default, fail-soft, admission, and refusal-shape
  tests keep passing; the method-classification sweep still pins `quit` as the only
  local-caller-only method.
- PO8 Prefs: projection text per status, derived purely from model facts; the
  existing panel row-index and read-only pins pass unmodified.
- PO9 Launcher/policy: `--tailnet` is the only argument the flag adds; `--fresh`/
  `--background` behavior is unchanged; `AppLaunchPolicy` parses the flag.

## External surface (frozen by this plan)

- Config: `tailnet.listen` port reinterpreted as the base port (no schema change;
  README and SKILL.md rewordings).
- IPC method `tailnet.status`. The reply is one JSON object per state; fields are
  absent when not listed, never null:
  - `{"state":"disabled","reason":<string>}`
  - `{"state":"waiting","base":<string>,"offset":<int>,"endpoint":<string>,"reason":<string>}`
  - `{"state":"listening","base":<string>,"offset":<int>,"endpoint":<string>}`

  `base` is the launch-frozen configured `tailnet.listen` text; `offset` is this
  identity's port offset; `endpoint` is the derived `address:port` this instance
  binds; `reason` is the human-readable cause of the current state.
- CLI `danterm tailnet status` printing that reply as JSON.
- Slot handle JSON gains `tailnet` (the same reply object) on `--tailnet` launches
  and omits it otherwise; `just slots` occupancy rows inherit it. An occupancy
  record that would exceed the fixed record size drops the `tailnet` object rather
  than failing the launch (the caller's printed handle still carries it in full).
- App argument `--tailnet`; justfile `launch-slot` / `launch-slot-optimized`
  argument passthrough.

## Non-goals

- Dynamic listener reconfiguration (rebind on config change, mutable admitted set).
- Watching interface/route changes; the fixed-interval retry is the only recovery.
- Editable tailnet fields in the preferences panel.
- A `doctor` row for tailnet (doctor runs without the app; the CLI subcommand
  covers the running-app case).
- TLS, pairing tokens, rate limiting (unchanged from the listener plan).
- Per-slot config files.

## Accepted risks

- AR1 Deterministic-looking resolve rejections (wildcard, non-tailnet range) retry
  forever rather than disabling; the rule stays one sentence and the reason is
  visible in every status surface.
- AR2 The retry interval and the user's chosen base port are discretionary
  constants; wrong values inconvenience, not endanger.
- AR3 An audit sink that becomes unwritable while waiting cannot record its own
  failure; listener-lifecycle audit stays best-effort, and the connection/request
  write-ahead gate is untouched.

## Rejected ideas

- RI1 Ephemeral/auto-chosen ports with discovery: masks zombie listeners, breaks
  the phone's saved targets, needs a port-0 carve-out in bind validation.
- RI2 Env-var opt-in instead of `--tailnet`: widens the launcher's deliberate
  environment allowlist and can leak into pane child environments.
- RI3 Extending an existing reply (`ping`, `ls`, `doctor.permissions`) instead of a
  new method: `ping` forbids content, `ls` is entity listing, and the permissions
  decoder is strict enough that a new key breaks old CLIs.
- RI4 An AppRuntime-owned retry timer driving the server: splits the stop/bind race
  across two files; the server actor owns its own lifecycle.

## Implementation discretion

- The retry interval constant.
- Exact prefs row wording and layout (append after the existing rows so pinned
  indices survive).

## Critical files

- `app/IpcServer.swift` -- the bind becomes a retryable state machine owned by the
  actor; status transitions push through the existing runtime-dispatch channel.
- `lib/DanTermProtocol/Sources/DanTermProtocol/` (`DanTermConfig.swift` + a new
  sibling) -- status type, offset derivation, activation gate; all pure, shared by
  core, support, and app.
- `app/AppRuntime.swift`, `app/AppDelegate.swift`, `app/AppLaunchPolicy.swift` --
  thread the opt-in, seed the model's initial status before the Elm loop runs
  (the `pendingConfigError` precedent), inject the identity offset as a model fact.
- `lib/DanTermCore/Sources/DanTermCore/` (`Msg.swift`, `Update.swift`,
  `IpcDispatch.swift`, `Projections.swift`) -- status Msg, pure `tailnet.status`
  reply from the model (no new Command case), prefs projection fields.
- `app/PreferencesPanel.swift`, `tests-ui/PreferencesPanelTests.swift` -- read-only
  section; everything rides the projection so the UI-test shim needs no new stubs.
- `scripts/dev-slot-launcher.py` + `scripts/tests/dev-slot-launcher_test.py`,
  `justfile` -- `--tailnet` flag, one-shot JSON-RPC status fetch into the handle,
  recipe passthrough.
- `cli/main.swift` + `DanTermProtocol` CLI parser, `integrations/danterm/SKILL.md`,
  `README.md` -- subcommand and docs, updated in the same change as the surface.

## Verification

- `just test` (gate: protocol/core/support suites, app-tests, launcher Python
  tests, CLI tests, lints). `just test-ui` for the panel rows.
- Manual, on the real tailnet: set a base in config; launch the user's dev app and
  `just launch-slot --tailnet | tail -1 | jq .tailnet`; confirm distinct endpoints
  via `danterm --socket <slot> tailnet status` and a `danterm --tcp` call against
  each; open Preferences and check the status row; stop Tailscale, relaunch, watch
  `waiting` become `listening` when Tailscale returns.

## Commit progress

- [x] 1. Derive per-instance tailnet endpoints and status in DanTermProtocol
- [x] 2. Gate and retry the tailnet bind on the derived endpoint
- [x] 3. Publish listener status through the model and `tailnet.status`
- [x] 4. Show the read-only tailnet section in the preferences panel
- [x] 5. Launch a pool slot with `--tailnet` and report status in the handle

## Implementation notes

- Commit 2: `IpcServer` resolves the activation itself, from the config, the
  process identity, and the opt-in flag it is given. The alternative was to
  resolve in `AppRuntime` and hand the server a finished endpoint, but the
  server already takes the config for the admitted node ids, and one owner for
  the whole launch-frozen decision keeps the status it authors and the address
  it binds from ever disagreeing.
- Commit 2: `tailnetOptIn` defaults to false and `AppRuntime` does not pass it
  yet, so a launcher pool slot opens no listener until commit 5 parses
  `--tailnet`. Production and dev slot 0 are unaffected, because the gate only
  applies to pool slots.
- Commit 2: the server holds its status as its own state and nothing reads it
  outside the server and its tests. Commit 3 publishes it into the model.
- Commit 2: the audit log gains a `listenerBound` event carrying the endpoint,
  which is the "success appends one entry" half of the transition rule.
- Commit 3: the server keeps its own `tailnetStatus` and publishes each change to
  the model, rather than the model asking the server for it. The model is what
  the prefs pane, the IPC reply, and (later) the launch handle read, and only a
  push can reach it from a retry that binds minutes after launch.
- Commit 3: the publish is awaited on the server's own turn instead of being
  detached, so two transitions cannot reach the model out of order. It runs
  after the accept loop starts, because adopting the listener and handing its
  descriptor to that loop must stay one uninterrupted turn.
- Commit 3: only a change is published. A bind that keeps failing for one reason
  would otherwise run a whole update frame per retry to store a value the model
  already holds.
- Commit 3: `AppRuntime` seeds the model from the server's `initialTailnetStatus`
  by assignment, the way it already assigns the launch config, because the Elm
  loop does not exist yet when the server is built.
- Commit 3: the README and SKILL.md wording for the base port and the retry lands
  here rather than with commit 2. The `tailnet status` output names `base`,
  `offset`, and `endpoint`, and none of those can be documented without the
  derivation rule they come from.
- Commit 4: the section is three rows -- the committed base, the derived
  endpoint, the live status -- plus a note that a tailnet edit applies at the
  next launch. Two rows would have folded the endpoint into the status sentence,
  but the endpoint is the fact the user came to read (it is what the phone
  saves), so it gets its own row and stays in place while the status moves.
- Commit 4: the panel builds each row's sentence from the projection and formats
  nothing itself, so the wording per status is pinned by the pure tests rather
  than only by the UI harness.
- Commit 4: the config row reads the committed config while the endpoint row
  reads the launch-frozen status, which is what makes a post-launch config edit
  legible as "next launch" instead of looking like the current endpoint.
- Commit 5: the launcher asks the app for the status over the control socket and
  relays the object it gets. It never derives a port or builds a status of its
  own, so the handle cannot disagree with `danterm tailnet status` or the
  preferences pane.
- Commit 5: the launcher's copy of the slot claim now closes in a `finally` at
  the end of the launch rather than before the socket wait. The occupancy row has
  to be rewritten with the status, and that can only happen once the app is
  reachable. The row written before the wait still names the pid, so a slot found
  busy in between is described exactly as before.
- Commit 5: an occupancy record that will not fit keeps the record written before
  the status query instead of failing the launch, so the row loses only the
  `tailnet` object. The caller's handle carries the status whole either way.
