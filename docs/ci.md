# CI/CD

## Workflows

| Workflow | Trigger | Signing | Output |
|----------|---------|---------|--------|
| `ci.yml` | Pull requests | Ad-hoc (`--sign -`) | Build verification + release-build validation |
| `release-stable.yml` | `v*` tags | Developer ID + notarized | GitHub Release with `.dmg` + `.zip` |

## Releasing

```bash
just release patch   # v0.0.1 -> v0.0.2
just release minor   # v0.0.2 -> v0.1.0
just release major   # v0.1.0 -> v1.0.0
just version         # show current version
```

## GitHub secrets

| Secret | Purpose | How to obtain |
|--------|---------|---------------|
| `DEVELOPER_ID_APPLICATION_CERT_P12` | Base64-encoded `.p12` with Developer ID Application cert + private key | Export from Keychain Access, then `base64 -i cert.p12` |
| `DEVELOPER_ID_APPLICATION_CERT_PASSWORD` | Password used when exporting the `.p12` | Set during export |
| `KEYCHAIN_PASSWORD` | Random string for ephemeral CI keychain | `openssl rand -hex 16` |
| `APPLE_API_KEY_ID` | App Store Connect API key ID | [appstoreconnect.apple.com/access/integrations/api](https://appstoreconnect.apple.com/access/integrations/api) |
| `APPLE_API_ISSUER_ID` | App Store Connect issuer ID (UUID) | Same page as above |
| `APPLE_API_KEY_P8` | Full `.p8` key file contents | Download from App Store Connect (one-time) |

## Pinned versions

- **Ghostty `v1.3.0`** — set via `GHOSTTY_TAG` env var in each workflow
- **Zig `0.15.2`** — set in the `mlugg/setup-zig` action (Ghostty v1.3.x requires Zig 0.15)

When upgrading Ghostty, update both `GHOSTTY_TAG` in the workflows and potentially the Zig version if the new Ghostty requires it.

## Runner requirements

- **`macos-26`** — required for latest Xcode SDK (Ghostty uses `kCVPixelFormatType_30RGB_r210` from CoreVideo, added in macOS 15 SDK)
- **`-Dxcframework-target=native`** — builds arm64 only; the universal (arm64+x86_64) build fails due to x86_64 cross-compilation SDK issues

## Nested helper signing

The release bundle ships the `danterm` helper at `DanTerm.app/Contents/MacOS/danterm`.
CI signs that nested executable before signing the outer `.app`, then verifies
the full bundle with `codesign --verify --deep --strict --verbose=2`.

## Troubleshooting

### Dependency URL staleness

As of Ghostty v1.3.0, dependency URLs use a CDN (`deps.files.ghostty.org`), so the old iTerm2-Color-Schemes URL patching is no longer needed. If a CDN URL goes stale in the future, a similar `sed` patch approach can be used.

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

macOS runners cost **10x** regular minutes. Free tier: 2,000 min/month = effectively 200 macOS minutes. GhosttyKit builds take ~5-10 min but are cached after the first run.
