# DanTerm theme catalog

The JSON files in this directory are DanTerm's canonical, tracked theme
collection. They are generated from the theme catalog bundled by the pinned
Ghostty release:

- collection: iTerm2-Color-Schemes via Ghostty
- Ghostty version: `v1.3.1`
- catalog release: `ghostty-themes-release-20260216-151611-fc73ce3`

Do not edit an individual theme by hand. After updating the pinned Ghostty
catalog and the provenance constants in `scripts/import-ghostty-themes.py`, run
`just update-themes` and review the resulting color-level diff. Builds consume
these committed files; they do not regenerate them.

The JSON schema is private build data, not a user-authored theme format or a
compatibility promise. See `NOTICE.iTerm2-Color-Schemes` for the upstream
collection license notice.
