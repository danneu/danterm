# Nix-managed config path

## Problem

DanTerm's home-manager module (`hm-module.nix`) exposes only `enable`,
`package`, and `startAtLogin`. A nix user has no supported way to keep
`~/.config/danterm/config.json` under version control in their nix repo.

The obvious nix idiom -- a `settings` option rendered to JSON via `home.file` --
does not work here, because DanTerm writes its own config: Preferences saves go
through `DanTermConfigStore.save`. A store-backed config file is read-only, so
every save would fail, and `home-manager switch` would revert any write that did
land.

Load-bearing premises about existing behavior:

- `DanTermConfigDocument.encoded()` returns the original bytes verbatim until a
  semantic edit occurs, and preserves unknown keys and untouched number tokens.
  A git-tracked config therefore does not churn on unrelated saves.
- `DanTermConfigStore.save` is a read-modify-write transaction whose write is
  atomic: a failed save leaves the file byte-identical.
- Foundation's atomic write replaces the destination path by rename. Against a
  symlink that destroys the link, substituting a regular file.

## Desired outcome

A nix user points DanTerm at a config file inside their own repo. DanTerm reads
and writes that file directly, so Preferences saves appear as reviewable diffs
in the nix repo, and `home-manager switch` never conflicts with them.

## Decision

Nix owns *where* the config lives, not *what is in it*.

Add `programs.danterm.configPath`. When set, the module links
`~/.config/danterm/config.json` to that out-of-store location via
`config.lib.file.mkOutOfStoreSymlink`. When unset, the module deploys no config
file at all and the app's current ownership is unchanged.

On the app side, the config write path resolves symlinks before its atomic
replacement, so the rename lands on the linked-to file instead of consuming the
link.

Behavioral scope: the config file's location and the write path's symlink
handling. Config content, schema, and the set of modeled settings are untouched.

## Invariants

- **I1** -- A save through a symlinked config path rewrites the link's target
  file and leaves the symlink itself in place. This holds when the target does
  not yet exist: seeding a dangling link creates the target rather than
  replacing the link.
- **I2** -- The atomic transaction guarantee survives the move to the resolved
  target: a failed or refused save leaves that file byte-identical.
- **I3** -- With `configPath` unset, the module deploys no config file, and
  DanTerm's config location and ownership are exactly what they are today.
- **I4** -- `configPath` designates a location outside the nix store, so the
  deployed config stays writable. A path the user supplies is not copied into
  the store.
- **I5** -- A save's read and its write address the same file. If the config
  symlink is retargeted while a save is in flight, the save cannot modify the
  new target.

## Proof obligations

- **PO1** (I1) -- Saving through a symlinked config path updates the target and
  leaves the link intact, including when the link is initially dangling.
- **PO2** (I2) -- The existing failed-write and refused-save coverage in
  `tests-ui/DanTermConfigStoreTests.swift` holds when the store writes through a
  resolved symlink.
- **PO3** (I3) -- Loading, seeding, and saving an ordinary non-symlinked config
  file are unchanged.
- **PO4** (I4) -- Verified by manual `home-manager switch` against both a set and
  an unset `configPath`; see AR1.
- **PO5** (I5) -- Retargeting the config symlink partway through a save applies
  the requested update to the file that was read, and leaves the new target
  byte-identical.

## Deliverables

- `hm-module.nix`: the `configPath` option and its `home.file` entry.
- `app/DanTermConfigPaths.swift`: symlink-resolving write.
- `README.md`: the nix snippet, in the Configuration section or the existing
  collapsed Nix install block.
- A `docs/design/` note recording why nix deploys the config file rather than
  generating its content, indexed in `docs/design/index.md`.

## Non-goals

- No `programs.danterm.settings` option. Nix does not generate config content.
- No layering or merge semantics between a nix-provided base and an app-writable
  overlay.
- No change to the config schema, the modeled settings, or Preferences.

## Accepted risks

- **AR1** -- The nix module gets no automated coverage, so I3 and I4 stay
  manually verified: a regression in the option's type, its conditional, or the
  link construction could deploy a config when `configPath` is unset, or produce
  a store-backed target, without any automated failure. Accepted because
  home-manager is not a flake input and adding it for a single eval check costs
  a lock node for a declaration that is a handful of lines.
- **AR2** -- The first app write to a hand-formatted repo config reformats it to
  sorted keys and two-space indentation, producing a one-time diff.

## Rejected ideas

- **RI1** -- A `settings` option rendering config content into the nix store
  (the `programs.alacritty.settings` idiom). Those apps do not write their own
  config; DanTerm does. A store-backed file makes every Preferences save fail
  and lets `switch` clobber app writes. Revisit only for a use case that
  genuinely needs nix-language composition -- per-host values, interpolation,
  shared modules -- and then as a base layer under a writable overlay, which the
  `configPath` symlink becomes without a breaking change.

## Implementation discretion

- How symlink resolution is performed, and where in the store's write path it
  sits.
- The `configPath` option's default representation for the unset case.

## Implementation notes

- Foundation's `URL.resolvingSymlinksInPath()` leaves a final dangling symlink
  unresolved. The store therefore asks `FileManager` for the final link's
  destination explicitly, while still using Foundation resolution for ordinary
  paths, existing targets, and parent directories.

## Follow Up

- Before release, run `home-manager switch` once with
  `programs.danterm.configPath` set and once unset, then confirm the set case
  creates an out-of-store link and the unset case deploys no config file, as
  required by PO4 for `hm-module.nix`.
