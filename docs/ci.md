# CI/CD

## Workflows

| Workflow | Trigger | Signing | Output |
|----------|---------|---------|--------|
| `ci.yml` | Pull requests | Ad-hoc (`--sign -`) | Build verification + release-build validation |
| `release-stable.yml` | `v*` tags | Developer ID + notarized | GitHub Release with `.dmg` + `.zip` |

`ci.yml` runs four independent jobs:

| Job | Runner | What it proves |
|---|---|---|
| `cliff-smoke` | `ubuntu-latest` | git-cliff changelog grouping, plus the two Nix checks that can only execute on Linux (`shell-integration`, `home-manager-shell-integration`) |
| `theme-freshness` | `ubuntu-latest` | re-importing the pinned theme archive leaves `themes/` byte-identical |
| `build` | `macos-26` | `./build-app.sh` produces a bundle that still matches its declared layout after ad-hoc signing |
| `release-build-check` | `macos-26` | `./build-app.sh --version` produces the declared release layout, and that layout survives a signed ZIP round-trip |

Both macOS jobs are checkout-then-build: DanTerm is a pure SwiftPM/AppKit build,
so there is no external toolchain to install or artifact to cache. `nix` appears
only where a job actually uses it -- the Linux checks and git-cliff in
`cliff-smoke`, and git-cliff plus `nix hash convert` in `release-stable.yml`.

## Releasing

```bash
just release patch   # v0.0.1 -> v0.0.2
just release minor   # v0.0.2 -> v0.1.0
just release major   # v0.1.0 -> v1.0.0
just version         # show current version
```

The release recipe waits for GitHub to register the tag-triggered workflow,
then follows that run until it finishes. A failed workflow makes the recipe
exit with a failure status.

## GitHub secrets

| Secret | Purpose | How to obtain |
|--------|---------|---------------|
| `DEVELOPER_ID_APPLICATION_CERT_P12` | Base64-encoded `.p12` with Developer ID Application cert + private key | Export from Keychain Access, then `base64 -i cert.p12` |
| `DEVELOPER_ID_APPLICATION_CERT_PASSWORD` | Password used when exporting the `.p12` | Set during export |
| `KEYCHAIN_PASSWORD` | Random string for ephemeral CI keychain | `openssl rand -hex 16` |
| `APPLE_API_KEY_ID` | App Store Connect API key ID | [appstoreconnect.apple.com/access/integrations/api](https://appstoreconnect.apple.com/access/integrations/api) |
| `APPLE_API_ISSUER_ID` | App Store Connect issuer ID (UUID) | Same page as above |
| `APPLE_API_KEY_P8` | Full `.p8` key file contents | Download from App Store Connect (one-time) |

## Runner requirements

- **`macos-26`** -- both macOS jobs and the release job pin the same image, so
  PR validation and the shipped build compile against the same Xcode and SDK.

## Nested helper signing

The release bundle ships two nested executables under
`DanTerm.app/Contents/Helpers/`: the `danterm` CLI, and `PTYSessionBootstrap`
(the terminal backend reports itself not ready without it, so a bundle missing
it launches and then fails to open a session).

The build emits `.spm-build/bundle-layout-release.json` from the Swift
`BundleLayout` declaration, and the two transformations that can change a bundle
after its producer checked it own their own verification:

- `scripts/sign-app-bundle.sh` signs every nested executable the plan declares
  *before* signing the outer `.app` -- signing the container seals whatever
  signatures the helpers already carry, so a helper signed afterwards
  invalidates the app -- then runs `codesign --verify --deep --strict` and
  re-checks the bundle against the plan.
- `scripts/unpack-app-zip.sh` unzips a published archive and runs the same two
  checks on the round-tripped bundle.

Both take the plan rather than a list of paths, so no workflow repeats a reduced
list of bundle contents in YAML, and neither transformation can be performed
without the check that follows it.

The agent hook scripts live at `DanTerm.app/Contents/Resources/danterm-hooks/`,
not `Contents/Helpers/`. They are executable shell scripts, not Mach-O nested
code, so placing them in Helpers would make their seal depend on an extended
attribute that is stripped by the published ZIP round-trip. Resources are sealed
by content in `CodeResources`, and CI verifies the published shape by unzipping
the signed app and running `codesign --verify --deep --strict`.

## Troubleshooting

### Re-triggering a release

GitHub Actions only fires on tag push events. If a tag already exists on the remote, `git push origin <tag>` says "Everything up-to-date" and nothing triggers. To re-trigger:

```bash
git push origin --delete v0.0.0
git tag -f v0.0.0
git push origin v0.0.0
```

### Signing certificate

The CI needs a **Developer ID Application** certificate (not "Apple Development" or "Apple Distribution"). Cloud-managed certificates (created by Xcode's automatic signing) can't be exported as `.p12`. You need a manually-created one:

1. [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates) → **+** → **Developer ID Application**
2. Generate CSR via Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority
3. Upload CSR, download `.cer`, double-click to install
4. Export from Keychain Access as `.p12` (right-click cert → Export Items)

### macOS runner minutes

macOS runners cost **10x** regular minutes. Free tier: 2,000 min/month = effectively 200 macOS minutes. Keep new work on the `ubuntu-latest` jobs unless it genuinely needs macOS.
