# IPC: four small contract fixes (IPC-2, IPC-4, IPC-6, IPC-3)

Source: `docs/scratch/2026-08-26-improvement-audit.md`, Wave 11. Four
separable commits; each is small and well understood.

## Problem and evidence

1. **The hello advertises a bound the socket does not arm.** Each connection
   decides once at admission whether it lives under the liveness contract
   (`ConnectionState.livenessBound`: nil for every local caller, the server's
   bound for a tailnet peer). `beginService` arms the reader from that value but
   writes the hello from the server-wide constant, so every local connection is
   told `silenceSeconds: 30` under a contract the server never enforces on it.
   `IpcHello.params` and `writeHello` cannot express "none". SKILL.md already
   says a local `--socket` connection is exempt; the wire says otherwise. Latent
   today (`UnixSocketTransport` is `.exempt` and never reads the number).
2. **`IpcServer.runtimeDispatch` is optional only for tests.** Production always
   supplies one. Nil gives the tests a server that admits, audits, counts, and
   never answers, and gives them no way to assert what reached the runtime.
3. **The catalog can build a request the decoder refuses.** `IpcPaneInput.text`
   accepts any string, `IpcRequest.params` encodes `.text("")`, and
   `decodePaneInput` rejects it with `-32602 invalid text`, while `input: []` is
   accepted and answered `ok`. Reachable: an empty iOS pasteboard sends
   `pane.input {"text": ""}` over the tailnet and gets an error where one
   character would succeed. The pane host already treats an empty paste as
   delivered with zero bytes written.
4. **`dispatch` computes `typedRequest.auditDescriptor` twice** for a remote
   audited request, one value at two sites.

## Decision

- D1. The hello's bound is optional and is the connection's own decision; the
  wire key is omitted when there is none. The pre-handshake refusal keeps the
  server's bound unconditionally: it names the deadline by which a *remote*
  slot is reclaimed, which does not depend on who was refused.
- D2. The server's runtime dispatch is non-optional; tests supply a recording
  dispatch.
- D3. The decoder accepts empty pane-input text. Dispatch keeps its single
  `.text` path (one paste submission), which the host completes as delivered.
  No second "empty means skip" rule is added.
- D4. One descriptor per request, computed once.

Coordination with IPC-1 (sibling): IPC-1 changes the shape `serve` receives.
The recording dispatch records whatever `serve`'s signature is when it lands;
whichever of IPC-1 / D2 lands second updates the fixture. D3 and D1 share no
files with IPC-1; D4 is in the same function but a different arm.

## Invariants

- I1. A connection's advertised silence bound equals the bound the server
  arms on it: a local hello carries no `silenceSeconds`; a tailnet hello
  carries the server's bound.
- I2. A hello without `silenceSeconds` is a valid hello for an exempt client
  (already guaranteed by `DanTermClientSession` and pinned at
  `ClientSessionTests`).
- I3. `.paneInput(input: .text(""))` survives its own wire format:
  `decode(params(r)) == r`, and `pane.input {"text": ""}` is answered `ok`.
- I4. A server is constructed only with a runtime dispatch.

## Proof obligations

- PO1 (I1): server-level test: local Unix hello reads nil bound; tailnet hello
  reads the server's bound (the existing remote test pins the second half).
  Protocol-level: `IpcHello.params` with no bound has no `silenceSeconds` key.
- PO2 (I3): `.text("")` joins the catalog round-trip fixtures; a core test
  shows the request decodes and replies `ok` once the submission completes.
- PO3 (I4 / D2): the remote suite stays green with recording dispatches, and
  at least one test asserts the decoded request reached the runtime.
- PO4 (D4): the existing audit-agreement tests stay green; no new test.

## Non-goals / Accepted risks

- Non-goal: changing the refusal frame, `pingInterval`, or the protocol
  version. Omitting a key an exempt client never reads is not a shape change.
- Non-goal: making `params` lazy (audit IPC-3 part 2); the vetting showed no
  measurable cost.
- AR1: any peer that required `silenceSeconds` on a local hello would break.
  None exists; both ends ship from this repo.
- Docs: SKILL.md's TCP liveness paragraph already matches I1; re-read it after
  D1 and edit only if it disagrees.

## Closing task

After D1-D4 have landed, tick the four `- [ ]` boxes for IPC-2, IPC-4, IPC-6,
and IPC-3 in `## Plan of work` of
`docs/scratch/2026-08-26-improvement-audit.md`, appending `-- done <sha>` to
each, and commit that file alone (`docs(audit): mark IPC-2/3/4/6 complete`).
That checklist is the only part of the audit file to edit.

## Implementation discretion

- Whether `makeServer` gets a default recording dispatch or each site passes
  one.

## Commit progress

- [x] 1. refactor(ipc): require a runtime dispatch on the server (D2)
- [x] 2. fix(ipc): advertise in hello the bound the connection is under (D1)
- [x] 3. fix(ipc): accept empty pane-input text (D3)
- [x] 4. refactor(ipc): build the audit descriptor once per request (D4)
- [ ] 5. docs(audit): mark IPC-2/3/4/6 complete
