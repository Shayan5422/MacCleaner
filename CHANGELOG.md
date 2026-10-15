# Changelog

All notable changes to Mac Cleaner are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [1.0.0] — 2026-10-15

First public release.

### Added
- **Smart Scan** that combines junk, app leftovers, large and old files, exact duplicates, startup items, security checks, privacy data and developer caches, counting every item once.
- **System Junk**: application and macOS caches, temporary files, logs, crash reports, Xcode build data, saved window states, device firmware, Mail attachment copies, installers and old downloads — each with an explanation of what removing it means.
- **Uninstaller** that finds an app's preferences, caches, containers, logs and support files with conservative matching, protects shared vendor data, detects running apps, and finds leftovers of apps you already removed.
- **Storage Analyzer** with interactive treemap and sunburst charts, large/old file lists, categories, Quick Look, search, Trash and "Move to…", including external drives. Hard links and APFS clones are never counted twice.
- **Duplicate Finder** using size, partial and full SHA-256 hashing, plus visually similar photos (Apple Vision) that are never selected automatically.
- **Startup Items** manager for login items, your launch agents (enable/disable with launchctl), app background items and system-wide items (read-only).
- **Performance** monitor: CPU (per core), memory composition and pressure, swap, disk and network throughput, battery health, thermal state and top processes, with an optional menu bar monitor and alerts.
- **Optimization** recommendations for memory-heavy and CPU-hungry apps with safe Quit actions — and no fake "RAM cleaning".
- **Security** checks: Gatekeeper, SIP, FileVault, firewall, XProtect, persistence locations, code signatures, quarantined downloads and a conservative adware rule list, clearly separating threats, suspicious items and information.
- **Privacy** cleaner for Safari, Chrome, Edge, Brave, Arc, Vivaldi, Opera and Firefox (caches, history, cookies, website data, sessions), recent items and the system download history — never passwords or bookmarks.
- **Cloud Storage** analysis for iCloud Drive, Google Drive, Dropbox and OneDrive with "Remove Download" that keeps files in the cloud.
- **Updates** for installed apps via Sparkle feeds, the App Store and Homebrew casks (opt-in, only when you ask).
- **Developer Tools** cleanup for Xcode, simulators, Homebrew, npm, pnpm, Yarn, pip, uv, Docker, Gradle, Maven and more, using official commands where they exist.
- **Automation** with daily/weekly/monthly schedules, low-storage triggers, junk alerts, dry runs, notify-before-cleaning and run history, using an `SMAppService` background agent.
- **History & Undo**: every cleanup is recorded and items moved to the Trash can be restored.
- Light and dark appearance, keyboard shortcuts, search, context menus and native notifications.
