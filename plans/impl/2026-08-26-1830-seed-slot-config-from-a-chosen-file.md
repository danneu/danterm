# Seed a development slot's config from a chosen file

## Context

A development slot always starts from an empty config file the launcher owns
(`scripts/dev-slot-launcher.py`). That isolation is deliberate and stays. But it
leaves no way to launch a slot on chosen settings: to see a theme, a font size, a
keybinding, or a reported bad config behave in a real app, the only route today is
to launch the bundle executable directly with `--config <path>`, which gives up the
slot pool -- the claim, the staged bundle, the log, the control socket wait, and the
JSON handle.

`--tailnet` already has exactly the shape needed. It reads a source config file,
projects part of it, and writes the result into the slot's own file at claim time.
It is one hardcoded source and one hardcoded projection of a mechanism that wants a
second value.

Outcome: `just launch-slot --seed-config <path>` launches an ordinary pooled slot
whose config starts as a copy of that file.

## Decision

Add `--seed-config <path>` to the launcher, and generalize the existing seeding
mechanism so `--tailnet` and `--seed-config` are two contributions to one seed
document rather than two branches.

- The seed document is decided from the launch request, then written into the
  slot's config file. `--seed-config` contributes the whole named document;
  `--tailnet` contributes the user's tailnet block. With neither, there is no seed
  and the slot starts from defaults, as today.
- The two compose: the seeded file is the base, and a `--tailnet` launch overlays
  the tailnet block on top of it. An agent can seed appearance settings and still
  reach the slot from the iOS client.
- One eligibility rule for both sources, and it is the app's, not the launcher's: a
  source qualifies when it is a JSON object naming `schemaVersion` 1 -- exactly what
  `DanTermConfigDocument.decode` accepts. Whether the document is valid deeper than
  that is the app's to judge and it says so loudly, so the launcher does not
  re-derive the answer.
- An ineligible `--seed-config` path -- absent, unparseable, or naming another
  version -- refuses the launch, before a slot is claimed and before the build runs.
  `--tailnet` keeps its leniency: it is a convenience whose absent or ineligible
  source means "nothing to copy", while `--seed-config` is an explicit request whose
  silent fallback would send the caller debugging the wrong terminal.
- Assembly preserves the seeded document except for the keys the launcher sets. The
  app keeps unknown values, including number tokens, exactly as written, so a
  launcher that re-encoded them could turn a document the app accepts into one it
  refuses.
- The named file is only ever read. The slot writes to its own copy, so the app's
  Preferences and `Open Config` in a seeded slot still reach the slot's file.

Critical files:

- `scripts/dev-slot-launcher.py` -- the flag, the seed assembly, and the launch
  path. `slot_config_path`, `tailnet_seed_document`, and `prepare_slot_config` are
  the existing seams; the seed source and projection move out of
  `prepare_slot_config` so the writer takes a document.
- `scripts/tests/dev-slot-launcher_test.py` -- the suite that already covers slot
  config isolation, the tailnet seed, and the end-to-end launch path.
- `agent-docs/dev-loop.md` (slot config section) and `README.md` (tailnet section)
  -- the two places that tell an agent how a slot's config is decided.

No app change: the app already accepts `--config <path>`
(`app/LaunchInstancePaths.swift`). No `justfile` change: `launch-slot` forwards
`*args`.

## Invariants

- **I1.** A slot's config path is the launcher's. `--seed-config` sets the file's
  starting contents and never where the slot reads or writes.
- **I2.** Every launch resets the slot's config file before the app starts, so no
  previous occupant's settings survive into a new claim.
- **I3.** A launch never writes to, links to, or leaves the slot reading the source
  file named by `--seed-config`, nor the user's standard config.
- **I4.** An ineligible `--seed-config` path refuses the launch, and that refusal
  costs no slot claim and no build.
- **I5.** A launch given both flags starts on the seeded document with the user's
  tailnet block in place.
- **I6.** The launcher is not an author of the config format: everything it writes
  into a slot's file came from a file it read, byte for byte, except the keys it
  sets.
- **I7.** Each source is read once. The document written into the slot's file is the
  one the launcher checked, whatever happens to the source after.

## Proof obligations

- I1: a seeded launch hands the app the slot's own config path, not the seed path.
- I2: the existing reset coverage extends to a seeded launch replacing a stale slot
  config.
- I3: after any launch, the named seed file and the user's standard config are
  byte-identical to before.
- I4: each ineligible seed shape (absent, unparseable, another `schemaVersion`)
  exits nonzero with a message, leaves the pool as it found it, and runs no build.
- I5: a launch with both flags produces a slot config holding the seeded contents
  and the user's tailnet endpoint and admitted nodes; a `--tailnet` source that is
  absent or ineligible leaves the seeded document alone rather than refusing.
- I6: a slot config written from a seed contains no key the sources did not carry,
  and a seeded value the app accepts but does not model -- an extreme number token
  among them -- reaches the slot's file unchanged.
- I7: a source changed after the launcher checks it does not reach the slot.

## Non-goals

- Changing how the app resolves its config, or its `--config` contract.
- Watching the seed file: the copy is a snapshot taken at launch, like the tailnet
  copy is today.
- Migrating across `schemaVersion` values, or judging a config's validity below the
  eligibility rule. The launcher does not arbitrate the config format.

## Rejected ideas

- **A pointer flag** (`--config <path>` passed straight through to the app), which
  would let a slot read and write the user's file and undo the isolation the
  separate slot config exists for. Seeding a copy keeps the isolation while giving
  the caller the starting state they wanted.
- **A plain byte copy** of the seed file, with no check and no merge. It cannot
  compose with `--tailnet` and cannot report an ineligible seed before the build, so
  it would trade I4 and I5 away. I6 keeps what made it attractive.

## Verification

Beyond the suite (`python3 scripts/tests/dev-slot-launcher_test.py`, and `just
lint`):

1. Write a config naming a distinctive theme, launch with
   `just launch-slot --seed-config <path>`, and confirm the slot's own config file
   holds that document, the slot answers on its socket, and
   `~/.config/danterm/config.json` is unchanged. The theme itself is confirmed by
   looking at the running slot.
2. Launch with `--seed-config` and `--tailnet` together and confirm the handle
   carries a bound `tailnet` status as well as the seeded settings.
3. Point `--seed-config` at a missing file and confirm the command fails with a
   message and `just slots` shows no new occupant.
4. `just stop-slot <n>` for each.

## Commit progress

- [x] 1. feat(dev): seed a development slot's config from a chosen file

## Implementation notes

- I6 is kept by carrying every JSON number as its own token (`ConfigNumber`) from
  the read through to the write, rather than by copying the seed file's bytes. A
  byte copy cannot compose with `--tailnet`, and Python's `json` reads `1e400` as
  a float infinity and writes it back as `Infinity`, which the app refuses. The
  launcher therefore re-serializes the document it read, in compact form and in
  source key order, with number tokens verbatim.
- The one eligibility rule tightened `--tailnet`'s source check: it accepted any
  document naming a `schemaVersion`, and now takes only the integer token `1`,
  the same value `DanTermConfigDocument.decode` accepts.
- `integrations/danterm/SKILL.md` joined the two documentation files the plan
  named. Its slot-config section told an agent to launch the bundle directly with
  `--config <path>` "when you need a config of your own", which `--seed-config`
  replaces for a pooled slot.
