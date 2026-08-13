# F4 -- Mac-to-Mac thin client: convergence, and what a mid-stream join lacks

The T4 finding, in its own file because the mid-stream-join half is the input to T8 and needs
room. The spike lives at [t4-spike/](t4-spike/); it is a throwaway evidence generator and is not
part of the app build or `just test`.

### F4 -- a second macOS process converges from the tape, and states exactly what a joiner lacks

- **Status:** complete. H3's convergence half is confirmed; the mid-stream-join half is now
  described in terms of concrete missing state rather than "it lacks history".

- **Date and investigator:** 2026-08-12, T4 session.

- **Commit and worktree state:** worktree `t4-mac-to-mac`, branched from `38676539`
  (`Merge branch 'worktree-pane-tape-jsonl'`). The only tracked change is the new
  `t4-spike/` directory. The app under test was a debug `just launch-slot` build of that
  same commit, in slot 1.

- **Commands, inputs, or reproduction:**
  - Client: `t4-spike/Sources/T4ThinClient/main.swift`, an executable that connects to the
    control socket itself (`AF_UNIX`, `hello`, then a `pane.tape` request with `follow`), decodes
    each `pane.tape.event` record into a `NeutralTerminalRecordingEvent`, drives its own
    `TerminalCore.Terminal`, and prints one JSON report. It applies `feed`, `resize`, `viewport`,
    and `mouse`, and ignores `write`, `input`, `paste`, and `focus`, the same way
    `NeutralTerminalRecording.replay` does. It does not use the `danterm` CLI as a transport, so
    the protocol path under test is the one a phone would use.
  - Scenario driver: `t4-spike/scenarios.sh <socket> <pane> <scenario>`, with scenarios
    `converge`, `join`, `joinbytes`, `state`, `aftermath`, `geometry`, `reflow`, `evict`,
    `reconnect`, and `close`. Each one starts one or two clients against a live slot, drives the
    source pane through `danterm pane input` / `pane zoom` / `pane close`, and captures both sides
    under `.build/t4/`.
  - Every run drove slot 1 with an explicit `danterm --socket
    /Users/dan/Library/Caches/com.danneu.danterm-dev.1/control.sock`.

- **Result or artifact paths:** reports and captured text under `.build/t4/` in the worktree
  (`<scenario>-client.json`, `<scenario>-source.txt`, `joinbytes.jsonl`). They are build output,
  not committed evidence; `scenarios.sh` regenerates them.

- **Measurements or examples:**

  **Convergence (`converge`).** A client attached with a backlog follow, replayed the pane's whole
  retained tape from birth, then followed live while `danterm pane input` ran a workload with SGR
  color, a wide-character pair, and eight lines of scrolling output. Its `viewportText` was
  **byte-identical** to the source pane's `danterm pane read` -- 30 lines, checked to the last
  byte, including the trailing space after the prompt. `scrollProjection.totalRows` was 66 on both
  sides (`pane rows` returned 66 rows). The client applied 73 events (61 `feed`, 11 `write`
  ignored, 1 `resize`) and reported no gap and no sequence break. It also planned a
  `RenderFramePlan` (179x66, 96 text runs, 3 background runs, cursor present) from its own
  engine, so the render seam works off a remotely fed terminal with no AppKit in the process.

  The uplink half works through the existing surface: the input that produced this output was sent
  with `pane.input` on a second connection while the client watched. A thin client needs no new
  method to type.

  **Joining mid-stream (`join`).** With `--from-now`, the client's first visible line was
  `echoecho after-join`, not `echo after-join`. `joinbytes.jsonl` names the cause: the first feed
  event after the join is sequence 93,
  `{"text":"echo "},{"control":"CR"},{"control":"ESC"},{"text":"[9C"}` -- fish repaints the
  command line and then moves the cursor forward nine columns *relative to a prompt the joiner
  never received*. The stream is not self-synchronizing: it is full of CR + CUF, CUP, and partial
  erases whose meaning is a function of the screen already on the terminal.

  **What is missing, measured (`state`).** Two clients attached to the same pane at the same
  moment, one replaying the whole tape and one from-now, while the pane ran a program that had
  already entered the alternate screen and set modes *before* either attached. The backlog client
  is the oracle; every difference is exactly what the join lost:

  | State | Backlog (correct) | From-now joiner |
  |---|---|---|
  | `isAlternateScreenActive` | `true` | `false` |
  | viewport top line | `ALT-BEFORE-JOIN` | `tick 3` |
  | `presentation.isCursorVisible` | `false` (`?25l`) | `true` |
  | `inputModes.applicationCursorKeys` | `true` (`?1h`) | `false` |
  | `inputModes.bracketedPaste` | `true` (`?2004h`) | `false` |
  | `inputModes.mouseTracking` | `click` (`?1000h`) | `off` |
  | cursor row | 8 | 5 |
  | scrollback | the pane's history | none |

  The two input-mode rows are the ones that bite hardest: a client that encodes keystrokes from
  its own `terminal.inputModes` -- which is what a real client must do -- sends CSI arrow keys
  where the child expects SS3, and sends an unbracketed paste, purely because it joined late.

  **The joiner can look fine and still be empty (`aftermath`).** Letting the joiner run past the
  program's `?1049l` and the shell's prompt repaint, its viewport ended up as a clean, correct
  two-line prompt -- the erase sequences in the repaint resynchronized the visible screen. But its
  `totalRows` was 66, the grid and nothing else, while the source pane had the whole session in
  scrollback. A joiner converges on the *visible screen* after the next full repaint and never
  converges on history. A client that only checked the top of the screen would report success.

  **Geometry (`geometry`).** A client constructed at a phone-shaped 40x20:
  - with `--from-now` it stayed 40x20 -- no resize event ever arrives, because resize events are
    recorded when the source pane changes, not when a subscriber attaches -- and rendered the
    child's output for a 179-column screen into 40 columns. `\033[5;100H` was clamped, the CR/CUF
    repaints landed in the wrong cells, and the result was interleaved garbage.
  - with a backlog follow it was **clobbered**: the tape's `resize` event took it from 40x20 to
    179x66. The stream's geometry is unconditional and authoritative. A client cannot both replay
    the tape and keep its own size.
  - The source pane's own resize is visible and tracked correctly when it is in the stream: the
    `converge` run recorded `80x24 -> 179x66`, the pane's birth-to-layout resize.

  **Local reflow (`reflow`).** After converging at 179x66, the client resized its own terminal to
  40 columns with no stream event behind it, and planned a coherent 40-column frame (67 text
  runs). This is the "observe" mode of the T10 question, and nothing in the client stops it -- the
  cost is that the next `resize` event in the stream overwrites it.

  **The retained tape is a partial snapshot, until it is not (`evict`).** After pushing
  `seq 1 1200000` (about 9.9 MB of feed) through the pane -- past the flight recorder's 8 MiB /
  32,768-event production bound -- a backlog client received a `gap` record of
  `droppedEventCount: 756, droppedFeedBytes: 554752, droppedWriteBytes: 1172`, then a contiguous
  suffix with no sequence break. The interesting damage is not the missing 554 KB of text:

  - the `start` record's `initial` geometry is the recorder's **birth** geometry, 80x24;
  - the `resize` event that corrected it to 179x66 was among the 756 evicted events;
  - so the client replayed 8,940 feed events into an 80x24 grid and ended with a 21-line
    viewport where the source pane has 66 rows.

  A gapped backlog replay is wrong about geometry and modes, not only about history, because the
  events that establish them are the oldest ones and are evicted first.

  **Reconnect (`reconnect`).** With `seq 1 4000000` running, a client dropped its connection after
  200 applied events at sequence 10089. A second client immediately attached with `--from-now` and
  received a start cursor of `sequence: 10306, feedByteOffset: 10310742`. Sequences 10090 through
  10305 -- 216 events -- were skipped, and **no `gap` record was emitted**, because from the
  producer's point of view a from-now request lost nothing relative to what it asked for. The loss
  is silent and only measurable by a client that remembers its own last sequence.

  **Stream end (`close`).** Closing the followed pane ended the stream with
  `{"kind":"end","reason":"pane-closed"}`, as documented.

- **Observation:** a second macOS process, in a different package with no AppKit and no PTY,
  reproduces a live pane's grid byte-for-byte from `pane.tape --follow` alone, and can plan its
  own frames from it. Joining that stream late produces a terminal that is wrong on every row of
  the table above. Some of it is corrected later by accident -- the visible screen at the next
  full repaint, and whichever modes the next prompt or program happens to restate -- but nothing
  in the protocol makes that happen, and scrollback never comes back.

- **Inference:**
  - H3's convergence half is confirmed for Mac-to-Mac. `NeutralTerminalRecordingEvent` is a
    sufficient remote wire format for the *output* direction, and `pane.input` already covers the
    input direction, so no new method is needed for a session that starts when the pane does.
  - A joining client needs a serialized state transfer, and the payload is not "the grid". From
    the divergence table, a `pane.snapshot` has to carry at least:
    1. **which screen is active**, and the contents of both -- a program that entered the
       alternate screen before the join is invisible in the stream;
    2. **the primary screen's history**, with its attributes, not just text;
    3. **the live grid's cells with attributes**, since the visible screen only self-corrects at
       the next full repaint, which may never come;
    4. **the cursor**: row, column, visibility, shape, blink, and the saved cursor (DECSC);
    5. **`inputModes` in full** -- application cursor keys, application keypad, LNM, focus
       reporting, bracketed paste, mouse tracking mode, SGR mouse encoding, kitty keyboard flags
       -- because the client encodes keystrokes locally and gets them wrong otherwise;
    6. **the remaining parser and screen modes** the tape sets and never restates: scroll region,
       origin and autowrap modes, tab stops, the current SGR pen, charset selection, synchronized
       output;
    7. **the geometry the snapshot was taken at**, which is not the tape's `initial` geometry;
    8. **the cursor position in the stream** -- sequence plus per-direction byte offsets -- taken
       atomically with the state above, or the splice is a race rather than a splice.
  - The snapshot and the stream must be fenced together. The recorder already does this for its
    own two captures: `TerminalFlightRecordingCapture` pairs an origin with a cursor snapshot
    precisely so a dump "cannot report geometry from before an event it then omits". A
    `pane.snapshot` needs the same fence against the subscription it is spliced onto.
  - The resume protocol has most of its coordinates already. `TerminalFlightRecordingCursor`
    (sequence plus feed and write byte offsets) is exactly a resume position, the `start` record
    already publishes it, and `cursorSnapshot(from:)` already computes exact per-direction loss
    against an arbitrary cursor and reports it as a `gap`. What is missing at the protocol edge is
    the ability for a client to *supply* a cursor: today `pane.tape` offers only `beginning`
    (backlog) and `now` (`fromNow`). A `fromSeq` request would reuse machinery that already
    exists and would turn today's silent reconnect loss into a stated `gap`.
  - Geometry has to be a negotiated property, not a stream property. Because the tape's `resize`
    event overwrites the client's grid unconditionally, "the phone renders at its own size" is not
    reachable by ignoring events -- everything positional after that point is misaligned. T10's
    *observe* mode is therefore local reflow **after** applying the stream's geometry (which the
    `reflow` run shows works), and *claim* mode means the client's size becomes the pane's size
    and enters the stream as a normal resize event. There is no third option in which the client
    quietly renders at a different size.
  - The retained tape is a usable snapshot substitute exactly while it is un-evicted, which makes
    the eviction bound a session-durability parameter, not just a debugging one. A snapshot ends
    that coupling and also removes the cost of replaying up to 8 MiB on every reconnect.

- **Competing interpretations:**
  - The join damage could be read as a fish-specific artifact, since fish's prompt repaint is what
    produced the doubled line. It is not: the mechanism is relative cursor motion against unknown
    screen state, which every line editor and every full-screen program uses. The alternate-screen
    and input-mode rows of the table are shell-independent.
  - One could argue no snapshot is needed because a backlog follow already converges, and the
    `converge` run is evidence for that. The `evict` run is the counter-evidence: convergence is
    conditional on retention, the events that fix geometry are the first ones evicted, and the
    reader learns of the loss only as a byte count.
  - The `aftermath` run could be read as "joins heal themselves". It shows the visible screen
    healing at the next full repaint while history stays permanently empty, so the honest reading
    is that a joiner heals what a repaint covers and nothing else.

- **Uncertainty:**
  - Everything here is one machine, one Unix socket, one shell (fish), and a debug build. No
    network, no latency, no TLS; a bridge may change the timing story, not the state story.
  - No timings were recorded. Nothing in this finding is a performance claim, diagnostic or
    otherwise.
  - The list of snapshot contents is derived from what diverged in these runs plus what
    `Terminal.presentation` / `Terminal.inputModes` expose. It is a floor, not a proof of
    sufficiency: DCS state, OSC 4 palette redefinitions, OSC 11 background overrides, hyperlink
    state, the title stack, and OSC 133 shell-integration marks were not individually probed, and
    at least the OSC 11 query (`ESC]11;?`) is visibly present in the captured stream.
  - The client discards the reply bytes its own terminal generates for queries such as `ESC[6n`
    and `ESC[0c`, which is correct for a read-only observer. What a *writer* client should do with
    them -- two engines answering the same query differently -- was not examined.
  - Security: this spike opened no listener. It used the existing Unix control socket, whose
    access control is filesystem permissions on the per-instance cache directory, and it added no
    network surface.

- **Next action:**
  - T8 designs `pane.snapshot` and sequence-numbered resume against the eight-item payload list
    and the fencing requirement above, and should treat `TerminalFlightRecordingCursor` plus
    `cursorSnapshot(from:)` as the existing half of the resume protocol rather than new work.
  - T10 takes the geometry conclusion: observe means local reflow after the stream's geometry,
    claim means the client's size enters the stream as a resize.
  - D3 can read the day-one-engine direction as supported: the engine reproduced a live pane
    exactly and planned its own frames, in a process with no AppKit.
  - T13, when it splits `TerminalSession`, has a working reference for the remote half's inputs;
    this spike is not that code and should not be graduated as-is.

- **Gaps in the control surface, for the record:** `pane.info` reports title, cwd, integration,
  agent, command, and connection state, but no geometry, no modes, and no screen state; `pane.rows`
  reports per-row width and structure but no attributes or modes; `pane.read` reports text only.
  So there is no way today for a client to ask what state a pane is in -- only to watch its bytes.
  The closest existing approximation to a snapshot is `pane.rows` plus `pane.read`, which carries
  no attributes, no cursor, and no modes. No API was extended for this spike.
