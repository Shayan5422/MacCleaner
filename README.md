<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Mac Cleaner icon">
</p>

<h1 align="center">Mac Cleaner</h1>

<p align="center">
  <strong>A fast, honest, native cleaner and system manager for macOS.</strong><br>
  No subscription. No account. No tracking. Everything stays on your Mac.
</p>

<p align="center">
  <a href="https://github.com/Shayan5422/MacCleaner/releases/latest"><img src="https://img.shields.io/github/v/release/Shayan5422/MacCleaner?label=download&color=6c5ce7" alt="Latest release"></a>
  <a href="https://github.com/Shayan5422/MacCleaner/actions/workflows/ci.yml"><img src="https://github.com/Shayan5422/MacCleaner/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI status"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Apple%20silicon%20%26%20Intel-native-black" alt="Universal">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
  <img src="https://img.shields.io/badge/dependencies-none-success" alt="No dependencies">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-lightgrey" alt="MIT License"></a>
</p>

<p align="center">
  <img src="docs/images/dashboard.png" alt="Mac Cleaner dashboard" width="900">
</p>

Mac Cleaner brings together what premium Mac cleaners do — junk cleanup, a complete uninstaller, storage visualization, duplicate finding, startup and performance management, security and privacy checks, developer cleanup and automation — in one native SwiftUI app. It's built around one rule: **your data is safer than any amount of free space.** You review everything before it's removed, personal files go to the Trash, and every cleanup can be undone.

## Features

| | |
|---|---|
| ✨ **Smart Scan** | One scan across junk, leftovers, large files, duplicates, startup items, security, privacy and developer caches. Items found by several checks are counted once. |
| 🧹 **System Junk** | App and macOS caches, temporary files, logs, crash reports, Xcode build data, device firmware, Mail attachment copies, installers and old downloads — each with what it is and what removing it means. |
| 🗑 **Uninstaller** | Removes apps with their preferences, caches, containers and support files. Conservative matching protects shared vendor data; running apps are detected; leftovers of already-deleted apps are found. |
| 📊 **Storage Analyzer** | Interactive treemap and sunburst, largest and oldest files, categories, Quick Look, search, Trash and "Move to…", external drives. APFS clones and hard links are never counted twice. |
| 🪞 **Duplicate Finder** | Exact duplicates by size → partial hash → SHA-256, plus visually similar photos with Apple Vision (never auto-selected). Hard links aren't treated as copies. |
| ⏻ **Startup Items** | Login items, your launch agents (enable/disable via `launchctl`), app background items and system-wide items, with developer, status and resource use. |
| 📈 **Performance** | Live CPU (per core), memory pressure and composition, swap, disk and network throughput, battery health, thermal state and top processes. Optional menu bar monitor and alerts. |
| 🛡 **Security** | Gatekeeper, SIP, FileVault, firewall and XProtect status, persistence locations, code signatures, quarantined downloads and known adware rules — threats, suspicious items and information clearly separated. |
| ✋ **Privacy** | Caches, history, cookies, website data and sessions for Safari, Chrome, Edge, Brave, Arc, Vivaldi, Opera and Firefox; recent items; download history. Passwords and bookmarks are never touched. |
| ☁️ **Cloud Storage** | iCloud Drive, Google Drive, Dropbox and OneDrive: what's stored locally vs. in the cloud, and "Remove Download" that keeps files in the cloud. |
| ⬇️ **Updates** | App versions with real update information from Sparkle feeds, the App Store and Homebrew — only when you ask. |
| 🔨 **Developer Tools** | Xcode DerivedData, archives, device support, simulators, Homebrew, npm, pnpm, Yarn, pip, uv, Docker, Gradle, Maven — using the tools' official commands where they exist. |
| ⏰ **Automation** | Daily, weekly or monthly cleaning, low-storage triggers, junk alerts, dry runs and a heads-up before cleaning. Only regenerable data is ever cleaned automatically. |
| ↩️ **History & Undo** | Every cleanup is recorded; anything moved to the Trash can be put back. |

## Screenshots

<table>
  <tr>
    <td><img src="docs/images/smart-scan.png" alt="Smart Scan results"></td>
    <td><img src="docs/images/system-junk.png" alt="System Junk"></td>
  </tr>
  <tr>
    <td><img src="docs/images/storage-dark.png" alt="Storage Analyzer with treemap (dark appearance)"></td>
    <td><img src="docs/images/performance-dark.png" alt="Performance monitor (dark appearance)"></td>
  </tr>
  <tr>
    <td><img src="docs/images/uninstaller.png" alt="Uninstaller"></td>
    <td><img src="docs/images/duplicates.png" alt="Duplicate Finder"></td>
  </tr>
  <tr>
    <td><img src="docs/images/security.png" alt="Security"></td>
    <td><img src="docs/images/privacy.png" alt="Privacy cleaner"></td>
  </tr>
  <tr>
    <td><img src="docs/images/developer.png" alt="Developer Tools"></td>
    <td><img src="docs/images/startup.png" alt="Startup Items"></td>
  </tr>
</table>

<p align="center"><img src="docs/images/dashboard-dark.png" alt="Dashboard in dark appearance" width="900"></p>

## Safety first

* **Nothing is removed without your review.** Results explain what each item is and what happens if it's removed. Only data apps regenerate automatically is pre-selected.
* **Personal files, apps and app settings always go to the Trash**, and **History** can put them back.
* **Built-in protection rules** refuse to touch macOS, your Documents/Desktop/Photos, keychains, Mail, Messages, cloud folders, browser passwords and bookmarks — checked again immediately before every removal.
* **Race-safe deletion:** each item is re-identified (device + inode) right before removal, paths through symbolic links are refused, and folders are deleted through file descriptors so a swapped-in symlink can't redirect deletion.
* **Items open in running apps are skipped.**
* **No fake optimizations:** no "RAM cleaners", no invented health scores, no fabricated results. When macOS doesn't allow something, Mac Cleaner says so and points you to the right setting.

See [docs/PERMISSIONS.md](docs/PERMISSIONS.md) for every permission, what is never removed, and the macOS limitations the app works within.

## Install

1. Download **Mac-Cleaner-x.y.z.dmg** from the [latest release](https://github.com/Shayan5422/MacCleaner/releases/latest).
2. Open it and drag **Mac Cleaner** to **Applications**.
3. *(Recommended)* Give it **Full Disk Access** in System Settings › Privacy & Security, so scans can include app containers, Safari data, Mail and the Trash. The app works without it and tells you what it couldn't check.

Requires macOS 14 Sonoma or later; universal for Apple silicon and Intel. Releases are signed with Developer ID and notarized by Apple. Developed and tested on macOS 27 (Apple M4 Pro).

## Build from source

```bash
git clone https://github.com/Shayan5422/MacCleaner.git
cd MacCleaner
open MacCleaner.xcodeproj   # then press ⌘R
```

Built with Xcode 27 (Swift 6, strict concurrency). Run the 400+ tests with:

```bash
xcodebuild -project MacCleaner.xcodeproj -scheme MacCleaner -destination 'platform=macOS' test
```

Signing, notarization and the release pipeline are described in [docs/RELEASING.md](docs/RELEASING.md); the code structure in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Privacy

Mac Cleaner has no analytics, no telemetry and no accounts. Scanning and cleaning work completely offline. The only network requests are update checks for your apps, made when you click "Check for Updates" (and can be disabled). The activity log stays on your Mac and records operations, never file contents.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘1 … ⌘0 | Dashboard, Smart Scan, System Junk, Storage, Duplicates, Uninstaller, Performance, Security, Privacy, Developer Tools |
| ⇧⌘S | Start Smart Scan |
| ⌘R | Scan / scan again on the current page |
| ⌘↩ | Clean the selection |
| ⌘[ | Back |
| ⌘, | Settings |

## License

Mac Cleaner is available under the [MIT License](LICENSE).
