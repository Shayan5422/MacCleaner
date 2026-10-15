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

## Versioning

Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in `project.yml`, run `xcodegen generate`, add an entry to `CHANGELOG.md`, then tag the release (`git tag v1.0.0`).

## Changing the bundle identifier

The identifier `com.maccleaner.MacCleaner` appears in `project.yml`, `Config/Info.plist` (URL scheme name) and the launch agent plist in `Config/LaunchAgents/` (its file name, `Label` and `AssociatedBundleIdentifiers`). Change all of them together, and update `AutomationAgentController.plistName`.
