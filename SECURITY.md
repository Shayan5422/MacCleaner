# Security policy

Mac Cleaner removes files, so safety bugs matter more than any other kind.

## Reporting a vulnerability

Please **don't open a public issue** for anything that could cause data loss or let Mac Cleaner remove, read or expose something it shouldn't (for example a path that bypasses the safety policy, a symlink or race-condition issue, or a privacy leak).

Report it privately through [GitHub Security Advisories](https://github.com/Shayan5422/MacCleaner/security/advisories/new). Include the macOS version, the steps to reproduce and, if possible, a minimal folder layout that triggers the problem. You'll get an answer as soon as possible, and a fix will be released before details are made public.

## Scope

* Removal of anything outside the locations allowed by `SafetyPolicy` (see `MacCleaner/Core/Cleanup/SafetyPolicy.swift` and `docs/PERMISSIONS.md`)
* Following symbolic links, crossing volumes, or time-of-check/time-of-use races during cleanup
* Credentials, bookmarks or personal data being modified or exposed
* Anything that weakens macOS protections (Gatekeeper, SIP, TCC, quarantine)
