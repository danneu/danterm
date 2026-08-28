# Validate the `--init` file once

Source: audit finding PERSIST-5 in `docs/scratch/2026-08-26-improvement-audit.md`
(Wave 10). Tick its `## Plan of work` box when this lands.

## Problem

`app/main.swift` runs `loadValidatedInitFile` over the `--init` file, keeps only
the decoded `AppModelSnapshot`, and throws the built model away. After launch,
`AppRuntime.bootstrapFromSnapshot` validates and builds the same snapshot a
second time, behind a "validation failed" fallback that cannot fire. The
recovery path (`main.swift` + `LaunchRecovery.swift`) and Import State already
hand the runtime a `ValidatedAppRestore`; `--init` is the one entry that does
not, against the rule `main.swift` states for itself ("validated exactly once,
at launch, and not again at bootstrap").

The builder mints ids for id-less entries, so the two builds of a hand-authored
file are different values and the first mint is discarded.

`ValidatedAppRestore.snapshot` has two readers: the `--init` handoff above and a
pass-through in `mergeCheckpoints`. Every consumer of a restore uses `model` and
`paneSnapshots`.

## Decision

Route `--init` through the validated restore path, like recovery and import:
`main.swift` keeps the whole `ValidatedAppRestore`, `AppDelegate` passes it to
`bootstrapFromValidatedRestore`, and `bootstrapFromSnapshot` is deleted. Delete
`ValidatedAppRestore.snapshot`; a validated restore then cannot be converted
back into an unvalidated one, so nothing can validate it twice.

Launch order is unchanged: an `--init` restore commits before the IPC server
starts.

## Invariants

- I1: An `--init` file is decoded, validated, and built exactly once per launch.
- I2: The pane ids the runtime installs from an `--init` file are the ids the
  launch-time validation produced.
- I3: A `ValidatedAppRestore` carries only the built model and its pane
  snapshots, so no consumer can recover the raw snapshot and validate it again.

## Proof obligations

- PO1 (I1, I2): new `SnapshotTests` case -- a restore built from an id-less
  snapshot has `paneSnapshots` keyed by exactly the set of pane ids present in
  its `model`. The existing deterministic-mint test stays as support for the
  generated id values. Existing assertions on `.snapshot` move to `.model`.
- PO2 (I3): compile-time -- `ValidatedAppRestore` has no `snapshot` member;
  every constructor and consumer in `app/` and `lib/DanTermCore` builds and
  reads it without one.
- Gate: `swift test --package-path lib/DanTermCore`, `just lint`, `just test`.
  Manual: `just launch-slot` with an `--init` file naming two tabs opens two
  tabs.

## Non-goals

- Reshaping `AppModel` (UPDATE-4). This change reduces UPDATE-4's surface by
  one construction site and one field; it does not start it.
- Changing the `--init` CLI surface or the slot launcher.

## Implementation discretion

- Name and type of the `AppDelegate` launch field that replaces `initSnapshot`.

## Commit progress

- [x] 1. refactor(persistence): carry the validated init restore into bootstrap
