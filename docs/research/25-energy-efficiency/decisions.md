# Decisions -- auditable decision log

No entries yet. D1 is expected at the Phase 2 gate: the host-queue QoS shape
(fixed `.userInitiated` vs fixed `.utility` with sync-fence boosting), decided
on T5's paired-benchmark latency verdicts plus T2/T7's energy deltas. The
Phase 3 build/reject calls (the nonvisible delivery cadence, the targeted nap
assertion) will follow as D2+ once the ceiling probes (T6, T7) and the
opportunity counter (T11) land in findings.

Rejections made during scoping (read-side throttling, standing nap assertion,
parse-side deferral) are recorded in [README.md](README.md) `## Rejected`, not
here -- they were declined on documented mechanisms rather than decided on
gathered evidence, and each names its reopening condition.
