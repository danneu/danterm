# External Terminal Gate Evidence - 2026-07-31

## Judgment

DanTerm's pinned external terminal evidence package is reproducible and gating.
The native gate, attributed neutral fixtures, 14 selected esctest2 cases, and
three response-driven vttest sessions cover the maintained package without
letting an upstream update silently change its inputs or expected behavior.

This closes only Milestone 9's external-evidence criterion. The milestone's
component-invariant, power/performance, and sustained-daily-use criteria remain
independent.

## Reproduction

```sh
just test
just test-terminal-protocol-probes
```

The external run passed on macOS 26.5.2 arm64. Its retained artifact directory
was `.build/terminal-protocol-probe-runs/20260731T233736Z-82863`.

| Program | Pin | Passing scope |
| --- | --- | --- |
| esctest2 | `664be3cf2c1e3f06bc93a8bafb48a0db83c607db` | 14 selected cases, 14 passed, 0 known bugs, 0 failed |
| vttest 2.7 (20251205) | `0229d7171a8574a2bf406c6ce14549f65d810e51` | VT100 DSR/CPR, VT100 DA1, and VT320 DECCPR |

Each external session launched through `TerminalPaneSessionController`, the
production PTY owner, and `PTYSessionBootstrap`. Every session retained its byte
recording, upstream log, stable summary, stdout/stderr, and ownership report.
All ownership reports recorded the pane session, child, PTY owner, descriptors,
and dispatch sources as released.

## Vttest judgments

- VT100 DSR/CPR (`6.3`) reported terminal OK and accepted both absolute and
  DECOM-relative cursor reports.
- VT100 DA1 (`6.4`) decoded DanTerm's exact `CSI ? 1 ; 2 c` reply as "VT100 with
  AVO (could be a VT102)."
- VT320 DECCPR (`11.2.5.2.7`) decoded a nonzero line and column. This corrects
  the `.6` path recorded during the source audit; the pinned menu table assigns
  DECXCPR to choice 7.

The result parser requires those exact source-authored positive judgments and
rejects incomplete output, the wrong menu path, unknown responses, failures,
bad formats, and unexpected results. The first live replay run failed because
vttest's startup DA1 handshake consumed the first wait marker. Adding that
source-defined handshake to each checked-in replay file made all three sessions
pass; it did not expose a DanTerm behavior failure, so no native regression
fixture was needed.

## Pinning and package boundary

Both external programs are fetched into ignored build storage and checked out
at full commit hashes. Esctest2's GPL-2.0 implementation remains external and
uses the checked-in DanTerm adapter. Vttest is built out of tree from its clean
pinned checkout; its license is copied into each retained run. DanTerm-authored
replay commands and report expectations are checked in, so upstream logs or
screens are never accepted as DanTerm truth.

The attributed neutral-fixture manifests remain the inventory and disposition
record for imported cases. The classification closure and corpus additions are
recorded in
[`docs/research/26-external-corpus-expansion/`](../research/26-external-corpus-expansion/README.md),
which also explains why visual vttest sessions, Ghostty's scoped case mine,
wraptest, and the other declined sources are not part of this gate.
