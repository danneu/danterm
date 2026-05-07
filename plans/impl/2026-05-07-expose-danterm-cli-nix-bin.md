# Expose DanTerm CLI From Nix Package

## Summary

Fix the Nix package so `programs.danterm.enable = true` installs a real
`danterm` executable into the user's Nix profile. Keep the in-app
"Install danterm Command in PATH" menu item for manual `.app` installs, but
Nix users should not need it.

## Key Changes

- Update `package.nix` only.
- Keep installing the release app bundle at `$out/Applications/DanTerm.app`.
- After copying the bundle, validate the expected release layout:
  - `$out/Applications/DanTerm.app/Contents/MacOS/DanTerm` exists and is executable.
  - `$out/Applications/DanTerm.app/Contents/Helpers/danterm` exists and is executable.
  - The GUI binary and CLI helper are not byte-identical.
- Add `$out/bin/danterm` as a symlink to
  `$out/Applications/DanTerm.app/Contents/Helpers/danterm`.
- Add `meta.mainProgram = "danterm"` while preserving
  `meta.platforms = [ "aarch64-darwin" ]`.
- Do not change `hm-module.nix`: `home.packages = [ cfg.package ]` will pick
  up `$out/bin/danterm` automatically.

## Intended `installPhase`

```sh
installPhase = ''
  mkdir -p "$out/Applications/DanTerm.app"
  cp -R . "$out/Applications/DanTerm.app/"

  gui="$out/Applications/DanTerm.app/Contents/MacOS/DanTerm"
  cli="$out/Applications/DanTerm.app/Contents/Helpers/danterm"

  test -x "$gui"
  test -x "$cli"

  if cmp -s "$gui" "$cli"; then
    echo "Error: bundled GUI and CLI helper are byte-identical" >&2
    exit 1
  fi

  mkdir -p "$out/bin"
  ln -s "$cli" "$out/bin/danterm"
'';
```

## Test Plan

- Run `nix build .#default --out-link /tmp/danterm-nix-result`.
- Verify `/tmp/danterm-nix-result/bin/danterm` exists and is executable.
- Verify `readlink /tmp/danterm-nix-result/bin/danterm` points at
  `Contents/Helpers/danterm`.
- Verify `cmp -s /tmp/danterm-nix-result/Applications/DanTerm.app/Contents/MacOS/DanTerm /tmp/danterm-nix-result/Applications/DanTerm.app/Contents/Helpers/danterm`
  exits nonzero.
- After updating `~/world` to the fixed DanTerm flake commit and rebuilding
  Home Manager, verify `type -a danterm` resolves to the Nix profile bin path
  before any app bundle `Contents/MacOS` path.
- In a fresh DanTerm pane, verify `danterm` prints `danterm: missing command`
  instead of launching/focusing the GUI, and `danterm ls` talks to the socket.

## Assumptions

- The release artifact already contains the relocated helper at
  `Contents/Helpers/danterm`.
- The Nix CLI should run the helper from the Nix store copy of the app bundle;
  that is fine because IPC uses `DANTERM_SOCK` or the production socket path.
- Manual `.app` users still need an explicit PATH install step, matching normal
  macOS app practice.
