# Tailnet config off switch: `tailnet.enable`

## Problem

The config is JSON, so the only way to turn the tailnet listener off today is
to delete the whole `tailnet` object, throwing away the `listen` address and
`admittedNodeIds` list the user would have to reconstruct later. There is no
non-destructive way to park the config, the way Nix's `enable` flag parks a
module.

Evidence: `DanTermConfigDocument.projectConfig` treats the section as
all-or-nothing, and `DanTermTailnetActivation.resolve`
(`lib/DanTermProtocol/Sources/DanTermProtocol/TailnetActivation.swift`) opens
a listener whenever a well-formed section with admitted nodes exists.

## Decision

Add one config key, `tailnet.enable` (boolean). Absent means `true`, so
existing configs keep their meaning and presence of the section still means
intent to use it. `false` keeps the section intact but keeps the listener
closed. Absence of the whole section remains a valid, fully-disabled state;
the flag is a second, softer path to the same closed outcome — it does not
become the primary gate.

The disable lands in `DanTermTailnetActivation.resolve` as one more named
`disabled(reason:)` guard, not in config projection, so every status surface
(preferences pane, `tailnet.status`, slot handles) reports the real cause.

`just launch-slot --tailnet` against a user config whose tailnet block has
`enable = false` refuses the launch with an error naming `tailnet.enable`,
instead of launching a slot whose listener silently never binds.
(User-adjudicated; verbatim copy and strip-the-flag were rejected.) The
refusal happens where the launcher already reads the user's tailnet block —
after the launch-facts helper names the config path, before the app spawns
(`seed_document` / `launch_slot_app` in `scripts/dev-slot-launcher.py`) —
and releases the claim, so a rejected launch starts no app and leaves the
slot free. The document the check reads is the same read that gets copied
into the slot, so the checked and copied values cannot diverge. (The user's
config path must keep coming from the launch-facts helper; the launcher
never derives it itself — the ambient-identity seam in
`docs/design/2026-05-28-pure-core-support-split.md`.) Every other
`--tailnet` case keeps its current behavior:
an absent or ineligible tailnet block still means "nothing to copy", and a
launched slot still relays its `tailnet.status` verbatim in the handle. The
rejected launch produces no handle; the disable reason reaches the user
through the launcher error, and through Preferences and `tailnet.status` on
any running instance that loaded the disabled config.

## Invariants

- I1: A well-formed `tailnet` section with `enable = false` yields a disabled
  activation whose reason names the config flag, distinct from the
  "not configured" reason. Absent or `true` behaves exactly as today.
- I2: `enable = false` survives a Preferences save. (`setTailnet` replaces the
  whole `tailnet` object; a modeled field it does not write back would be
  silently deleted on save, re-enabling the listener.)
- I3: A `tailnet` section that is malformed — including a non-boolean
  `enable` — stays closed, as the closed-by-default rule already requires.
- I4: `launch-slot --tailnet` with `enable = false` in the user's tailnet
  block exits nonzero with a message naming `tailnet.enable`; no app is
  spawned and the slot is free afterward — the rejection can never strand a
  running occupant. Any other tailnet block (absent, ineligible, or enabled)
  behaves exactly as today.

## Proof obligations

- PO1 (I1): activation tests for `enable` false / true / absent, in
  `TailnetActivationTests.swift`.
- PO2 (I2): a settings-save round-trip test alongside
  `tailnetConfigSurvivesSettingsSave` in `DanTermConfigDocumentTests.swift`.
- PO3 (I3): a non-boolean `enable` case in the existing parameterized
  `invalidTailnetConfigStaysDisabled` test.
- PO4 (I1, surface): the preferences projection shows the new reason string —
  `PreferencesTailnetTests.swift` asserts exact strings and gains a case.
- PO5 (I4): launcher tests (`scripts/tests/dev-slot-launcher_test.py`,
  `just test-tooling`) prove both sides of the boundary: `enable = false`
  rejects with the named error, starts no app, and leaves the slot free,
  while an existing lenient case (absent tailnet block) still launches and
  returns a handle. Exercised through `launch_slot_app`.

## Files

- `lib/DanTermProtocol/Sources/DanTermProtocol/DanTermConfig.swift` — field on
  `DanTermTailnetConfig`, defaulted so existing positional constructions
  (e.g. `app-tests/IpcServerRemoteTests.swift`) keep compiling.
- `lib/DanTermProtocol/Sources/DanTermProtocol/DanTermConfigDocument.swift` —
  parse in `projectConfig`, write back in `setTailnet`.
- `lib/DanTermProtocol/Sources/DanTermProtocol/TailnetActivation.swift` — the
  new guard in `resolve`.
- `scripts/dev-slot-launcher.py` — the `--tailnet` rejection.
- Docs: `docs/tailnet.md` schema table ("two config keys" becomes three),
  `README.md` config table row, the slot-launcher tailnet paragraph in
  `integrations/danterm/SKILL.md`, and the `--tailnet` description in
  `agent-docs/dev-loop.md`.

## Non-goals

- No Preferences UI to toggle the flag; tailnet settings stay file-edited and
  launch-frozen, as the pane already says.
- No change to `IpcServer`'s independent read of `admittedNodeIds`; it is
  never consulted while no listener binds.

## Rejected ideas

- RI1: Have the launcher treat every post-launch `disabled` tailnet status as
  a `--tailnet` failure. Rejected: it changes the launcher's tested leniency
  for absent/ineligible tailnet config, and the pre-launch `enable` check
  (I4) removes the case that motivated it without inspecting status reasons.

## Implementation discretion

- Whether `setTailnet` writes `enable` always or only when `false`
  (omit-when-true avoids churning existing files); I2 is the contract either
  way.
- The Preferences "Tailnet" configured-text row when disabled (keep showing
  the listen address, or read "Disabled"); the status line carries the reason
  regardless.

## Verification

`swift test --package-path lib/DanTermProtocol`, targeted DanTermCore
preferences tests, `just lint`, then `just test` before commit;
`just test-tooling` for the launcher change.

## Implementation notes

- `setTailnet` writes `enable` only when it is false. True is what an absent key
  already means, so a save leaves existing config files unchanged. I2 holds
  either way.
- The Preferences "Tailnet" configured row keeps showing the listen address when
  the section is parked; it is still the config the next launch reads. Only the
  status line names the flag, reading "Disabled -- the config sets
  `tailnet.enable` to false".
- The launcher refusal is raised from `seed_document`, which is the one place
  that reads the user's document, so the checked value is the value that would
  have been copied. `launch_slot_app` closes the claim on that path before
  re-raising: nothing spawned, so no app is there to inherit the descriptor and
  the slot would otherwise read as busy with no occupant.
- The refusal gets its own `TailnetDisabledError` rather than reusing
  `LaunchFailedError`, whose contract is "a started app that never became
  usable". `main` prints and exits on both the same way.
