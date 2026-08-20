# Canonical-mode input delivery gate for the PTY write path

## Problem

`danterm tab new --cmd` (also `pane split --cmd`, `group new --cmd`) silently
fails to run the command when the initial input, command plus trailing LF,
exceeds 1024 bytes. The tab opens, the text sits at the prompt, nothing
executes, and no error appears anywhere. `danterm pane input` has the same
failure against any program reading the tty in canonical mode, plus a worse
one: a single oversized write wedges the kernel input queue full, after which
every later input byte, including plain Enter, is silently discarded too.

Desired outcome: a command of any length up to the existing 8 MiB submission
bound runs, and input that cannot be delivered resolves as an explicit, typed
error instead of silence.

## Evidence (all reproduced in this session, 2026-08-20)

- Kernel mechanism, from the pinned xnu checkout. The pty master write path
  (`references/xnu/bsd/kern/tty_dev.c#ptcwrite`) blocks for backpressure at
  TTYHOG - 2 = 1022 queued bytes only when the tty is in raw mode or a
  completed line is already queued. In canonical mode with no completed line,
  it feeds every byte to `references/xnu/bsd/kern/tty.c#ttyinput`, which at
  MAX_INPUT = 1024 queued bytes discards each further byte (ringing BEL under
  the default IMAXBEL) and reports the write as fully successful. This
  resolves the 1022-vs-1024 question: 1022 is the blocking threshold, 1024 is
  the silent-discard threshold.
- Bare pty harness: canonical mode accepts a 1025-byte write, reports 1025
  written, and the reader never sees a complete line (the LF was the discarded
  byte). Raw mode stops the same write at 1022 with EAGAIN and loses nothing.
- DanTerm end-to-end (dev slot): `tab new --cmd` with total bytes 1024 runs;
  1025 does not. A 5008-byte line sent by `pane input` to a shell already at
  its prompt (line editor active, tty raw) delivered fully and executed:
  `wc -c` confirmed the exact byte count.
- Wedge: with `cat` running (canonical), a 2000-byte `pane input` line lost
  its tail, and a following short `probe123` + Enter was also silently
  discarded. Both CLI calls returned success.
- The slave's termios is readable through the master: `tcgetattr` on the
  master fd reflects an ICANON change made on the slave (verified on this
  machine).

## Load-bearing premises

- P1: a canonical-mode tty cannot hold an undelimited byte run of 1024 or
  more; such a run is undeliverable, not merely slow. No signal reaches the
  writer when the kernel discards.
- P2: in raw mode the kernel provides lossless backpressure (EAGAIN at 1022),
  and DanTerm's existing nonblocking write loop plus write source already
  handles it correctly. The 5008-byte delivery above proves this end to end.
- P3: interactive shells put the tty in raw mode while their line editor is
  at the prompt, so "wait for the tty to leave canonical mode" makes a command
  of any length deliverable, and matches the semantic intent of `--cmd`
  (submit this line at the prompt). This claim is about zsh, Bash, and fish,
  the shells DanTerm supports, so it is established by those real binaries in
  real PTYs, not by a synthetic child.
- P4: `pane input`'s documented contract (SKILL.md: "byte-producing
  submissions must cross the PTY master" or the command errors) is already
  the right contract; the implementation currently violates it.

## Decision

Add one delivery gate at the single choke point where bytes cross the PTY
master: the host's pending-input flush path, which `--cmd` initial input,
`pane input`, and terminal replies already share. The gate reads the tty's
termios through the master fd before writing:

- Raw mode: flush freely; kernel backpressure is lossless (P2).
- Canonical mode: flush normally unless the pending bytes themselves contain
  an undelimited run that reaches the canonical line capacity. That property
  is decided from the bytes about to be written and the tty's current termios
  alone; the gate keeps no model of the kernel's queue. A byte delimits the
  run only after the active input translation is applied, matching
  `references/xnu/bsd/kern/tty.c#ttyinput`: CR is discarded under IGNCR and
  delimits only under ICRNL, and LF becomes CR under INLCR and then does not
  delimit. Such a run is withheld entirely, no partial write, and held in the
  existing bounded pending queue until the tty leaves canonical mode. The hold
  is re-evaluated on child output and on a timer. A bounded wait that expires,
  or process exit, rejects the submission with a typed failure.

  The gate deliberately stops at the segment it is writing. The PTY master has
  no interface that reports input-queue occupancy (RI4), and it cannot observe
  the events that change it: a child reading, a child calling `tcflush`, the
  line editor honoring VKILL or VERASE, or a child leaving and re-entering
  canonical mode without draining what is queued. A gate that carried a
  running count across those events would be a partial, drifting copy of the
  kernel line discipline: it would still miss real occupancy in one direction
  and withhold deliverable short lines in the other, breaking I6. Restricting
  the gate to the one fact the master can decide is what makes it exact.
- Launch input (`--cmd`) becomes a tracked submission like any other, so its
  rejection is observable instead of vanishing (it currently carries no
  submission identity and can never report a result).

Why this shape: it is the single structure in which both failure properties
cannot happen. Long commands work because the bytes wait for the line editor
(P3) and then ride the lossless raw-mode path (P2); a run the kernel cannot hold
is never written (P1), so it can neither be truncated nor wedge the queue, and
anything undeliverable resolves as an explicit rejection (P4). Loss that
depends on what the queue already holds is a separate problem the master
cannot see (AR4). Scoping the
fix to launch alone would be scoped wrong: the wedge evidence shows
`pane input` fails the same way, and both paths already share the queue the
gate sits on.

Why wait-then-reject rather than reject-immediately: at launch the tty is
always canonical for the first few milliseconds (the shell has not started
its line editor yet), so an immediate rejection would break every long
`--cmd`, the motivating use case. The wait converges fast in the normal case
and turns into a loud, bounded error in the abnormal one.

Layering: the gate needs `tcgetattr`, so it lives in the PTY host (IO layer).
The new typed failure travels through the existing submission-result path to
the CLI.

## Invariants

- I1: DanTerm never writes into a canonical-mode tty a segment the gate's
  conservative scanner classifies as oversized. The scanner reads the segment
  and the current termios only: it counts bytes between delimiters, judging
  delimiters after the tty's active input translation, and treats no other
  byte as changing the line. Every run the kernel would truncate on its own is
  in that class; the class is deliberately wider (AR5) and does not extend to
  lines the queue was already holding (AR4).
- I2: a segment the scanner classifies as oversized is withheld
  all-or-nothing: no prefix of it crosses the master, so a submission DanTerm
  judges undeliverable can never wedge the queue and poison input that follows
  it.
- I3: every byte-producing input submission, launch input included, resolves
  exactly once as delivered or rejected, and a rejection carries a reason
  distinguishable from write errors and process death.
- I4: a rejected `--cmd` is visible through the pane's queryable state (not
  only in a log), and a rejected `pane input` returns a CLI error.
- I5: raw-mode input delivery is unchanged and lossless up to the existing
  8 MiB submission bound; above that bound the submission still fails with the
  existing explicit buffer-limit error, never silently.
- I6: canonical-mode delivery of any segment the scanner does not classify as
  oversized is unchanged, so typeahead into a starting shell and input to
  line-reading programs (`read`, password prompts, `cat`) keep working with
  today's timing.

## Proof obligations

- PO1 (I1, P3): a launch command well past 1024 bytes arrives complete and
  byte-exact, and executes. Proven both against a synthetic child that starts
  canonical and then switches to raw (the mechanism), and against real zsh,
  Bash, and fish binaries in real PTYs (P3 itself, for every supported shell).
- PO2 (I3): the same oversized run against a child that stays canonical
  resolves as the new typed rejection within the bounded wait; expiry says it
  was an expiry.
- PO3 (I2): after such a rejection, a subsequent short line to the same child
  is delivered and read; the queue is not wedged.
- PO4 (I5, P2): a multi-megabyte submission to a slowly-reading raw-mode
  child is delivered byte-exact through backpressure.
- PO5 (I6): a sub-capacity command line delivered while the child is still
  canonical (typeahead) executes once the reader consumes it, as today.
- PO6 (I4, I3): the CLI surface reports the rejection: `pane input` exits
  non-zero with the reason, and the pane's queryable state shows the launch
  input's fate. Canonical-timeout, process-ended, and write-failed submissions
  each surface a distinct external reason, so the typed host failures survive
  the IPC path rather than collapsing into one generic error as they do today.
- PO7 (I6): after a child clears its incomplete canonical line (VKILL) or
  flushes its input queue, later short lines are still delivered normally; the
  gate holds no state that could withhold them.
- PO8 (I1): with `INLCR` set, and again with `IGNCR | ICRNL` set, a run whose
  apparent delimiter does not actually terminate the line is still withheld;
  no truncated write reaches the kernel.

## Non-goals

- Changing what `--cmd` means: it stays typed interactive shell input (no
  `shell -c`, no temp-file sourcing, no shell-specific injection).
- XPORT-3 (absolute-coordinate pending-input spans): adjacent structure,
  independent work; this plan neither needs it nor blocks it.

## Accepted risks

- AR1: a check-then-write race remains if the child flips raw-to-canonical
  between the termios read and the write. This is inherent to writing a pty
  from the master side; every terminal emulator shares it. Chunking writes
  narrows the window; nothing closes it.
- AR2: programs that stay canonical now get oversized lines rejected after a
  bounded wait instead of silently truncated. That is a behavior change, and
  the correct one: the kernel cannot deliver those lines.
- AR3: a custom VEOL delimiter is not modeled, so a run it would delimit may
  be held and rejected even though delivery was possible. The failure
  direction is loud, not silent.
- AR5: the scanner over-classifies. It counts only bytes between delimiters,
  so a segment whose own contents would have shortened the kernel's line --
  VKILL, VERASE, VWERASE, an input flush -- can be called oversized and
  rejected even though the kernel would have accepted it. Modeling those
  characters would rebuild part of the line discipline, which the gate
  deliberately refuses; the failure direction is a loud rejection, not silent
  loss.
- AR4: cumulative queue occupancy is out of scope. A short line can still be
  truncated when the kernel already holds most of a canonical line, whether
  those bytes came from an earlier write, from user typeahead, or from a child
  that left and re-entered canonical mode without reading. The master exposes
  no occupancy interface (RI4) and cannot observe the reads, flushes, or
  editing that change it, so this cannot be prevented from where the gate
  sits; the gate eliminates the self-inflicted, individually undeliverable
  runs that caused both reproduced incidents.

## Rejected ideas

- RI1: length validation only (reject long `--cmd` up front). Makes the loss
  loud but breaks the motivating use, long agent-launch commands, which the
  gate delivers fine.
- RI2: out-of-band delivery (spawn `shell -c`, write a file and source it,
  shell-specific buffer stuffing). Changes interactivity and history
  semantics, is shell-specific, and does nothing for `pane input`.
- RI3: readiness heuristic on first child output. An indirect proxy for the
  fact that matters; the termios bit is the direct fact and is readable from
  the master (verified).
- RI4: keeping a slave fd open to poll input-queue occupancy. Perturbs
  master-side EOF and hangup detection on child exit, and still cannot see
  the discard happen.

## Deliverables beyond code

- SKILL.md: document the new `pane input` failure mode and the bounded wait,
  replace any implied 1024-byte ceiling on `--cmd` with the real 8 MiB
  submission bound, and say that exceeding that bound is an explicit
  buffer-limit error, in the same change.

## Implementation discretion

- The bounded-wait duration and the re-check cadence while holding.
- The capacity constant's exact value and margin below the kernel thresholds
  (cite `references/xnu/bsd/sys/tty.h#TTYHOG` at the definition).
- How launch input acquires submission identity, and where the reducer versus
  host splits the hold state.

## Commit progress

- [x] 1. Gate oversized canonical-mode PTY input
- [ ] 2. Surface typed input rejection through pane state and IPC
- [ ] 3. Prove long shell launch delivery and document the CLI contract
