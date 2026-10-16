# Building, signing, notarizing and releasing

## Requirements

* macOS 14 or later to run; Xcode 26 or later (Swift 6) to build. The project is developed with Xcode 27.
* For distribution: an Apple Developer Program membership with a **Developer ID Application** certificate in your keychain.
* Optional: [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) if you change `project.yml`.

## Build and run

```bash
open MacCleaner.xcodeproj
```

Choose the **MacCleaner** scheme and press ⌘R. Debug builds are signed to run locally, so no team is needed.

From the command line:

```bash
xcodebuild -project MacCleaner.xcodeproj -scheme MacCleaner -configuration Debug build
```

## Tests

```bash
xcodebuild -project MacCleaner.xcodeproj -scheme MacCleaner -destination 'platform=macOS' test
```

Tests create and delete files only inside temporary folders. One test moves a temporary file to your Trash and restores it, to verify Undo.

Every push to `main` and every pull request runs the same build and test suite on GitHub Actions (`.github/workflows/ci.yml`, on the `xcode-27` macOS image). The workflow also fails if the build produces any Swift compiler warnings. No signing secrets are needed: CI builds use the project's ad-hoc "Sign to Run Locally" setting. Dependabot (`.github/dependabot.yml`) keeps the actions up to date.

## Changing the project

`project.yml` is the source of truth. After editing it (or adding/removing files):

```bash
xcodegen generate
```

## Release pipeline

`scripts/release.sh` archives a Release build, exports it with your Developer ID, verifies the signature and hardened runtime, builds a signed DMG and zip, and — if a notary profile is given — notarizes and staples both.

1. Save notarization credentials once (you'll be asked for an [app-specific password](https://account.apple.com)):

   ```bash
   xcrun notarytool store-credentials "MacCleanerNotary" --apple-id "you@example.com" --team-id YOURTEAMID
   ```

2. Build the release:

   ```bash
   scripts/release.sh --team YOURTEAMID --notary-profile MacCleanerNotary
   ```

   Output: `build/release/Mac-Cleaner-<version>.dmg`, `.zip` and `.sha256`.

3. Check Gatekeeper's verdict (the script does this too):

   ```bash
   spctl --assess --type execute --verbose "build/release/export/Mac Cleaner.app"
   ```

To ship without notarization, use `--skip-notarization`; people will then have to Control-click › Open the app the first time.

The script can also notarize with an App Store Connect API key instead of a keychain profile (`--notary-key AuthKey.p8 --notary-key-id <id> --notary-issuer <uuid>`), and sign with a specific keychain (`--keychain <path>`); the release workflow uses both.

## Automated releases (GitHub Actions)

`.github/workflows/release.yml` runs the same pipeline on GitHub's macOS 27 image: tests, a universal Release archive signed with Developer ID, a signed DMG and zip, notarization, stapling, Gatekeeper checks, SHA-256 checksums, and a GitHub release whose notes are the version's section of `CHANGELOG.md`. Mac Cleaner's built-in update check reads these releases, so the asset names (`Mac-Cleaner-<version>.dmg`, `.zip`, `.sha256`) must stay as `release.sh` produces them.

### One-time setup

Signing needs your Developer ID certificate and notarization credentials as encrypted repository secrets. Run this yourself in Terminal; it asks for the files and passwords and sends them straight to GitHub with the GitHub CLI:

```bash
scripts/setup-release-secrets.sh
```

| Secret / variable | What it is |
|---|---|
| `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD` | The "Developer ID Application" certificate and private key, exported from Keychain Access as `.p12` |
| `NOTARY_API_KEY_P8_BASE64`, `NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER_ID` | An App Store Connect API key for `notarytool` (recommended) |
| `NOTARY_APPLE_ID`, `NOTARY_APP_PASSWORD` | Or: an Apple ID and an app-specific password |
| `APPLE_TEAM_ID` (variable) | Your Developer Team ID |

The certificate is imported into a temporary keychain that is deleted at the end of every run. Pull requests never get access to these secrets: the workflow only runs for tags and manual runs.

### Releasing a version

1. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in `project.yml`, run `xcodegen generate`, and add a `## [X.Y.Z] — date` section to `CHANGELOG.md`.
2. Merge to `main`, then tag and push:

   ```bash
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```

The workflow refuses a tag that doesn't match `MARKETING_VERSION` or has no changelog section. You can also start it from **Actions › Release › Run workflow**: without "publish" it only uploads the build as a workflow artifact (ad-hoc signed when the secrets aren't set up), with "publish" it also creates the tag and the release.

## Versioning

Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in `project.yml`, run `xcodegen generate`, add an entry to `CHANGELOG.md`, then tag the release (`git tag v1.0.0`). Pushing the tag publishes the release (see above).

## Changing the bundle identifier

The identifier `com.maccleaner.MacCleaner` appears in `project.yml`, `Config/Info.plist` (URL scheme name) and the launch agent plist in `Config/LaunchAgents/` (its file name, `Label` and `AssociatedBundleIdentifiers`). Change all of them together, and update `AutomationAgentController.plistName`.
