# Application-exit job corruption (SIGSEGV on Cmd-Q)

Research started: 2026-07-30. **Status: CLOSED INCONCLUSIVE -- the victim, the
fault class, the corrupted value's provenance, the reproduction, and the arena
are all settled (`F1`-`F5`, `F8`-`F10`, `F12`, `F13`); the write that installed
the bad resume pointer is not (`D1`). Static analysis was exhausted (`F6`, `F7`)
and the one budgeted live-debugger attempt closed inconclusive because its
instrumentation silently never fired (`F11`). Phase F then removed the entire
Swift Concurrency exit arena in `6d97878` and `50c5240`; the user verified the
optimized build quits cleanly. Reopen only if the crash returns.**
Deliverable: `PO1` of the exit-crash plan -- name the root cause, or record the
diagnosis as inconclusive so the D/F gate can be re-decided. This file exists
because the arena is about to be demolished: the fix takes Swift Concurrency out
of the termination path entirely, which removes the reproduction along with the
bug. The evidence had to be captured while the crash still exists.
Continues: no ancestor. Adjacent to doc 19 (owner-queue occupancy), whose `19/F4`
census cost is why the exit path's 2-second deadline is reachable at all.

## Purpose

Quitting DanTerm Dev (Cmd-Q) segfaults after the window is gone, reproduced 2/2
on 2026-07-30 and 4/4 again live under a debugger. The question this file
answers is narrow: **what is the faulting job, and where does the address it
jumps to come from?** It does not own the fix -- the exit path is independently
defective and is being replaced regardless.

Scope boundary: this is a diagnosis record. No design, no remediation, no
performance work belongs here.

## Provenance

Two crash reports, both `EXC_BAD_ACCESS (SIGSEGV)`:

| run | report | image base | `pc` / `far` |
| --- | --- | --- | --- |
| 1 | `DanTerm Dev-2026-07-30-134057.ips` | `0x102c70000` | `0xf2e3aa94` |
| 2 | `DanTerm Dev-2026-07-30-134432.ips` | `0x1020dc000` | `0xf22a6a94` |

Both name image UUID `77738389-04bc-3fe6-806b-18d9323e7324`, DanTerm Dev
`0.0.84`. The binary installed at `~/Applications/DanTerm Dev.app` is a UUID
match, so every symbolication below is against **the exact binary that
crashed**, not a rebuild. Code-wise that binary is `02f3ba1`; the four commits
since are documentation only.

Symbolication method, reproducible from the reports alone:

```
atos -o "~/Applications/DanTerm Dev.app/Contents/MacOS/DanTerm Dev" \
     -arch arm64 -l 0x100000000 0x1000C8B20
```

`-l 0x100000000` is the link-time base for a `MH_EXECUTE`; feed it
`0x100000000 + (register - image_base)` to turn any crash-time address into a
symbol.

## Findings

**F1. The victim is the exit task-group child, confirmed by symbol.** `x8` is
`image_base + 0xC8B20` in both runs. That offset resolves to

```
closure #1 in closure #1 in closure #1 in
SwiftTerminalBackend.terminateForApplicationExit()  (SwiftTerminalBackend.swift:109)
```

with **symbol offset zero** -- it is the function's entry point, not an interior
address. Line 109 is
`group.addTask { await handle.terminateForApplicationExit() }`. The bytes at
that address are an ordinary arm64 prologue (`sub sp, sp, #0x20`;
`stp x29, x30, [sp, #0x10]`), so `x8` holds a correct, intact code pointer. The
plan's identification of the job was right.

**F2. It is an instruction-fetch fault, not a data access.** `esr = 0x82000006`
(instruction abort, translation fault), and `far == pc` in both runs. Frame 0
belongs to no image; `vmregioninfo` reports the address "is not in any region",
266,556,780 bytes below `__TEXT`. That places it inside `__PAGEZERO`, which is
why the fault is instant and total rather than a corrupted read.

**F3. The job's resume pointer was already garbage before any of our code ran.**
The full stack is `start_wqthread` -> `_pthread_wqthread` ->
`_dispatch_worker_thread2` -> `_dispatch_root_queue_drain` -> `swift_job_runImpl`
-> `swift::runJobInEstablishedExecutorContext` -> **fault**. Not one instruction
of DanTerm executed. The thread's queue is
`com.apple.root.default-qos.cooperative`, i.e. the Swift concurrency pool; what
the main thread is doing at the same moment is `F13`.

**F4. The bad target is image-derived, not heap noise.** `pc - slide` is the
**identical constant `0xF01CAA94`** across two runs whose slides differ
(`0x2c70000` vs `0x20dc000`). Heap garbage cannot survive ASLR that way. Three
equivalent statements of the same value:

- `pc = image_base + (int32)0xF01CAA94` -- the image base plus a **negative
  32-bit displacement** (`-266,556,780`).
- `pc = image_base - 0x0FE3556C`.
- `pc = x8 - 0x0FEFE08C` -- a fixed offset from the victim closure's own entry.

The system is underdetermined by two samples: any of those bases fits. What is
*not* underdetermined is the shape -- a 64-bit code address was replaced by
`some_image_address + a_negative_32-bit_quantity`. That is the signature of a
relative or compact function pointer resolved against the wrong base, which is
the hypothesis the plan formed from the raw offsets and which this file
confirms.

**F5. `x0 == pc`.** The branch target also sat in the first argument register at
fault time, which is consistent with an indirect call through a value the
runtime had just loaded and passed along, rather than a return into a smashed
stack (`sp`/`fp` are intact and the frame chain unwinds cleanly for six frames).

**F6. The constant is not stored in the binary.** Scanning the whole executable
for the little-endian encodings of `0xF01CAA94`, `0xF0101F74` (the `x8`-relative
form) and `0x0FE3556C` returns **zero occurrences**. So it is not a mis-emitted
rebase target and not a corrupted constant pool entry: the value is **computed
at runtime**.

**F7. The static route to the corrupting instruction is closed on this machine.**
Identifying which field `runJobInEstablishedExecutorContext` loaded requires
disassembling `libswift_Concurrency.dylib` at image offset `0x2e18` (symbol
offset 472). That dylib exists only inside the dyld shared cache here --
`/usr/lib/swift/libswift_Concurrency.dylib` and the Cryptexes path are both
absent, and neither `dyld_shared_cache_util` nor `dyld-shared-cache-extractor` is
installed. Under lldb the cache maps but `image lookup -a` resolves nothing in
that range, so the addresses cannot be tied back to symbols with confidence.
Rejected as a route; a live process is required.

**Where the static phase left it.** `F1`-`F7` name the job and the shape of the
corruption, but not the write. Under `PO1` that is the inconclusive branch, so
the D/F gate was re-decided by the user on 2026-07-30: **one focused
live-debugger attempt before Phase F**, on the reasoning that Phase F demolishes
the reproduction and this is the cheapest moment the cause can still be found.

## Live debugger attempt

### Method

The same UUID-matched 0.0.84 bundle, launched under `lldb` from a Python
`command script` (`SBDebugger`, synchronous mode) with
`eLaunchFlagStopAtEntry | eLaunchFlagDisableASLR` and
`DANTERM_TERMINAL_BACKEND=swift`, driven by a background thread that clears the
restore prompt over Accessibility and then sends Cmd-Q. Disabling ASLR is what
makes the whole exercise tractable: link-time addresses from `nm` become
runtime addresses, so breakpoints can be set on `nm` offsets directly and every
run is comparable to every other.

Three traps worth recording, because each cost a run:

- `SBTarget.Launch` in synchronous mode blocks until the process stops. Without
  `eLaunchFlagStopAtEntry` it never returns for a GUI app, so no driver thread
  ever starts and the session simply hangs.
- `SBLaunchInfo.SetLaunchFlags` **replaces** the debugger's defaults, including
  `target.disable-aslr`. Passing only `eLaunchFlagStopAtEntry` silently
  re-enables ASLR, and every raw-address breakpoint then resolves to nothing
  while still reporting itself as created.
- The restore prompt is modal at launch and swallows Cmd-Q, so it has to be
  dismissed as an explicit first step rather than as a retry.

### Findings

**F8. The crash does not need scrollback saturation or a resize.** It
reproduced on the *first* attempt on a freshly launched app with a single pane,
and 4/4 across live runs (plus the original 2/2 reports). The saturate-resize
preamble in the original reproduction was incidental. This is a plain-quit
crash, and it is close to deterministic.

**F9. With ASLR disabled the fault address is exactly `0xF01CAA94`.** That is
`F4`'s constant with a zero slide, so `F4` now rests on three independent
slides (`0x2c70000`, `0x20dc000`, `0`) plus a fourth ASLR'd debugger run at
`0xf4a0aa94`. The bad target is image-relative, full stop.

**F10. `x8 == 0x1000C8B20` in every single run**, ASLR'd or not, across
different heaps and different process lifetimes -- the child closure's
`(1) await resume partial function`. Whatever produces it is not reading heap
garbage.

**F11. The instrumentation was unsound: six breakpoints on the exit ladder, all
reporting themselves resolved, none of which ever fired.** With ASLR off, on
`0x1000C8EC0` (the protocol witness), `0x1000C83D8`
(`SwiftTerminalBackend.terminateForApplicationExit()`), `0x1000C86B0` (the
`Task.detached` closure), `0x1000C87BC` (the `withTaskGroup` closure),
`0x1000C8AC4` (the `addTask` child closure) and `0x1001CAE54`
(`TerminalPTYHost.terminateForApplicationExit()`) -- each created with
`locs=1`. The first and only stop lldb reported was the `EXC_BAD_ACCESS`.

**Do not read that as "the ladder did not run."** `F13` shows it did. Raw
`SBTarget.BreakpointCreateByAddress` in this setup reports a resolved location
and then does not trap, and the failure is silent, so this whole line of
instrumentation produced nothing. Anything built on `nm` addresses here needs a
positive control -- a breakpoint known to fire -- before its negatives mean
anything. This is why the watchpoint could never be armed.

**F12. It is quit-triggered, not spontaneous.** A control run, identical except
that the quit driver was disabled, left the app alive and healthy for ~90 s with
no fault.

**F13. The main thread's own stack proves the exit ladder ran, exactly as the
plan describes.** From the crash report's thread 0
(`com.apple.main-thread`), innermost last:

```
QuitConfirmationPanel.confirmQuit(_:)
  AppRuntime.send(_:) -> AppRuntime.perform(_:)
    -[NSApplication terminate:]  -> ... -> AppDelegate.applicationWillTerminate(_:)
      SwiftTerminalBackend.terminateForApplicationExit()   (DanTerm Dev +0xc8644)
        OS_dispatch_semaphore.wait(wallTimeout:)
          _dispatch_semaphore_wait_slow -> semaphore_timedwait_trap
```

`+0xc8644` is `+0x26c` into the function that starts at `0xC83D8`, i.e. the
`completion.wait(timeout:)` call site at `SwiftTerminalBackend.swift:114`. So at
fault time the main thread is blocked on the exit semaphore inside
`terminateForApplicationExit`, and the faulting job is on the cooperative pool.
That is the plan's premise, confirmed from evidence rather than assumed. It also
names the trigger precisely: **confirming** the quit panel, not merely pressing
Cmd-Q.

## Decisions

**D1. The corrupting write is not identified, and Phase D closes inconclusive on
`PO1`'s second branch.** The watchpoint plan depended on catching the child job
at creation, and the instrumentation needed for that never worked (`F11`). Per
the user's re-decision of the gate on 2026-07-30, one focused live attempt was
the budget, so Phase F proceeds under `AR2`.

**D2. The plan's arena is confirmed, not displaced.** `F13` puts the main thread
inside `terminateForApplicationExit`, blocked on its `DispatchSemaphore`, at the
moment the cooperative pool faults resuming a job whose resume partial function
(`F10`) belongs to the `addTask` child. Every structural claim the plan makes
about the exit path is therefore about the right code. What remains unknown is
only the write, not the arena -- so `AR2`'s risk is narrower than it was before
this attempt, though not eliminated.

## Residual uncertainty

- The write that installs `0xF01CAA94`. Unanswered.
- If the crash survives Phase F, the next probe needs working instrumentation
  first (`F11`): breakpoint by *symbol name* on `swift_task_create` and on
  `applicationWillTerminate`, verify both fire, and only then chase the resume
  slot. `nm`-address breakpoints are not usable here.
