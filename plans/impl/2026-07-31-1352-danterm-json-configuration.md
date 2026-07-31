# DanTerm-owned JSON configuration file

## Context

Replacing libghostty with the DanTerm Swift engine orphans the configuration
file. `~/.config/danterm/config` is today a Ghostty-style flat `key = value`
file with a split reader: libghostty consumes most of it, and
`DanTermConfigParser` recognizes exactly two keys (`remote-theme`,
`alert-clear-mode`). When libghostty goes, nothing parses `theme`, `font-size`,
`scrollbar`, `copy-on-select`, `progress-style`, or `macos-option-as-alt`.
Those keys become dead text in users' files while the engine silently falls back
to baked-in defaults, and the Preferences panel's Theme and Font Size rows are
permanently "(default)" (`app/SwiftTerminalBackend.swift` already stubs
`preferences` to empty and `reloadConfig()` to a no-op).

`plan-terminal-engine/11-configuration-themes.md` already commits to a
DanTerm-owned format with no Ghostty compatibility, and to settings entering
the engine as explicit inputs rather than ambient reads. This plan is the first
concrete instance of that commitment.

### Load-bearing premises

- **P1. Only theme is wired into the Swift engine.** Font size is a literal
  `13` inside `TerminalRenderMetrics.init?(displayScale:)`; scrollback is a
  fixed 10 MiB constant; option-as-alt is unconditional; copy-on-select,
  window padding, and a configurable scrollbar do not exist in the Swift path.
  Any key beyond theme requires engine plumbing before it can mean anything.
- **P2. The app writes the config file from two places.** The Preferences panel
  Save button (`Update.swift`, `case .prefSave`) writes four settings -- theme,
  font size, alert clear mode, remote theme -- and the Open DanTerm Config
  action creates the file from a seed when it is absent, today a comment-only
  header duplicated across `AppDelegate` and `PreferencesPanel`. Both are in
  scope; nothing else writes the file, so it stays round-trippable through a
  decode/mutate/encode cycle.
- **P3. No stock Foundation JSON tree round-trips numbers faithfully.**
  Measured on the current SDK: a `Double`-backed tree (which is what
  `DanTermProtocol.JSONValue` is) rewrites `9007199254740993` as
  `9007199254740992`, while `JSONSerialization` preserves that integer but
  rewrites `0.1` as `0.10000000000000001`. Preserving a value the app never
  interprets therefore means retaining its original number token, not
  re-deriving text from a parsed numeric type.

## Decision

Introduce `~/.config/danterm/config.json`, a DanTerm-owned versioned JSON
document that both the user and the Preferences panel edit. Reads decode
through a pure, versioned boundary in `DanTermCore` modeled on
`ThemeCatalogDocument`; all file IO stays in `app/`.

One Preferences Save is one write transaction: re-read the file, decode it into
an untyped tree, apply every changed field, re-encode the whole document, and
write it atomically once. Editing the tree rather than the typed struct is what
keeps content outside the schema alive across a save; re-encoding rather than
splicing text is possible only because plain JSON carries no comments to
preserve. Per P3, that tree must retain the source token of any number it does
not itself set, so the reducer's current one-command-per-changed-field shape
collapses into a single transaction command.

v1 ships only keys with an observable effect (P1):

```json
{
  "schemaVersion": 1,
  "font": { "size": 13 },
  "theme": { "default": "Monokai Remastered", "remote": "Purplepeter" },
  "ui": { "alertClearMode": "focus" }
}
```

`theme.default` becomes a third fallback in `effectiveTheme(for:)` (today
`remoteThemeOverride ?? pane.theme`, with the Swift backend substituting the
baked `.dark` when nil). Its own default is **Monokai Remastered**, which
replaces `.dark` as what a pane with no configured theme actually looks like;
`.dark` survives only as the last resort when a named theme cannot be resolved
from the catalog. `theme.remote` keeps its existing Purplepeter default.
`font.size` requires threading a size through
`TerminalRenderMetrics` and the session view, which changes cell metrics and
therefore the grid dimensions a pane reports to its PTY -- that resize path is
part of this work, not a follow-on.

Critical files: `lib/DanTermCore/Sources/DanTermCore/DanTermConfig.swift` (the
parser and writer being replaced), `ThemeCatalogDocument.swift` (the decode
pattern to follow), `Update.swift` `case .prefSave` (the four write sites),
`app/AppRuntime.swift` (the read-modify-write command performers),
`app/DanTermConfigPaths.swift` (path + disk load + the seed, whose duplicate
literal in `PreferencesPanel.swift` shares the `AppDelegate` open-config
behavior), and
`lib/TerminalCore/Sources/TerminalRenderExecution/TerminalRenderExecution.swift`
(the hardcoded font size).

## Invariants

- **I1. A save preserves everything it does not target.** Content the app never
  interprets -- an unmodeled top-level key, an unmodeled sibling nested beside a
  modeled one, and any number's exact written value -- survives a Preferences
  save unchanged. Setting `font.size` may not rewrite the rest of `font`.
- **I2. Output is deterministic.** Saving a value that is already in the file
  produces a byte-identical file, so repeated saves do not churn it.
- **I3. Clearing a setting removes its key.** A cleared Theme or Font Size
  leaves no residue in the file, and the absent key means "use the default".
- **I4. A config the app cannot fully account for never becomes a written
  config.** Only a document that parses *and* carries exactly the integer
  `schemaVersion: 1` is writable. Unparseable content, a missing or malformed
  version, and any other version all take the same path: run on defaults, say
  so, and refuse every write until it resolves. This is what stops an older
  build from rewriting a newer file and destroying fields it cannot represent.
  It also binds the app's own authoring: any file DanTerm creates -- including
  the one Open DanTerm Config seeds when none exists -- is itself a valid,
  writable v1 document, so the app can never strand the user behind a config
  only hand-repair can unblock.
- **I5. Decode degrades per field.** A value outside its field's accepted
  domain falls back to that field's default and leaves the rest of the
  configuration in force -- a deliberate departure from
  `ThemeCatalogDocument`'s all-or-nothing rule, which is right for a bundled
  resource and wrong for a hand-edited user file. The v1 domains: `font.size`
  is a finite number above zero; `theme.default` and `theme.remote` are
  non-empty strings; `ui.alertClearMode` is one of the two known modes. A
  well-formed theme name that the catalog does not contain is not a decode
  failure -- it resolves at render time, where I9's last-resort applies.
- **I6. Every shipped key has an observable effect.** No key decodes into a
  value the engine ignores.
- **I7. A save preserves the external edits it can see.** The file is re-read
  at save time and never cached in the model, so any external edit already on
  disk when the transaction reads it survives the save, whatever key it touched.
  Edits landing after that read are AR4, not a violation.
- **I8. A failed Save is visible and leaves no partial file.** A Save either
  lands entirely or not at all; a failure anywhere leaves the file byte-identical
  regardless of how many fields changed, keeps the values applied for the
  running session, and tells the user the write failed.
- **I9. Every default is a resolvable catalog theme.** With no config file at
  all, a local pane renders Monokai Remastered and a remote pane Purplepeter --
  both named themes that the bundled catalog resolves, not the baked `.dark`
  fallback.

## Proof obligations

- **PO1 (I1).** After a Preferences save, a config still contains, unchanged:
  an unmodeled top-level key; an unmodeled sibling inside each object whose
  known child was set or removed; and, byte for byte, both untouched numbers
  from P3 -- the integer too large for a `Double` round trip and the fraction
  `JSONSerialization` reformats.
- **PO2 (I2).** Saving an unchanged value twice yields byte-identical files,
  including for an integral font size, which must not acquire a decimal point.
- **PO3 (I3).** Clearing Theme or Font Size in Preferences removes the key, and
  reloading the file yields the default.
- **PO4 (I4).** Each of a syntactically broken config, one with no
  `schemaVersion`, one whose version is not an integer, and one at a higher
  version yields default behavior at launch and refuses a subsequent
  Preferences save. Conversely, invoking Open DanTerm Config with no file
  present produces one that loads without falling back to defaults and accepts
  a Preferences save immediately afterward.
- **PO5 (I5).** A document with one out-of-domain field retains every other
  configured value, exercised once per v1 domain: a non-positive font size, an
  empty theme name, and an unrecognized alert mode.
- **PO6 (I6, I9).** Each shipped key changes observable behavior:
  `theme.default` colors a pane with no explicit theme, `theme.remote` retimes
  remote panes, `font.size` changes rendered cell metrics and the reported grid
  size, and `ui.alertClearMode` changes whether focus clears alerts. Proven on
  an already-running pane, reached by both Preferences Save and explicit Reload
  Config -- not only on a newly created one -- with the font-size change
  carrying its grid resize through to the live PTY.
- **PO7 (I7).** An unrelated key edited externally after the app loaded the
  file, but before the save transaction re-reads it, is intact after the save.
- **PO8 (I8).** A Save changing several fields at once, failing at write time,
  leaves the file byte-identical -- no field landing while another does not --
  leaves the values applied in the model, and produces a user-visible report
  naming the file.
- **PO9 (I9).** With no config file present, both default theme names resolve
  against the bundled catalog rather than falling through to `.dark`.
- **PO10 (end-to-end).** Launching the built app with a hand-written config
  applies every setting, and a Preferences save round-trips through the file.

## Non-goals

- Migrating or reading the legacy `~/.config/danterm/config`. It is ignored
  entirely; no import, no warning, no deletion.
- Ghostty config, theme, or keybinding compatibility.
- Keybindings in the config file.
- A file watcher. Reload stays explicit, as today.
- Expanding the Preferences panel beyond the four settings it already exposes.
- Configuring anything the Swift engine hardcodes (scrollback budget,
  option-as-alt, copy-on-select, window padding, font family).

## Accepted risks

- **AR1. Comments in config files are lost as a capability.** The current flat
  format preserves user comments through a save; plain JSON cannot carry them
  at all. Accepted because the file stays small and the Preferences panel
  covers every key it holds.
- **AR2. Key order and whitespace are the encoder's, not the user's.** A
  hand-formatted file is reformatted by the first Preferences save. Accepted as
  the direct cost of whole-document re-encoding, which is what makes the writer
  small enough to be obviously correct.
- **AR3. Settings reset on upgrade.** With no migration, users lose their
  configured theme, font size, remote theme, and alert clear mode and must
  re-enter them. Accepted because this branch is pre-release and the legacy
  file's keys were mostly Ghostty's, not DanTerm's.
- **AR4. A simultaneous writer loses.** An external edit landing between a save
  transaction's read and its write is overwritten. Accepted because the only
  other writer is a human in a text editor, the exposed window is one
  read-modify-write, and the loss is one manual edit the user can redo.

## Rejected ideas

- **RI1. JSON5 plus a span-preserving text writer.** Would keep comments by
  splicing single value ranges instead of re-encoding, since Foundation reads
  JSON5 (`JSONDecoder.allowsJSON5`) but cannot write it. Rejected as far more
  machinery -- a tokenizer, an edit-verification guard, and their test matrix --
  than a configuration file of this size justifies. Recorded because comment
  support is the obvious thing to want back.
- **RI2. An mtime or content check that aborts on external edits.** Would turn
  AR4's lost edit into a visible conflict error. Rejected because the abort's
  only recovery is the user redoing the edit -- the same outcome as losing it --
  bought by adding a failure mode to the sole write path Preferences has.

## Implementation discretion

- How the failed-write and unreadable-config reports reach the user (alert,
  `danterm doctor` row, or both), subject to I4 and I8.

## Commit progress

- [x] 1. feat(config): add a lossless versioned JSON document boundary
- [ ] 2. feat(config): apply JSON configuration live across the Swift backend
