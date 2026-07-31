# Drag-and-drop files onto Swift-engine terminal panes

## Problem

Dropping a file (e.g. an image onto Claude Code) works in a libghostty pane
but silently does nothing in a Swift-engine pane. The Swift engine's pane view
(`app/SwiftTerminalSessionView.swift`) is not a drag destination at all: it
never registers dragged types and implements no `NSDraggingDestination`
methods, so AppKit rejects the drag before any path text is produced. Nothing
else in the pane hierarchy (`PaneWrapperView`, `ScrollableTerminalView`,
`SplitContainerView`, the window) registers dragged types, so there is no
competing destination and no interception -- the drop is simply refused.

The libghostty path already works end to end: `app/TerminalView.swift`
registers `[.fileURL, .URL, .string]` and turns the pasteboard into shell text
via the pure, already-tested `DragDropInput.buildContent`
(`lib/DanTermCore/Sources/DanTermCore/DragDropInput.swift`).

Desired outcome: a drop onto a Swift-engine pane inserts the same text the
libghostty pane inserts today.

## Decision

Make `SwiftTerminalSessionView` a drag destination that reuses the existing
pure helper, and write the resulting text into the pty through the controller's
paste path (`TerminalPaneSessionController.sendPaste`) rather than a raw text
write.

`sendPaste` was chosen over `sendText` because it is what preserves parity.
The libghostty pane's `ghostty_surface_text` call is not a raw write: it lands
in `Surface.zig#textCallback`, which forwards to `completeClipboardPaste` and
so already sanitizes control characters and applies bracketed-paste markers
under DEC 2004. `sendPaste` reproduces that in the Swift engine (and also
scrolls the viewport to the bottom); `sendText` would have been the divergence.

The safety this buys is mode-conditional, and the plan claims only what it
delivers: escape-sequence injection is defeated unconditionally, because
control characters are filtered before the bracket markers are applied;
auto-execution of an embedded newline is prevented only while DEC 2004 is on,
since the unbracketed branch converts LF to CR -- the same residual libghostty
panes have today.

Content derivation is unchanged and stays in the pure core -- no new
pasteboard-aware logic in `DanTermCore`. The pasteboard-to-arguments extraction
step ahead of it is shared by both views rather than duplicated, so the two
panes cannot drift on which pasteboard types they read.

Critical files:

- `app/SwiftTerminalSessionView.swift` -- the drag destination.
- `app/TerminalView.swift` -- gives up its private extraction step to the
  shared one; its observable drop behavior is unchanged. The shared extraction
  cannot live here: `TerminalView.swift` needs GhosttyKit and is deliberately
  excluded from the UI harness, so it needs a GhosttyKit-free home or no proof
  obligation below can run.
- `test-ui.sh` -- the UI harness compiles a hand-listed source set; both
  `DragDropInput.swift` and the shared extraction's file must be added to it.
- `tests-ui/SwiftTerminalSessionViewTests.swift` +
  `tests-ui/SwiftTerminalSessionViewTestShim.swift` -- where the behavioral
  coverage lands; the shim controller already records `sendPaste` output as
  encoded bytes.

## Invariants

- **I1** A drag carrying any of file-URL, URL, or plain-string is accepted by a
  Swift-engine pane with a copy operation; a drag carrying none of them is
  refused.
- **I2** The text a drop delivers is exactly `DragDropInput.buildContent`'s
  output for the same pasteboard -- same file-path-first priority and same
  shell quoting as a libghostty pane.
- **I3** Dropped content reaches the pty through the paste path, so it is
  sanitized and bracketed under the terminal's current input modes.
- **I4** A drop that yields no content writes nothing. (A drop at a torn-down
  pane also writes nothing, inherited from the controller's existing
  `isTornDown` guard -- this change neither establishes nor weakens it.)

## Proof obligations

- **PO1** (I1) A drop with an accepted type is accepted; one with only an
  unrelated type is refused.
- **PO2** (I2) A file drop delivers the shell-quoted path, including a path
  containing spaces. `DragDropInput`'s own priority/quoting rules are already
  covered by `lib/DanTermCore/Tests/DanTermCoreTests/DragDropInputTests.swift`
  and need not be re-proven here.
- **PO3** (I2) A non-file drop -- a pasteboard carrying a URL and a plain
  string but no file URL, as a link dragged out of a browser produces --
  delivers the shell-quoted URL, not the unquoted plain string.
- **PO4** (I3) The bytes reaching the controller are the paste encoding of the
  content, not a raw text write.
- **PO5** (I3, AR1) A multi-line drop with bracketed paste off delivers
  CR-converted bytes, making the residual auto-execute behavior tested and
  visible rather than assumed.
- **PO6** (I4) An empty/whitespace-only pasteboard produces no write.

These land in the `just test-ui` harness, which mounts the real view; it needs
a stub conforming to `NSDraggingInfo` (none exists today).

Manual end-to-end check: `just build-run`, open a Swift-engine pane running
Claude Code, drag an image from Finder onto it, confirm the quoted absolute
path appears; repeat in a libghostty pane and confirm the inserted text matches.

## Non-goals

- Changing the libghostty pane's drop behavior.
- Changing `DragDropInput`'s priority or quoting rules.
- Reading image data off the pasteboard or writing temp files -- only the path
  text is delivered, as today.
- A paste-safety confirmation gate (refuse-until-confirmed for a multi-line
  payload at an unbracketed pane). That is the real answer to AR1, but it needs
  a config knob and a sheet, and both backends are equally exposed so it must
  cover the clipboard paste path too. Its own plan.

## Accepted risks

- **AR1** With bracketed paste off, a multi-line dropped payload auto-executes
  line by line, because the encoder converts LF to CR. Accepted: this is
  exactly what libghostty panes do today, so it is a pre-existing cross-backend
  gap rather than something this change introduces, and closing it belongs to
  the paste-protection plan named in Non-goals rather than a drop-path special
  case.

## Follow Up

- Restore the UI harness's missing Swift-pane search types and controller APIs in
  `tests-ui/SwiftTerminalSessionViewTestShim.swift`; `just test-ui` otherwise
  fails to compile the search calls added by `facbac0` before any UI tests run.
