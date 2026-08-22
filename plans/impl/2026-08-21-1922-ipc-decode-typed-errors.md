# Close the IPC decode error surface

## Problem

`IpcRequest.decode` produces only `IpcRequestDecodeError`, but its untyped
throwing interface lets callers believe any error can escape. `IpcServer` and a
core test helper therefore carry duplicate fallback paths that translate an
unreachable error into JSON-RPC `-32603`. The decoder's private chain also calls
closed parsers through untyped throwing interfaces, so a new parser error does
not force its IPC translation site to change.

## Decision

Make the public decoder and every closed parser in its call chain expose its
actual error type. At every boundary that translates one of those parser
errors, catch the typed error and switch over it exhaustively; typed `catch`
clauses alone do not prove enum-case exhaustiveness. Remove the decoder's
internal-error outcome and both fallback paths. Unexpected failures in later
core dispatch remain genuine JSON-RPC internal errors.

This is a source-level API change in `DanTermProtocol`. DanTerm requires no
compatibility shim for in-repository callers.

## Invariants

- I1. An IPC wire decode either returns an `IpcRequest` or throws an
  `IpcRequestDecodeError` that describes a client-facing method or parameter
  failure.
- I2. Every translation of a closed parser error uses a compiler-exhaustive
  switch over the typed error. Adding a parser failure therefore forces every
  translation boundary, including the shared pane-tape CLI path, to handle it.
- I3. Unknown methods still return JSON-RPC `-32601`; invalid parameters still
  return `-32602` with their current messages.
- I4. Every rejected, parseable request is registered, answered, and recorded
  once as `requestDecodeFailed`.
- I5. Internal failures after successful wire decoding still return JSON-RPC
  `-32603`; this change does not narrow the core dispatch error boundary.

## Proof obligations

- PO1 (I1, I2). Compile-time API contracts accept `IpcRequest.decode`,
  `parseLaunchSpec`, `paneTapeSyncPolicy`, `decodePaneTapeSyncHistoryBytes`, and
  `KeyMods.decode` only with their declared error types. Before implementation,
  the contract file must fail to compile because Swift rejects conversion from
  an untyped throwing function to its typed function type. Each parser-error
  conversion uses a switch whose exhaustiveness the compiler checks.
- PO2 (I3). Existing protocol and CLI coverage keeps the unknown-method and
  invalid-parameter codes and messages unchanged. Before the launch-error
  translation is rewritten, add behavioral coverage that distinguishes a
  non-object launch as `"launch must be an object"` from a non-string launch
  field as `"launch.<field> must be a string"`.
- PO3 (I4). An app integration test sends a valid JSON-RPC envelope with
  invalid request parameters and observes the `-32602` response plus exactly
  one decode-failure audit record.
- PO4 (I5). Existing core IPC tests keep the post-decode internal-error response
  behavior green.
- PO5. The DanTermProtocol tests, the focused app integration test, and the full
  `just test` gate pass.

## Non-goals

- No CLI command, wire shape, audit schema, or client-facing error text changes.
- No general typed-throws conversion outside the parsers reachable from
  `IpcRequest.decode`.
- No change to core request validation or runtime error handling after decode.

## Rejected ideas

- Returning `Result` from the closed parsers: typed throws already exposes the
  same closed error type, and an exhaustive switch in the catch body provides
  the same compiler enforcement without replacing the parsers' throwing APIs.

## Implementation discretion

- The placement and spelling of private conversion helpers are implementation
  details, provided every closed parser error remains compile-time exhaustive.

## Commit progress

- [x] 1. test(ipc): pin decode failure responses and audit
- [x] 2. refactor(ipc): close the request decode error surface
- [ ] 3. docs(audit): mark IPC-5 done
