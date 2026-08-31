# Make the phone shell's effect interpreters total (MOBKIT-6)

## Context

Two effect interpreters in `MobileSessionController` can decline to do their
job and tell nobody. `beginStream` returns silently when `pendingSession` is
nil, and `send` optional-chains through a nil `runner`, so its catch never
runs for the nil case. By the time either effect is performed the model is
already `.serving`, and only a stream response or a `connectionEnded` can move
it off -- there is no request timeout -- so a silent decline leaves the phone
showing "Connected" forever with no stream.

Both branches are unreachable under the current event order (traced in
MOBKIT-6, `docs/scratch/2026-08-26-improvement-audit.md`). The defect is the
silent drop itself: the shell may only diverge from the model's belief for a
reason the model was told about.

## Decision

Make both interpreters total. Every branch of a shell effect interpreter
either performs the effect or dispatches a `.connectionEnded` cause. The cause
for a missing session or runner is `.deviceSetup` -- the documented "the phone
could not make sense of its own setup" failure, already used by the model for
a rejected stream and an unreadable event, and already mapped to the
"Device setup failure" status and manual reconnect.

Files:

- `ios/DanTermMobileApp/Sources/DanTermMobileApp/MobileSessionController.swift`
  -- `beginStream` and `send`.
- `ios/DanTermMobileKit/Tests/DanTermMobileKitTests/MobileSessionModelTests.swift`
  -- the new model test (the app target has no test target; the model is where
  the behavior is testable).

## Invariants

- I1: The request-bearing interpreters (`beginStream`, `send`) never return
  without either performing their effect or dispatching a `.connectionEnded`
  cause.
- I2: `.connectionEnded(.deviceSetup)` while `.serving` ends the connection
  and words the status as a device-setup failure.

## Proof obligations

- PO1 (I2): a `MobileSessionModelTests` test drives a session to `.serving`,
  handles `.connectionEnded(.deviceSetup)`, and asserts the connection ends
  with the device-setup status. This locks the existing-behavior premise the
  shell change relies on; it passes before the shell edit, so it is written
  and run first to confirm the premise, not as a red phase.
- PO2 (I1): verified by inspection -- the branches are unreachable today, so
  no behavioral test can drive them. A smoke run (`just ios-app simulator
  --slot <n>` against `just launch-slot --tailnet`) confirms attach and
  stream still work.

## Non-goals

- No request timeout in the model. The finding notes its absence; totality of
  the interpreters is the fix here, and a timeout is a separate decision.
- No change to `runner`/`pendingSession` ownership. The optionals are genuine
  shell facts; only their silent branches go.

## Verification

- `swift test --package-path ios/DanTermMobileKit --filter MobileSessionModelTests`
- `just lint`
- Smoke run per PO2.

## Commit progress

- [x] 1. fix(ios): report unavailable session effects
- [x] 2. docs(audit): mark MOBKIT-6 complete
