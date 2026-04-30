# Capture remote user@host via title-channel REMOTE_HOST event

## Context

DanTerm's current SSH detection is a binary `isRemote: Bool` on `PaneModel`,
flipped on by a custom `ssh()` shell wrapper that emits
`__DANTERM_EVT__:<token>:REMOTE_START` over the title channel before exec'ing
`command ssh`. The toolbar shows a purple accessory; no host info is captured
or displayed.

We want the actual `user@host` so the toolbar can show *which* remote you're on.
The local shell can't know this (`ssh foo` could resolve to anything via
`~/.ssh/config`). The remote shell trivially knows via `whoami`/`hostname`.

Two facts shape the design:

- Both standard channels for shell→terminal host reporting are dead ends
  through libghostty:
  - **OSC 7** (`file://host/path`) — Ghostty validates host as local with
    `internal_os.hostname.isLocal()` and silently drops non-local; the
    `pwd_change` action never reaches embedders. See
    `.ghostty-src/src/termio/stream_handler.zig:1163-1177`.
  - **OSC 1337 `RemoteHost=user@host`** (the iTerm2 standard) — Ghostty's
    parser recognizes the key but routes it to an `unimplemented` arm that
    sets `parser.command = .invalid`. No structured `Command` is built and
    no embedder action is dispatched. See
    `.ghostty-src/src/terminal/osc/parsers/iterm2.zig:176-194`.
- libghostty's C API exposes only structured actions (`SET_TITLE`, `PWD`,
  `DESKTOP_NOTIFICATION`, ...). There is no raw-OSC callback. The only OSC
  family that round-trips intact is OSC 0/2 (window title), which DanTerm
  already rides via the `__DANTERM_EVT__:<token>:...` protocol.

So the design extends the existing title-channel protocol with a new event
emitted from the *remote* shell's prompt hook, with the per-pane token
forwarded over SSH as `LC_DANTERM_TOKEN` (using the well-known `LC_*`
trick to bypass strict `AcceptEnv` policies).

## Design

### Data flow

```
1. DanTerm spawns shell with env DANTERM_TOKEN=<uuid>
   (existing — AppRuntime.swift:160)

2. User types `ssh caja`. Local zsh's ssh() wrapper:
   - emits __DANTERM_EVT__:<tok>:REMOTE_START (existing fast trigger)
   - calls: LC_DANTERM_TOKEN=<tok> command ssh -o "SendEnv LC_DANTERM_TOKEN" caja

3. caja's sshd accepts LC_* (after the planned AcceptEnv setting is
   applied — see "nix wiring" below) → shell on caja sees
   LC_DANTERM_TOKEN in its env.

4. Remote shell's snippet detects LC_DANTERM_TOKEN, registers a
   precmd / fish_prompt hook that emits on every prompt:
     __DANTERM_EVT__:<tok>:REMOTE_HOST:<base64(whoami)>:<base64(hostname)>

   user and host are encoded as separate base64 payloads (joined by `:`)
   so neither can corrupt the other and the Swift side never has to
   parse `user@host` heuristically.

5. The OSC traverses ssh stdout → local PTY → libghostty → SET_TITLE
   action → DanTerm's surfaceTitle Msg.

6. translateMsg() in ModelOperations.swift validates the token, decodes
   both base64 payloads to UTF-8 strings, builds
   RemoteSession(user:host:), and dispatches
   Msg.remoteSessionReported(paneId, session).

7. Update sets pane.remoteSession = session, ensures isRemote = true,
   sets remoteThemeOverride if first transition.

8. PaneWrapperView toolbar shows session.displayString
   (i.e. "user@host") *inside* the existing purple remote accessory,
   next to the globe icon — the accessory expands horizontally to fit
   the label and contracts back to icon-only when remoteSession is nil.

9. On exit ssh, local shell's precmd fires CMD_END → clears
   isRemote + remoteSession.
```

Key properties:
- Idempotent: per-prompt re-emission with unchanged value is a no-op (theme
  isn't reapplied; toolbar refresh is cheap).
- Nested SSH: the receiver branch defines its own `ssh()` wrapper that
  re-forwards `LC_DANTERM_TOKEN` as an env-var prefix on the subprocess.
  Since the wrapper sets the env var inline (`LC_DANTERM_TOKEN=$tok ssh ...`),
  the next remote shell sees it on first read; two-hop and deeper chains
  work without any disk persistence.
- Spoofable like all OSC-based metadata. UI-only; never gate destructive
  ops on it. Same caveat iTerm2 documents for `RemoteHost`.

### Why `LC_DANTERM_TOKEN` (not `DANTERM_TOKEN`)

`AcceptEnv` is **not** a default in OpenSSH — `sshd_config(5)` documents
"the default is not to accept any environment variables", and NixOS's
`services.openssh.settings.AcceptEnv` defaults to null (no directive
emitted). Many Linux distros ship `/etc/ssh/sshd_config` with
`AcceptEnv LANG LC_*` pre-configured, which is why this convention is
common in the wild — but it's a distro choice, not an OpenSSH default.

We pick `LC_*` anyway because it's the conventional whitelist most servers
already enable, even if not by default. The plan explicitly enables it on
caja via nix and documents the requirement for unmanaged remotes.

### v1 scope: first remote shell + nested ssh; sudo/su deferred

A naive receiver — read `LC_DANTERM_TOKEN`, copy to a shell-local var,
`unset` it — works for the first remote shell and for nested ssh (since
the receiver-side `ssh()` wrapper re-forwards `LC_DANTERM_TOKEN` as an
env-var prefix). It does **not** survive privilege transitions like
`sudo -i` or `su - user`, because those start fresh login shells with
stripped env, and shell-local variables don't cross process boundaries.

Robust sudo/su recovery would require:

- **System-wide receiver installation**, not just home-manager
  per-user. On caja, root's default shell is bash; even if dan's fish
  init has the receiver, root's `sudo -i` bash login shell never sources
  it. We'd need a bash receiver and a system-level
  `programs.bash.interactiveShellInit` (or equivalent in `/etc/profile.d/`).
- **A safe cross-uid token transport.** A per-TTY temp-file scheme that
  works across uids (so root via sudo can read dan's token) opens a
  TOCTOU surface: predictable paths in `/tmp`, symlink attacks, mode
  verification on every existing dir. Doable but non-trivial.

Both are reasonable v2 work but unnecessary complexity for "show me
which host I'm on". v1 ships:

- ✅ `ssh user@host` → toolbar shows `user@host` (initial connect)
- ✅ Nested `ssh other` from a receiver shell → toolbar updates to
  `user@other`
- ✅ Exit ssh → label clears
- ❌ `sudo -i` / `su - user` → toolbar shows the parent shell's user (stale
  but not wrong-host). Will be addressed in v2.

The receiver, accordingly, is purely env-var-driven: no temp files, no
TOCTOU surface, no system-wide installation needed.

### Sender vs receiver in one script

The existing `scripts/danterm-integration.{zsh,fish}` are inlined into
home-manager via `builtins.readFile`
(`hosts/macbook/modules/shells.nix:36-37`, `:127`, `:231`). Cleanest is to
extend those same scripts so they handle both roles, gated by which env
var is set:

- `DANTERM_TOKEN` set → local DanTerm-spawned shell → command tracking
  + `ssh()` wrapper.
- `LC_DANTERM_TOKEN` set (and `DANTERM_TOKEN` not set) → remote shell over
  SSH → per-prompt `REMOTE_HOST` emission.

The branches are mutually exclusive because the local block `unset`s
`DANTERM_TOKEN` immediately, and `LC_DANTERM_TOKEN` is set only by the
local `ssh()` wrapper for the ssh subprocess (it's never in the
parent shell).

### Scope decisions for v1

- **`hostname` (short), not `hostname -f`** — confirmed.
- **Per-prompt emission**, not once-only — confirmed. Cheap (one printf
  per prompt) and gives the Swift side an idempotent re-confirmation
  signal on every prompt cycle. Also lays groundwork for v2 sudo/su
  support without changing the wire protocol.
- **ssh only**, not mosh — mosh's env propagation requires
  `--ssh="ssh -o SendEnv=LC_DANTERM_TOKEN"`; the existing `mosh()`
  wrapper continues to emit `REMOTE_START` (purple accessory still shows)
  but won't carry user@host. Punted to v2.
- **Keep `REMOTE_START` fast-trigger** — fires before the remote shell
  finishes connecting, so the accessory appears immediately rather than
  waiting for the first remote prompt.
- **UI**: the user@host text lives **inside** the existing purple
  `remoteAccessory`, next to the existing remote icon. The accessory
  keeps its compact icon-only footprint when no `remoteSession` is set
  (no snippet on remote, sshd strips `LC_*`, or before the first remote
  prompt) and expands horizontally when one is set. The label is
  truncating-tail so a long host doesn't push out the pane title. No
  new sibling in the toolbar's leading stack.

## Concrete changes

### Shell scripts (~/world)

**`scripts/danterm-integration.zsh`** — extend the existing file:

- Modify the existing `ssh()` wrapper in the local-DanTerm branch to
  forward the token via `LC_DANTERM_TOKEN`:
  ```zsh
  ssh() {
    printf '\e]0;__DANTERM_EVT__:%s:REMOTE_START\a' "$_danterm_tok"
    LC_DANTERM_TOKEN="$_danterm_tok" command ssh -o "SendEnv LC_DANTERM_TOKEN" "$@"
  }
  ```
- Extend the existing `if [[ -n "$DANTERM_TOKEN" ]]; then ... fi` block
  by replacing its closing `fi` with an `elif ...; then ...; fi` so the
  whole conditional becomes a single `if/elif/fi`. (`elif` must follow
  an open `if`/`elif`, not a closed `fi`.)
  ```zsh
  elif [[ -n "$LC_DANTERM_TOKEN" ]]; then
    typeset -g _danterm_tok="$LC_DANTERM_TOKEN"
    unset LC_DANTERM_TOKEN
    _danterm_b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
    _danterm_remote_host() {
      local ub="$(_danterm_b64 "$(whoami)")"
      local hb="$(_danterm_b64 "$(hostname)")"
      printf '\e]0;__DANTERM_EVT__:%s:REMOTE_HOST:%s:%s\a' \
        "$_danterm_tok" "$ub" "$hb"
    }
    precmd_functions+=(_danterm_remote_host)
    ssh() {
      # Same shape as the local-DanTerm ssh wrapper: REMOTE_START first to
      # clear any stale host label, then forward the token to the next hop.
      # If the next hop has the snippet + AcceptEnv, REMOTE_HOST will
      # repopulate the label; if not, the label stays empty (correct).
      printf '\e]0;__DANTERM_EVT__:%s:REMOTE_START\a' "$_danterm_tok"
      LC_DANTERM_TOKEN="$_danterm_tok" command ssh -o "SendEnv LC_DANTERM_TOKEN" "$@"
    }
  fi
  ```

  Each of `whoami` and `hostname` is base64-encoded independently and
  joined with a literal `:` separator. base64 alphabet is
  `[A-Za-z0-9+/=]`, no `:`, so the separator is unambiguous on the Swift
  side.

  No filesystem touch, no temp dirs, nothing to clean up. The token
  exists only in the receiver shell's memory and is forwarded to ssh
  subprocesses via inline env-var assignment.

**`scripts/danterm-integration.fish`** — extend the existing file:

- Modify the local-DanTerm `ssh` wrapper (currently lines 25-28) to
  forward the token. Fish doesn't support POSIX-style inline env-var
  assignment; use `set -lx` to set a local-exported variable for the
  duration of the function:
  ```fish
  function ssh --wraps ssh
    printf '\e]0;__DANTERM_EVT__:%s:REMOTE_START\a' $_danterm_tok
    set -lx LC_DANTERM_TOKEN $_danterm_tok
    command ssh -o "SendEnv LC_DANTERM_TOKEN" $argv
  end
  ```
- Extend the existing `if set -q DANTERM_TOKEN ... end` block (lines
  12-33) by replacing its closing `end` with `else if ...; <body>; end`
  so the whole conditional becomes a single `if/else if/end`. (`else if`
  must appear inside the open `if`, not after the closed `end`.) Fish's
  prompt-cycle hook is the `fish_prompt` event, fired before each
  prompt render:
  ```fish
  else if set -q LC_DANTERM_TOKEN
    set -g _danterm_tok $LC_DANTERM_TOKEN
    set -e LC_DANTERM_TOKEN
    function _danterm_remote_host --on-event fish_prompt
      set -l ub (printf '%s' (whoami) | base64 | tr -d '\n')
      set -l hb (printf '%s' (hostname) | base64 | tr -d '\n')
      printf '\e]0;__DANTERM_EVT__:%s:REMOTE_HOST:%s:%s\a' $_danterm_tok $ub $hb
    end
    function ssh --wraps ssh
      # Same shape as the local wrapper: REMOTE_START first to clear stale
      # host label, then forward the token to the next hop.
      printf '\e]0;__DANTERM_EVT__:%s:REMOTE_START\a' $_danterm_tok
      set -lx LC_DANTERM_TOKEN $_danterm_tok
      command ssh -o "SendEnv LC_DANTERM_TOKEN" $argv
    end
  end
  ```

  Use `tr -d '\n'` (not `string trim`) to delete *all* newlines.
  `string trim` only strips leading/trailing whitespace; both BSD and
  GNU `base64` line-wrap output at 76 chars by default, so a long
  hostname/FQDN can produce embedded newlines that `string trim` would
  preserve, breaking the OSC payload. `tr -d '\n'` is the same primitive
  the zsh snippet uses, keeping both shells aligned.

Notes:

- `set -g` makes `_danterm_tok` global (function-scope wouldn't survive
  past the script's own block); fish global vars persist for the shell
  session, equivalent to `typeset -g` in zsh.
- `tr -d '\n'` is required (not `string trim` — see explanation
  immediately above the snippet). `string trim` only handles leading
  and trailing whitespace, not embedded newlines from base64 line
  wrapping.
- `set -lx` (local-exported) is preferred over `env LC_DANTERM_TOKEN=$_danterm_tok ...`
  because `env` rebuilds the entire env once (fine, but extra fork) and
  doesn't compose well with fish builtins like `command`.

### nix wiring

**`hosts/caja/modules/shells.nix`** — caja currently has no DanTerm
integration. Add it so caja's fish shell emits `REMOTE_HOST` when
SSHed-into from DanTerm.

- In the `let` block, add:
  ```nix
  dantermFishIntegration = builtins.readFile ../../../scripts/danterm-integration.fish;
  ```
- In `programs.fish.interactiveShellInit`, append at the end (before
  the closing `''`):
  ```
  ${dantermFishIntegration}
  ```

**`hosts/macbook/modules/shells.nix`** — no structural changes; the
existing `${dantermZshIntegration}` and `${dantermFishIntegration}`
inclusions cover the new content of the scripts.

**`hosts/caja/configuration.nix`** — extend `services.openssh.settings`
(currently lines 120-129) to whitelist locale env vars. OpenSSH's
compiled-in default is to accept **no** environment variables; without
this directive the token never reaches the receiver shell. Add:

```nix
services.openssh.settings.AcceptEnv = [ "LANG" "LC_*" ];
```

The NixOS module pins this option's type to `null or list of string`, so
the list form is required (string form fails evaluation).

### DanTerm Swift

**`app/Model.swift`** — add a typed `RemoteSession` struct, and a
`remoteSession` field on `PaneModel`:

```swift
struct RemoteSession: Equatable {
    var user: String
    var host: String

    var displayString: String { "\(user)@\(host)" }
}
```

In `PaneModel`, alongside `isRemote` (line 72):
```swift
var remoteSession: RemoteSession? = nil  // set by REMOTE_HOST event; ephemeral; not persisted
```

Using a struct (not a string) keeps the model type-safe, makes
equality/diff trivial, and avoids any temptation on the Swift side to
parse `user@host` heuristically (which would break if a hostname or
username ever contains `@`).

**`app/Msg.swift`** — add new case after line 58:
```swift
case remoteSessionReported(paneId: PaneId, session: RemoteSession)
```

**`app/ModelOperations.swift`** — extend the event protocol:

- Line 743 `enum DantermEvent`: add
  ```swift
  case remoteSession(value: RemoteSession)
  ```
- Line 782-789 `translateMsg` switch: add
  ```swift
  case .remoteSession(let value):
    return .remoteSessionReported(paneId: paneId, session: value)
  ```
- Line 800-813 `parseDantermEvent`: add a branch. The wire payload is
  `<base64(user)>:<base64(host)>` — split on a literal `:`, decode each
  half, build the struct. base64 output never contains `:`, so the
  separator is unambiguous:
  ```swift
  } else if event.hasPrefix("REMOTE_HOST:") {
    let payload = String(event.dropFirst("REMOTE_HOST:".count))
    let parts = payload.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let userB64 = String(parts[0])
    let hostB64 = String(parts[1])
    guard !userB64.isEmpty, !hostB64.isEmpty,
          let userData = Data(base64Encoded: userB64),
          let user = String(data: userData, encoding: .utf8),
          !user.isEmpty,
          let hostData = Data(base64Encoded: hostB64),
          let host = String(data: hostData, encoding: .utf8),
          !host.isEmpty
    else { return nil }
    return .remoteSession(value: RemoteSession(user: user, host: host))
  }
  ```
  Reject conditions (any → nil → event dropped silently):
  - Wrong number of `:`-separated parts (must be exactly 2)
  - Either base64 segment empty
  - Either base64 segment fails to decode
  - Either decoded payload is not valid UTF-8
  - Either decoded string is empty

**`app/Update.swift`** — three changes:

- Add a `.remoteSessionReported` handler near `remoteSessionStarted`
  (line 514):
  ```swift
  case .remoteSessionReported(let paneId, let session):
    guard model.panes[paneId] != nil else { return [] }
    let wasRemote = model.panes[paneId]!.isRemote
    let oldSession = model.panes[paneId]!.remoteSession
    model.panes[paneId]!.isRemote = true
    model.panes[paneId]!.remoteSession = session
    guard !wasRemote || oldSession != session else { return [] }
    if !wasRemote {
      model.panes[paneId]!.remoteThemeOverride = model.config.remoteTheme
      return [.applyPaneTheme(paneId: paneId)]
    }
    return []
  ```

- Extend the `commandEnded` handler at line 506-510 to also clear
  `remoteSession`:
  ```swift
  case .commandEnded(let paneId):
    model.panes[paneId]?.isRemote = false
    model.panes[paneId]?.remoteSession = nil
    guard model.panes[paneId]?.remoteThemeOverride != nil else { return [] }
    model.panes[paneId]?.remoteThemeOverride = nil
    return [.applyPaneTheme(paneId: paneId)]
  ```

- Extend the `remoteSessionStarted` handler at line 514 to clear any
  stale `remoteSession`. Essential for the nested-SSH case where the
  user does `ssh other` from a receiver shell and `other` lacks the
  snippet (or rejects `LC_*`): without this, the toolbar would keep
  showing the previous host's label while the user is on a different
  machine. `REMOTE_START` fires immediately on the wrapper invocation,
  so the label correctly goes blank pending a new `REMOTE_HOST`:
  ```swift
  case .remoteSessionStarted(let paneId):
    guard model.panes[paneId] != nil else { return [] }
    model.panes[paneId]?.isRemote = true
    model.panes[paneId]?.remoteSession = nil   // clear stale session
    model.panes[paneId]?.remoteThemeOverride = model.config.remoteTheme
    return [.applyPaneTheme(paneId: paneId)]
  ```

**`app/AppRuntime.swift`** — add `.remoteSessionReported(let paneId, _)`
to the toolbar-refresh switch at line 134-138 so the new event triggers
a toolbar refresh. Update the two `wrapper.updateToolbar(...)` calls
(lines 1024, 1037) to pass
`remoteSession: model.panes[wrapper.paneId]?.remoteSession`.

**`app/PaneWrapperView.swift`** — the user@host text goes **inside** the
existing purple `remoteAccessory`, not as a separate label beside it.
Visual goal:

```
[icon dan@caja]  pane title…
```

Concrete changes:

- The leading stack (`PaneWrapperView.swift:127-133`) keeps its current
  layout exactly: `alertBadge`, `remoteAccessory`, `progressIndicator`,
  `toolbarLabel`. No new top-level item.
- Add a private `remoteSessionLabel: NSTextField` field. Add it as a
  subview of `remoteAccessory`, positioned to the right of `remoteIcon`.
- Layout uses three groups of constraints: **always-on** (centering and
  intrinsic icon sizing), **compact-only**, and **expanded-only**.
  Hidden subviews don't deactivate their own constraints, so the
  compact and expanded sets must toggle atomically; keeping the icon's
  vertical and intrinsic sizing always active prevents the icon from
  becoming under-constrained when sets swap.

  ```swift
  private var compactConstraints: [NSLayoutConstraint] = []
  private var expandedConstraints: [NSLayoutConstraint] = []

  // Always active — icon's vertical centering and intrinsic dimensions.
  // (The existing remoteIcon.centerYAnchor constraint at
  // PaneWrapperView.swift:106 stays. Replace the existing
  // `remoteAccessory.widthAnchor.constraint(equalToConstant: 22)` at
  // line 109 with the per-set width below.)
  NSLayoutConstraint.activate([
    remoteIcon.centerYAnchor.constraint(equalTo: remoteAccessory.centerYAnchor),
    // any existing icon width/height constraints stay here
  ])

  compactConstraints = [
    remoteIcon.centerXAnchor.constraint(equalTo: remoteAccessory.centerXAnchor),
    remoteAccessory.widthAnchor.constraint(equalToConstant: 22),
  ]
  expandedConstraints = [
    remoteIcon.leadingAnchor.constraint(equalTo: remoteAccessory.leadingAnchor, constant: 4),
    remoteSessionLabel.leadingAnchor.constraint(equalTo: remoteIcon.trailingAnchor, constant: 4),
    remoteSessionLabel.trailingAnchor.constraint(equalTo: remoteAccessory.trailingAnchor, constant: -6),
    remoteSessionLabel.centerYAnchor.constraint(equalTo: remoteAccessory.centerYAnchor),
    remoteSessionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200), // hard cap
    remoteAccessory.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
  ]
  NSLayoutConstraint.activate(compactConstraints) // start compact
  ```

- `remoteSessionLabel`: small font (e.g. `NSFont.systemFont(ofSize: 11)`),
  `textColor = .white` (matches the globe icon's tint on `systemPurple`),
  `lineBreakMode = .byTruncatingTail`,
  `usesSingleLineMode = true`,
  `setContentCompressionResistancePriority(.defaultLow, for: .horizontal)`.
  The 200pt `lessThanOrEqualToConstant` in `expandedConstraints` is the
  hard cap that, combined with `byTruncatingTail`, ensures a 100-char
  hostname truncates inside the badge rather than starving the pane
  title.

- Extend `updateToolbar` (line 216) to take
  `remoteSession: RemoteSession? = nil`. Body sets bindings and toggles
  the constraint sets:
  ```swift
  remoteAccessory.isHidden = !isRemote
  remoteSessionLabel.stringValue = remoteSession?.displayString ?? ""
  remoteSessionLabel.isHidden = remoteSession == nil
  if remoteSession == nil {
    NSLayoutConstraint.deactivate(expandedConstraints)
    NSLayoutConstraint.activate(compactConstraints)
  } else {
    NSLayoutConstraint.deactivate(compactConstraints)
    NSLayoutConstraint.activate(expandedConstraints)
  }
  ```
  When `remoteSession == nil` (e.g. immediately after `REMOTE_START`,
  on a remote without the snippet, or before the first remote prompt)
  the accessory returns cleanly to the compact 22pt icon-only purple
  square, same as today.

### Tests

**`tests/ExportTests.swift`** — add cases for the new event:
- `parseDantermEvent: valid REMOTE_HOST` → returns
  `.remoteSession(value: RemoteSession(user: "dan", host: "caja"))`
  (assert structured equality, not string equality on a combined form)
- `parseDantermEvent: REMOTE_HOST with missing user field` (e.g.
  `REMOTE_HOST::<base64(host)>`) → nil
- `parseDantermEvent: REMOTE_HOST with missing host field` (e.g.
  `REMOTE_HOST:<base64(user)>:`) → nil
- `parseDantermEvent: REMOTE_HOST with no separator` (e.g.
  `REMOTE_HOST:<base64(user)>`) → nil
- `parseDantermEvent: REMOTE_HOST with invalid base64 in user` → nil
- `parseDantermEvent: REMOTE_HOST with invalid base64 in host` → nil
- `parseDantermEvent: REMOTE_HOST with empty decoded user`
  (`<base64(empty)>:<base64(host)>` where decoded user is `""`) → nil
- `parseDantermEvent: REMOTE_HOST with empty decoded host` → nil
- `translateMsg` for a `surfaceTitle` carrying valid `REMOTE_HOST`
  produces `.remoteSessionReported(paneId:session:)` with the expected
  `RemoteSession`

**`tests/UpdateRemoteTests.swift`** — add cases (all assertions use
`RemoteSession` equality, e.g.
`expectEqual(model.panes[paneId]?.remoteSession, RemoteSession(user: "dan", host: "caja"))`):
- `remoteSessionReported sets remoteSession and isRemote on first call`
- `remoteSessionReported applies remoteThemeOverride only on first transition`
- `remoteSessionReported with same session is no-op (no effects)`
- `remoteSessionReported with different session (changed host or user)
  updates remoteSession (no theme reapply)`
- `commandEnded clears remoteSession too`
- `remoteSessionReported on missing pane returns empty effects`
- `remoteSessionStarted clears stale remoteSession` — covers the
  nested-SSH scenario where the next hop lacks the snippet; without
  this clear, the pane would keep the previous host's label while on a
  different machine.

#### Shell-script regression test

Swift tests don't cover the script's behavior — a fish or zsh edit could
break `REMOTE_START`, `LC_DANTERM_TOKEN` forwarding, or env unset, and
`just test` would still pass. Add a shell smoke test in
`~/world/scripts/tests/danterm-integration_test.sh` (POSIX sh runner that
invokes both `zsh` and `fish` against their respective snippets).

**Mechanics — the parts that have to be right:**

- *ssh stubbing*: don't try to override `command` (fish reserves it as
  a builtin and can't be shadowed by a user function). Instead, create
  a temp directory, drop an `ssh` shell script in it that captures its
  argv and env to a dedicated capture file (so it stays separate from
  the snippet's OSC bytes on stdout), and **prepend that dir to `$PATH`**.
  Then `command ssh` in the snippet resolves to the shim. Works
  identically in zsh and fish.
  ```sh
  shim_dir="$(mktemp -d)"
  export SHIM_CAPTURE="$shim_dir/capture.txt"
  : > "$SHIM_CAPTURE"
  cat > "$shim_dir/ssh" <<'SHIM'
  #!/bin/sh
  {
    printf 'argv:'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'
    printf 'LC_DANTERM_TOKEN=%s\n' "${LC_DANTERM_TOKEN-<unset>}"
  } >> "$SHIM_CAPTURE"
  SHIM
  chmod +x "$shim_dir/ssh"
  PATH="$shim_dir:$PATH"
  ```
  Two distinct capture targets, both consulted in the assertions:
  - `$SHIM_CAPTURE` (file): `argv:` line and `LC_DANTERM_TOKEN=...` line
    from each shim invocation. Used to verify token forwarding and
    `SendEnv` argv.
  - **stdout** of the test subshell (redirect to a separate file at
    test-driver level): OSC sequences emitted by the snippet's
    `printf '\e]0;...\a'` calls. Used to verify `REMOTE_START`,
    `REMOTE_HOST`, and `CMD_END`.
- *Hook firing*: `precmd_functions` and `fish_prompt` events do not
  auto-fire in non-interactive shells. Fire them explicitly:
  - zsh: `for f in "${precmd_functions[@]}"; do "$f"; done`
  - fish: `emit fish_prompt` (triggers all `--on-event fish_prompt`
    handlers), or call the function directly: `_danterm_remote_host`
- *OSC capture*: the snippet writes OSC sequences to stdout via
  `printf`. Run the test body inside a subshell with stdout redirected
  to a capture file; grep that file for the expected `__DANTERM_EVT__:...`
  payloads.

**Scenarios — five for both shells:**

1. **Sender — token forwarding**:
   - Set `DANTERM_TOKEN=tok-A`, source the snippet.
   - Call `ssh somehost` (resolves to shim via PATH).
   - Assert capture file contains `LC_DANTERM_TOKEN=tok-A` and the
     `argv:` line includes `-o SendEnv LC_DANTERM_TOKEN`.
   - Assert stdout (separate capture) contains `__DANTERM_EVT__:tok-A:REMOTE_START`.

2. **Receiver — REMOTE_HOST emission on prompt**:
   - Set `LC_DANTERM_TOKEN=tok-B` (no `DANTERM_TOKEN`), source the snippet.
   - Fire prompt hooks:
     - zsh: `for f in "${precmd_functions[@]}"; do "$f"; done`
     - fish: `emit fish_prompt`
   - Assert stdout contains
     `__DANTERM_EVT__:tok-B:REMOTE_HOST:<base64(whoami)>:<base64(hostname)>`,
     where the two segments decode independently to `$(whoami)` and
     `$(hostname)` respectively.
   - Assert env after sourcing: `LC_DANTERM_TOKEN` unset.

3. **Receiver — long hostname produces no embedded newlines**:
   - Add a `hostname` shim to the same `$PATH` directory that returns a
     string long enough to force `base64` line-wrapping (e.g. 90+ chars,
     such as
     `very-long-hostname-that-wraps-base64.example.tail-scale.corp-network.example`).
     Same for `whoami` if you want to also stress that field.
   - Fire prompt hooks as in #2.
   - Capture the OSC payload between the `__DANTERM_EVT__:tok-B:REMOTE_HOST:`
     prefix and the `\a` (BEL) terminator.
   - Assert the payload contains exactly one `:` separator and **no
     newline characters** (`\n` or `\r`). Decode each base64 half;
     assert decoded host equals the long shim output exactly.
   - This catches the failure mode where `base64`'s default 76-char
     line wrapping would otherwise leak `\n` into the OSC and the Swift
     parser would reject the event.

4. **Receiver — nested ssh forwards token**:
   - Continuation of #2 (receiver shell, `_danterm_tok=tok-B`).
   - Call `ssh next-host`.
   - Assert capture: `LC_DANTERM_TOKEN=tok-B` and `-o SendEnv LC_DANTERM_TOKEN`
     in argv. Assert stdout: `REMOTE_START`.

5. **Mutual exclusion — local + receiver**:
   - Set both `DANTERM_TOKEN=tok-A` and `LC_DANTERM_TOKEN=tok-B`. Source.
   - Fire prompt hooks. Assert stdout contains `CMD_END` (local-DanTerm
     precmd ran) but does **not** contain `REMOTE_HOST`. Confirms the
     receiver `elif` / `else if` branch was skipped because the local
     `if` matched first.

**How it runs.** The test is a self-contained POSIX shell script
runnable directly:

```sh
bash ~/world/scripts/tests/danterm-integration_test.sh
```

Failures produce diffable output (the captured OSC bytes vs. expected)
rather than just a non-zero exit. Document the invocation in the
DanTerm README and in the world AGENTS.md "Commands" section so a
future change to either snippet has a documented regression check
nearby.

`world:check` runs `nix flake check ~/world` per `world/AGENTS.md`,
which is unrelated to shell-runtime smoke testing. Wrapping this script
as a flake `checks.<system>` derivation would require running zsh/fish
inside a sandboxed nix build, which adds complexity without proportional
benefit for a personal-config repo. Keep it as a manual target; if it
ever proves useful in CI later, that's a v2 wiring change, not a v1
blocker.

Layout:
```
~/world/scripts/tests/
├── danterm-integration_test.sh        # POSIX harness, dispatches to zsh/fish
├── danterm-integration_test.zsh       # zsh test body
└── danterm-integration_test.fish      # fish test body
```

### README

Update the README's zsh and fish snippets (around line 174-235) to match
the new contents of `scripts/danterm-integration.{zsh,fish}`. Add a short
explainer about the `LC_DANTERM_TOKEN` mechanism so users SSHing to hosts
they don't manage know what to install on the remote.

## Critical files

| File | Lines | Change |
|---|---|---|
| `scripts/danterm-integration.zsh` (~/world) | 28-35 (modify ssh()); replace closing `fi` (line 36) with `elif [[ -n "$LC_DANTERM_TOKEN" ]]; then ...; fi` | sender forwards token via `LC_DANTERM_TOKEN`; receiver branch on `LC_DANTERM_TOKEN` |
| `scripts/danterm-integration.fish` (~/world) | 25-32 (modify ssh()); replace closing `end` (line 33) with `else if set -q LC_DANTERM_TOKEN ... end` | mirror of zsh |
| `hosts/caja/modules/shells.nix` (~/world) | let block, fish.interactiveShellInit | wire integration into caja's fish |
| `hosts/caja/configuration.nix` (~/world) | services.openssh.settings (line ~120-129) | add `AcceptEnv = [ "LANG" "LC_*" ];` |
| `app/Model.swift` | ~72 | add `RemoteSession` struct + `remoteSession: RemoteSession?` field |
| `app/Msg.swift` | ~58 | add `remoteSessionReported(paneId:session:)` case |
| `app/ModelOperations.swift` | 743-814 | new `DantermEvent.remoteSession`; parser arm (split + decode two base64 fields); translateMsg arm |
| `app/Update.swift` | 506, 514 | `remoteSessionReported` handler; clear in commandEnded; clear stale in remoteSessionStarted |
| `app/AppRuntime.swift` | 134-138, 1024, 1037 | refresh trigger on `.remoteSessionReported`; pass remoteSession to updateToolbar |
| `app/PaneWrapperView.swift` | 19, 95-109, 216 | add `remoteSessionLabel` *inside* `remoteAccessory` (next to `remoteIcon`); replace fixed 22pt width with compact/expanded `NSLayoutConstraint` sets toggled in `updateToolbar`; show `session.displayString` |
| `tests/ExportTests.swift` | end | parser tests |
| `tests/UpdateRemoteTests.swift` | end | update handler tests |
| `README.md` | ~174-235 | sync snippets, document LC_* |
| `~/world/scripts/tests/danterm-integration_test.sh` (+ `.zsh`, `.fish`) | new | shell smoke test for sender/receiver/nested/mutual-exclusion scenarios |

## Reuse / patterns to follow

- `parseDantermEvent` (`ModelOperations.swift:792`) — base64 decode pattern
  for `CMD_START` is what `REMOTE_HOST` mirrors.
- `PaneTokenStore` (`ModelOperations.swift:750`) — token store; no change
  needed, the existing UUID is what we forward.
- `translateMsg` (`ModelOperations.swift:771`) — token validation already
  rejects spoofed events; the new event piggybacks on this.
- `applyPaneTheme` effect — already idempotent for remote-theme override.
- Toolbar refresh switch (`AppRuntime.swift:133-138`) — add the new Msg to
  this list; no new Effect type needed.

## Verification

1. **Swift unit tests** — `just test` should pass. New tests cover
   parser and update handler.

2. **Shell-script smoke test** — run
   `~/world/scripts/tests/danterm-integration_test.sh`. Should pass all
   five scenarios in both zsh and fish. Failures point at exact captured
   bytes vs. expected.

3. **Build** — `just build` to verify Swift compiles.

4. **Confirm `AcceptEnv` is live on caja** before running e2e:
   ```sh
   ssh caja 'sshd -T 2>/dev/null | grep -i acceptenv'
   ```
   Expect a line containing `acceptenv lang lc_*`. If absent, the
   `AcceptEnv` directive didn't apply; the rest of the e2e will silently
   fall back to the no-host-label path.

5. **Manual end-to-end on caja** (real path):
   1. After applying the nix changes, the user runs `darwin-rebuild switch`
      on macbook (so the new `ssh()` wrapper is in shell init) and
      `nixos-rebuild switch` on caja (so caja's fish gets the receiver
      snippet **and** sshd accepts `LC_*`).
   2. Open DanTerm Dev. In a pane, run `ssh caja`.
   3. Expected: purple accessory appears immediately (REMOTE_START fast
      path), then within ~1 prompt the toolbar shows `dan@caja`
      (REMOTE_HOST event).
   4. **Nested-ssh test**: from caja's shell, run `ssh silverstone` (or
      any reachable host with the snippet installed). Toolbar should
      change to `dan@silverstone` within one prompt. Confirms the
      receiver-side `ssh()` wrapper re-forwards the token. `exit`
      returns to `dan@caja`.
   5. **Cleanup**: type `exit` to leave the original SSH. Accessory and
      label disappear; `isRemote` cleared.
   6. **Sudo non-regression**: run `sudo -i`. Accept that the toolbar
      may stay at `dan@caja` until exit (v2 work). The pane should
      remain functional; no crashes or errors. After `exit`, return to
      caja's normal prompt and verify label stays correct.

6. **Manual end-to-end on an unmanaged remote**:
   1. SSH to a host without the snippet: accessory appears
      (REMOTE_START), label stays empty. Confirms graceful degradation
      when the receiver isn't installed.
   2. Confirm degradation case for sshd-without-AcceptEnv: SSH to a host
      whose sshd doesn't accept `LC_*`. The remote shell sees no
      `LC_DANTERM_TOKEN`, the receiver branch's `if` is false, no
      precmd registered. Same graceful degradation.
   3. **Nested-SSH-stale-clear** — critical: `ssh caja` (label →
      `dan@caja`), then from caja's shell `ssh some-unmanaged-host`.
      Toolbar should immediately drop the `dan@caja` label (REMOTE_START
      cleared it) and stay blank for the duration of the unmanaged-host
      session. Confirms `.remoteSessionStarted` clears stale
      `remoteSession`. After exiting back to caja, the next caja prompt
      re-emits and the label restores to `dan@caja`.

7. **Verify token validation** — manually emit a fake event from a
   non-DanTerm shell:
   ```sh
   ub=$(printf 'fake' | base64 | tr -d '\n')
   hb=$(printf 'evil' | base64 | tr -d '\n')
   printf '\e]0;__DANTERM_EVT__:wrong-token:REMOTE_HOST:%s:%s\a' "$ub" "$hb"
   ```
   `translateMsg` should drop it (`tokenForPane` mismatch). Pane should
   not gain a `remoteSession`. Existing test `Token validation: wrong
   token drops event` covers this pattern; add an analogous case for
   REMOTE_HOST.

8. **Confirm no leakage of `LC_DANTERM_TOKEN` into subprocess env** —
   on the remote shell, after the snippet runs:
   ```sh
   echo "$LC_DANTERM_TOKEN"   # should be empty
   env | grep DANTERM         # should show nothing
   ```
   Confirms the snippet `unset`s the env var after copying to a shell
   variable.

## Out of scope (explicit non-goals for v1)

- **Sudo / su user transitions.** `sudo -i` and `su - user` start fresh
  login shells with stripped env, and the v1 receiver is purely
  env-var-driven. Toolbar will keep showing the parent user (e.g.,
  `dan@caja`) until exit. v2 work to fix this requires (a) bash-snippet
  parity, (b) system-wide installation in NixOS module (so root's
  default bash login shell sources it), and (c) a TOCTOU-safe per-TTY
  cross-uid token transport. None of those are necessary for the
  primary "show me which host I'm on" use case.
- **mosh user@host detection.** Existing `mosh()` wrapper still emits
  `REMOTE_START` for the purple accessory, but no host label. Mosh's
  env propagation requires `--ssh="ssh -o SendEnv=LC_DANTERM_TOKEN"`;
  v2.
- **`~/.ssh/config` alias resolution via `ssh -G`.** Not needed once the
  remote snippet is installed; it's the receiver of truth. Could be a
  v2 fallback for hosts where the user can't install the snippet.
- **Persisting `remoteSession` across DanTerm restart.** Field is
  ephemeral by design (matches `isRemote`).
- **`danterm install-remote <host>` CLI** to scp the snippet. Manual
  install for now; document in README.
