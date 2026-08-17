# The Test-Seam Rule: a Component Never Asks Whether It Is Under Test

- Status: Accepted
- Date: 2026-08-17

## Context

Some components own resources a test cannot conjure. `TerminalPTYHost` is the
worked example: it owns a PTY master descriptor, a forked child session, and a
set of dispatch sources, and it is the only thing in the process that may touch
them. A test that wants to see one of its edges has to get the component into a
state the test cannot build directly, so entry points appear whose only caller
is a test.

Two very different constructs then sit side by side in the same file, and the
tree says nothing to separate them:

- A field the host sets so that its next real descriptor write returns a chosen
  errno. The host branches on it before the write. Production never sets it.
- A constructor parameter that supplies the collaborator performing a blocking
  spawn. Production passes the system implementation; a test passes one that
  parks the handoff. The host does not know which it got.

`scripts/terminal-pty-host-test-seam-lint.sh` already fails the gate when about
twenty named knobs come back, so the tree does hold a verdict on the specific
names it lists. A list of banned names is not a rule, though. It cannot say
whether the *next* `package` entry point is the defect or the fix, and three
separate pieces of work need that answer at the same time:

- driving the PTY host's own tests through a real PTY channel with no child
  process,
- the wider PTY test-seam cleanup,
- the `AppRuntime` effect-ports work.

Left to a plan file each would settle it separately, and they would not agree.
A plan is also the wrong home: plans are historical, and a rule cited from three
places has to outlive the work that first needed it.

## Decision

**R1 -- The defect is asking.** A production component must not query test
identity -- an environment variable, a bundle or process-name check, a global
"under test" flag -- and must not branch on a test-only fault flag, meaning
state whose only purpose is to make the component's next real operation fail in
a chosen way. That, and only that, is the defect this rule names. A component
that never asks behaves in a test exactly as it behaves in production, because
it cannot tell the two apart.

**R2 -- Everything else a test does, it does in domain terms.** A test may
supply an ordinary domain value, or drive a transition the component's own
domain already defines. Neither is a seam in the pejorative sense. The
component runs its production code over production-shaped input; what changed is
who produced the input, not what the component does with it.

**R3 -- Three legal routes, and injection is only the usual one.** A test
reaches a component through:

- a **constructor-injected collaborator** -- the component calls it the same way
  whoever built it,
- a **direct event entry point** -- the test drives a transition the domain
  already defines, rather than waiting for the system edge that usually
  produces it,
- **observation-only capture** -- the component hands out what it already has
  and changes nothing by being watched.

A route is legal because it satisfies R1 and R2, not because it appears in this
list. A fourth route that satisfies both is legal too, and a construct from this
list that violates R1 is not saved by being on it.

**R4 -- A collaborator's production implementation need not span its type.** A
collaborator's type may permit values the production implementation never
returns. Optional child identity on an adopted PTY channel is the case that
forced this: the system spawner always forks a child, so it always reports one,
while a test-support channel reports none. The absence is data on an injected
value. The component reads that data, which is R2; it does not read who supplied
it, which is R1.

**R5 -- Debug gating is a separate question.** Whether an entry point is
compiled out of shipping builds decides what a shipping build pays for, not
whether the entry point is legal. A `package` or `#if DEBUG` declaration still
has to satisfy R1 and R2, and one that does needs no apology for existing in a
debug build.

## Consequences

- The PTY host's injected input-write errno, and the branch that reads it in the
  flush path, are illegal under R1 and go. Real write failure is produced by a
  real closed descriptor instead, which is also stronger evidence: the injected
  branch proved the host's own rejection bookkeeping and nothing about the
  descriptor.
- The host's forced exit-bound entry point, its interaction entry point, and its
  debug output-observer window stay. The first two drive transitions the host's
  domain already defines (R3), and the third only observes (R3). None asks
  whether it is under test.
- The existing constructor-injected collaborators for spawning, child-exit
  probing, and source and descriptor lifecycle stay as they are. This rule
  describes the pattern they already follow; it does not introduce it.
- `scripts/terminal-pty-host-test-seam-lint.sh` keeps its list of banned names.
  The list is now the enforcement of a stated rule rather than the rule itself,
  so a name is added to it when R1 is violated, and adding a name is no longer
  an argument about taste.
- The cost is that R2 admits more entry points than a flat "no test-only API"
  ban would, and each one still has to be read against R1 rather than counted.
  The alternative bans the injected collaborators too, which would put the
  nondeterministic spawn handoff back out of reach of any test.

## References

- `scripts/terminal-pty-host-test-seam-lint.sh` -- the gate that enforces R1
  against `lib/TerminalPTY/Sources/TerminalPTYHost/TerminalPTYHost.swift` by
  name, plus its self-test at
  `scripts/tests/terminal-pty-host-test-seam-lint_test.sh`.
- [2026-05-28: Pure Core / Portable Support / Platform Runtime: a Purity-Enforced Three-Layer Split](2026-05-28-pure-core-support-split.md)
  -- the same shape one layer up: the pure core's four ambient inputs are
  injected through `CoreEnv` rather than sensed, and a lint enforces it.
- [2026-08-06: The AppKit UI Harness Is a Whole-Module Substitution Seam, Not a Test Target](2026-08-06-ui-harness-whole-module-substitution.md)
  -- the substitution mechanism available where a component takes its
  collaborators concretely and R3's routes are therefore closed.
