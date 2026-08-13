# Confirm before closing a pane or tab with a running command

## Context

Closing a pane today discards whatever is running in it without a word. A pane
running `npm run dev`, a long `rsync`, or a half-finished migration closes on
Cmd+W exactly as fast as an idle shell. The only thing that currently earns a
pane-close prompt is uncompleted to-dos.

DanTerm already knows what is running. Shell integration
(`integrations/shell-integration/danterm.zsh` / `danterm.fish`) emits a private
`DanTermShell=3` OSC on `preexec` / `precmd`; `Terminal.dispatchDanTermShell`
turns that into `.commandStarted(String)` / `.commandEnded`, and `reduceSession`
stores it as `SessionModel.command: CommandLifecycle` — the full command line, in
the pure model, reachable from `update()`.

Goal: a pane or tab close that would kill a running command asks first, naming
the command.

### Decisions already taken

- **Signal**: `session.command == .running`. Not the sidebar busy dot — that dot
  reads `SessionModel.agent` (Claude/Codex agent activity over IPC hooks) and
  would not fire for `vim` or `npm run dev`.
- **No shell integration means no prompt.** A pane whose `IntegrationLatch` is
  `.neverReported` reports no command lifecycle; silence is treated as idle.
- **Scope**: interactive pane close and tab close. `danterm pane close` /
  `tab.close` over IPC stay unguarded — they are the scripting surface. The
  confirmation lives on the `.request*` messages, which only the keyboard and
  the menu send; IPC dispatches `.closeTab` / `.closePane` directly and so can
  never raise a close alert.
- **One exception, and it is not a close confirmation.** An IPC close of the
  last pane or tab still hits `wouldQuitFromClose` and raises the quit panel.
  That guard is the app refusing to vanish, not a prompt about the close: the
  same line fires for `.sessionEnded` when a shell exits, which no caller
  initiated. Letting a script terminate DanTerm outright with no human in the
  loop is the worse outcome, so the guard stays on the IPC path.
- **Presentation**: the existing `NSAlert` sheet via `AppRuntime.runConfirmation`
  for close warnings; the non-modal `QuitConfirmationPanel` stays the
  presentation for a user-initiated quit.

## The structural problem this fix has to clear first

Close confirmation is four parallel implementations of one idea. Quit,
close-tab, and close-tabs each have their own emit chokepoint, their own
`Command`, and their own confirm/cancel `Msg` pair; pane close has none of these
— it returns its `Command` inline, never occupies the `pendingConfirmation`
slot (so its sheet can stack with a quit sheet), sends no `Msg` on cancel, and
on confirm calls `sessions[paneId]?.requestClose()`, a different teardown route
from the unconfirmed path that silently does nothing if the session is absent.

The split also breaks the confirmation's promise. `.confirmCloseTab` on the last
tab clears the slot, dispatches `.closeTab`, hits `wouldQuitFromClose`, and
raises a *second* confirmation — so an alert that said "Closing it will quit
DanTerm" closes nothing and asks again. This is current behavior, deliberately
pinned by `testConfirmCloseTabLastMultiPaneRoutesToTerminate`
(`lib/DanTermCore/Tests/DanTermCoreTests/UpdateTabTests.swift`). Adding running
commands as a new reason to prompt widens the set of closes that land in it.

Adding a fourth parallel implementation for panes is the wrong move. The plan
below replaces all four with one.

## Approach

### I1 — One confirmation transaction

A pending confirmation is a single value in the model carrying three things:

- **subject** — what the user asked to close: a pane, a tab, a set of tabs, or
  the app. Confirming closes exactly this and nothing else.
- **impact snapshot** — what closing it cost at the moment the alert was raised
  (below). Drives whether to ask at all, and supplies the alert's copy. Carried
  by the three **close** subjects only; an app subject has none.
- **quit authorization** — whether the alert told the user that confirming
  would quit DanTerm.

The user authorizes an action, not an outcome. Confirming performs the ordinary
close of the subject; the existing `wouldQuitFromClose` guard on `.closeTab` /
`.closePane` then decides whether that close quits, against the model as it
stands at confirm time. Quit authorization is what lets the guard terminate
directly instead of raising a second confirmation.

That yields the invariant: **confirming never destroys more than the alert
described, and never asks again about something the alert already promised.**
Concretely, with a sheet open while IPC and terminal events keep mutating the
model:

- A last-tab alert said it would quit, then another tab appears. Confirming
  closes the subject tab only — the guard does not fire, so the new tab and its
  running command survive untouched.
- A non-quitting alert, then the other tabs disappear. Confirming closes the
  subject; the guard fires and raises the quit confirmation, exactly as it does
  for any unauthorized close. The user is asked about quitting because they were
  never told about it.
- Nothing changed. The guard fires, authorization is present, and the app
  terminates — one prompt.

The same window lets new work appear *inside* the subject: IPC can split a pane
into the tab under the sheet and start `rsync` there. Confirming would then kill
a command the alert never named. So confirming a **close** subject also checks it
against the snapshot, and refreshes instead of committing when either holds:

- the subject now contains a pane the snapshot does not cover, or
- a pane the snapshot does cover is now running a command, and it is not the
  command the snapshot recorded for *that pane*.

Refreshing means the transaction clears and the subject goes back through its
request gate, producing a fresh alert that describes the subject as it now
stands — and, for a batch, re-deriving the whole batch including quit
authorization.

The check is therefore **per pane, not per command text**. Two panes can be
running the same command; a snapshot that only listed command strings would see
a newly split pane running `sleep 300` as already covered and destroy it
unnamed. So the snapshot records each affected pane and what that pane was
running, and an unseen pane invalidates the agreement even when it is idle,
because the alert stated a pane count that no longer holds.

The check is also on **growth only**. A pane that stopped running a command, or
a to-do that got completed, leaves the subject strictly less costly than what
the user agreed to destroy, so confirming commits — a pane running nothing is
not running a different command. Comparing the snapshot for equality instead
would re-ask every time a command in the subject merely finished, turning a
confirmed close into a prompt the user cannot get past.

Consequences:

- One emit chokepoint replaces `emitTerminateConfirmation`,
  `emitCloseTabConfirmation`, and `emitCloseTabsConfirmation`. It refuses to
  emit while a transaction is pending, keeping the anti-stacking guarantee that
  slot exists for, and now covering pane close too.
- One confirm `Msg` and one cancel `Msg` replace `confirmTerminate` /
  `cancelTerminate` / `confirmCloseTab` / `cancelCloseTab` / `confirmCloseTabs` /
  `cancelCloseTabs`. Confirm clears the slot and closes the subject; cancel
  clears the slot. `QuitConfirmationPanel` sends the same pair.
- One `Command` shows the alert, replacing `showClosePaneConfirmation`,
  `showCloseTabConfirmation`, and `showCloseTabsConfirmation`.
- The quit panel stays projected from the model, shown only when the pending
  transaction's subject is the app itself. A close-subject transaction is an
  alert, never the panel.
- `.closeTab` and `.closePane` keep their existing `wouldQuitFromClose` guards
  unchanged. They are the single place the quitting decision is made, for
  confirmed and unconfirmed closes alike — a shell exiting (`.sessionEnded`) in
  the last pane of the last tab still raises the quit confirmation.

**What is frozen and what is live.** The impact snapshot is frozen at emission
because a modal sheet's text cannot change under the user's eyes. The quit
panel is not a sheet: it is non-modal and deliberately stays usable while panes
come and go, so its copy is recomputed from the live model on every
reconciliation, as it is today. Only close-alert copy reads the snapshot.

**The app subject is live end to end.** It has no snapshot, so there is nothing
to validate at confirm time: confirming an app subject terminates, always.
Freezing an impact for it and then refusing to commit on growth would be
incoherent in both directions — the panel's copy is live and never names
commands, so a refresh would redraw the same panel with no new information and
no sign that Confirm did anything, and a machine starting commands in a loop
could keep the user from ever quitting. Growth validation exists to keep a
*frozen* sentence honest; the panel has no frozen sentence to keep honest.

### I2 — Close impact

One value answers "what would closing this cost", computed from the model so the
gate that decides to prompt and the copy that explains the prompt cannot
disagree: the uncompleted to-do rollup (reusing `tabTodoRollup`), and every
affected pane in tree order paired with the command it is running, if any. Pane
identity is part of the value, not just the command strings — that is what lets
the confirm-time check in `I1` tell a newly split pane from one it already
covered. Pane count and the command list for the copy both fall out of it.

Impact is computed for each subject: one pane, one tab, or a set of tabs.

The **warning predicate** over an impact is: at least one affected pane is
running a command, or the to-do rollup is non-zero. Pane count is carried for
copy and is not part of the predicate — every impact has at least one pane, so
including it would make the predicate universally true.

### I3 — When to ask

- **Pane close** (`.requestClosePane`): ask when the pane's impact meets the
  warning predicate. Today it asks only on uncompleted to-dos. The existing
  last-pane-in-tab branch, which delegates to the tab subject so the tab rollup
  subsumes the pane's to-dos and there is no double prompt, keeps that shape and
  applies the predicate to the tab's impact.
- **Tab close** (`.requestCloseTab`): ask when the tab has more than one pane —
  the existing condition, unchanged — or its impact meets the warning predicate.
  A single-pane tab running a command now asks where it previously closed
  silently.
- **Tab batch** (`.requestCloseTabs`): already always asks; it gains the richer
  impact for its copy.
- Unchanged: `.closeTab`, `.closePane`, and the IPC `tab.close` / `pane.close`
  arms.

### I4 — Alert copy

One copy builder, replacing `closeTabConfirmationCopy` (currently stranded in
`app/AppRuntime.swift`, a layering slip) and `closeTabsConfirmationCopy`. It
takes the subject and the impact and produces two things: the informative
sentence, and the display form of the single named command when there is exactly
one. Both are pure; the app layer only renders them.

The command is **not** interpolated into the sentence. `NSAlert.informativeText`
is a plain `String` with no attributed variant, so a command set in the body text
would be indistinguishable from the prose around it — exactly the confusion the
monospaced form exists to prevent. The sentence says a command is running; the
command itself is a separate monospaced line under it, rendered by the runtime as
the alert's `accessoryView`.

**Title line** (`messageText`), unchanged from today:

- pane — `Close pane?`
- tab — `Close tab "<title>"?`
- batch — `Close <n> tabs?`, or `Close <n> tabs and quit DanTerm?`

**Sentence** (`informativeText`): a subject noun, then up to three clauses, in
this order, joined as `A`, `A and B`, or `A, B and C`.

| clause | exact text | when |
|---|---|---|
| extra panes | `<n> terminal panes` | tab subject: pane count > 1; batch subject: total panes > tab count; never for a pane subject |
| running commands | `a running command` | exactly one affected pane is running |
| | `<n> running commands` | more than one |
| unfinished to-dos | `1 unfinished task` | rollup == 1 |
| | `<n> unfinished tasks` | rollup > 1 |

Subject nouns and the empty-clause fallbacks are the existing ones:
`This pane has <clauses>.` / `This tab has <clauses>.` /
`These tabs have <clauses>.`, falling back to `This pane will be closed.` /
`This tab will be closed.` / `These tabs will be closed.` when no clause fires.
This also settles a current inconsistency: the pane path says "uncompleted task"
today and the tab paths say "unfinished task". `unfinished` wins everywhere.

When the close would quit DanTerm as of emission, the existing quit sentence is
appended — ` Closing it will quit DanTerm.` for a pane or tab subject,
` Closing them will quit DanTerm.` for a batch — and the transaction records that
the user was told. Saying it is what authorizes terminating without asking again.

**What the gates can actually produce.** The builder is total over subject and
impact, but `I3` cannot reach every form, and the plan does not ask for copy no
user will see:

- No pane subject ever quits. The last pane of a tab delegates to the tab
  subject, so a pane subject is always a non-last pane and the quit sentence
  never appends to one.
- Only the batch fallback is live. A pane subject is gated on the warning
  predicate, so it always carries a command or to-do clause; a tab subject is
  gated on that predicate *or* pane count > 1, and each of those fires a clause.
  A batch of idle single-pane tabs has no clause, which is why
  `These tabs will be closed.` still needs to exist.

Worked examples:

```
Close tab "build"?
This tab has 2 terminal panes, a running command and 1 unfinished task.
    npm run dev
[Cancel] [Close Tab]
```

```
Close pane?
This pane has a running command.
    sleep 300
[Cancel] [Close Pane]
```

```
Close 3 tabs and quit DanTerm?
These tabs have 5 terminal panes and 2 running commands. Closing them will quit DanTerm.
[Cancel] [Close 3 Tabs]
```

**Command display form.** Produced only when exactly one affected pane is
running, since that is the only case the sentence claims to name.

A command line is terminal-reported text, so it is exactly what `DisplayLine`
exists for: the confirmation `Command` carries the detail as a `DisplayLine`,
like the tab title beside it already does. That is the whole normalization —
the type collapses whitespace, then strips C0/C1 controls and the bidi
overrides and isolates, in that order. Do not hand-roll it. The same command
string already reaches a notification title through `DisplayLine` in
`alertPresentation`, and a second, weaker normalizer for the same data is how
the two drift.

The rest:

- Bound the normalized text at 60 characters: longer than that, keep the first
  59 and append `…` (U+2026). The bound is applied after normalizing, so a
  command that is 200 characters of escape sequences elides on what will
  actually be drawn rather than on what was stripped.
- No quoting or delimiter. The line stands alone in its own view, so nothing
  around it can be confused with the command's own characters — which is the
  second reason to keep it out of the sentence.
- Rendered by the runtime in a non-editable, non-selectable `NSTextField` set in
  `NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight:
  .regular)`, reading `line.text` at the boundary so the readout site stays
  greppable, with `lineBreakMode = .byTruncatingTail` as a width backstop under
  the 60-character bound. No accessory view when there is no named command.

## Files

- `lib/DanTermCore/Sources/DanTermCore/` — `Model.swift` (the pending
  transaction replaces `PendingConfirmation`), `Msg.swift`, `Command.swift`,
  `Update.swift` (the three request arms, the confirm/cancel arms with the
  confirm-time growth check, the unchanged quit guards),
  `ModelOperations.swift` (impact, chokepoint, copy), `Projections.swift`
  (`desiredQuitConfirmation`).
- `app/AppRuntime.swift` — one confirmation command case; delete
  `closeTabConfirmationCopy`; `runConfirmation` gains an optional monospaced
  detail line, set as the alert's `accessoryView` when the copy names a command.
- `app/QuitConfirmationPanel.swift` — send the unified confirm/cancel messages.

No persistence change: the pending transaction is ephemeral and excluded from
snapshots. No IPC surface change, so `integrations/danterm/SKILL.md` is
untouched.

## Implementation discretion

Helper and type names, how the transaction's subject and quit authorization are
spelled as Swift types, whether impact builders are free functions or properties,
and how the copy builder's clause list is assembled. None of these change
observable behavior or an invariant; the tests below pin what does.

The alert strings in `I4` are not discretionary — they are the specification, and
`PO9` asserts them literally.

## Proof obligations

TDD, Swift Testing, in `lib/DanTermCore/Tests/DanTermCoreTests/`. Behavioral —
each asserts the command emitted, the model state, or the copy text, never
internal call shape.

**PO1 — impact.** A pane whose session reports a running command contributes it;
an idle pane and a pane with no session contribute none. A tab's impact collects
running commands from every pane in tree order alongside the to-do rollup. A tab
batch aggregates running commands across all of its tabs.

**PO2 — when to ask.** A non-last pane running a command raises the
confirmation and stays in the model; an idle pane with no to-dos still closes
with no confirmation. The last pane of a tab, running a command, routes to the
tab subject — one prompt, not two. A single-pane tab running a command raises
the confirmation; the same tab idle and to-do-free closes directly.

**PO3 — the single-confirmation invariant.** Confirming a close whose subject is
the last tab terminates directly: no second confirmation is raised and the
pending slot ends empty. This replaces
`testConfirmCloseTabLastMultiPaneRoutesToTerminate`, whose pinned two-prompt
chain is the behavior being fixed — it is rewritten, not deleted, so the
last-tab path stays covered. A shell exiting in the last pane of the last tab
still raises the quit confirmation, since that entry is unauthorized.

**PO4 — the model changing around the subject.** With a quit-authorized
transaction pending on the last tab, adding a tab and then confirming closes
only the subject tab: the added tab and its running command survive, and the app
does not terminate. With an unauthorized tab-close transaction pending, removing
the other tabs and then confirming closes the subject and raises the quit
confirmation rather than terminating silently.

Each subject kind reaches termination by its own close path, so cover the
unauthorized-becomes-app-emptying transition for all three, not just a single
tab. In every case, confirming closes the subject and nothing else, and raises
the quit confirmation instead of terminating:

- **Batch.** An unauthorized batch of tabs; the tabs outside the batch go away
  while the alert is open. Today's batch arm closes each tab and terminates once
  none remain, which would quit an app the user was never warned about.
- **Pane.** An unauthorized non-last pane whose sibling pane's shell exits,
  leaving the subject the last pane of the last tab. This is shrinkage, so the
  growth check commits, and the quit decision is `.closePane`'s guard alone.

**PO4a — an app subject always terminates.** With an app-subject transaction
pending, starting a command in a pane and then confirming terminates: no refresh,
no second panel. This pins the asymmetry in `I1` — growth validation is a
property of close subjects, and quitting cannot be starved by a pane that keeps
starting work.

**PO5 — the subject gaining work under an open alert.** With a tab-close
transaction pending, starting a command in a pane of that tab and then
confirming does not close the tab: a fresh confirmation describing the subject
as it now stands is raised instead. The same holds when the change lands in one
tab of a pending batch. Three cases pin the per-pane keying specifically:

- The snapshot covers a pane running `sleep 300`; a *second* pane running the
  same `sleep 300` is split into the subject. Confirming refreshes rather than
  closing both — command text alone must not make the new pane look covered.
- An *idle* pane is split into the subject. Confirming refreshes, because the
  alert stated a pane count that no longer holds.
- A covered pane finishes its command. Confirming commits — not running is not
  running something different.

**PO6 — anti-stacking.** Emitting a pane-close confirmation fills the pending
slot, and a `.requestQuit` while it is pending is a no-op. The quit panel
projection returns nil while a close-subject transaction is pending, so the
panel and the alert can never both be up.

**PO7 — live quit panel copy.** While an app-subject transaction is pending,
the quit panel projection reports the live pane count: closing a non-last pane
decrements it. This is the existing
`desiredQuitConfirmationDecrementsWithPanes`, which must keep passing — the
emission snapshot must not reach the panel.

**PO8 — confirm and cancel.** Confirm clears the slot and closes the subject for
each subject kind; cancel clears the slot and leaves the model otherwise
untouched.

**PO9 — copy.** Assert the exact strings from `I4`, for each subject kind.

- One running command yields the sentence clause `a running command` plus a
  command display line equal to the command; several yield `2 running commands`
  and no command line.
- Panes, commands, and to-dos together produce
  `This tab has 2 terminal panes, a running command and 1 unfinished task.` —
  the three-clause form the old two-clause builders could not express.
- A batch of idle single-pane tabs yields `These tabs will be closed.`
- The quit sentence appends when the close would quit as of emission: `Closing
  it will quit DanTerm.` for a tab subject, `Closing them will quit DanTerm.`
  for a batch. Assert no test for a quitting pane subject or for the pane and
  tab fallbacks — `I4` shows the gates cannot produce them.
- A pane subject and a tab subject with the same single running command produce
  the same command display line, so the two paths cannot drift apart.
- Command display form: a 61-character command renders as 59 characters plus
  `…`; a 60-character command is untouched; a command containing `"` and `'`
  passes through unchanged, since the form does not quote.

**PO10 — the display boundary covers the command detail.** Extend the existing
sweep in `DisplayBoundaryTests.swift`, which already reads the close-tab
confirmation, to the new confirmation command detail, and add a control-bearing
and a bidi-override input to its hostile set — a command carrying `ESC` or
`U+202E` must reach the view flat and in visual order. `DisplayLine` is what
makes this pass; the obligation is that the sweep would catch the detail being
added as a bare `String`, which the whitespace cases above cannot.

Monospace rendering itself is an AppKit property of the accessory view, not a
core behavior, so it is confirmed in the `Verification` walkthrough rather than
by a unit test.

Existing to-do-only confirmation tests in `UpdateTodoTests.swift` and
`UpdateTabTodoTests.swift` are updated to the unified command and messages.

## Verification

1. `swift test --package-path lib/DanTermCore`, then `just test`.
2. `bash ./dev-build.sh --no-install` to confirm the app target compiles.
3. End to end in an isolated slot (`just launch-slot`, driven with an explicit
   `danterm --socket <slot>`):
   - Run `sleep 300` in a split pane; `danterm --socket <slot> pane info --pane
     <pane-id>` should report `.pane.command` as running. Cmd+W: expect
     `This pane has a running command.` with
     `sleep 300` on its own monospaced line below it. Cancel —
     the pane stays, and a following Cmd+Q still raises the quit panel, proving
     the slot cleared. Cmd+W again and confirm — the pane closes.
   - An idle pane with no to-dos closes on Cmd+W with no sheet.
   - Two-pane tab with a running command and one unfinished to-do, Shift+Cmd+W:
     expect the three-clause copy.
   - A single window, single tab, single pane running `sleep 300`, Cmd+W: one
     sheet that says it will quit DanTerm, and confirming quits — no second
     prompt.
   - With a tab-close sheet open on an idle two-pane tab, use the CLI from
     another terminal to start `sleep 300` in one of its panes, then confirm:
     expect a fresh sheet naming `sleep 300` rather than the tab closing.
   - Run a long command with embedded newlines and quotes (a multiline `for`
     loop, or `echo "a  b"` with runs of spaces). Cmd+W: the command line is
     one monospaced line, space-normalized, elided with a trailing `…`, and the
     alert does not grow wider than an ordinary alert.
   - Run a command whose text carries an escape sequence and a right-to-left
     override (`printf` of `\033[31m` and `‮` inside the command line).
     Cmd+W: the detail draws flat, in the order it was typed, with no color and
     no reversed run.
   - `danterm pane close --pane <id>` on a pane running `sleep 300` closes it
     with no prompt.

## Non-goals / accepted risks

- Prompting on agent activity (`SessionModel.agent`). The sidebar dot's signal
  is deliberately not used; revisit if agent panes close unwarned in practice.
- A per-command ignore list (never prompt for `less`, `man`, a pager).
- A `confirm-on-close` config flag.
- Guarding `danterm pane close` / `tab.close` behind a `--force` flag.
- Migrating close confirmations from `NSAlert` to the non-modal panel.
- To-dos added to the subject while its alert is open are not revalidated: they
  are destroyed on confirm without being named. Closing has always discarded
  to-dos silently, so this is unchanged behavior rather than a promise this
  feature breaks, and the confirm-time check stays scoped to running commands.
- A **close** subject whose panes start commands continuously can re-ask on every
  confirm. Each fresh alert is accurate about what is running, and Cancel always
  works, so no retry counter or suppression window is warranted. Quitting cannot
  be starved this way: an app subject runs no growth check and terminates on
  confirm.
