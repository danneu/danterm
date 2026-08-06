# Copy-on-select as a configurable option

## Problem

libghostty copied the selection to the clipboard as soon as a mouse selection
gesture finished (Ghostty's `copy-on-select`, default `true` on macOS). The
Swift engine dropped that behavior: today the only path to the clipboard is an
explicit Cmd-C / Edit > Copy, and `TerminalInteractionPolicy`'s pointer-up arm
has no commit hook at all.

Bring the behavior back as an option the user controls: a `ui.copyOnSelect`
boolean in `~/.config/danterm/config.json` with a matching checkbox in the Cmd+,
preferences panel. **Default `true`**, matching the libghostty behavior DanTerm
used to have and Ghostty's own macOS default.

**Load-bearing premise.** A selection has to survive program output over the
rows it covers. It does, as of the work that retired selection-overwrite
invalidation. Before that fix, a TUI that repainted between the last drag event
and the pointer-up destroyed the selection before the gesture finished, so
copy-on-select would have copied nothing in exactly the applications it matters
for. This feature builds on that contract rather than working around it, and it
must not regress it.

## Decision

Selection completion is one atomic commit on the serialized owner. When a
selection-owned pointer-up is applied, the owner captures the completed
selection's text in the same step that applies the selection mutation, and
relays that immutable string to the main actor. The main actor writes what it
was handed and performs no second read of its own, so output arriving after the
gesture completed cannot change or erase what gets copied.

The policy reports only *that a selection-owned gesture finished*, inspecting
neither config nor selected text. Eligibility is pointer ownership, which is what
keeps consumed gestures -- mouse-reporting app, pane menu, link activation -- from
ever copying.

The configuration gate is expressed as subscriber presence: text is materialized
only when copy-on-select has an active subscriber. With the option off nothing
downstream of the policy extracts text at all, which makes "off costs nothing" a
checkable property rather than an assertion.

Emptiness is judged where the text is captured, since it is a property of the
extracted string: the owner relays only a non-empty result, so an absent or
empty selection produces no relay and no clipboard write. Cmd-C keeps its
current behavior -- changing what an explicit copy does to the clipboard is not
this feature's business.

`copyOnSelect` reaches the pane the way the rest of the per-pane configuration
does, through the existing pane-config projection and reconcile. The config key
itself follows the same path as the other `ui` keys -- decoded on load, written back
without disturbing untargeted content, held in the preferences draft so toggling
is draft-only until Save, and surfaced with the same labeled-row and dirty-row
treatment as its neighbors in the panel.

Three documents are in scope. The README's Settings table and sample JSON gain
the key. The README's Shift-to-bypass-mouse-capture tip currently ends by
telling the reader to press Cmd-C after releasing the drag, which stops being
what happens once the option defaults to on; it needs to say that the release
itself copies while `ui.copyOnSelect` is on.
`plan-terminal-engine/08-input-interaction.md` currently states that
copy-on-select is not part of the engine and lists it as a non-goal; that
normative contract must instead describe the configurable, default-on behavior,
or later work is entitled to delete this feature as a documented exclusion.

## Invariants

- **I1.** With the option on, finishing a local selection gesture -- drag,
  double-click word, triple-click line, and Shift-drag while mouse reporting is
  active -- writes the selected text to the system pasteboard.
- **I2.** The text written is exactly the selection as it stood when the gesture
  completed, captured atomically with the completing pointer event, and delivered
  at most once. Output arriving between completion and delivery cannot change or
  suppress it.
- **I3.** The clipboard is never cleared or overwritten with an empty string. A
  bare click that selects nothing, and a present selection whose text is empty,
  both leave the previous contents intact. (`selectedText` is nil only when no
  selection exists; a present selection over blank or padding content is non-nil
  and empty, so both cases must be rejected.)
- **I4.** A gesture the terminal consumed never copies, and `selectAll` / Cmd-A
  is not a pointer gesture and never copies.
- **I5.** With the option off, the pointer-up path materializes no selected text
  anywhere. The gate is subscriber presence, so a selection-owned pointer-up
  with no subscriber produces no completion at all -- there is nothing
  downstream to extract text for.
- **I6.** Explicit Cmd-C is unchanged in both modes, including its current
  treatment of a present-but-empty selection.
- **I7.** `ui.copyOnSelect` defaults to true when the key is absent; a
  wrong-typed stored value
  degrades to the default without discarding sibling keys; re-saving a document
  that already carries the key, with the value unchanged, re-emits the original
  bytes; a reload applies a new value without a restart. Like every other
  modeled key, a Save writes the key into a document that does not yet carry it,
  which dirties and re-encodes that document. Do not special-case the default to
  keep it out of the file: that would diverge from the sibling keys, and it
  would make an off-then-on round trip drop the key instead of restoring it.
- **I8.** A completion queued before teardown is never delivered after it.

## Proof obligations

- **PO1 (I1).** Each gesture kind copies when enabled.
- **PO2 (I2).** At the controller -- the production relay, not a shim -- with
  output interleaved both before the pointer-up is applied and again before
  main-queue delivery: the handler receives the exact text the selection held at
  completion, exactly once.
- **PO3 (I3).** An absent selection and a present-but-empty one each leave prior
  clipboard contents intact.
- **PO4 (I4).** Pointer-up consumed by mouse reporting, by the pane menu, and by
  link activation each report no completion; `selectAll` copies nothing.
- **PO5 (I5).** At the controller, with no subscriber installed, a
  selection-owned pointer-up delivers no completion. That is the behavioral form
  of "nothing is extracted": no completion means no captured string to deliver.
  Observing an untouched pasteboard alone is insufficient, because it cannot
  tell "gated" apart from "extracted and discarded"; counting calls to whatever
  helper happens to perform the extraction is also wrong, because it pins the
  test to where extraction currently lives.
- **PO6 (I6).** Cmd-C behavior is unchanged in both modes.
- **PO7 (I7).** Default, decode, per-field type degradation, byte-identical
  unchanged save, draft set / reset / save / reload, the projection's dirty
  label, and the pane key carrying the configured value.
- **PO8 (I8).** The existing application-exit fence and teardown-suppression
  coverage extends to this completion.

## Non-goals

- Changing what an explicit Cmd-C writes for a present-but-empty selection.
- The missing `font.family` row in the README settings table: an independent
  documentation correction that should not share this feature's review or
  rollback.
- Primary-selection semantics or middle-click paste.

## Accepted risks

- **AR1.** Because a selection survives output over its rows, a gesture held
  across a repaint copies the text under the highlight at completion, which can
  differ from what was there when the drag began. Inherited from the
  selection-survival contract this plan depends on, and consistent with Cmd-C.
- **AR2.** Capturing the text walks the whole retained projection, so with the
  option on, every selection-owned release pays that walk on the PTY host queue
  and briefly stalls that pane's output when scrollback is saturated. Bounded at
  once per gesture and identical to what Cmd-C already costs, so the option
  being on is no worse than the copying the user does today by hand. This cost
  is also the concrete reason the gate in I5 has to sit upstream of extraction.

## Rejected ideas

- **RI1.** Deciding eligibility inside the pointer policy. It would force the
  policy to read config and selected text, inverting the gate so text is
  materialized on every pointer-up even when the option is off.
- **RI2.** Having the main actor re-read the selection after the hop, fenced onto
  the owner queue. The fence does not close the window -- output between gesture
  completion and the fenced read changes what is read -- and capturing at
  completion removes the second read rather than guarding it.

## Implementation discretion

- How subscriber presence gates materialization: installing and removing the
  completion handler as the option changes, versus a flag consulted on the owner.
- Placement of the checkbox and its dirty row within the preferences grid.

## Verification

1. `just test` (gate), then `just test-ui` from a GUI session.
2. This checkout is a worktree, so interactive verification runs
   `just provision-worktree` then `just launch`, driving the launched slot with
   an explicit `danterm --socket` argument every time. Do not use
   `just build-run`; it would replace the user's canonical dev app.
3. With no config change, drag-select and confirm the selected text reaches the
   clipboard -- the default is on.
4. Drag-select, double-click a word, triple-click a line; each lands in the
   clipboard. Click once on empty space and confirm the clipboard still holds the
   last selection.
5. In a mouse-reporting app (`vim`, `htop`), clicking does not touch the
   clipboard while Shift-drag still selects and copies.
6. Against a repainting TUI (Claude Code, `btop`): drag a selection over live
   output, release, and confirm the clipboard holds the selected text rather
   than nothing.
7. Cmd+, -> untick "Copy selection to clipboard" -> Save. Confirm the dirty row
   shows the previous value before saving and clears after, that the config file
   gains the key with every other key byte-identical, and that drag-selecting
   now leaves the clipboard untouched.
8. Hand-edit the key back to `true`, reload with Cmd+Shift+,, and confirm
   copy-on-select resumes without a restart.

## Commit progress

- [x] 1. feat(terminal): relay selection text captured at gesture completion
- [ ] 2. feat(config): add ui.copyOnSelect and copy completed selections
