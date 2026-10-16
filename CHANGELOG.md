# Changelog

All notable changes to Mac Cleaner are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [2.0.0] — 2026-10-16

Mac Cleaner becomes the assistant that watches over your Mac: an antivirus with free, self-updating virus definitions, real-time shields, PortPilot's port manager, a startup guard and a menu bar hub that keeps running when the window is closed.

### Added
- **Antivirus** with Mac Cleaner's own scanning engine for the free **ClamAV® signature databases** (about 3.6 million signatures: file hashes, body and logical signatures, PE section hashes) plus **abuse.ch MalwareBazaar** hashes.
  - Quick, Full and custom scans (files, folders, external drives, drag and drop), inside zip, gzip, tar and universal binaries, without ever downloading cloud-only files.
  - **Quick Scan** checks running programs, startup items, apps, browser extensions and what arrived in Downloads and Desktop in the last 90 days, for Mac threats. Full, custom and drive scans check everything, including Windows and Linux threats.
  - Definitions verified with ClamAV's digital signatures before they're used, and updated automatically through ClamAV's own **freshclam** when it's installed (one click with Homebrew) or a built-in updater that follows ClamAV's rules (incremental CDIFF updates, rate limits).
  - **Virus Chest**: threats are moved into a locked, obfuscated vault where they can't run, and can be restored or deleted. Only threats identified by ClamAV's signed definitions are moved automatically, never from inside an app; other matches wait for your decision.
  - **File Shield** scans new and changed files in Downloads, Desktop, Documents, the Applications folders and launch agent folders as they appear. **Download Shield** also checks where a download came from against abuse.ch URLhaus and ThreatFox.
  - Scan history, "Test Protection" with the EICAR test file, a Virus Scan area in Smart Scan, and an optional quick scan and definitions update with each scheduled automation run.
- **Web Shield** warns within a minute when a browser opens a site that abuse.ch lists for spreading malware (Safari, Chrome, Edge, Brave, Arc, Vivaldi, Opera, Firefox). History stays on your Mac; only matches are kept.
- **Ports & Network**, from PortPilot:
  - every listening port grouped by project, with framework, launch origin, auto-start manager and resource use;
  - find what uses a port, and a safe Stop that never touches your terminal, editor or other users' processes;
  - Stop & Disable Auto-Start for launchd, pm2 and Docker; Recently Stopped with Relaunch.
  - **Connections** shows every process's network connections and flags known malicious servers (abuse.ch ThreatFox), with a background **Network Shield**.
  - **Network Check** reviews Wi-Fi security, router, DNS, proxies, the firewall, services exposed to the network and devices on your network.
- **Startup Guard** on the Startup Items page:
  - **Opened at Login**: what opened automatically at your last login and why (login items, launch agents, background items apps registered with macOS, apps reopened at login), with a way to stop each;
  - **Changes**: a timeline of startup items that were added, removed or changed, with a notification and an antivirus scan for new ones;
  - **Background Items**: every way software starts automatically, including Background Task Management items, extensions, plug-ins, cron and hooks.
- **Menu bar hub**: Mac Cleaner stays in the menu bar when you close its window, with protection status, open ports with Stop, disk and CPU, Smart Scan, updates and an **Activity** feed of everything it noticed. The menu bar item can show open ports, CPU or free space, and turns red when threats are found. Optional Open at Login.
- **Mac Cleaner updates**: a daily check for new versions on GitHub; "Download & Install" verifies the SHA-256 checksum, the Developer ID signature and notarization before replacing the app, and rolls back on any failure.
- **About** window with the author's website, GitHub and LinkedIn, project links and acknowledgements.

### Changed
- **Updates** page redesigned: grouped sections, short versions with "4.3.6 → 5.1.1", one clear action per app, release notes inline, Update All, and no horizontal scrolling.
- Equal-height, full-width summary tiles and balanced card grids on every page; short versions in the Uninstaller; a cleaner Security page that points to the Antivirus.
- The sidebar has a new **Protection** group (Antivirus, Security, Ports & Network); Automation and History moved under System.

### Fixed
- The live CPU and memory gauges on the Dashboard and Performance pages animated every update, and each animation frame laid out the whole page again: an open Dashboard used about 20% CPU. It now uses about 2%.
- Files that Spotlight, Quick Look or XProtect were only reading for a moment (for example a freshly downloaded app being indexed) were skipped as "in use" during cleanup.
- Counts of one read correctly ("1 file", "1 folder couldn't be read") throughout the app.

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
