# Mac Cleaner for iPhone and iPad

The iOS version of Mac Cleaner. It cleans what iOS lets an app clean (photos, videos, contacts, and
files in folders you pick), checks the device's security, blocks malware sites in Safari, and walks
you through Settings for everything an app can't reach.

Everything runs on the device. The app makes two kinds of requests: Apple's software update catalog
(`gdmf.apple.com`), to tell whether iOS is up to date, and abuse.ch's public malware lists (URLhaus
and ThreatFox) for Safari protection and the link check. Nothing about the device, its photos,
contacts or files is sent anywhere.

## What it does

| Tab | What it does | Needs |
|---|---|---|
| Overview | Storage used and available, what the last scans can free, protection status, and the guides that help this device now | — |
| Clean › Photos | Duplicates and similar photos (perceptual hashes), screenshots and bursts; each group keeps its best photo (a favorite, then an edited one, then the highest resolution) | Photos, full or limited access |
| Clean › Videos | Videos of 100 MB or more, and screen recordings | Photos |
| Clean › Contacts | Duplicates (same name, phone number or email) to merge, and incomplete contacts (no name, or no way to call or write) | Contacts |
| Clean › Files | Large files (50 MB or more), old files (unchanged for a year), duplicates (SHA-256) and empty folders | The folders you pick in Files |
| Protect | Checkup of the passcode, Face ID or Touch ID, VPN and proxy, and the iOS version; Safari protection with up to 50,000 malware rules; a link check against the lists saved on the device | Turning on the Safari extension in Settings |
| Guides | 18 guides with the steps for iOS 17 and for iOS 18 or later: Recently Deleted, photo storage, offloading apps, Messages attachments, Safari data, WhatsApp and Telegram media, updates, Stolen Device Protection, Lockdown Mode… | — |

Nothing is deleted without a confirmation, and by default nothing is gone for good:

- Photos and videos go to Recently Deleted in Photos for 30 days.
- Files go to Recently Deleted in Files (On My iPhone and iCloud Drive). Deleting permanently is a
  separate choice, and the only one for locations without Recently Deleted, such as a folder inside an app.
- Contacts are saved as a vCard backup before every merge or deletion, and a backup can be added back from the app.

## What iOS doesn't allow

iOS keeps every app in its own sandbox, and Mac Cleaner uses public APIs only, so it can't:

- clear System Data or other apps' caches;
- see or delete other apps' files, or offload and delete apps;
- scan apps and files for malware the way the Mac app does;
- scan in the background.

For each of these, a guide shows the quickest way in Settings, with the steps for the device's iOS
version. Files that are only in iCloud or another cloud service are skipped, so a scan downloads
nothing.

## Build and run

Built and tested with Xcode 27. The app supports iOS 17 and later on iPhone and iPad.

```bash
open iOS/MacCleanerMobile.xcodeproj
```

The simulator needs no signing. To run on a device, pick your team under Signing & Capabilities for
the `MacCleanerMobile` and `ContentBlocker` targets. The App Group
`group.com.maccleaner.MacCleaner.mobile`, which the app and the Safari extension share, has to be
registered on that team once, from the App Groups section of the same tab:
`xcodebuild -allowProvisioningUpdates` creates the app IDs and profiles but doesn't register app
groups. After that, the command line can build and install on a device too:

```bash
xcodebuild -project iOS/MacCleanerMobile.xcodeproj -scheme MacCleanerMobile -configuration Release -destination 'id=<device UDID>' -derivedDataPath iOS/build/device -allowProvisioningUpdates DEVELOPMENT_TEAM=<team ID> build
```

```bash
xcrun devicectl device install app --device '<device UDID>' 'iOS/build/device/Build/Products/Release-iphoneos/Mac Cleaner.app'
```

Tests (Swift Testing, fixtures only; any simulator from `xcrun simctl list devices available`):

```bash
xcodebuild test -project iOS/MacCleanerMobile.xcodeproj -scheme MacCleanerMobile -destination 'platform=iOS Simulator,name=iPhone Air'
```

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
and committed. After changing the spec:

```bash
xcodegen generate --spec iOS/project.yml
```

The app icon is drawn by `scripts/generate-ios-icon.swift`.

### Launch arguments

Debug builds accept these arguments, to check a screen in the simulator without tapping through the
app. Release builds ignore them.

| Argument | Effect |
|---|---|
| `-onboardingCompleted '<true/>'` | Skips the introduction |
| `-onboardingPage 2` | Opens the introduction on that page |
| `-debugTab overview\|clean\|protect\|guides` | Opens that tab |
| `-debugOpen photos\|videos\|contacts\|files` | Opens that screen in the Clean tab and starts its scan |
| `-seedSampleContacts` | Adds, once, a few look-alikes of the simulator's sample contacts |
| `-seedSampleFiles` | Adds a "Sample Files" folder with large, old and duplicate files |

```bash
xcrun simctl launch booted com.maccleaner.MacCleaner.mobile -onboardingCompleted '<true/>' -debugOpen contacts -seedSampleContacts
```

## Layout

```
iOS/
├── project.yml              XcodeGen spec
├── MacCleanerMobile/
│   ├── App/                 entry point, tabs, introduction, AppModel
│   ├── Core/                formatting, device and storage info
│   ├── DesignSystem/        colors, cards, gauges, permission and progress views
│   ├── Features/
│   │   ├── Overview/
│   │   ├── Photos/          PhotoKit scan, perceptual hashes, grouping, scan cache (photos and videos)
│   │   ├── Contacts/        duplicate finder, merge planner, vCard backups
│   │   ├── Files/           folder bookmarks, scanner, hasher, deleter
│   │   ├── Protection/      checkup, update catalog, abuse.ch lists, Safari rules, link check
│   │   └── Guides/          guide content, suggestions, progress
│   └── Resources/           asset catalog, privacy manifest
├── ContentBlocker/          Safari content blocker; reads the rules the app saves in the App Group
├── MacCleanerMobileTests/   Swift Testing suites
└── scripts/                 app icon generator
```

The code uses Swift 6 with complete concurrency checking. Each feature has a `@MainActor @Observable`
model; scanning and hashing run off the main actor.

## Privacy

`PrivacyInfo.xcprivacy` declares no tracking and no collected data, and the reasons for the APIs
Apple asks about: UserDefaults (`CA92.1`), file timestamps (`3B52.1`, `C617.1`) and disk space
(`85F4.1`). Photos and Contacts are read only after the system asks for permission, and folders only
after the person picks them.

## Before the App Store

"Mac" is an Apple trademark, and Apple doesn't allow its trademarks in an iOS app's name. Choose
another name for the App Store, and change `INFOPLIST_KEY_CFBundleDisplayName` in `project.yml` to
match.
