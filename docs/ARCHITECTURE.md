# Architecture

Mac Cleaner is a single native macOS app target written in Swift 6 (strict concurrency) and SwiftUI, with no third-party dependencies (the antivirus engine reads ClamAV's databases with its own Swift code). The project is described by `project.yml` ([XcodeGen](https://github.com/yonaskolb/XcodeGen)); the generated `MacCleaner.xcodeproj` is committed so XcodeGen isn't required to build.

```
MacCleaner/
├── App/              App entry (main.swift), scenes, commands, navigation, onboarding, dependency wiring
├── Core/             Everything below the UI — no SwiftUI here
│   ├── FileSystem/   getattrlistbulk reader, parallel walker, scanner, size accounting
│   ├── Cleanup/      SafetyPolicy, CleanupEngine, SafeRemover
│   ├── System/       processes & open files (libproc), code signing, apps, volumes, notifications
│   ├── Models/       DiskUsage, scan models shared by all features, exclusions, path helpers
│   ├── Permissions/  Full Disk Access detection, System Settings links, remembered folders
│   ├── Settings/     SettingsManager (UserDefaults) + value snapshots for background work
│   ├── Logging/      ActivityLogger (os.Logger + rotating JSONL), HistoryStore (restore)
│   └── Utilities/    ProcessRunner, ToolLocator, BackgroundWork, formatting
├── DesignSystem/     Theme, reusable components, the shared cleanup flow and result lists
├── Features/         One folder per screen: service(s) + view model + views
└── Resources/        Asset catalog (app icon, accent color)
MacCleanerTests/      Swift Testing suites (core safety & accounting, features)
Config/               Info.plist additions, entitlements, launchd agent plist
scripts/              typecheck, test harness, icon generator, release pipeline
```

## Layers

1. **Core** is nonisolated, `Sendable` and UI-free, so the background automation agent can use it headlessly.
2. **Features** follow MVVM: a service (`struct`/`actor`) does the work, a `@MainActor @Observable` view model holds state, SwiftUI views render it. Every view model receives `AppServices` (dependency injection — tests substitute temporary stores and policies).
3. **App** creates `AppServices` and the view models once (`AppEnvironment`) and wires navigation between features.

## File system engine

* **`BulkDirectoryReader`** reads whole directories with `getattrlistbulk(2)`: names, types, inode, device, link count, logical and allocated size, BSD flags (hidden, compressed, *dataless*), and APFS clone data (`ATTR_CMNEXT_PRIVATESIZE`, `CLONEID`, `EXT_FLAGS`, `CLONE_REFCNT`). Results were verified field-by-field against `lstat`.
* **`ParallelDirectoryWalker`** runs a work-stealing traversal on dedicated threads (not the Swift concurrency pool, since directory reads block). It never follows symlinks (`O_NOFOLLOW`), stays on one volume, honors exclusions, reports progress, and supports cancellation. On an M4 Pro it reads ~130–160k entries/s (≈1.2 M entries of `~/Library` in 9.5 s).
* **`UsageAccumulator`** de-duplicates storage: hard links count once and are only "reclaimable" when every name is included; APFS clones count their shared blocks once per clone family and their private blocks individually, so reclaimable space is never overstated. On the startup disk the analyzer scans `/System/Volumes/Data` and maps firmlinks back to familiar paths, so nothing is counted twice through `/Users` and `/System/Volumes/Data/Users`.

## Cleanup pipeline

```
scan result ──► CleanupCandidate ──► CleanupFlow (confirm) ──► CleanupEngine (actor)
                                                               │
                         ┌─────────────────────────────────────┘
                         ▼
   for each item:  drop nested duplicates
                   SafetyPolicy.evaluate(path, purpose)      allow-list per purpose + global deny-list
                   FileSnapshot re-check (device + inode)   time-of-check/time-of-use protection
                   open-file / running-executable check     libproc, skipped if in use
                   Trash (FileManager.trashItem) or SafeRemover (fd-relative unlinkat, O_NOFOLLOW_ANY)
                   ──► HistoryStore (restore) + ActivityLogger
```

* **`DeletionPurpose`** (`junk`, `userFile`, `application`, `applicationData`, `privacyData`, `developerData`) decides where an item may be removed and whether it may skip the Trash. Personal files, apps and app settings always go to the Trash.
* **`SafeRemover`** deletes trees through directory file descriptors (`openat`/`unlinkat`) and verifies each directory's inode after opening it, so a folder swapped for a symlink mid-way can't redirect deletion; it never crosses mount points.

## Smart Scan

Each feature can implement `SmartScanProvider`. `SmartScanRunner` runs providers with bounded parallelism and per-area progress; `SmartScanMerger` removes items reported by more than one area (same path or same inode) and excludes nested items from totals, so recoverable space is never double counted.

## Automation

`SMAppService.agent` registers `Config/LaunchAgents/com.maccleaner.MacCleaner.automation.plist`. launchd starts the app's own executable with `--run-automation` about once an hour (and coalesces runs missed during sleep); `main.swift` detects the flag and runs `AutomationRunner` headlessly. It exits immediately unless a schedule, storage threshold or daily junk check is due, pauses in Low Power Mode, and only ever removes `.safe`, regenerable candidates from the categories the person picked. "Notify before cleaning" announces a cleanup and performs it on the next check, so it can be skipped.

## Antivirus

```
ClamAV main/daily (.cvd, .cld) ──► ClamAVContainer: header, MD5 + RSA digital signature, signed .info index
abuse.ch hash lists ─────────────┘          │
                                            ▼
                       AVDatabaseBuilder ──► engine.mcavdb (versioned binary, written to a temp file and renamed)
                                            │
                                 AVEngine.load (memory-mapped)
                                            │
             scanFile(atPath:) ──► file type (magic) ─► hashes (MD5/SHA-1/SHA-256, PE sections, only for sizes that occur)
                                   │                 ─► body signatures: rare-anchor prefilter per target type, then full match
                                   │                 ─► logical signatures: subsignature counts, expressions, PCRE
                                   └─ archives & universal binaries: zip, gzip, tar, crx, fat Mach-O (in memory, with limits)
```

* **Definitions** (`AVDefinitionsUpdater`): ClamAV's own **freshclam** when it's installed, otherwise a built-in updater that behaves like it (DNS TXT version checks, signed incremental CDIFF updates, full downloads at most once a day per file, backoff on 403/429). abuse.ch feeds are downloaded and merged with expiry. A new database is compiled next to the old one and swapped in only when it loads; a database written in an older format (`AVDatabaseFormat.version`) is rebuilt from the downloaded definitions.
* **Scans** (`AVScanService`) enumerate with the Core walker (no symlinks, one volume, exclusions, never opening cloud-only files) and scan on dedicated worker threads. `AVScanPlanner` builds Quick Scan from running programs, launchd jobs, login items, apps, browser extensions and the carrier files in Downloads and Desktop from the last 90 days; quick, Smart Scan and scheduled scans skip Windows and Linux signatures. **Virus Chest** (`AVVirusChest`) moves items with identity re-checks into an obfuscated, 0700 vault; `AVAutoQuarantine` moves only detections backed by signed definitions and never from inside an app bundle.
* **Shields**: `AVFileShield` (FSEvents with debouncing for in-progress downloads) and `AVDownloadOrigin` (where-from metadata against URLhaus/ThreatFox). `AVEngineHolder.shared` lets other features (Guardian, Smart Scan, Automation) scan with the loaded engine.

## Ports & Network

`PortScanEngine` lists listening sockets with `sysctl`/`libproc`, resolves project roots, frameworks, launch origins and auto-start managers, and builds stop plans (`PortKillPlanner`): the root of the launch up to boundary processes (shells, terminals, IDEs, AI agents), its descendants signalled children first, every PID's start time re-checked right before signalling. `NetConnectionScanner` reads every process's sockets for the Connections tab and the Network Shield; `NetChecker` reads Wi-Fi security (CoreWLAN), routes, DNS and proxies (SystemConfiguration) and the ARP cache.

## Guardian

`GuardianController` runs the **Startup Guard** (snapshots of every startup mechanism, diffs, FSEvents on launch agent folders, the "opened at login" analysis from process start times and `lsappinfo`), the **Web Shield** (new browser history rows, read from APFS clones of the databases, matched against `ThreatIntelRegistry`) and posts to `ProtectionEventLog`, the shared activity feed the menu bar shows.

## Menu bar and app lifecycle

`AppEnvironment.shared` is created once and starts the background services at launch (`startBackgroundServices`), also when the app starts at login without a window. `AppPresence` keeps Mac Cleaner in the menu bar when its windows close (the Dock icon hides while no window is open) and brings the main window back from the menu bar, a notification or a Dock click. `AppUpdateController` checks GitHub once a day; `AppUpdateInstaller` verifies the SHA-256 checksum, the code signature (`identifier "com.maccleaner.MacCleaner" and anchor apple generic and certificate leaf[subject.OU] = "244735TY4Y"`) and notarization before swapping the app atomically.

## Concurrency

Swift 6 language mode with complete strict-concurrency checking. View models are `@MainActor`; engines are actors or `Sendable` values; blocking I/O runs on GCD queues via `BackgroundWork` or on walker threads. Long operations are cancellable and report progress.

## Testing

`MacCleanerTests` uses Swift Testing. Destructive code is tested only inside temporary folders: symlink-attack resistance, replaced-item detection, locked files, nested selections, in-use detection with a child process, Trash + restore, policy allow/deny rules, hard-link and clone accounting, walker correctness, and feature parsers (fixtures for launchd plists, appcasts, `simctl`/`docker`/`brew` output, browser databases).
