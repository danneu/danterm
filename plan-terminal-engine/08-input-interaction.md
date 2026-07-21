# Input and Interaction

## Problem

macOS text composition, terminal key protocols, mouse-reporting applications,
local selection, paste safety, clipboard access, and links overlap at the view
boundary and need explicit precedence.

## Decision

AppKit translates system events into explicit engine inputs. Key encoding,
mouse reporting versus local selection, paste policy, and link validation are
deterministic decisions outside the framework calls that receive events, access
the clipboard, or open URLs.

### Keyboard and text input

macOS owns text composition through its text input system. Option remains a
native composition modifier so dead-key sequences for Spanish text work. The
initial engine does not offer Option-as-Alt. Functional keys and non-text
terminal input use the terminal key encoder.

The engine supports the legacy xterm key contract, application cursor/keypad
modes, focus reporting, bracketed paste, and the Kitty keyboard protocol before
becoming the default backend. Kitty behavior is opt-in through its protocol;
legacy applications retain legacy key behavior.
xterm `modifyOtherKeys` is deferred; its set and query sequences stay inert
until a prioritized application workflow demonstrably requires it.

macOS composition has precedence over every terminal keyboard mode. Option is
never reinterpreted as terminal Alt while it is participating in composition;
Kitty encoding applies only after text is committed and to non-text key events.

### Mouse and selection

The engine supports local text selection and SGR mouse reporting. When an
application has captured mouse input, Shift-drag bypasses reporting and creates
a local selection.

The primary screen exposes retained history through wheel scrolling and a
native vertical scrollbar. The local viewport follows the live bottom until the
user navigates to older content. While at bottom, output and reflow keep it at
the newest rows. While browsing history, the top displayed logical position is
the stable anchor: output and reflow do not snap it to the bottom, and eviction
clamps it to the oldest retained logical position without re-enabling bottom
follow. Navigating explicitly to the newest row re-enables bottom follow. The
scrollbar represents the currently reflowed visual-row extent and viewport.

Search navigation reveals its selected match without enabling bottom follow,
and local scrolling does not clear a selection or search. Selection endpoints
and search matches remain attached to retained logical content across appended
output and reflow; content overwritten by terminal output or evicted from
history invalidates the affected endpoint or match rather than retargeting it to
unrelated text.

When application mouse reporting is active, an unmodified wheel event is sent
to the application and does not scroll local history. Shift-wheel forces local
history navigation and emits no mouse-report bytes. The native scrollbar is
always local and never emits terminal mouse input.

Copy-on-select is not part of the initial engine. Explicit copy uses the current
selection.

### Paste and clipboard

Paste preserves text, tabs, and newlines, removes unsafe control bytes, and uses
bracketed-paste markers when the application enables that mode. The initial
engine does not show a multiline-paste confirmation.

OSC 52 writes are allowed up to 1 MiB of decoded clipboard content. OSC 52 reads
are denied. This policy applies equally to local, tmux, and remote applications.

### Links

OSC 8 hyperlinks and automatic `http://` and `https://` detection are supported.
Both explicit and detected links are activatable only when the resolved URL uses
`http` or `https`; other schemes remain inert text. Cmd-hover exposes allowed
link interaction and Cmd-click opens the resolved URL. File path and
source-location navigation are deferred.

## Invariants

- Text committed by macOS composition reaches the PTY as the intended Unicode
  text without an extra Option/Alt encoding.
- Key encodings agree with active terminal modes and advertised protocols.
- Local selection never emits mouse-report bytes to the child application.
- A locally scrolled viewport remains attached to the same retained logical
  content across output and reflow until that content is evicted.
- Mouse-report capture and its Shift override cannot both consume one wheel or
  drag gesture.
- Remote output cannot read the system clipboard through OSC 52.
- Paste cannot inject disallowed terminal control sequences through clipboard
  content.
- Link activation is an explicit user action and malformed links do not launch.
- Terminal output cannot activate file URLs or custom URL handlers through an
  OSC 8 target.
- Identical normalized input and terminal modes produce identical encoded bytes
  or local actions.

## Proof obligations

- Dead-key Spanish input and Chinese IME composition commit correct UTF-8 text.
- Legacy, application-mode, modified, and Kitty key scenarios emit their
  specified byte sequences.
- Dead-key composition remains native while each supported Kitty keyboard mode
  is active.
- Mouse tracking modes receive correct press, release, motion, and wheel events,
  while Shift-drag selects and Shift-wheel scrolls history locally.
- Wheel and scrollbar fixtures cover bottom follow, navigation away from and
  back to bottom, stable anchors during output and primary-screen reflow,
  eviction clamping, search reveal, selection retention, and scrollbar
  round-trips.
- Bracketed and unbracketed paste preserve allowed content and remove disallowed
  controls.
- OSC 52 accepts bounded writes, rejects oversized writes, and never returns
  clipboard contents.
- Explicit and detected hyperlinks have correct hover, selection, and opening
  behavior, and non-HTTP schemes never become activatable.
- Input-policy tests run without AppKit; focused integration tests prove macOS
  composition, event translation, clipboard access, and URL opening at the
  system boundary.

## Non-goals

- Initial Option-as-Alt configuration.
- Copy-on-select.
- File path, source location, or arbitrary custom-link handlers.
- Clipboard read permission prompts in the initial engine.

## Implementation discretion

- The exact unsafe-control policy, provided ordinary text, tabs, and newlines
  retain the stated behavior and escape injection is prevented.
- The URL detector, provided explicit OSC 8 links and the required URL schemes
  behave consistently.
