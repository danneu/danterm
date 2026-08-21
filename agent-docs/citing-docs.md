# Citing DanTerm's own documents

Rules for links and ids inside comments, docs, plans, and commit messages.
External source trees under `references/` use a different form, described in
[reference-sources.md](reference-sources.md).

- Cite research outside `docs/research/` as `research/N/ID`, such as
  `research/15/F4`; the prefix names the tree, and
  [../docs/research/README.md](../docs/research/README.md) resolves the stable
  number to a path. Inside `docs/research/`, keep the portable bare cross-doc
  form such as `9/F3` required by `FORMAT.md`.
- Cite a design doc by path and id, then use the bare id within that same file;
  design docs are durable statements of their contracts, so a direct pointer
  is better than a paraphrase.
- Do not cite plan ids. Restate the invariant in the clause that would have
  carried the id, because plans are historical and their ids are not unique.
  When the same invariant needs restating across many files, graduate it to a
  design doc instead.
- `scripts/docs-lint.py` resolves every repo-relative path cited in AGENTS.md,
  CLAUDE.md, `agent-docs/`, and `docs/` outside `docs/scratch/`, so a rename that
  orphans a citation fails the gate. When a document names a deleted path on
  purpose -- a supersession banner does exactly that -- declare it in that file
  with `<!-- docs-lint: allow-missing the/path -->`. The marker exempts only
  that path and only in that file.
