# CLI-5: derive the CLI target policy from the route's wire method and enforce it in the parser

Audit item: `docs/scratch/2026-08-26-improvement-audit.md` CLI-5 (Wave 11). Lands before CLI-4.

## Problem

"quit must name its instance explicitly" is declared twice and enforced once, in the wrong place.

- The catalog declares `targetPolicy: .explicitRequired` on `quit`
  (`lib/DanTermProtocol/Sources/DanTermProtocol/CLICommandCatalog.swift`). Nothing reads that case.
- `routeCLIInvocation` (`CLIParser.swift`) enforces only `.localOnly`.
- The live rule runs in `cli/main.swift#selectConnectionTarget`, keyed on `IpcRequestMethod.terminatesInstance`.
- `doctor` is declared `.localOnly` yet already resolves an ambient instance to send `doctorAppFacts`, so the declaration is false today.

A catalog entry whose declared policy differs from the policy applied to it is representable, and one already exists. The wire method is only known after argument parsing; there is no static route -> method map, which is why the catalog carries a hand-written policy at all.

## Decision

One value, one derivation, one reader.

- Every CLI route names its wire method statically (`nil` for routes that send no request: `help`, `skill`).
- `targetPolicy` is a projection of that method: no method -> local-only; `terminatesInstance` -> explicit target required; otherwise ambient targeting allowed. The stored policy and its constructor argument go away.
- `routeCLIInvocation` enforces the policy for every route, with the descriptor and parsed target both in hand. `selectConnectionTarget` only resolves (explicit, then `DANTERM_SOCK`, then identity fallback); it takes no method.
- Closed-connection-is-success stays keyed on `terminatesInstance` in `resolveReply`; the `terminatesInstance` doc no longer claims the targeting rule.
- Consequence for `doctor`: it sends a request, so it becomes ambient-allowed and accepts `--socket`/`--tcp`. The parsed target is passed through to the doctor's app query so an accepted flag is honored. Naming the instance in doctor output is CLI-4's.

Shape CLI-4 builds on: no `targetPolicy:` argument exists; `doctor` is already `.implicitAllowed`; `routed.target` reaches `gatherDoctorAppFacts`; `selectConnectionTarget(explicit:environment:fallback:)`.

## Invariants

- I1. A route's declared wire method equals the method of the request its parser builds.
- I2. A route whose method ends the instance is refused without `--socket`/`--tcp`, before any connection, with `"<command> requires an explicit --socket <path> or --tcp <host:port>"`. Wording unchanged for `quit`.
- I3. A route with no wire method refuses `--socket`/`--tcp` with `"<command> does not accept --socket or --tcp"`.
- I4. Every other route accepts an explicit target and falls back to ambient resolution without one.
- I5. `quit` remains the only instance-ending method.

## Proof obligations

- PO1 (I1): for every route with a method, a minimal valid invocation parses to a request carrying that method. `DanTermProtocolTests`.
- PO2 (I2, I3, I4): for every catalog entry, its projected policy predicts the parser's acceptance or refusal of a target flag and the refusal text. `DanTermProtocolTests`, driven from the catalog so a new command is covered on arrival.
- PO3 (I2): the existing `quit` ambient-refusal cases in `cli-tests/SocketSelectionTests.swift` move to the parser tests with their assertion text unchanged.
- PO4 (I5): existing `IpcRequestTests` "quit is the only instance-ending method" stays.
- `just test` green; `usageText` in `cli/main.swift` stays true without edits, and `integrations/danterm/SKILL.md` describes doctor's newly accepted target flags (quit's rule and wording are unchanged).

## Non-goals

- Doctor output naming its instance, row titles, JSON projection (CLI-4, CLI-6).
- Changing any refusal wording or exit code.

## Rejected ideas

- RI1. Add the missing `.explicitRequired` branch and keep the stored enum: leaves two hand-maintained declarations that must agree and keeps doctor's false `.localOnly`.

## Implementation discretion

- Where the route -> method map lives (on `CLIParserRoute` or beside the catalog) and how PO1 constructs minimal invocations per route.

## Implementation notes

- The checked-in CLI skill still called `doctor` local-only. This change updates that contract because the project requires CLI surface and skill documentation to stay in sync.
