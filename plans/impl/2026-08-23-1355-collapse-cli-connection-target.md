# Collapse the CLI connection target mirror

## Problem

The CLI represents the same Unix-socket or TCP endpoint with
`CLIConnectionTarget` before ambient resolution and `CLIResolvedTarget` after
it. The two types have identical cases and payloads, and a complete converter
copies one into the other. A new transport or payload change can make these
mirrors drift even though the distinction between unresolved and resolved state
is already carried by optionality.

## Decision

Use `CLIConnectionTarget` as the one connection-target type across parsing,
ambient selection, request dispatch, and session opening. A parsed invocation
may omit its target. Target selection produces a non-optional value before any
connection attempt.

Keep ambient target resolution in the CLI. It depends on process environment,
the identity-derived fallback, method policy, and CLI-specific errors; none of
those concerns belongs in the protocol parser.

## Invariants

- **I1.** The transport vocabulary has one authority. Unix-socket and TCP cases
  cannot drift between parsed and selected targets.
- **I2.** An invocation may have no explicit target, but request dispatch and
  session opening always receive a selected target.
- **I3.** Existing selection precedence and errors do not change: an explicit
  target wins, a usable `DANTERM_SOCK` wins over the fallback, an in-pane caller
  without a usable socket fails closed, and an ordinary caller uses the
  identity-derived fallback.
- **I4.** Instance-ending methods continue to require an explicit Unix-socket or
  TCP target. They never use ambient state or the fallback.
- **I5.** Unix and TCP targets continue to construct the same transports with
  the same timeout and handshake behavior.

## Proof obligations

- **PO1 (I2-I4).** The existing socket-selection suite proves explicit Unix and
  TCP selection, ambient socket selection, fail-closed pane behavior,
  identity-derived fallback, and explicit targeting for instance-ending
  methods.
- **PO2 (I5).** The existing CLI characterization suite proves executable-level
  Unix and TCP connection behavior.
- **PO3.** `just lint` and the required pre-commit `just test` gate pass.

## Non-goals

- No CLI syntax, output, wire format, transport policy, or public API behavior
  changes.
- Do not move ambient resolution into `DanTermProtocol` or add a compatibility
  type for `CLIResolvedTarget`.
- Do not change CLI documentation or the bundled DanTerm skill; their external
  surface is unchanged.

## Implementation discretion

- The exact order of the mechanical type substitutions and deletion is left to
  implementation.
