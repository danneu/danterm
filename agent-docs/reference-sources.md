# Reference sources

External sources to consult when implementing against the libghostty C API
or referencing other terminals' approaches.

## Ghostty source

The Ghostty source is cloned locally at `.ghostty-src/` (by `build-lib.sh`).
When you need to reference the libghostty C API, read these files directly
instead of making web requests:

- `.ghostty-src/include/ghostty.h` -- full C API header (types, structs,
  functions).
- `.ghostty-src/macos/Sources/Ghostty/` -- Ghostty's own macOS Swift app
  (reference implementation).
- `.ghostty-src/src/apprt/embedded.zig` -- embedded runtime (implements the
  C API).

For any other external library, clone it locally first so you can read it
directly. Never use web requests to read source code when a local clone is
available.

## Local reference checkouts

The following pinned source trees are materialized under `references/`:

- [`references/libvterm/`](../references/libvterm/) -- Parser, state,
  scrollback, and resize/reflow behavior for neutral fixtures.
- [`references/alacritty/`](../references/alacritty/) -- Terminal recordings
  and replay-runner cases for neutral fixtures.
- [`references/xnu/`](../references/xnu/) -- Darwin kernel process, signal,
  tty, and Mach behavior.
- [`references/libdispatch/`](../references/libdispatch/) -- Dispatch queue,
  continuation, and work-item implementation details.
- [`references/libpthread/`](../references/libpthread/) -- Darwin pthread
  lifecycle, cancellation, and synchronization behavior.
- [`references/libplatform/`](../references/libplatform/) -- Apple platform
  primitives used below dispatch and pthread.
- [`references/Libc/`](../references/Libc/) -- Darwin C runtime, process,
  signal, and terminal interfaces.
- [`references/objc4/`](../references/objc4/) -- Objective-C runtime ownership,
  teardown, and message dispatch behavior.

These directories are gitignored and absent from a fresh clone. If a source
tree is missing, run `just fetch-references [name]` and read it locally instead
of fetching individual files over the web. Run `just fetch-references --list`
to see the available names and their pinned commits.

Do not edit these checkouts. A refetch replaces an entry wholesale, so local
changes are lost.

Cite refetchable source as `file#identifier`, using the nearest enclosing named
identifier when the point itself has no name. Do not cite it as `file:line`:
line numbers rot when a pin advances, while named identifiers usually survive.
DanTerm's own tracked files still use `file:line`, because Git preserves the
version that a citation describes.

## Other terminals

- `github:manaflow-ai/cmux` -- another macOS terminal built on libghostty
  (vertical tabs, AI agent notifications). Useful reference for feature work.

## Don't-guess rule

Don't guess at API signatures, delegate protocols, enum cases, or framework
behavior. Check local sources first; if insufficient, search online and read
official docs before writing code. AGENTS.md surfaces this rule in
`## Boundaries` so the agent sees it before diving in -- this file holds
the full context.
