---
name: Docs should use stable groups, not exhaustive file lists
description: AGENTS.md file trees should be architectural overviews with representative files, not complete inventories that go stale on every file add/rename/delete
type: feedback
---

Don't replace stale exhaustive file trees with updated exhaustive file trees — that recreates the same drift vector.

**Why:** Every new file added or renamed requires a doc update, and the maintenance burden scales with feature work. The file tree went from 12 to 33 files and nobody updated the docs.

**How to apply:** In AGENTS.md and similar architecture docs, describe stable groups and representative files rather than enumerating every source/test file. Use `glob` or `ls` for the actual file list — docs should capture structure and intent, not inventory.
