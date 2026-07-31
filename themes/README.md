# DanTerm theme catalog

The JSON files in this directory are DanTerm's canonical, tracked theme
collection. They are generated from the theme catalog bundled by the pinned
iTerm2-Color-Schemes release:

- collection: iTerm2-Color-Schemes
- catalog release: `release-20260720-153658-97e244c`
- release asset: `ghostty-themes.tgz`
- SHA-256: `7329d0e2e958ee8404e516a6550bd07334edc611334a73f84d50477daa459f0c`

Do not edit an individual theme by hand. After updating the release and digest
pins in `scripts/import-ghostty-themes.py`, run `just update-themes` and review
the resulting color-level diff. Builds consume these committed files; they do
not download or regenerate them.

The JSON schema is private build data, not a user-authored theme format or a
compatibility promise. See `NOTICE.iTerm2-Color-Schemes` for the upstream
collection license notice.
