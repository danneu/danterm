# Terminal security audit -- findings register

Date: 2026-08-25
Scope: DanTerm at `master` (1b7f31e0), macOS app plus `lib/`. Excludes
`references/`, `.refs/`, `.cmux-*`, `.build*`, and the iOS companion.

Scope correction (2026-08-25, after review): excluding the iOS companion was
wrong for the ipc findings. That companion is the control socket's only remote
client, so "what a remote peer may do" could not be answered without reading
it. The gap produced the wrong remedy in DT-SEC-02 and hid DT-SEC-23, -24,
and -25. Any future finding about remote authority reads `ios/` first.

The contamination was not confined to the ipc findings. The class sweep below
was run against Mac-only source, which is how two absent rows cleared the paste
classes on a sanitizer the control plane's input path never reaches. The phone
also runs its own `TerminalCore` replica driven by the tape
(`ios/DanTermMobileKit/Sources/DanTermMobileKit/PaneReplica.swift:78`), so a
parser-class row is a claim about two renderers and two sinks. Where a row's
answer depends on a host decision rather than on `TerminalCore` itself, it now
says which host it checked.

Method: web research produced a taxonomy of 56 terminal-emulator and
terminal-app vulnerability classes with real CVE citations (2003 through
2026). Each class was then checked against this codebase by reading source.
This file records the result.

Status values: `open`, `fixed`, `accepted` (a decision was made to live with
it), `refuted` (investigated and shown not to exist), `question` (needs an
answer before it can be classified).

Verification column: `read` means a person or agent read the cited source.
`observed` means the behavior was confirmed on a running system or on disk.

---

## Tracking table

| ID | Name | Sev | Area | Status | Verif | Issue |
|---|---|---|---|---|---|---|
| DT-SEC-01 | `tape-cross-pane-read` | high | ipc | open | read | Any caller reads any pane's flight tape, which holds unechoed keystrokes |
| DT-SEC-02 | `j12-understates-remote-reach` | high | ipc | question | read | J12 still says local-only reach, but the register never recorded the remote grant the iOS client runs on |
| DT-SEC-03 | `checkpoint-mode-0644` | high | persistence | fixed | observed | Scrollback checkpoint written world-readable |
| DT-SEC-04 | `skill-glob-equals-bash` | high | agent | open | read | `Bash(danterm *)` grants arbitrary command execution via `--cmd` |
| DT-SEC-05 | `recovery-dir-mode-incidental` | med | persistence | fixed | observed | `Recovery/` reaches 0700 only as a side effect of the audit writer |
| DT-SEC-06 | `shell-envelope-no-nonce` | med | protocol | open | read | `DanTermShell=3` events are forgeable by any output |
| DT-SEC-07 | `agent-attach-unauthenticated` | med | ipc | open | read | Any caller claims or detaches any agent session on any pane |
| DT-SEC-08 | `no-peer-credential-check` | med | ipc | open | observed | No `getpeereid` on the control socket; file mode is the whole gate |
| DT-SEC-09 | `osc52-write-silent` | med | clipboard | open | read | Unprompted clipboard overwrite, reachable from a remote host over ssh |
| DT-SEC-10 | `notification-body-unnormalized` | med | ui | open | read | Notification body is a raw String, unlike the title |
| DT-SEC-11 | `agent-ingests-raw-bytes` | med | agent | open | read | `pane tape --raw` gives an agent bytes the human never sees rendered |
| DT-SEC-12 | `command-line-persisted` | med | persistence | open | read | Shell integration exports every command line into model state and the checkpoint |
| DT-SEC-13 | `ls-output-control-chars` | low | ipc | open | read | Titles and cwds leave through `ls` with control characters intact |
| DT-SEC-14 | `local-connections-unbounded` | low | ipc | open | read | Local accept loop has no connection cap and no idle timeout |
| DT-SEC-15 | `socket-chmod-after-listen` | low | ipc | fixed | read | Socket is 0600 only after `listen()` returns |
| DT-SEC-16 | `replay-file-mode-0644` | low | persistence | fixed | read | Scrollback replay temp files written world-readable |
| DT-SEC-17 | `osascript-no-automation-entitlement` | low | packaging | open | read | Hardened runtime plus `osascript` with no AppleEvents entitlement |
| DT-SEC-18 | `bidi-unimplemented` | info | unicode | accepted | read | No bidi, so overrides reorder displayed output visually |
| DT-SEC-19 | `audit-omits-input-content` | med | ipc | open | read | `pane.input` is audited by count only, which is now the forensic floor for the remote grant |
| DT-SEC-20 | `fixed-format-reply-residual` | info | parser | accepted | read | Replies are valid shell words even though their content is ours |
| DT-SEC-21 | `grapheme-width-desync` | info | unicode | closed | read | Mode 2027 reported permanently-set; >2-cell clusters unrepresentable |
| DT-SEC-22 | `json-nesting-depth` | -- | ipc | refuted | observed | Foundation caps nesting at 512; no stack exhaustion |
| DT-SEC-23 | `tailnet-peer-full-authority` | high | ipc | open | read | An allowlisted StableID may pull unechoed keystrokes off the machine and inject into any pane |
| DT-SEC-24 | `events-text-unsanitized` | info | ipc | accepted | read | `events[].text` reaches the PTY verbatim; the paste sanitizer covers only the top-level form |
| DT-SEC-25 | `roster-subscription-whole-app` | med | ipc | open | read | A roster subscription is a standing whole-app feed of every pane title and cwd, unscoped |

Counts: 5 high, 10 medium, 5 low, 4 info-accepted or closed, 1 refuted.

Status: 15 open, 4 fixed (DT-SEC-03, -05, -15, -16), 3 accepted, 1 closed,
1 refuted, 1 question (DT-SEC-02).

---

## High

### DT-SEC-01 `tape-cross-pane-read`

**Issue.** `pane read`, `pane tape`, and `pane snapshot` accept any pane UUID.
The only check in dispatch is that the pane exists
(`lib/DanTermCore/Sources/DanTermCore/IpcDispatch.swift:578-580`). There is no
binding between the caller and the pane it names, and pane ids are enumerable
through `ls` (`IpcDispatch.swift:74-77`).

The flight tape records PTY *write*-side bytes -- `recordWrite` at
`lib/TerminalPTY/Sources/TerminalPTYHost/TerminalFlightRecorder.swift:328-333`,
called from `TerminalPTYHost.swift:1994-2001` -- so it contains input to
non-echoing prompts. J12 states this outright: "a tape can contain what was
typed, including input a `sudo` or `ssh` prompt did not echo." The production
window is 8 MiB / 32,768 events
(`TerminalFlightRecorder.swift:17-21`). No redaction path exists in the repo.

`DANTERM_PANE` is written into every child's environment
(`lib/DanTermCore/Sources/DanTermCore/TerminalLaunchEnvironment.swift:27`) but
is never read back anywhere -- the definition and that one write are its only
occurrences.

**Impact.** A process in pane A -- a dependency postinstall, a prompt-injected
agent -- reads pane B's typed passwords. Panes look like a boundary and are not
one.

**External class.** No direct CVE analogue; closest is the general local-IPC
authorization class (CVE-2025-49596).

**Ideal fix.** Bind the caller to a pane. `DANTERM_PANE` is already in the
child environment; require the caller to present it and scope tape and read
access to that pane, with anything broader an explicit, separately granted
capability. This makes cross-pane reads impossible rather than merely gated.

**Cheaper fix.** Leave reads open but require a per-instance capability token
for `pane tape` specifically, since it is the only command that returns
keystrokes.

**Correction.** The remote half of this item's exposure is DT-SEC-23, not
DT-SEC-02 as first written. The local half stated above stands on its own: a
process running as the user reads another pane's tape with no remote peer
involved. Note that the ideal fix here and DT-SEC-23's ideal fix are the same
mechanism seen from two sides -- scoping a caller to the panes it owns -- so
they should be designed once.

---

### DT-SEC-02 `j12-understates-remote-reach`

**Status: question.** The first draft of this item recommended flipping
`paneRead`, `paneTape`, `paneSnapshot`, and `paneInput` to
`requiresLocalCaller: true`. That remedy is refuted: those four methods are how
the iOS client works. `MobileSessionModel.swift:708-713` sends `paneInput`,
`:272-278` streams `paneTape`, `:205-213` sends `paneSplit`, `:389` sends
`paneResize`, and the bootstrap handshake is `roster`
(`MobileSession.swift:65-69`). Those five methods plus a library-generated
`ping` are the phone's entire send surface; the flip would leave it a read-only
roster viewer. The original audit excluded `ios/` from its scope, which is why
it drew the conclusion backwards.

**The finding that survives.** J12 says the flight tape's bound is "that
socket's existing local-only reach." That sentence was true when it was
written and is not true now. The traits table marks only `quit` as
`requiresLocalCaller: true`
(`lib/DanTermProtocol/Sources/DanTermProtocol/IpcRequest.swift:127-155`,
enforced at `IpcDispatch.swift:42-44`), and that is deliberate -- it is the
grant the phone runs on. Nobody went back and recorded the grant.

So the code is current and the register is stale. This inverts the usual
direction, and it matters more than a normal doc lag: J11 requires a grant that
lets output or input cross a machine boundary to be a decision the register
makes, with its own stated bound. This grant was made in code without that
entry, so the register now reads as a *narrower* promise than the product
keeps. Anyone reasoning about remote authority from the design docs -- a future
audit included, as this one proves -- starts from a false premise.

**Impact.** No runtime exposure of its own. The exposure the earlier draft
described is real but belongs to DT-SEC-23, which states it as a grant rather
than as a mismatch.

**Ideal fix.** Write the remote grant into the register: which methods an
admitted peer may call, what the bound is, and what admission is trusted to
prove. Then J12's local-only sentence is corrected in the same edit rather than
left to contradict it. No code changes.

**Open question this cannot answer alone.** The bound depends on what the
allowlist is taken to prove, which is DT-SEC-23. Sequence -23 first, or decide
both together.

---

### DT-SEC-03 `checkpoint-mode-0644`

**Issue.** `lib/DanTermSupport/Sources/DanTermSupport/CheckpointWriter.swift:65`
calls `data.write(to: url, options: .atomic)` with no mode, producing 0644.

Confirmed on this machine:

    .rw------- 3.1M ipc-audit.jsonl
    .rw-r--r-- 353k last-enriched.json
    .rw-r--r--  10k last-light.json
    .rw-r--r--   48 session.json

`last-enriched.json` holds `PaneSnapshot.scrollback`
(`lib/DanTermCore/Sources/DanTermCore/Model.swift:961`), bounded at 4,000 lines
and 400,000 characters per pane
(`lib/DanTermSupport/Sources/DanTermSupport/Persistence.swift:194`), rewritten
every 600 s (`app/AppRuntime.swift:183-185`) and on clean exit
(`app/AppDelegate.swift:795`).

**Impact.** Durable, offline capture of every pane's terminal content. Practical
exposure today is bounded by `~/Library` being 0700, so this is defense in
depth rather than a live leak -- but the file mode is the layer that should not
depend on that.

**External class.** Ghostty GHSA-hfg5-8q2c-crhc is this bug exactly:
`write_scrollback_file` created 0644 files, fixed in 1.0.1 with 0600. Also
CVE-2025-22275 (iTerm2 logged terminal I/O to a world-readable path).

**Ideal fix.** Every file this process owns is created 0600 by construction,
not per call site. `DanTermInstancePaths` already centralizes path derivation;
give it the writer, so a new persisted file cannot get the mode wrong. The
audit writer already does this correctly
(`IpcAuditLogWriter.swift:290-303`) and is the model.

**Cheapest fix.** Add the mode at `CheckpointWriter.swift:65`.

**Fixed** by `848f6eba`, `cc3aea24`, `46602ec0`, `d6fb2d0c`, and
`75fb11da` (`plans/impl/2026-08-25-0840-one-owner-for-created-file-modes.md`,
then `plans/impl/2026-08-25-1012-one-private-write-seam-for-both-products.md`).
The ideal fix was taken: `lib/PrivateFile` is now the sole creator of a file or
a directory in either shipped product -- the Mac app with its CLI, and the phone
app -- it states 0600 / 0700 on the descriptor before the artifact is nameable,
and the atomic write modes its temp sibling too, so no world-readable name for
the content ever exists. Two classes of artifact stay umask-default and are
named as classes wherever the invariant is written down: the config artifacts,
and the CLI installation artifacts.
`scripts/private-file-mode-lint.sh` fails the gate on a raw create outside the
seam, in `ios/` as in `app/`, `lib/`, and `cli/`.

---

### DT-SEC-04 `skill-glob-equals-bash`

**Issue.** `integrations/danterm/SKILL.md:5` grants
`allowed-tools: Bash(danterm *)`. `tab new --cmd` does not exec the string --
`resolvedInitialInput`
(`lib/TerminalPTY/Sources/PaneProcessLifecycle/LaunchPolicy.swift:247-256`)
appends a newline and writes it verbatim into the already-running interactive
login shell's stdin. Full metacharacter interpretation, rc files, aliases, and
embedded newlines all apply. `group new --cmd` and `pane split --cmd` are the
same path.

The glob also covers `--tcp <host:port>`, an attacker-chosen outbound
connection carrying a JSON-RPC payload, and `pane input`, which writes
arbitrary bytes into any pane.

**Impact.** The grant is functionally unrestricted `Bash` with an extra step.
Any text an attacker can print into a pane that an agent later reads becomes a
capability escalation with no approval prompt.

**External class.** OWASP Agentic Top 10 ASI01. CVE-2025-54795 is the same
shape -- an allowlist matched a command string that the shell then interpreted
differently.

**Ideal fix.** Split the CLI's authority so the safe surface can be granted
without the unsafe one. Navigation, inspection, and todo verbs are one
capability; `--cmd`, `pane input`, `pane tape`, and `--tcp` are another that a
skill cannot pre-approve. Then the skill grants only the first.

**Cheaper fix.** Narrow the glob in `SKILL.md` to the specific safe subcommands
and document that the execution verbs require explicit approval each time.

---

### DT-SEC-23 `tailnet-peer-full-authority`

**Issue.** An admitted tailnet peer has the whole command surface: it reads any
pane's flight tape, which J12 says "can contain what was typed, including input
a `sudo` or `ssh` prompt did not echo," and it writes bytes into any pane
through `paneInput`. Only `quit` is withheld
(`IpcRequest.swift:127-155`).

This is a grant, not a bug -- the iOS client is built on it. It is filed as a
finding because the grant has no stated bound, and because of what it makes the
allowlist entry worth.

**Impact.** The allowlist entry is a credential equivalent to a shell on the
Mac, and it is a bearer credential: possession of the admitted device is the
whole proof. A stolen unlocked phone, or a compromised admitted node, is a live
keystroke exfiltration channel plus arbitrary command execution, for as long as
the entry stands. Nothing expires, nothing re-authenticates, and nothing scopes
a peer to fewer panes than all of them.

**Note.** Admission itself is well built and fails closed: opt-in behind four
independent gates
(`lib/DanTermProtocol/Sources/DanTermProtocol/TailnetActivation.swift:50-88`),
CGNAT-range and live-interface validation
(`lib/DanTermSupport/Sources/DanTermSupport/TailnetBindAddress.swift:132-155`),
whois through tailscaled plus a StableID allowlist
(`app/IpcServer.swift:445-454`), and refusal when the audit log cannot be
written (`app/IpcServer.swift:465-471`). The finding is about what admission
buys, not about who gets admitted.

**External class.** The general standing-bearer-credential class; nearest in
shape is a long-lived unscoped API token.

**Ideal fix.** Decide what the allowlist proves, then make the grant express
exactly that and no more. The likely shape: a peer is scoped to the panes it is
actively serving rather than to all of them, admission carries an expiry that
re-attaching renews, and tape capture -- the one verb that returns keystrokes
-- is a separately granted capability rather than something admission implies.

**Cheaper fix.** Keep the grant as-is and put a bound on the worst verb alone:
`paneTape` requires a per-instance capability the phone is given at pairing and
the user can revoke, leaving `paneInput` and the rest on plain admission.

**Prerequisite.** Whatever is decided lands in the register as DT-SEC-02's
missing entry. The two items close together.

---

## Medium

### DT-SEC-05 `recovery-dir-mode-incidental`

`CheckpointWriter.swift:59-62` and
`lib/DanTermSupport/Sources/DanTermSupport/RecoveryStore.swift:48-51` both
create `Recovery/` with `withIntermediateDirectories: true` and no chmod. The
only thing that tightens it to 0700 is
`IpcAuditLogWriter.prepareDirectory` (`IpcAuditLogWriter.swift:288-292`), which
runs on the first IPC connection (`app/IpcServer.swift:426`) or a tailnet bind.
An instance that never receives a `danterm` invocation leaves the directory at
umask default with scrollback inside it.

The confidentiality of the checkpoint currently depends on an unrelated
component happening to have run first. Same ideal fix as DT-SEC-03: one owner
for directory and file modes.

**Fixed** with DT-SEC-03. `PrivateFile.createDirectory` gives `Recovery/` its
0700 itself, so the mode no longer depends on the audit writer having run. A
test writes a checkpoint from an instance that never constructed an audit writer
and asserts the directory mode.

### DT-SEC-06 `shell-envelope-no-nonce`

`OSC 1337;DanTermShell=3` (`lib/TerminalCore/Sources/TerminalCore/Terminal.swift:2229-2292`)
is field-count validated, size-bounded at 88 KiB, and base64-encoded, but
carries no per-session secret. Any program that can write to the pane can emit
`command-start`, `command-end`, and
`connection;remote;<b64user>;<b64host>`.

Consequences: the pane's displayed connection state is forgeable, so a local
pane can claim to be a remote host or the reverse; a fabricated command line
reaches `ls`, `pane info`, and the persisted `PaneSnapshot.command`, and it
reaches the phone's pane roster, where a forged chip and title are the only
identity the user has when choosing which pane to type into. OSC 133
prompt marks (`Terminal.swift:1959-2008`) have the same property.

**External class.** VS Code's OSC 633 command-spoofing bug, fixed with a
per-session nonce passed to the shell integration. Also CVE-2019-9535 and
CVE-2026-41253 (iTerm2, the same missing origin check seven years apart) and
CVE-2026-54686 (Warp DCS lifecycle-hook spoofing).

**Ideal fix.** The integration already receives a per-pane environment. Pass a
per-session nonce in it and require the envelope to carry it; events without
the nonce are ignored. This makes forgery structurally impossible rather than
bounded. Note this is the general in-band-control-plane rule the research keeps
returning to, and DanTerm is already on the right side of it for the *control*
plane -- the shell envelope is the one place a privileged verb is parseable
from untrusted output.

### DT-SEC-07 `agent-attach-unauthenticated`

`AgentSession.init?(kind:sessionId:)`
(`lib/DanTermCore/Sources/DanTermCore/AgentSession.swift:22-31`) validates
charset only: kind is 1-32 of `[a-z0-9_-]`, sessionId 1-128 of
`[A-Za-z0-9._:@+-]`. The pane is checked for existence only
(`IpcDispatch.swift:105-108`). Any caller claims any agent identity on any pane
and can detach a real session.

Grants: pane chip presentation, activity state, and the `currentWaitGeneration`
bookkeeping that `paneInput` reads (`IpcDispatch.swift:328`), so a spoofed
attach perturbs a real agent's input accounting.

The charset gate is itself well placed -- `recoveryMessage`
(`AgentSession.swift:41-46`) feeds shell-replay text, and the gate is what
keeps metacharacters out of it. Keep that; add identity on top.

**Correction.** `agentAttach` is reachable remotely, and that is a grant the
iOS client uses rather than an oversight; cite DT-SEC-23 for the remote half,
not DT-SEC-02.

### DT-SEC-08 `no-peer-credential-check`

`Darwin.accept(fileDescriptor, nil, nil)` (`app/IpcServer.swift:345`), then
`caller: .local` unconditionally (`app/IpcServer.swift:411-431`). No
`getpeereid`, `LOCAL_PEERCRED`, `SO_PEERCRED`, or code-signing check exists in
the codebase.

Observed on this machine, the file-mode gate is intact:

    drwx------ ~/Library
    drwx------ ~/Library/Caches/com.danneu.danterm
    srw------- control.sock

So for the unix socket this is a coherent same-uid trust model rather than a
hole. It is not the process's whole trust model: the same dispatcher also
serves the tailnet listener, where uid means nothing and admission is a
StableID allowlist (`app/IpcServer.swift:445-454`, DT-SEC-23). Two disjoint
gates -- file mode for one transport, node identity for the other -- reach one
unscoped command surface, and `IpcCallerIdentity` is the only thing that tells
them apart. `DANTERM_SOCK` is not what grants access -- the path is fully derivable from
public inputs
(`lib/DanTermProtocol/Sources/DanTermProtocol/SocketPath.swift:17-24`), so
unsetting it buys nothing.

**Ideal fix.** `getpeereid(2)` on accept, rejecting any uid but our own, plus a
code-signing requirement if the threat model includes same-uid malware. The man
page guarantees neither side can influence the credentials its peer sees, so
this converts a umask-dependent property into an enforced one, and it gives a
future per-caller policy one verified identity to be written against on both
transports rather than one derived and one verified. Whether it is worth doing
is a threat-model decision that should be written down either way.

### DT-SEC-09 `osc52-write-silent`

`Terminal.swift:2584-2599` accepts up to 1 MiB decoded and calls
`setClipboardWrite`, reaching `NSPasteboard.general` with `clearContents()` +
`setString()` and no prompt (`app/SwiftTerminalSessionView.swift:1325-1328`).
The shell integration forwards `LC_DANTERM` over ssh and mosh
(`integrations/shell-integration/danterm.zsh:181-189`), so a compromised remote
host silently rewrites the local clipboard.

Read is correctly denied (`Terminal.swift:2595` rejects the `?` form) -- only
the write side is open.

**External class.** CVE-2026-48725 (Warp). CVE-2025-55754 (Tomcat) uses OSC 52
as the payload of a log-injection chain.

**Ideal fix.** G12 grants the write; the gap is that J11 requires each grant to
state its bound, and "reaches the system pasteboard with no user action" is not
bounded. Either gate the write on a user gesture or a per-pane permission, or
amend G12 to state that an unprompted clipboard write is the accepted bound and
why.

### DT-SEC-10 `notification-body-unnormalized`

`windowTitle(for:)` sends titles through `DisplayLine`, which collapses
whitespace and strips control scalars
(`lib/DanTermCore/Sources/DanTermCore/Projections.swift:795-801`). The
notification body does not get that treatment -- it is a raw `String` on
`Command` (`lib/DanTermCore/Sources/DanTermCore/Command.swift:81`) and reaches
`UNMutableNotificationContent` at `app/AppRuntime.swift:832-847`. Delivered
banners persist in Notification Center history, outside the app's control.

Throttling is one per pane per kind (`Update.swift:2120-2140`), which bounds
volume but not content. Attacker-chosen text renders as a system notification.

**External class.** CVE-2022-41322 (kitty) is this shape with code execution
attached.

**Fix.** Route the body through `DisplayLine` like the title. There is no
reason for the two to differ.

### DT-SEC-11 `agent-ingests-raw-bytes`

`pane tape --raw` hands an agent the unrendered PTY stream. SGR set to
background color, cursor motion that overwrites, Cf-class and Tags-block
codepoints, and bidi overrides all make the byte stream say something the
rendered grid does not.

DanTerm already has the fix available: `pane read` and `pane snapshot` return
the rendered grid. This is a documentation and default question, not a missing
capability.

**External class.** Trail of Bits, "Deceiving users with ANSI terminal codes in
MCP" (2025-04-29). CVE-2026-35651 (OpenClaw) spoofs an approval prompt this
way.

**Ideal fix.** State in `SKILL.md` that agent ingestion uses the rendered forms,
and that `--raw` is a debugging tool whose output must not be treated as
trustworthy text. Optionally mark stripped content with a visible marker so the
two views can be diffed.

### DT-SEC-12 `command-line-persisted`

`danterm_emit_command_start`
(`integrations/shell-integration/danterm.bash:47`) base64-emits every command
line the user runs. It becomes `PaneSnapshot.command`, is exposed by `ls` and
`pane info`, and lands in the checkpoint. A secret on a command line --
`mysql -pSECRET` -- is persisted.

Separately, the IPC audit log deliberately retains `command` and `cwd`
(`IpcAuditDescriptor.swift:56-59`) as exercised authority, at 0600.

Fixing DT-SEC-03 bounds the on-disk copy to the local user. It does not bound
the exposure. The same `command` string leaves through `ls`, `paneInfo`, and
`roster`, none of which require a local caller, so an admitted peer reads every
command line the shell integration captured -- and the phone keeps its own
persisted replica of pane content on a second device
(`MobileSessionModel.swift:315-325`). Whether command lines should be captured
at all is the decision to make; if they are kept, they belong behind the same
caller-to-pane scoping DT-SEC-01 and DT-SEC-23 need.

### DT-SEC-25 `roster-subscription-whole-app`

**Issue.** `subscribeRoster` (`IpcDispatch.swift:78-82`) registers the
*connection* as a permanent push target (`app/AppRuntime.swift:557-580`), and
every change pushes a fresh projection (`:537-553`). The projection walks every
group, every tab, and every pane in the application
(`lib/DanTermCore/Sources/DanTermCore/PaneRosterProjection.swift:17-40`), each
item carrying group name, tab title, pane title, agent chip, and selection
state (`lib/DanTermProtocol/Sources/DanTermProtocol/PaneRoster.swift:13-27`).
There is no per-peer filtering.

**Impact.** Pane and tab titles track the running command and the cwd, so a
subscription is a continuous, real-time metadata feed of everything happening
on the Mac -- what is being run, where, and when -- delivered to an admitted
peer for as long as it stays connected. It is quieter than DT-SEC-23's
keystroke path and needs no further requests once armed.

**Related.** Tape follows have the same unscoped shape in a different key:
subscriptions are keyed by a fresh id rather than by connection
(`app/PaneTapeBroker.swift:27`), and nothing caps how many one caller may hold.

**Ideal fix.** The same caller-to-pane scoping DT-SEC-01 and DT-SEC-23 need: a
subscription returns the panes the peer is entitled to, not the machine. Absent
scoping, the roster is the cheapest whole-machine observation channel in the
product.

### DT-SEC-19 `audit-omits-input-content`

`pane.input` is audited by byte and event count only
(`IpcAuditDescriptor.swift:5-10`), while `--cmd` and `--cwd` are retained. A
remote key injection appears in the log as "pane.input, 3 events" with no way
to recover what was typed.

**Repriced (2026-08-25).** This was made as a local-user privacy choice and
rated `info` on that basis. It is now the forensic floor for a standing remote
grant that nothing expires and nothing scopes (DT-SEC-23): after a stolen phone
or a compromised admitted node, the audit log is the only record that exists,
and the one thing an investigator most needs -- what was typed -- is the one
thing dropped. `command` and `cwd` are retained
(`IpcAuditDescriptor.swift:52-56`), so the log preserves content for the less
dangerous verb and discards it for the more dangerous one.

**Fix.** Reprice against caller identity: retain input content when the caller
is `.remote` (the log is already 0600 and already refuses to run when it cannot
be written), or state plainly that reconstructing remote input after an
incident is out of scope. Either answer is defensible; the current state is the
one nobody chose. Sequence with DT-SEC-23.

## Low

### DT-SEC-13 `ls-output-control-chars`

Titles and cwds reach `danterm ls` with control characters intact.
`SKILL.md:812-817` warns callers rather than sanitizing at the source. Anything
rendering `ls` output naively re-enters the escape-injection classes. The
emitter is the right place to fix this -- that is the lesson of CVE-2024-58251
and CVE-2026-45803.

Two emitters of the same strings already disagree, and both are remote-callable:
`roster` projects through a hygiene pass the phone depends on
(`ios/DanTermMobileKit/Sources/DanTermMobileKit/MobileDisplayText.swift:1-9`),
`ls` and `paneInfo` emit raw. The fix is not new code -- route them through the
projection `roster` already uses, so the emitter-side answer is one answer
instead of one per verb.

### DT-SEC-14 `local-connections-unbounded`

The local accept loop has no connection cap and no idle timeout
(`app/IpcServer.swift:423`). Remote connections are capped at 8 with a 30 s
silence bound. Each local connection holds a descriptor and a reader thread. A
same-uid attacker already has DT-SEC-08, so this is a robustness gap more than
a security one. It has one availability consequence worth naming: the two
listeners share a descriptor table, so unbounded local connections starve
`accept` on the tailnet listener and deny the phone its session. The asymmetry
-- the remote loop caps and reaps, the local one does neither -- is the
argument for giving both the same accounting.

### DT-SEC-15 `socket-chmod-after-listen`

`ControlSocketListener.swift` binds at `:57`, listens at `:67`, and chmods to
0600 at `:70`, so the socket carries `0777 & ~umask` briefly while already
accepting. The directory chmod at `:41` follows `createDirectory` for the same
reason. The 0700 parent is the mitigation in both cases. The clean form is to
set the umask around creation, or create and chmod before `listen`.

**Fixed** with DT-SEC-03. `PrivateFile.bindSocket` binds the node and modes it
to 0600 as one operation and hands back a descriptor that has not yet listened,
so the window is unrepresentable rather than merely closed. `listen()` stays
with the listener.

### DT-SEC-16 `replay-file-mode-0644`

`writeReplayFile` (`app/AppRuntime.swift:1041-1048`) writes scrollback to
`<temp>/danterm-scrollback/<bundle-id>/<uuid>.txt` with `.atomic` and no mode,
in a directory created with no chmod. The path is exported as
`DANTERM_RESTORE_SCROLLBACK_FILE` and the shell integration `cat`s and `rm`s it
(`danterm.bash:14-17`), so it is short-lived -- but only under a shell that
sources the integration. Same owner-of-modes fix as DT-SEC-03.

**Fixed** with DT-SEC-03. The replay file and the directory holding it are both
created through the seam, at 0600 and 0700.

### DT-SEC-17 `osascript-no-automation-entitlement`

`CLIPathInstaller.swift:36-51` drives `osascript` with
`do shell script ... with administrator privileges`. Release signs with
hardened runtime and no entitlements
(`.github/workflows/release-stable.yml:66-68`), and
`com.apple.security.automation.apple-events` is not declared. That combination
normally needs the entitlement or is subject to AppleEvents TCC prompting.

The command text itself was reviewed: two hardcoded or bundle-derived paths,
correct POSIX single-quote escaping (`CLIPathInstaller.swift:288-290`), passed
as an AppleScript `argv` item rather than interpolated into `-e`. No injection
found. This is the only privileged shell in the product.

---

## Accepted and informational

### DT-SEC-18 `bidi-unimplemented`

No bidi implementation exists; the grid renders in logical order. This blocks
Trojan Source in link targets outright, because `isActivatableWebURI` rejects
every format-category scalar. It does mean an override sequence in ordinary
output or a pane title reorders what the user reads, and that DanTerm disagrees
with the reviewer's editor. Rendering bidi controls visibly is the stronger
answer if this is ever revisited. See CVE-2021-42574 (disputed on NVD).

### DT-SEC-24 `events-text-unsanitized` (accepted)

Two input forms reach different encoders, and only one is sanitized.
`IpcPaneInput.text` dispatches to `.paste` (`IpcDispatch.swift:335`), which
reaches `encodeTerminalPaste`
(`lib/TerminalCore/Sources/TerminalCore/TerminalInputEncoding.swift:168-197`)
and is stripped of ESC and C0/C1, then bracketed. `IpcPaneInput.events[].text`
dispatches to `.text` (`IpcDispatch.swift:344-351`), which reaches `sendText`
(`TerminalPaneSession.swift:573-585`) and writes `Array(text.utf8)` to the PTY
verbatim -- ESC, C1, and a literal `ESC [ 201 ~` included.

**Why this is accepted, not a bypass.** The paste-bypass class exists because
the *content* is untrusted (a clipboard the user did not author) while the
*action* is trusted. Here the caller already holds unrestricted keystroke
authority over the pane: anything it could smuggle through a forged paste
terminator it can simply send as the next event. Sanitizing `.text` would
remove no authority the caller lacks. The raw form is the deliberate primitive
for programmatic input, and the phone's paste gesture correctly takes the safe
form (`MobileInputMapper.swift:79-82`, whose comment names the distinction).

**What would reopen it.** If any path ever routes content the caller did not
author into `events[].text` -- a clipboard bridge, a shared-input feature, an
agent relaying text it read elsewhere -- the class returns at once. The
asymmetry is safe only while every `pane.input` caller is already fully
authorized, which is the assumption DT-SEC-01 and DT-SEC-23 exist to question.

### DT-SEC-20 `fixed-format-reply-residual`

Eight reply paths exist, all bounded by `maximumReplyBytes` 64 KiB
(`Terminal.swift:1094`, `:6481-6485`): OSC 10/11 color, kitty keyboard query,
XTVERSION, DSR, CPR, DA1, DECRQM, and the focus report. None echo
attacker-supplied bytes, which is what makes DanTerm immune to the whole
echoback family. The residual is the dgl.cx class: a reply is still a valid
shell word, so an attacker who controls the filesystem can pre-place an
executable matching a reply's text. Terminals cannot fully fix this -- the
layer is the shell. Recorded so the reply surface stays minimal by intent.

### DT-SEC-21 `grapheme-width-desync` (closed)

**The class.** Terminal, multiplexer, and application disagree on how many
cells a grapheme cluster occupies. East Asian Width class `A` is 1 cell in a
Western context and 2 in CJK with no negotiation; an emoji ZWJ sequence is one
grapheme but many codepoints, which legacy `wcwidth` sums to 4, 6, or 8 where a
grapheme-aware terminal renders 2. Every disagreement offsets the rest of the
line. It is a security class and not only a correctness one: a desynced cursor
lets remote output overwrite cells the user already read and believes are
trusted.

**Why it is closed.** Two independent structural answers.

Mode 2027, the negotiation protocol for this, is implemented and reported as
permanently enabled. `Terminal.swift:825` defines it; `:6469` returns DECRQM
status `3`, which in DECRPM means permanently set and not resettable; `:6559`
makes set and reset a deliberate no-op. An application that queries is told
grapheme clustering is always on, and that answer cannot drift.

A cluster wider than 2 cells is unrepresentable. `TerminalCellWidth` has
exactly three cases -- `zero`, `narrow`, `wide`
(`lib/TerminalCore/Sources/TerminalCore/UnicodeProperties.generated.swift:7-11`).
The `wcwidth` 0.8.0 clamp that roughly 35 terminals adopted as a runtime check
is here an unrepresentable state. Width comes from pinned Unicode 17.0.0 tables
with no runtime ICU, so it cannot shift under an OS update, and clusters are
capped at 256 bytes (`Terminal.swift:1060-1070`).

**Residual, not a DanTerm defect.** A legacy application using `wcwidth`, or
tmux in between, still disagrees with DanTerm on emoji ZWJ sequences. DanTerm
emits the correct signal and cannot compel the other side to read it. Recorded
as a compatibility fact.

### DT-SEC-22 `json-nesting-depth` (refuted)

An audit pass flagged `JSONValue.init(from:)`
(`lib/DanTermProtocol/Sources/DanTermProtocol/JSONValue.swift:44-64`) as
unbounded recursion inside a 16 MiB frame
(`IpcLineFramer.swift:16`), and therefore a stack-exhaustion crash reachable by
any caller.

Probed directly with a standalone binary reproducing the same decode shape:
Foundation's `JSONDecoder` rejects nesting past 512 levels with "Too many
nested arrays or dictionaries" before `JSONValue`'s recursion goes deep. Depth
500 decodes; depth 1000 throws cleanly. No depth cap is needed.

---

## Classes checked and found absent

Recorded so they are not re-audited. Each row is a real vulnerability class
from the research with at least one CVE; the right column is why DanTerm cannot
be hit.

| Class | CVE examples | Why absent |
|---|---|---|
| Title report injection | CVE-2003-0063, CVE-2024-38395, CVE-2026-54057 | No XTWINOPS; no `t` final in CSI dispatch. No title report-back exists |
| DECRQSS echoback | CVE-2008-2383, CVE-2022-45872, CVE-2022-47583 | DECRQSS not implemented; I5 denies it plus DA2 and XTGETTCAP |
| Font query echoback | CVE-2022-45063, CVE-2023-39726 | No OSC 50 |
| Color query echoback | CVE-2026-54057 | OSC 10/11 replies are canonical, built from internal state |
| Error-message echoback | CVE-2020-35605, CVE-2026-42850 | No reply interpolates request bytes |
| OSC 52 clipboard read | (defaults issue, no CVE) | `Terminal.swift:2595` rejects the `?` form before decoding |
| Screen readback DECRQCRA | (no CVE; xterm default-off) | Not implemented |
| Kitty graphics file read | CVE-2026-54055, CVE-2026-54056 | DCS/APC/PM/SOS accumulate nothing (`EscapeAbsorber.swift:534-535`) |
| Image decoder bombs | CVE-2026-33633, CVE-2026-33642 | No image protocol of any kind |
| Sixel exhaustion and overflow | CVE-2022-24130, CVE-2026-11623 | No sixel |
| Terminal-driven file writes | CVE-2003-0021, CVE-2026-48720 | No `OSC 1337 File=`, no OSC 55, no download path |
| Bracketed-paste bypass | CVE-2019-17068, CVE-2021-31701 | Paste sanitizer strips ESC and all C0/C1 except TAB/LF/CR, on every paste path on both hosts. Not the same as the control plane's raw input verb -- see DT-SEC-24 |
| Paste control characters | CVE-2026-26982 | Same sanitizer; applies regardless of paste mode. DT-SEC-24 states what it does not cover |
| C1-in-UTF-8 filter bypass | (bypass vector for most filter fixes) | J9: 8-bit C1 unsupported by construction |
| Combining-mark overflow | CVE-2026-52859 | 256-byte grapheme cluster cap (`Terminal.swift:1060-1070`) |
| Escape parameter overflow | CVE-2012-2738, CVE-2026-59117 | 24 params, saturating at `UInt16.max`; REP clamped to columns remaining |
| Unterminated string flood | CVE-2021-33500, CVE-2021-28848 | 2 MiB cap, whole sequence discarded (J2, J7) |
| Window-op and DECCOLM DoS | CVE-2006-7236, CVE-2024-37535 | No XTWINOPS |
| Link scheme and argument injection | CVE-2023-46321, CVE-2025-49091 | http/https only, RFC 3986 authority parse, invisible and bidi scalars rejected, Cmd press-and-release arming |
| OSC 7 DNS exfiltration | (macOS Terminal, fixed Tahoe 26.1) | Host compared literally against `gethostname`; never resolved |
| Menubar manipulation | CVE-2003-0023, CVE-2003-0024 | No output-driven menu surface |
| Answerback / ENQ | (historical) | No answerback |
| Telemetry and auto-update egress | -- | No telemetry, no updater, no HTTP client in app or lib. Not a no-network product: the app accepts inbound TCP on a tailnet address (DT-SEC-23) and `danterm --tcp` dials a caller-named host (DT-SEC-04). Both are audited control-plane transports, not egress on the app's own initiative |
| Custom URL scheme handler | CVE-2004-0489 | No `CFBundleURLTypes` in `app/Info.plist`, and none in `ios/DanTermMobileApp/Info.plist` |
| Hardened-runtime exceptions | (class 45) | Release signs `--options runtime` with no entitlements; `get-task-allow` is dev-only |

---

## Cross-cutting note

The parser is not where DanTerm's risk is. Section J of
`docs/design/2026-08-06-swift-terminal-engine.md` already forecloses most of the
classic families by decision rather than by filtering, and the reply surface is
small enough that the entire echoback family -- which is every terminal RCE in
the public record -- has no foothold.

The findings cluster in three places instead:

1. **The control plane's authority is ambient.** Anything running as the user,
   and anything on an admitted tailnet node, has the full command surface.
   DT-SEC-01, -04, -07, -08, -23, -25. The common shape is that a caller is
   never scoped to a subject: no local caller is bound to a pane, and no remote
   peer is bound to less than everything. One mechanism -- caller-to-pane
   scoping -- closes the local and remote halves together, and it is the fix
   named in six items rather than six fixes.
   DT-SEC-19 is the same cluster seen after the fact: with no scoping, the
   audit log is the only bound, and it drops the content that matters most.
   DT-SEC-02 sits beside this cluster as its bookkeeping: the remote grant
   these items describe was never written into the register at all.
2. **File modes have no single owner.** Three writers each decide their own,
   and only one gets it right. DT-SEC-03, -05, -16. *Fixed:*
   `lib/PrivateFile` is now that owner for both shipped products, a lint keeps
   creation inside it, and the same change closed DT-SEC-15.
3. **Two grants landed without stating their bound**, which J11 requires:
   the unprompted clipboard write and the unnormalized notification body.
   DT-SEC-09, -10.

J11 says a new protocol that lets output reach the filesystem, the clipboard,
another application, or the network is a decision the register must make, and
that every grant states its own bound. The gap is enforcement of that rule, not
the rule.
