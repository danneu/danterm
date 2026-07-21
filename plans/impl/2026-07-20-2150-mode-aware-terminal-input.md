# Milestone 6 slice 6: mode-aware keyboard, focus, and safe-paste input

## Context

`plan-terminal-engine/08-input-interaction.md` fixes the input contract: AppKit
translates system events into explicit engine inputs; key encoding and paste
policy are deterministic decisions outside the framework calls that receive
events; the engine supports the legacy xterm key contract, application
cursor/keypad modes, focus reporting, bracketed paste, and the Kitty keyboard
protocol before becoming the default backend; macOS composition has precedence
over every terminal keyboard mode; paste preserves text, tabs, and newlines,
removes unsafe control bytes, and uses bracketed-paste markers when enabled;
"Key encodings agree with active terminal modes and advertised protocols" and
"Identical normalized input and terminal modes produce identical encoded bytes
or local actions" are standing invariants.
`plan-terminal-engine/10-protocols-shell-integration.md` requires that
capability queries never claim unsupported behavior and lists "legacy xterm and
Kitty keyboard negotiation" in the accepted tranche.
`plan-terminal-engine/04-terminal-core.md` names "keyboard event
interpretation" a core non-goal -- read against the 03 boundary this excludes
platform event interpretation (NSEvent, IME, composition), not deterministic
byte encoding from already-normalized semantic keys, which is exactly the pure
decision 08 demands be testable without AppKit ("Input-policy tests run
without AppKit").

Slice-map note: the Milestone 6 map sketched input encoding after viewport
navigation; slice 5 (`plans/impl/2026-07-20-1659-local-viewport-navigation.md`)
landed and explicitly deferred DECCKM-aware arrow encoding to "the
input-encoding slice" (its AR3). Mouse reporting stays a separate Milestone 6
slice and is out of scope here.

Verified premises (against the working tree):

- `Terminal` (`lib/TerminalCore/Sources/TerminalCore/Terminal.swift`) keeps
  modes as discrete fields (`isInsertMode`, `isLineFeedNewLineMode`,
  `isOriginMode`, `isAutoWrapMode`, `isCursorVisible`,
  `isSynchronizedOutputActive`, ...). `applyDECPrivateModes` handles only
  6, 7, 25, 2026, 1047, 1048, 1049; `applyANSIModes` handles 4 and 20;
  `decPrivateModeStatus`/`ansiModeStatus` return 0 for unknown modes. DECCKM
  (mode 1), 1004, 2004, keypad application mode, and Kitty flags have no
  state anywhere. `ESC =` / `ESC >` reach `dispatchEscape(_ final:)` and hit
  `default: break` (parsed-and-ignored).
- CSI private markers `<`, `=`, `>`, `?` are collected into `intermediates`
  when first after CSI (`EscapeAbsorber.swift:161-163`), and `dispatchCSI`
  gates on exact intermediate arrays. Bare `CSI u` (empty intermediates) is
  SCORC restoreCursor, guarded on empty parameters (`Terminal.swift:1777`).
  `CSI > 1 u`, `CSI < u`, `CSI = 1;1 u`, and `CSI ? u` are all currently
  inert, as are the modifyOtherKeys sequences (`CSI > 4;2 m`, `CSI ? 4 m`).
- Replies flow through `appendReply` -> `replyBytes` ->
  `pendingReplyBytes`/`drainReplyBytes()`; the host drains only inside
  `applyOutput` and writes drained bytes back to the PTY. `softReset()`
  (DECSTR) and `hardReset()` (RIS) both funnel through `resetControlState()`
  -- the single mode-reset choke point. `switchAlternateScreen` swaps grid
  rows only; mode flags persist across 1047/1049.
- `TerminalPTYHost` is the serialized owner of the authoritative `Terminal`;
  `send(_:)` snaps the viewport to bottom before `.sendInput`; capture
  support records `.input` and viewport transitions. `TerminalWheelIntent`
  carries pre-encoded `alternateScreenStepBytes` built by the session with
  the mode-blind encoder (slice 5's AR3 stopgap).
- `TerminalPaneSessionController.sendKey` calls the stateless free function
  `encodeTerminalKey`
  (`lib/TerminalPTY/Sources/TerminalPaneSession/TerminalInputEncoding.swift`)
  against no mode state, then `send` -- the shape this slice removes.
  `TerminalInputKey` covers only return/tab/backspace/escape, arrows,
  home/end, page keys, deleteForward, and `letter`; `letter` encodes only
  under Control.
- `app/SwiftTerminalSessionView.swift`: `keyDown` bails on Cmd, runs
  `interpretKeyEvents`; committed text -> `sendText`; otherwise
  `terminalKey(for:)` -> `sendKey`. Control characters fail
  `isCommittedTerminalText` (scalars below 0x20 and the 0xF700-0xF8FF PUA
  range are excluded), so Ctrl combos and function keys fall through to the
  encoder path. `setFocused(_:)` and `pasteClipboard()` are empty stubs;
  there is no `resignFirstResponder` override and no `paste(_:)`
  implementation, so menubar Cmd-V is dead on the Swift pane; context-menu
  Paste reaches `pasteClipboard()` via `PaneWrapperView.swift:481`. IPC
  `sendInputKey` drops F1-F12.
- `lib/DanTermProtocol`: `NamedKey` already has `f1...f12`; `KeyMods`
  carries only ctrl/alt; `KeyTokens.swift` parses `S-` into an internal
  ModSet that already has a `.shift` slot and rejects it unconditionally
  ("v1", lines 28-31).
- Fixture machinery: `NeutralTerminalRecordingEvent` =
  `feed`/`resize`/`viewport`/`checkpoint`; unknown event types throw.
  `TerminalFixtureTests` replays under authored/bytewise/split chunkings,
  drains reply bytes after each feed into a buffer that `expect` checkpoints
  assert (`replyBytes`), and compares whole `Terminal` values across
  strategies. The manifest test pins 32 files and a hard-coded
  `expectedCases` table; `t/25state_input.test` (pinned commit
  `934bc2fbf21800ac3458a499df8820ca5fb45fd3`) is absent from both.
  `recordedDeviations` currently holds seven declared deviations.
- Upstream `t/25state_input.test` emits fixterms-flavored CSI-u for several
  legacy (no-mode-enabled) combos: Ctrl-Shift-A -> `\e[65;5u`, Ctrl-I ->
  `\e[73;5u`, Ctrl-Tab -> `\e[9;5u`, modified Space (`\e[32;2u`, ...),
  Ctrl-Alt-letter -> `\e[65;7u`. Strict xterm legacy emits `0x01`, `0x09`,
  `0x09`, NUL/ESC forms, and ESC + control byte respectively, and
  readline-based apps render unsolicited CSI-u as garbage.
- `plan-terminal-engine/15-open-questions.md:18-19` carries the
  modifyOtherKeys question.

User-settled toggles for this slice: mouse reporting is out of scope;
modifyOtherKeys is deferred unless prioritized workflow evidence requires it;
Kitty support is negotiation-complete but implements flag 1 (disambiguate)
only; IPC/CLI gains Shift support (`S-` on named keys, `KeyMods.shift`);
native Option/dead-key/IME composition keeps precedence over all terminal
keyboard modes; encoding happens owner-side against authoritative modes.

## Decision

Scope: keyboard/focus/paste mode state and Kitty negotiation in the core
(pure state + replies), a pure mode-aware encoder module in TerminalCore,
owner-side encoding entry points on the PTY host, expanded key vocabulary
through AppKit and IPC, paste and focus wiring in the Swift pane, the adapted
`25state_input` fixture family plus native Kitty/paste/IPC/AppKit tests, and
the modifyOtherKeys decision record. No mouse reporting, no OSC 52, no
Option-as-Alt.

- **D1. Keyboard modes are core state; the encoder is a pure TerminalCore
  function, not a `Terminal` method.** `Terminal` gains state for
  DECSET/DECRST 1, DECKPAM/DECKPNM, 1004, 2004, and the per-screen Kitty
  flag stacks in D3. The modes use the existing dispatch and reset seams,
  participate in value equality, and expose a read-only projection consumed
  by pure key, focus, and paste encoding. DECRQM reports 1/2 for modes 1,
  1004, and 2004. Rationale against the alternatives: mutating `Terminal`
  methods appending to `replyBytes` (libvterm's shape) would conflate the
  child-output reply stream with user input and stretch 04's core contract,
  while keeping the encoder session-side forces mirrored mode state and
  re-creates the stale-snapshot race. A pure core function is (a) callable
  by the fixture runner, which only touches TerminalCore, (b) callable
  inside the host actor against the authoritative value (TerminalPTY already
  depends on TerminalCore), and (c) exhaustively testable without AppKit.
- **D2. Legacy encoding is strict xterm; libvterm's fixterms outputs are
  declared deviations.** With empty Kitty stacks, DanTerm never emits CSI-u:
  Ctrl+letter (with or without Shift) -> the control byte; Ctrl+I -> 0x09;
  Ctrl+Space -> NUL; Shift+Space -> 0x20; Alt -> ESC prefix on the
  otherwise-encoded bytes; Ctrl+Alt+letter -> ESC + control byte; Ctrl+Tab
  -> 0x09; Shift+Tab -> `CSI Z`; Enter -> 0x0D (0x0D 0x0A under LNM; ESC
  0x0D with Alt); Backspace 0x7F (Ctrl: 0x08; Alt: ESC 0x7F); modified
  navigation/function keys use `CSI 1;mods X` / `CSI n;mods ~` with
  mods = 1 + (shift 1 | alt 2 | ctrl 4); DECCKM selects SS3 forms for
  unmodified arrows/Home/End only; F1-F4 unmodified SS3 P/Q/R/S, modified
  `CSI 1;mods P..S`; F5-F12 `CSI 15/17/18/19/20/21/23/24 [;mods] ~`; Insert
  `CSI 2~`; keypad digits/operators/Enter ASCII under DECKPNM and SS3 forms
  under DECKPAM (KP0 -> `ESC O p`, matching upstream). Rationale: emitting
  unsolicited CSI-u breaks readline-family apps on the Milestone 7 list;
  xterm, ghostty, and kitty all emit plain legacy bytes when no enhancement
  is negotiated; fixterms behavior is exactly what Kitty flag 1 provides on
  request.
- **D3. Kitty keyboard: full negotiation, flag 1 (disambiguate) only,
  per-screen stacks.** `dispatchCSI` gains final-`u` handling inside the
  intermediate-gated blocks: `[0x3E]` push (flags masked to supported bits),
  `[0x3C]` pop n (default 1; clamps at empty), `[0x3F]` query -> reply
  `CSI ? flags u` with the active stack top (0 when empty -- the reply's
  presence is the support signal), `[0x3D]` set flags;mode (modes 1/2/3 per
  spec, operating on the stack top). All other finals under those
  intermediates stay inert, and bare `CSI u` remains SCORC. Two stacks
  (primary, alternate) selected by the active screen; screen switches never
  copy or clear them; `resetControlState()` clears both (RIS per spec;
  DECSTR conservatively, AR3). Stack depth is a pinned constant with
  oldest-entry eviction on overflow per the spec's allowance (default 8;
  discretion). Unsupported bits (2 event types, 4 alternate keys, 8
  report-all, 16 associated text) are masked at push/set so the query never
  advertises them -- the 10-protocols honesty rule. Flag 2 is deferred
  because it requires keyUp/repeat plumbing through view, controller, host,
  and protocol for zero Milestone 7/8 minimum-workflow need; nvim wants
  flag 1, Claude Code wants modified-Enter disambiguation (flag 1), and
  spec-conforming clients degrade correctly against a masked reply
  (user-settled).
- **D4. Kitty flag-1 encoding.** While the active stack top is nonzero:
  Esc -> `CSI 27 u` (`CSI 27;mods u` modified); any key with Ctrl and/or
  Alt -> `CSI unshifted-codepoint;mods u` (Ctrl+A -> `CSI 97;5u`,
  Ctrl+Shift+A -> `CSI 97;6u`); Enter/Tab/Backspace unmodified keep
  0x0D/0x09/0x7F, modified become `CSI 13/9/127;mods u` (Shift+Enter ->
  `CSI 13;2u`, Shift+Tab -> `CSI 9;2u` -- `CSI Z` is legacy-only);
  arrows/Home/End always use CSI forms (`CSI [1;mods] A..D/H/F`) -- DECCKM
  and DECKPAM are ignored while any flag is active; F1/F2/F4 use CSI
  P/Q/S forms, while F3 uses `CSI 13~` unmodified and `CSI 13;mods~`
  modified so it cannot collide with a cursor-position response; other
  tilde keys keep `CSI n;mods ~`; unmodified and shift-only text keys still
  produce text; modified keypad keys use the spec's functional codepoints
  (57399+) in CSI-u. mods = 1 + (shift 1 | alt 2 | ctrl 4); Command/super
  is never encoded (filtered at the view; absent from IPC). Exact per-key
  rows follow the kitty functional-key table (discretion within pinned test
  vectors).
- **D5. modifyOtherKeys is DEFERRED, and the decision is recorded.** No
  state, no encoding, no `CSI > 4;n m` effect, no `CSI ? 4 m` reply -- both
  remain verified-inert, so vim's probe times out and it falls back to
  legacy keys (its graceful path) while nvim and modern TUIs use Kitty
  flag 1. Rationale: every Milestone 7/8 app on the list completes its
  minimum workflow on legacy + Kitty; a second overlapping enhancement
  protocol multiplies the encoder matrix and test surface for no
  demonstrated need. Recording: this plan; delete the bullet at
  `plan-terminal-engine/15-open-questions.md:18-19`; add one sentence to
  08-input-interaction.md's keyboard section ("xterm modifyOtherKeys is
  deferred; its set and query sequences stay inert until a prioritized
  application workflow demonstrably requires it"). Reopen trigger: a
  Milestone 7/8 minimum workflow failing for lack of it.
- **D6. Owner-side atomic encoding.** The serialized pane owner reads
  authoritative modes, encodes, and writes keys, paste, focus reports, and
  alternate-screen wheel input in one FIFO step. Keys and non-empty
  sanitized pastes snap the viewport to bottom; focus never snaps, and a
  sanitized-empty paste produces no markers, write, or viewport movement.
  Alternate-screen wheel input uses authoritative DECCKM, resolving slice 5
  AR3. Controllers, sessions, and backend adapters only forward normalized
  input and hold neither encoding logic nor mode mirrors. Encoded bytes and
  viewport transitions continue through the existing capture paths.
- **D7. Paste pipeline.** Pure core policy removes every C0 byte
  except HT/LF/CR, removes DEL and C1 scalars (U+0080-U+009F), and always
  removes ESC -- an embedded `ESC[201~` therefore degrades to the literal
  text `[201~` and escape injection is structurally impossible; unbracketed
  paste additionally normalizes CRLF and lone LF to CR (line-execution
  convention); bracketed paste preserves LF/CR verbatim. Marker encoding
  yields `ESC[200~`/`ESC[201~` iff 2004 and the sanitized body is non-empty;
  an empty or fully stripped body is a complete no-op before marker
  generation or viewport snapping. The host composes marker + sanitized
  body + marker in one owner step. Both menubar Cmd-V and the
  pane's context-menu Paste read string content from the system pasteboard
  and submit it through that same owner-side policy.
- **D8. Focus wiring.** Runtime pane-focus signals and responder transitions
  pass through one deduplicating focus funnel before reaching the pane
  owner. The owner gates reports on authoritative 1004 at emission time; no
  report occurs when the mode is off or merely enabled, and focus reporting
  never mutates `Terminal`.
- **D9. Expanded vocabulary and adapters.** The shared normalized key
  vocabulary covers Insert, F1-F12, keypad keys, and character keys carrying
  the true unshifted Unicode scalar. AppKit derives that scalar from the
  keyboard layout without Control's character mutation, so Ctrl+Space and
  Ctrl+`[`, `\\`, `]`, `^`, and `_` reach the encoder alongside letters.
  Option passes as a modifier only on non-text keys because composition owns
  text keys (D10). IPC maps every existing named F-key and adds Shift to its
  modifier set; the CLI accepts `S-` on named keys while continuing to reject
  `S-letter`. Both the Swift-engine and Ghostty session adapters propagate
  Shift, including `S-Tab`, so the backend-neutral wire operation has the
  same meaning during coexistence. `integrations/danterm/SKILL.md` documents
  the widened CLI surface.
- **D10. Composition precedence is structural.** The view's flow is
  unchanged: `interpretKeyEvents` first; committed text (dead-keys, IME,
  Option-composed characters) always leaves via `sendText` as plain UTF-8 --
  never through the key encoder, under every mode including active Kitty
  flags (08: Kitty encoding applies only to non-text keys and after
  commit). Only events that produce no committed text reach `sendKey`.
  Marked-text handling, `isCommittedTerminalText`, and the Cmd bail are
  untouched.
- **D11. Adapted input corpus.** Neutral fixture inputs produce ordered
  bytes from the replayed terminal's authoritative modes without mutating
  `Terminal` or embedding platform events. The adapted corpus retains
  libvterm provenance, and its manifest dispositions cover every upstream
  case heading: unmodified ASCII, Alt letters, cursor keys, LNM Enter, F1,
  keypad, paste, and focus are adopted; Ctrl letters, Ctrl-Alt letters,
  Ctrl-I, Space, and the Ctrl rows of Shift-Tab use DanTerm's strict-legacy
  outputs. The deviation record states that DanTerm emits strict xterm
  legacy encodings where pinned libvterm emits unsolicited fixterms CSI-u
  for modified letters, Space, and Tab. Native DanTerm provenance covers
  Kitty negotiation and input encoding alongside the pure Kitty and paste
  policy tests.

## Invariants

- **I1 (mode fidelity).** For every key/paste/focus input, emitted bytes are
  a pure function of (normalized input, authoritative modes at emission);
  DECCKM, DECKPAM/DECKPNM, LNM, 1004, 2004, and the active Kitty stack top
  each change exactly their specified encodings and nothing else.
- **I2 (no unsolicited enhancement).** With empty Kitty stacks, output
  contains only strict xterm legacy encodings -- no CSI-u ever; the Kitty
  query reply reports exactly the stored (masked) flags; modifyOtherKeys
  set/query sequences remain inert with no reply; DECRQM reports 1/2 for
  modes 1, 1004, 2004 and 0 for unimplemented modes.
- **I3 (composition precedence).** Text committed by macOS composition
  (dead-keys, IME, Option-composed) reaches the PTY as its UTF-8 via the
  text path under every keyboard mode, including active Kitty flags; the
  key encoder never sees it.
- **I4 (owner atomicity).** Mode read, encoding, and PTY write happen in one
  owner-executor step for keys, paste, focus, and the wheel alt-arm; no
  component outside the executor holds encoding logic or mode mirrors; once
  the owner has applied a mode-setting feed, no later input can produce
  bytes encoded against the superseded mode value.
- **I5 (paste safety).** The sanitized paste body reaching the PTY contains
  no ESC, no C0 other than HT/LF/CR, and no DEL/C1; embedded bracket-end
  text is neutralized; tabs and newlines are preserved per policy (LF -> CR
  only when unbracketed). The only ESC bytes in a bracketed paste are the
  engine-generated markers, which wrap the body iff authoritative 2004 is
  active at emission; an empty body emits nothing and leaves the viewport
  unchanged.
- **I6 (focus gating and lens purity).** `CSI I`/`CSI O` are emitted iff
  1004 is set when the owner processes the focus change; focus changes,
  encodings, and paste mutate no `Terminal` state; focus never scrolls;
  sendKey and non-empty paste snap the viewport to bottom exactly like
  non-empty `send`.
- **I7 (reset and screen discipline).** `resetControlState` restores all
  new modes to defaults and empties both Kitty stacks (DECSTR and RIS);
  keyboard modes persist across 1047/1049 switches; each screen's Kitty
  stack is independent and the active screen selects the effective flags.
- **I8 (fixture transparency).** Input fixture events never mutate
  `Terminal`; the existing corpus, chunk-invariance results, manifest
  equality, and recording replays pass unchanged except for the added
  corpus and manifest coverage; emitted bytes remain ordered and derive
  from the replayed terminal's modes.
- **I9 (one vocabulary end-to-end).** IPC key names (F-keys, `S-` prefix)
  and AppKit key events map onto the same
  `TerminalInputKey`/`TerminalKeyModifiers` vocabulary and produce
  identical bytes for identical semantic input.

## Proof obligations

- **PO1 (I1, I2).** Core encoder matrix tests (`TerminalKeyEncodingTests`):
  the full legacy modifier matrices for arrows/nav/F-keys,
  Ctrl/Alt/Shift letter-space-control-punctuation-tab-enter-backspace forms,
  including Ctrl+Space and Ctrl+`[`, `\\`, `]`, `^`, and `_`, the DECCKM
  SS3-vs-CSI split, DECKPAM/DECKPNM keypad tables, LNM Enter, and the Kitty
  flag-1 matrix (Esc, modified Enter/Tab/Backspace, Ctrl(+Shift) letters,
  Ctrl+Space/control-punctuation, arrows ignoring DECCKM, unmodified
  `CSI 13~` and modified `CSI 13;mods~` F3 rows, representative keypad CSI-u
  rows).
- **PO2 (I2, I7).** Kitty negotiation tests (`TerminalKittyKeyboardTests`):
  push/pop/query/set round-trips; masking of unsupported bits in push, set,
  and query; pop-past-empty clamp; overflow eviction at the pinned depth;
  per-screen independence across 1047/1049; both stacks cleared by DECSTR
  and RIS; bare `CSI u` still restores the cursor (SCORC regression);
  `CSI > 4;2 m` and `CSI ? 4 m` inert with an empty reply stream; updated
  `TerminalModeTests`/`TerminalQueryTests`/`TerminalResetTests` matrices
  for modes 1/1004/2004 and keypad.
- **PO3 (I5).** Paste policy tests: control stripping, ESC removal,
  embedded `ESC[201~` neutralization, CRLF/LF -> CR only when unbracketed,
  tab/newline preservation, marker wrapping iff 2004, and empty or fully
  stripped paste producing no bytes or viewport movement.
- **PO4 (I8).** The adapted input corpus passes every expectation under all
  chunkings; its manifest covers every upstream case disposition and the
  strict-legacy deviation; all existing fixtures replay byte-identical; the
  DanTerm Kitty recording replays.
- **PO5 (I4).** Host-level race tests via capture support: feed `CSI ? 1 h`
  through `applyOutput` then immediately `sendKey(.up)` -- captured input
  is `ESC O A`; the same shape for 2004-gated paste wrapping and 1004-gated
  focus; the wheel alt-arm emits SS3 arrows when DECCKM is set on the
  alternate screen (replacing the slice 5 carried-bytes test); the
  controller contains no encoding call sites.
- **PO6 (I6).** Focus emits nothing with 1004 off, `CSI I`/`CSI O` with it
  on, mutates no snapshot, and does not move a browsing viewport; sendKey
  and non-empty paste snap to bottom (twin of slice 5's PO5 trigger test),
  while sanitized-empty paste preserves a browsing viewport; a capture of a
  session containing keys/paste/focus replays whole-value equal.
- **PO7 (I9).** IPC tests: `sendInputKey` F-keys reach the PTY with correct
  bytes; `S-Tab` parses and produces `CSI Z` (legacy) / `CSI 9;2u`
  (flag 1); `S-letter` and other still-unsupported forms stay rejected;
  both `TerminalSession` adapters preserve Shift and deliver Shift-Tab;
  AppKit and IPC paths produce identical bytes for the shared vocabulary;
  `integrations/danterm/SKILL.md` documents the widened surface.
- **PO8 (I3).** UI-harness tests (`just test-ui`): dead-key composition
  (Option+e, e), Ctrl+Space, every ASCII control-punctuation key, and a
  function-key event with Kitty flag 1 active -- committed text goes out as
  text, normalized control characters match the core's legacy and Kitty
  vectors, and the F-key goes out encoded; Cmd-V via `paste(_:)` and
  context-menu `pasteClipboard()` both deliver sanitized clipboard content;
  the focus funnel dedupes repeated setFocused/first-responder signals.

Slice exit gate: `just test` green (all packages plus lint scripts), `just
build` green, and `just test-ui` green including PO8; a checked Milestone 6
slice 6 sub-bullet in `plan-terminal-engine/14-roadmap.md` linking the
promoted plan; the 15-open-questions and 08 edits landed. Live sanity check,
non-gating: in a Swift-engine pane run `cat -v` and verify arrow/F5/Shift-Tab
bytes; arrows in `less` (DECCKM); `printf '\e[?2004h'; cat -v` then paste
multiline text and see bracket markers; paste text containing an escape
sequence into `cat -v` and see it stripped; run `kitten show-key -m kitty` or
nvim to see flag-1 negotiation; Cmd-V pastes.

## Non-goals

- Mouse reporting in any form (separate Milestone 6 slice).
- xterm modifyOtherKeys (deferred by D5) and the 1035/1036/1039 meta modes.
- Kitty flags 2/4/8/16, key-release/repeat events, and keyUp handling.
- Option-as-Alt configuration and preedit (marked-text) rendering.
- Multiline-paste confirmation and OSC 52 (08 places both elsewhere).
- F13+ keys, media keys, and non-macOS keyboard layouts beyond the
  layout-derived unshifted-scalar normalization contract.
- Alternate-scroll mode (1007) as a real mode; the wheel alt-arm stays
  unconditional (now DECCKM-aware).

## Accepted risks

- **AR1.** With empty Kitty stacks, Ctrl+Shift+letter is indistinguishable
  from Ctrl+letter (strict legacy). By design; flag 1 is the remedy apps
  opt into.
- **AR2.** Apps requesting Kitty flags 2/4/8/16 run with only flag 1 in
  effect; the masked query reply is the spec's own degradation path, but
  behavior differs from full-kitty terminals.
- **AR3.** DECSTR clears the Kitty stacks (the spec mandates only RIS). A
  conservative superset via the single `resetControlState` choke point;
  matches xterm's DECSTR keyboard-mode resets in spirit.
- **AR4.** Focus reports track DanTerm's pane-focus signal and
  first-responder status, not window-occlusion nuance; an app may see
  focus-in while the window is inactive in edge sequences. The dedupe
  funnel bounds the noise.
- **AR5.** No initial focus report on 1004 enable; an app enabling 1004
  learns focus state only at the next transition (xterm-compatible).
- **AR6.** Local keyboards cannot produce Alt+letter combos (Option owns
  composition per 08); IPC can (`M-` prefix). The asymmetry is the
  documented product contract, not a defect.
- **AR7.** Accepting `S-` widens the v1 wire surface; Shift on
  legacy-meaningless combos participates only where encodings define it
  (e.g. `S-Up` -> `CSI 1;2A`), and `S-letter` stays rejected.

## Rejected ideas

- **RI1.** Encoding as `Terminal` mutating methods appending to
  `replyBytes` (the libvterm shape): conflates the child-reply stream with
  user input, forces host drains outside `applyOutput`, and stretches 04's
  core contract; a pure function gives the same fixture reach without the
  coupling.
- **RI2.** Keeping the encoder in `TerminalPaneSession` with mirrored mode
  state: every mirror is a lagging snapshot across a `CSI ? 1 h` echo --
  exactly the race class slice 5's RI7 removed for wheels.
- **RI3.** Implementing modifyOtherKeys now "since we're in the encoder
  anyway": doubles the enhanced-encoding matrix for zero prioritized-app
  need; vim degrades gracefully, nvim uses Kitty.
- **RI4.** Implementing all Kitty flags: flag 2 alone drags keyUp/repeat
  plumbing through five layers; claiming flags without release events would
  violate the capability-honesty rule.
- **RI5.** Adopting libvterm's fixterms legacy outputs verbatim to keep the
  fixture pristine: ships readline-breaking bytes to every Milestone 7
  shell; the manifest's deviation mechanism exists precisely for this.
- **RI6.** A single Kitty stack shared across screens: the spec requires
  per-screen stacks so a full-screen app's flags cannot leak to the shell
  on exit.
- **RI7.** Sanitizing paste in the AppKit layer: untestable without AppKit
  and bypassable by IPC-originated paste later; core-pure policy serves
  both.
- **RI8.** Carrying pre-encoded arrow bytes in `TerminalWheelIntent`
  (status quo): now that the encoder is core-side, the host can encode
  DECCKM-correct arrows itself; the carried payload was slice 5's stopgap
  (its AR3).

## Implementation discretion

- Kitty stack depth constant and eviction bookkeeping; exact keypad
  functional-codepoint rows beyond the pinned test vectors.
- Sanitizer treatment of exotic scalars beyond the pinned classes (e.g.
  U+2028/U+2029), provided I5 holds.
- Fixture serialization and replay-helper details.
- Whether `TerminalPaneSession` re-exports the moved types via typealiases
  or call sites reference TerminalCore directly.
- Focus dedupe placement (view vs controller) and the AppKit keyCode table
  layout.

## Commit progress

- [x] 1. Add pure mode-aware terminal input policy and conformance fixtures
- [ ] 2. Route normalized input atomically through PTY ownership and IPC adapters
- [ ] 3. Wire AppKit input behavior and finish slice documentation and UI proof
