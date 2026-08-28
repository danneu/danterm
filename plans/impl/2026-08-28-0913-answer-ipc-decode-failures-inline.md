# Answer an IPC decode failure on the server (IPC-1)

Source: `docs/scratch/2026-08-26-improvement-audit.md`, finding IPC-1 (Wave 11).

## Problem

When `IpcRequest.decode` rejects a JSON-RPC line, `IpcServer.dispatch`
(`app/IpcServer.swift`) already holds the rpc id and an
`IpcRequestDecodeError` that owns its own `code` and `message`. Instead of
writing that answer, it registers the request as pending, hops to the main
actor, and sends `Msg.ipcRequestDecodeFailed` into the pure core, whose only
job (`Update.swift`, no `model` reference) is to echo `.ipcError` with the
same code and message. The sibling protocol error -- a line that is not a
JSON-RPC envelope -- is already answered inline by the server with `-32700`.
So one class of protocol error has two reporting paths, and the common one
cannot be answered while the main actor is busy.

Desired outcome: a decode failure is answered where it is detected, and the
runtime and core have no shape that represents "a request that failed to
decode".

## Decision

Answer the decode failure inline in the server's catch arm with the existing
`writeErrorResponse(id:code:message:)` on the connection (the same writer the
malformed-line path uses), and delete the failed-decode shape end to end: the
server-to-runtime message enum, the `Msg` case, and its `Update` arm. The
runtime dispatch seam then carries only a caller identity and a decoded
request.

Decisive constraints:

- D1. The connection's close-time `servedRequests` audit field counts only
  requests handed to the runtime. A decode failure is not served, matching
  the malformed-line path today. This is a deliberate change of the count
  and is stated in the commit message.
- D2. Reply ordering on a connection is unchanged: the inline answer occupies
  the slot the main-actor reply occupied, because the reader is blocked on
  each line until it is handled and the runtime's reply today is written
  synchronously inside its own main-actor frame.

## Invariants

- I1. A JSON-RPC request with an id whose method or params fail to decode
  receives an error response with the decode error's code (`-32601` for an
  unknown method, `-32602` for bad params) and message, and never reaches
  the runtime.
- I2. Responses on one connection arrive in request order across a mix of
  valid and undecodable requests.
- I3. By construction: every request the runtime or core receives over IPC
  is a decoded `IpcRequest`. No runtime or core code can branch on a decode
  failure.

## Proof obligations

- PO1 (I1, D1). `app-tests/IpcServerRemoteTests.swift`-style test: a server
  whose runtime dispatch records its calls; send an unknown method with an
  id; assert the response's `error.code == -32601` and the dispatch was never
  called; assert the connection's close record reports zero served requests.
- PO2 (I2). On one connection send a valid `ping` then an unknown method;
  assert the two responses arrive in that order.
- PO3 (I3). Compile-time: the `Msg` case and the runtime message enum no
  longer exist. The `DanTermCoreTests` helper in `UpdateIpcTests.swift` that
  routes bad-params tests through the deleted `Msg` case must build the
  `.ipcError` command itself; existing bad-params assertions stay green.

## Non-goals

- The core's later dispatch failures keep their existing JSON-RPC
  internal-error boundary (unchanged since `c62bcb72`).
- No CLI surface change; `integrations/danterm/SKILL.md` is untouched.
- IPC-2, IPC-3, IPC-4, IPC-6 (sibling tab). IPC-3 and IPC-4 edit the same
  `dispatch` / runtime-funnel code; whichever lands second rebases onto the
  two-value dispatch seam and D1.

## Implementation discretion

- Whether the runtime dispatch closure takes two positional values or a
  small struct; only "decoded request or nothing" is contractual.

## Verification

- `swift test --package-path lib/DanTermCore --filter UpdateIpcTests`
- `just test-ui` is not needed; PO1/PO2 live in `app-tests`, run via
  `just test`.
- `just test` before commit.

## Commit progress

- [x] Answer decode failures inline; delete the failed-decode shape from the
  server-to-runtime seam, `Msg`, and `Update`; add PO1/PO2 tests and rewrite
  the `UpdateIpcTests` helper (PO3). Gate green.
- [x] Mark IPC-1 done in `docs/scratch/2026-08-26-improvement-audit.md`:
  tick its `- [ ]` line in `## Plan of work` and append `-- done <sha>` of
  the previous commit. Commit that file alone as `docs(audit): mark IPC-1
  complete`.
