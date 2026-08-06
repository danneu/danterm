# Browsing scrollback survives an application's history wipe as follow, not as top

## Context

Splitting or closing a split while browsing a codex TUI's scrollback jerks the
pane to the top of the conversation. Old DanTerm on libghostty did not do this.

The split itself is not the cause. Codex runs inline on the primary screen, so
its transcript is real DanTerm scrollback, and on every SIGWINCH it emits
`ESC[r ESC[H ESC[2J ESC[3J ESC[H` and reprints the whole transcript -- ED 3
destroys the retained history the browse anchor named. Captured from a real
codex 0.146.1 on a PTY across a resize; replaying that byte stream through
`TerminalCore` reproduces the jump, and stripping only `ESC[3J` from the replay
leaves the browse position exactly where it was. So the resize/reflow anchor
machinery is correct and ED 3 is the whole trigger.

What the engine does with the wipe is the defect. Eviction clamps a browse
anchor to the oldest retained position and keeps browsing; when the wipe leaves
nothing retained, that clamp pins the viewport to the first row of an empty
stream, and codex's reprint then accumulates *below* the window. Ghostty runs
the same clamp but then asks whether the anchor has landed inside the live grid,
and returns to bottom-follow when it has (`PageList.zig#fixupViewport`, applied
after both erase and resize) -- which is why the old build did not strand the
user at the top.

Desired outcome: an application that wipes and reprints its own history leaves
the pane following the live bottom, as it did on libghostty.

## Decision

Make the anchor clamp refuse to strand a displaced viewport: when the clamp has
to move an out-of-range top anchor and the position it lands on is the newest
window the stream can show, the viewport returns to bottom-follow. An anchor
that is still valid where it sits is never converted, even when it already
addresses the newest window -- the clamp is a fallback for content that stopped
existing, not a policy over every viewport. Applies wherever that clamp already
runs -- after eviction, and after both height and width resize -- matching
ghostty's placement of the same fixup. No ED 3 special case, and no new viewport
state.

This amends a written contract. `plan-terminal-engine/08-input-interaction.md`
currently promises that eviction clamps the anchor "without re-enabling bottom
follow"; that sentence must gain the exception, since it is the sentence this
change contradicts.

Preserving the user's actual reading position across a wipe-and-reprint is out
of scope: the content is genuinely destroyed and re-emitted, often reflowed, so
re-finding it would be a content-identity feature, not a fix.

## Invariants

- **I1.** A clamp that displaces an out-of-range browse anchor onto the newest
  showable window re-enables bottom follow, so subsequent output scrolls under
  the viewport.
- **I2.** A clamp that leaves older retained content above the window keeps
  browsing. Routine scrollback-budget eviction while a user reads old output
  must not yank them to the bottom.
- **I3.** Explicit reveal-style positioning at the live bottom is unaffected:
  search navigation still reveals a match without enabling bottom follow, and a
  later clamp that does not have to move that anchor leaves it browsing. Only a
  displacing clamp -- the fallback after the anchored position stopped being
  addressable -- converts to follow.
- **I4.** The viewport change is presented: a clamp that flips to follow
  repaints, like any other viewport transition.

## Proof obligations

- **PO1** (I1, the incident): browsing mid-history, feeding codex's SIGWINCH
  repaint shape (`ESC[3J` among it) and then a fresh transcript leaves the
  viewport following the newest rows rather than pinned at the top.
- **PO2** (I1): growing a pane's height until the pull-back absorbs all
  retained history leaves a browsing viewport following, and later output stays
  visible.
- **PO3** (I2): browsing at the oldest retained row while budget eviction rolls
  the stream forward still browses, with the window tracking retained content.
- **PO4** (I1): a width change whose reflow shortens the stream enough to push a
  browsing anchor past the newest window leaves the viewport following, and
  later output stays visible.
- **PO5** (I3): search reveal at the live bottom still does not enable follow,
  and survives a subsequent resize that runs the clamp without displacing it --
  output after that resize does not scroll the revealed match away.

`TerminalViewportTests` already pins the pre-change answers for PO1's ED 3 leg
and PO2; both expectations change with this work, and the amended contract
sentence travels in the same commit.

## Non-goals

- Preserving reading position across a wipe-and-reprint (see Decision).
- Any change to alternate-screen viewport behavior, which never browses.
- Any app-, pane-session-, or scrollbar-layer change: the seam is `Terminal`.

## Accepted risks

- **AR1.** An application that wipes history while the user browses now loses
  their position to the bottom instead of the top. That is the libghostty
  behavior being restored, and no better answer exists without content
  identity.

## Implementation discretion

- Whether the clamp's name and doc comment change to reflect its broadened
  contract.
- Whether the now-redundant "anchor older than the oldest retained row" branch
  that precedes the clamp is folded into it.

## Critical files

- `lib/TerminalCore/Sources/TerminalCore/Terminal.swift` -- the shared anchor
  clamp (`clampViewportAnchorToRetainedStream`) called from eviction and both
  resize legs; `scroll(toTopRow:)` already encodes the follow-at-bottom rule
  this change extends to the clamp.
- `lib/TerminalCore/Tests/TerminalCoreTests/TerminalViewportTests.swift` --
  where the existing eviction/resize viewport specs live.
- `plan-terminal-engine/08-input-interaction.md` -- the contract sentence.

## Verification

- `just test`.
- End to end in a slot: `just launch-slot`, run `codex` in a pane, build enough
  transcript to scroll, scroll partway up, split the tab, then close the split.
  The viewport should end at the live bottom both times, never at the top.
