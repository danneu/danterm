# Agent-session toolbar chip: sparkles icon + name-only label

## Context

We're on the `agent-session-awareness` branch building per-pane agent-session
awareness (Claude/Codex). The branch already ships a pane-toolbar accessory chip
for agent sessions, modeled on the existing SSH "remote session" chip: a teal
background, an SF Symbol glyph in an `NSImageView`, and a label. It currently
renders as `cpu` + `"Claude 4f3a2b1c"` (display name + first 8 chars of the
session id).

The user wants this chip to read like the SSH remote chip but for agents:
**just the agent name, with an icon** -- `{icon} {name}`. Two refinements to the
already-built chip:

- **Icon:** the user asked for a "robot" icon. Verified on this machine
  (macOS 26 / SF Symbols 7) that there is **no stock `robot` SF Symbol** -- only
  `robotic.vacuum`. The chip is built around a white-tinted SF Symbol (to match
  the SSH globe), so the user chose **`sparkles`** (Apple's standard "AI" glyph)
  over a full-color robot emoji that would not tint and would fight the chip's
  style.
- **Label:** drop the session-id suffix so the chip shows the **agent name
  only** (`"Claude"`). The full id is already available via the chip's tooltip
  (`PaneWrapperView.swift:328`), so nothing is lost.

Intended outcome: an agent pane shows a clean `[sparkles] Claude` chip in the
toolbar, visually consistent with the SSH `[globe] user@host` chip.

## What already exists (reuse, do not rebuild)

The entire chip is already implemented and only needs the two value tweaks above:

- `app/PaneWrapperView.swift` -- `agentAccessory` (teal), `agentIcon`
  (`NSImageView`), `agentSessionLabel`, the compact/expanded constraint sets, the
  visibility toggle in `updateToolbar(...)`, and the full-id tooltip are all in
  place and unchanged.
- `app/Reconcile.swift:226` -- `reconcilePaneChrome()` already passes
  `render.agentSession` into `updateToolbar(...)`.
- `lib/DanTermCore/.../Projections.swift` -- `PaneToolbarRender.agentSession`
  already projected from `pane.agentSession`.
- `agentSessionLabel.stringValue` is driven by `AgentSession.toolbarLabel`
  (`PaneWrapperView.swift:326`), which is the single lever for the visible text.

## Changes

### 1. Label -> name only (pure core)

`lib/DanTermCore/Sources/DanTermCore/AgentSession.swift` (~line 29) -- change
`toolbarLabel` to return the display name only, and add a one-line doc comment
recording why the id is omitted (it lives in the tooltip; keeps the chip
compact, mirroring the SSH chip):

```swift
/// Text for the pane toolbar's agent chip: the agent display name only. The
/// full session id is intentionally omitted here -- it lives in the chip's
/// tooltip -- so the chip stays compact, mirroring the SSH remote chip.
var toolbarLabel: String {
    AgentCatalog.displayName(for: kind)
}
```

`toolbarLabel` has exactly one production consumer (`PaneWrapperView.swift:326`)
and three test assertions; no other caller depends on the old `name <id>` shape
(confirmed by grep).

### 2. Icon -> sparkles (app)

`app/PaneWrapperView.swift` (~line 159) -- swap the SF Symbol name:

```swift
agentIcon.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Agent session")
```

And update the now-stale section comment (~line 151) from
`// Agent accessory: teal background with CPU icon, hidden by default` to
`// ... with sparkles icon, ...`. No constraint/layout changes -- the glyph slot
is unchanged.

### 3. Update the 3 label assertions (core tests)

`lib/DanTermCore/Tests/DanTermCoreTests/AgentSessionTests.swift` -- the only
assertions that pin the old `name <id>` format:

- line 20: `"Claude 4f3a2b1c"` -> `"Claude"`
- line 29: `"Codex thread_1"` -> `"Codex"`
- line 40: `"Future_Agent abc123"` -> `"Future_Agent"`

These keep their purpose (pin that the chip text is the catalog display name with
**no** session id), and the surrounding `sessionId` / `resumeCommand` /
`recoveryMessage` assertions in the same tests are unaffected -- those paths still
carry the full id. No other test asserts the toolbar label string.

## Out of scope

- The Nix `SessionStart` hook wiring (world repo `common/claude-code.nix` /
  `common/codex.nix`) remains a separate follow-up; not needed to see the chip.
- No change to the chip color, geometry, tooltip, projection, or reconcile path.

## Verification

1. **Targeted core test:**
   `swift test --package-path lib/DanTermCore --filter AgentSessionTests`
   -- the three changed assertions pass (and fail first if reverted).
2. **Full local gate:** `just test` (core Swift Testing + protocol XCTest +
   DanTermSupport + core-purity lint + shell self-tests).
3. **Visual, in-app:** `just build-run`, then in a pane simulate an attach
   without needing the hook wired:
   `danterm agent attach --kind claude --id 4f3a2b1c-0000-4000-9000-abcdef123456`
   -> the toolbar shows a teal `[sparkles] Claude` chip (name only); hovering the
   chip shows the tooltip with the full session id. Run `danterm` again with a
   `codex` kind to confirm `[sparkles] Codex`. Returning to the shell prompt
   (`CMD_END`) clears the chip.
