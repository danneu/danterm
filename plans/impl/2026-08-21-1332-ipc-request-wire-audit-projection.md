# IPC request wire and audit projection

## Problem

`IpcRequest.params` encodes launch authority for `group.new`, `tab.new`, and
`pane.split`, but the audit descriptor names only the latter two. A successful
`group.new` request can therefore launch a command while its durable record has
no command or working directory.

The target half of this problem is already solved: wire params and audit
targets share one typed target description. Launch authority and input
accounting still come from separate request switches, so a request can carry
either fact on the wire without the audit projection seeing it.

## Decision

Build wire params and permitted audit facts from one internal request
projection. The projection owns target entries, launch authority, and redacted
input accounting together. A launch-bearing projection writes the full launch
object to the wire and admits only its command and working directory to the
audit descriptor. An input-bearing projection writes content to the wire and
admits only its byte or event count to the descriptor.

Keep method lookup separate from this projection. Asking which method a
request represents must not encode its payload. Keep decoding separate because
it validates untrusted wire input rather than projecting a trusted request.

## Invariants

- **I1 -- launch agreement.** Every request that carries a launch command or
  working directory on the wire carries the same values in its durable audit
  descriptor.
- **I2 -- content boundary.** Audit records retain no launch title, pane text,
  input event details, todo text, or other content-bearing request fields.
- **I3 -- input accounting.** Pane text input records its UTF-8 byte count and
  structured pane input records its event count.
- **I4 -- target agreement.** Every audit target names the same key and entity
  as the request's wire params, with the existing lowercase audit spelling.
- **I5 -- wire stability.** JSON-RPC methods, parameter keys, values, and decode
  behavior do not change.
- **I6 -- audit stability.** The audit schema and every other method's records
  stay unchanged. Every CLI-issued `group.new` record gains its working
  directory because the CLI always supplies one, and a command-bearing request
  also gains its command.

## Proof obligations

- **PO1 (I1).** Representative `group.new`, `tab.new`, and `pane.split`
  requests each carry a non-nil command, working directory, and title. Their
  audit descriptors agree with the encoded command and working directory.
- **PO2 (I4, I5).** Every representative catalog request still round-trips,
  keeps its exact pre-change params object, and keeps its audit target equal to
  its wire target. Coverage includes a launch-less `tab.new` and every current
  conditional omission.
- **PO3 (I2).** Across the representative catalog, no non-target wire value
  appears in an encoded audit descriptor except the admitted launch command
  and working directory. Launch titles and all other content-bearing values
  remain absent.
- **PO4 (I2, I3).** Text and structured pane input retain only their existing
  accounting values. Other requests that carry a `text` parameter do not gain
  input accounting or leak their text.
- **PO5 (I1, I2, I6).** A remote `group.new` request produces durable started
  and completed records with its command and working directory and without its
  title.

## Non-goals

- Do not change the public IPC request types, CLI syntax, wire format, decode
  errors, audit event schema, or server audit lifecycle.
- Do not redesign method traits or the typed request decoder.
- Do not add content fields to the audit descriptor.

## Rejected ideas

- **RI1 -- add `group.new` to the launch switch.** This fixes the present
  symptom but keeps the independent enumeration that caused it.
- **RI2 -- filter raw params by key name.** Parameter names are not globally
  semantic: `text` is pane input in one method and todo content in others, and
  targets require an audit-specific UUID spelling. Raw filtering cannot enforce
  the content boundary.

## Implementation discretion

- The private projection and payload type names, factory shape, and file
  placement are implementation choices. The projection must remain internal to
  `DanTermProtocol`, and the request catalog must have one exhaustive projection
  over wire params and audit facts.
