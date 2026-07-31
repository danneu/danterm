# 2026-07-31: Nix-Managed Config Location

- Status: Accepted
- Date: 2026-07-31

## Context

DanTerm owns and updates `~/.config/danterm/config.json`. Preferences saves are
atomic read-modify-write transactions that preserve unknown settings, but an
atomic replacement aimed at a symlink replaces the link itself. Home Manager's
usual generated-settings pattern is also a poor fit: it produces a read-only
store file that DanTerm cannot update.

Nix users still need a supported way to keep the live config in a versioned nix
repository and review app-made Preferences changes there.

## Decision

The Home Manager module owns the config location, not its contents. Its optional
`programs.danterm.configPath` setting accepts an absolute string path and uses
`config.lib.file.mkOutOfStoreSymlink` to link DanTerm's standard config path to
that writable location. When the option is unset, the module deploys no config
file.

DanTerm resolves the config symlink once at the start of each seed or save
transaction. Every existence check, read, directory creation, and atomic write
in that transaction uses the captured target URL. This preserves the symlink,
supports an initially missing target, and prevents a concurrent link retarget
from sending a save derived from the old file into the new file.

## Consequences

- Preferences saves become ordinary diffs in the user's nix repository.
- Nix does not generate, merge, or otherwise own config content.
- `configPath` must be a string rather than a nix path literal so nix does not
  copy the target into its read-only store.
- A hand-formatted config may receive a one-time sorted, two-space JSON rewrite
  on the first semantic edit.
- The module declaration and unset behavior remain manually verified because
  Home Manager is not a flake input solely for module evaluation tests.

## References

- [Home Manager module](../../hm-module.nix)
- [Config filesystem boundary](../../app/DanTermConfigStore.swift)
- [Config transaction tests](../../tests-ui/DanTermConfigStoreTests.swift)
