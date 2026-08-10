# `just fetch-references` -- reproducible local reference checkouts

## Context

AGENTS.md tells agents to mine `references/libvterm/` and `references/alacritty/`,
and `scripts/import-alacritty-recordings.py` reads a path inside one of them --
but nothing in the repo says how those directories come to exist. They were
cloned by hand and are hidden only by a line in `.git/info/exclude`, a
machine-local file that is not committed. A fresh clone, a new worktree, or a
fresh agent gets an empty `references/` and no instruction, and re-cloning by
hand lands on whatever upstream `main` happens to be that day.

Separately, agents working on this project regularly need Apple system source
that is not vendored anywhere: the open SIGSEGV-on-Cmd-Q research
(`docs/research/22-application-exit-job-corruption.md`) reasons about a
dispatch-queue arena and a corrupted resume pointer entirely from inference,
because `libdispatch` and `libpthread` source is not on disk. Reading it over
the network, file by file, is slow and unciteable.

Outcome: one command, `just fetch-references`, materializes every external
reference at a pinned revision, sparsely, into `references/`. Plus a citation
convention -- `file#identifier` rather than `file:line` -- so that citations
into these trees survive a pin bump.

## Approach

Model it on `/Users/dan/Code/braid/scripts/fetch-references.py` (staging
directory, per-entry atomic swap, `--list`, optional positional filter), with
three changes forced by this repo:

- Braid resolves pins from `flake.lock`/`Cargo.lock`. DanTerm has no such
  lockfile, so **pins are explicit literals in the manifest**.
- Braid clones whole repos. xnu and alacritty are large, so entries carry an
  optional **sparse cone**.
- Braid always re-fetches. Follow `build-lib.sh`'s cache instead: **skip an
  entry already at its pin** unless `--force`.

### 1. `scripts/fetch-references.py` (new)

Hyphenated CLI entry point, stdlib only, module docstring in house style
(intent + "pinned by scripts/tests/fetch_references_test.py").

**Manifest.** A module-level list of entries, each carrying: the directory name
under `references/`, the clone URL, the pinned **commit SHA**, an optional
sparse cone (empty means whole repo), a one-line `why` blurb surfaced by
`--list` and reused by the docs, and the human-readable release tag as
descriptive metadata only.

`I1` **Every pin is a full commit SHA, never a tag or branch.** Apple's
release tags are mutable refs on a mirror; if one moves, a fresh machine and an
existing one materialize different source while both report the same pin, which
silently invalidates citations and any research conclusion resting on them. The
tag is recorded beside the SHA so a human can read what release it is, but it
never participates in fetching or in cache validity.

Initial entries (SHAs are the peeled commits of the named tags, resolved
2026-07-30):

| name | repo | pin (commit SHA) | release tag | sparse cone |
|---|---|---|---|---|
| `libvterm` | neovim/libvterm | `934bc2fbf21800ac3458a499df8820ca5fb45fd3` | -- | (whole, 760K) |
| `alacritty` | alacritty/alacritty | `852e971cddfabe222d2d5bcda466e130f53af207` | -- | `alacritty_terminal` |
| `xnu` | apple-oss-distributions/xnu | `ac9718fb1af618d5ce8678d0dc6e8a58f252216f` | `xnu-12377.121.6` | `bsd/kern`, `bsd/sys`, `bsd/dev`, `osfmk/kern`, `osfmk/mach` |
| `libdispatch` | apple-oss-distributions/libdispatch | `701f4d1a24ae9c6863901bbbb22624b7d1b87321` | `libdispatch-1542.100.32` | (whole) |
| `libpthread` | apple-oss-distributions/libpthread | `1f4f5265b319111142f1bf3a27d4484ef5a98314` | `libpthread-539.100.4` | (whole) |
| `libplatform` | apple-oss-distributions/libplatform | `b7ed7cf5cf7dd12b98672435db2225a860f199d8` | `libplatform-375.120.2` | (whole) |
| `Libc` | apple-oss-distributions/Libc | `4e34d0559e3a1b081afeb8604d9e204a1f31321d` | `Libc-1752.120.2` | (whole) |
| `objc4` | apple-oss-distributions/objc4 | `ebfe77e64331034c867285a95d3ac205203291d5` | `objc4-951.7` | (whole) |

The two existing pins are the revisions **currently on disk** (verified via
`git -C references/<n> rev-parse HEAD`), so every existing citation in
`plans/impl/` keeps resolving. Per `I2` the first run still refetches them --
it lands the same content, and for alacritty it replaces today's full clone
with the cone. All cited alacritty paths live under `alacritty_terminal/`, so
that cone is safe.

Deliberately excluded: `swiftlang/swift`. Its tree is large enough to dominate
the fetch, and the runtime questions this project actually hits are better
answered by libdispatch/libpthread. Add it later if a doc needs it.

**Fetch contract.** Each entry is fetched into a staging directory as a
shallow, blob-filtered checkout of its pinned SHA, with the sparse cone applied
so only cone paths are materialized *and* only their blobs are downloaded. A
plain shallow fetch would download every blob of the commit even when the
working tree shows only the cone, so the filter is what makes the cone pay.
Fetching a SHA directly requires the server to serve arbitrary-SHA wants;
GitHub does, and the test fixture enables it explicitly.

`I2` **Cache validity is the checkout's resolved HEAD commit matching the
pinned SHA, plus its recorded cone matching the manifest cone.** Both halves
are required and the HEAD half is authoritative -- this mirrors
`build-lib.sh`'s `cache_at_pinned_tag`, which compares resolved OIDs rather
than trusting a recorded label, precisely so a checkout whose HEAD moved is not
skipped. Consequences the implementation must honor:

- A checkout with **no cone record is always stale** and is refetched, whatever
  its HEAD. A hand-made checkout can sit at the pinned SHA while containing a
  different subtree entirely -- the on-disk `references/alacritty` is a full
  clone, not the `alacritty_terminal` cone -- and nothing recoverable from the
  directory distinguishes "correct cone" from "wrong cone at the right commit".
  Refetching is both simpler than inferring and the only way the first run
  produces the cone the manifest actually specifies.
- A checkout whose recorded cone matches but whose HEAD has moved is stale and
  refetched.
- Changing only the manifest cone makes an entry stale even at the right SHA.
- `--force` refetches regardless.

The cone must therefore persist alongside each checkout; its on-disk
representation is implementation discretion. Only a record this script wrote
counts -- there is no adoption path.

`I3` **A failed or interrupted fetch never leaves a reference directory absent,
half-populated, or replaced by a partial tree.** Achieved by staging then
swapping, with a backup of the prior tree restored on any failure -- braid's
pattern. This must hold for an ordinary fetch failure, for a
`SIGINT`/`KeyboardInterrupt` arriving mid-fetch, **and for one arriving inside
the swap itself.** The swap is a pair of renames with a window between them
where the target path holds neither tree; an interrupt landing there would
delete a reference directory outright, which is the worst outcome the invariant
exists to prevent. The swap window must therefore defer interrupt delivery
until either the old or the complete new tree occupies the target path.

CLI: `[names...]`, `--list`, `--force`. Unknown name exits 1 listing valid ones.

### 2. `justfile` (modify)

Beside the existing `fetch-ghostty` recipe, a variadic `fetch-references *ARGS`
passing through to the script, with a doc comment showing the all / one-entry /
`--list` forms.

Add `python3 ./scripts/tests/fetch_references_test.py` to the `test` recipe,
next to the other `scripts/tests/*_test.py` lines.

### 3. `.gitignore` (modify)

Add `/references/`. Today the exclusion lives only in
`/Users/dan/Code/danterm/.git/info/exclude:10`, which is per-machine and
uncommitted -- so anyone else who runs the new recipe gets ~50MB of untracked
noise in `git status`. Committing the rule is the point of making the directory
reproducible.

### 4. `agent-docs/reference-sources.md` (modify)

New `## Local reference checkouts` section. This is the tracked home for the
index -- **not** a `references/README.md`, which would sit inside a gitignored
directory that `fetch-references.py` overwrites wholesale on every run.

It must carry four things; exact wording is implementation discretion.

1. **The entry list: one markdown bullet per entry, each a link to
   `references/<name>/`, followed by a short blurb on what that repo is useful
   for.** The blurb is the manifest's `why` field, so the doc and `--list`
   cannot drift.
2. **The recovery instruction:** these directories are gitignored and absent
   from a fresh clone; if the folder you want is missing, run `just
   fetch-references [name]` and read it locally rather than fetching files over
   the web one at a time.
3. **The don't-edit warning:** a refetch replaces the directory wholesale, so
   local edits are lost.
4. `I4` **The citation rule: cite refetchable reference trees as
   `file#identifier`, never `file:line`.** Line numbers rot on the first pin
   bump; an enclosing named identifier survives. Use the nearest enclosing
   named identifier when the point of interest is not itself named. DanTerm's
   own tracked files keep `file:line` -- git pins those.

### 4b. `docs/research/12-cell-representation.md` (modify)

Its `## Investigation rules` section instructs agents to verify claims against
`.ghostty-src/` or `references/alacritty/` and "cite the file and line" -- a
live instruction that directly contradicts `I4`. Change it to `file#identifier`.
The rule there already covers `.ghostty-src/`, which `build-lib.sh` also
refetches at a bumped pin, so both trees fall under `I4` for the same reason.

Existing `file:line` citations in `plans/impl/` stay as-is; they are records of
completed work, not instructions to future agents.

### 5. `AGENTS.md` (modify)

In `## Boundaries`, replace the two hardcoded `references/` bullets with one
that covers the whole directory, points at `just fetch-references` and
`agent-docs/reference-sources.md`, and keeps the mine-and-adapt intent. Add the
`file#identifier` rule to `## Don't guess` or alongside it, since that is where
an agent already looks before reading reference source.

## Tests

`scripts/tests/fetch_references_test.py` -- stdlib `unittest`, run as
`python3 <file>`, loading the hyphenated script via
`importlib.util.spec_from_file_location` (the established pattern in
`terminal_memory_profile_test.py`). Offline and CI-portable: build a real local
git origin with `git init` as the fixture, exactly like
`scripts/tests/build-lib-fetch_test.sh`, and point a test manifest at it. The
fixture repo needs `uploadpack.allowFilter` and `uploadpack.allowAnySHA1InWant`
enabled for the SHA-pin and blob-filter paths.

Behavioral cases, each structure-insensitive (assert on the resulting tree and
exit status, not on the git commands issued):

1. A sparse entry materializes only its cone -- a file outside the cone is
   absent, one inside is present with correct content.
2. A whole-repo entry materializes a file at any depth.
3. A SHA pin lands that exact commit's content (assert file content, not `git
   describe`), including when the fixture also has a tag pointing elsewhere --
   `I1`, that no tag name influences what is fetched.
4. Re-running with the entry already at its pin leaves it untouched and does no
   fetch (assert via a sentinel file written into the checkout surviving).
5. **No cone record** (`I2`): a checkout whose HEAD is at the pinned SHA but
   which carries no cone record is refetched, and the resulting tree is the
   manifest's cone -- including when the pre-existing tree held a *different*
   subtree at that same commit.
6. **Moved HEAD** (`I2`): a checkout whose cone record matches but whose HEAD
   has been moved off the pin is refetched, not skipped.
7. Changing only the sparse cone in the manifest triggers a refetch and the new
   cone is materialized.
8. `--force` refetches an up-to-date entry (sentinel file gone).
9. A fetch that fails mid-run (pin that does not exist upstream) exits non-zero
   and leaves the previously-fetched tree intact -- `I3`.
10. **Interrupt during transfer** (`I3`): run the script as a subprocess, send
    `SIGINT` while the fetch is in flight, and assert the previously-fetched
    tree is still intact and complete. Test 9 alone would still pass if
    interrupt handling later stopped restoring the backup.
11. **Interrupt inside the swap** (`I3`): deliver `SIGINT` in the window between
    the two renames and assert the target path holds a complete tree -- the old
    one or the new one, never absent. Test 10 cannot reach this window, since
    slowing the transfer only widens a phase the swap is not in; the test must
    target the swap boundary directly and must not depend on winning a race.
    How delivery is made deterministic is `RI5`.
12. An unknown name exits 1 and names the valid entries.
13. `--list` prints every manifest entry name.

No test asserts against the network or against the real manifest's pins.

## Verification

1. `python3 ./scripts/tests/fetch_references_test.py` -- passes.
2. `just fetch-references --list` -- prints all eight entries.
3. `just fetch-references` on this machine -- all eight entries land; libvterm
   and alacritty are refetched at their existing SHAs. Run it a second time:
   every entry now reports skipped-at-pin.
4. `du -sh references/*` -- confirm the sparse cones actually bounded the
   fetch (xnu should be tens of MB, not the full tree; alacritty should shrink
   from today's 50M full clone).
5. `ls references/libdispatch/src/queue.c references/xnu/bsd/kern/kern_exit.c`
   -- the files that motivated this exist locally.
6. `git status --short` -- `references/` produces no untracked noise.
7. `python3 ./scripts/import-alacritty-recordings.py` still resolves its
   `references/alacritty/alacritty_terminal/tests/ref` path (the cone check).
8. Every bullet in the `agent-docs/reference-sources.md` list resolves to a
   real directory after step 3, and the set of bullets matches
   `just fetch-references --list` exactly -- no entry documented but unfetched,
   none fetched but undocumented.
9. `grep -rn ':[0-9]\+' docs/research/12-cell-representation.md` around the
   investigation rules -- no surviving "cite the file and line" instruction.
10. `just test` -- full local gate green.

## Implementation discretion

- `RI1` On-disk representation of the recorded sparse cone (`I2`): any form
  that survives a checkout and can be compared against the manifest.
- `RI2` Exact git command choreography for the fetch, and the staging/backup
  directory naming, so long as `I1`-`I3` hold.
- `RI3` Exact wording of the new `agent-docs/reference-sources.md` prose and
  the justfile doc comment.
- `RI4` How the test fixture makes a fetch slow enough to interrupt (test 10).
- `RI5` How test 11 delivers `SIGINT` deterministically inside the swap window
  (a test-only seam is acceptable; a timing race is not).

## Non-goals / accepted risks

- `AR1` Pin bumps stay manual: no staleness check, no automated bump. These
  trees are read by agents, not built against, so a stale pin costs nothing
  until someone needs newer source -- at which point editing one SHA is the
  whole operation.
- `AR2` The docs list and the manifest can drift between commits; only
  verification step 8 catches it, not a test. A lint would be mechanism to
  guard a one-line doc edit that the same commit always touches.
