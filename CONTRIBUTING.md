# Contributing

Thanks for helping improve Mac Cleaner!

* **Safety first.** Every change that removes files must go through `CleanupEngine` with the right `DeletionPurpose`, and new locations need matching rules in `SafetyPolicy` plus tests that run only inside temporary folders.
* **No fake features.** Don't add estimates, scores or "optimizations" that aren't backed by real measurements or real effects. If macOS doesn't allow something, explain the limitation in the UI.
* **Code style.** Swift 6 with strict concurrency and zero warnings. View models are `@MainActor @Observable`; blocking work runs off the main thread and off the Swift concurrency pool (`BackgroundWork`, the directory walker).
* **Project file.** `project.yml` is the source of truth — run `xcodegen generate` after adding or removing files.
* **Tests.** `xcodebuild -project MacCleaner.xcodeproj -scheme MacCleaner -destination 'platform=macOS' test` must pass.

Please describe what you changed and how you tested it in the pull request.
