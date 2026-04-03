---
name: Plans must be evidence-based, not speculative
description: Don't propose fixes based on theoretical memory issues without measurement. Verification must prove the fix addresses the actual problem, not just that it compiles.
type: feedback
---

Don't propose fixes based on speculative diagnosis. If claiming something leaks or accumulates memory, prove it with measurement first, then fix. "just build && just test" is insufficient verification for a memory fix — it only proves compilation, not that memory behavior changed.

**Why:** User rejected an autoreleasepool plan because it was speculative — the enriched checkpoint runs on the main queue and returns, so the main run loop autorelease pool likely already handles it. The plan would have shipped a no-op.

**How to apply:** For performance/memory fixes, include concrete measurement steps (Instruments, heap snapshots, logging) in the plan. Only propose the fix if measurement shows the problem exists. Also don't leave duplicated code untouched — factor shared logic into helpers so fixes apply uniformly.
