# Architecture

Mac Cleaner is a single native macOS app target written in Swift 6 (strict concurrency) and SwiftUI, with no third-party dependencies. The project is described by `project.yml` ([XcodeGen](https://github.com/yonaskolb/XcodeGen)); the generated `MacCleaner.xcodeproj` is committed so XcodeGen isn't required to build.

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

## Concurrency

Swift 6 language mode with complete strict-concurrency checking. View models are `@MainActor`; engines are actors or `Sendable` values; blocking I/O runs on GCD queues via `BackgroundWork` or on walker threads. Long operations are cancellable and report progress.

## Testing

`MacCleanerTests` uses Swift Testing. Destructive code is tested only inside temporary folders: symlink-attack resistance, replaced-item detection, locked files, nested selections, in-use detection with a child process, Trash + restore, policy allow/deny rules, hard-link and clone accounting, walker correctness, and feature parsers (fixtures for launchd plists, appcasts, `simctl`/`docker`/`brew` output, browser databases).
