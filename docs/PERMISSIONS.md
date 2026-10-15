# Permissions, entitlements and macOS limitations

Mac Cleaner is built to work *with* macOS security, never around it. This page lists every permission the app may ask for, why, what happens without it, and the platform limits that shaped its features.

## Distribution model

| | |
|---|---|
| Distribution | Developer ID (outside the Mac App Store), notarized by Apple |
| App Sandbox | **Off** — a disk cleaner has to read your whole home folder (with your approval). In the sandbox, every folder would have to be picked by hand and most cleaning features would be impossible. |
| Hardened Runtime | **On** (required for notarization) |
| Entitlements | `com.apple.security.automation.apple-events` — only to ask System Events for your login items when you open Startup Items |
| SIP | Never needs to be disabled. Protected system locations are never touched. |
| Network | Not needed for any core feature. Only "Check for Updates" contacts app update feeds and the App Store lookup API, when you click it (can be turned off in Settings). |

## Privacy permissions (TCC)

| Permission | Used for | Without it |
|---|---|---|
| **Full Disk Access** | Measuring and cleaning protected locations: app containers (`~/Library/Containers`), Safari history/cookies, Mail attachment copies, the Trash size, some logs | These items are skipped. Scans show a banner and count folders that couldn't be read — nothing is estimated. |
| **App Management** (macOS 13+) | Moving other apps to the Trash in the Uninstaller | macOS blocks the move; Mac Cleaner explains how to allow it or to drag the app to the Trash in Finder. |
| **Automation → System Events** | Listing and removing "Open at Login" items | Login items can't be listed; a button opens System Settings › General › Login Items instead. |
| **Notifications** | Automation results, security-scan alerts, performance alerts you enable | Everything still works; you just aren't notified. |
| **Login Items & Extensions** (background item) | The automation agent registered with `SMAppService` | Automatic cleaning stays off; macOS shows the item so you can turn it off at any time. |

Mac Cleaner detects Full Disk Access by attempting to **open** (never read) a file that macOS protects behind it, and offers the exact System Settings pane.

## What is never removed

Enforced by `SafetyPolicy` immediately before every removal, after re-checking that the item is still the one that was scanned:

- macOS itself: `/System`, `/usr`, `/bin`, `/sbin`, `/private/etc`, `/private/var/db`, system volumes, SIP-protected (`SF_RESTRICTED`) or locked items
- Your home folder's top-level folders (Desktop, Documents, Downloads, Library…) and Library's top-level folders themselves
- Keychains, Mail, Messages, Photos libraries, Calendars, Contacts, iCloud Drive and other cloud folders
- Passwords, bookmarks and keys: `Login Data`, `Web Data`, `Bookmarks`, `logins.json`, `key4.db`, `places.sqlite`, `*.keychain-db`, browser `Local State`
- Anything reached through a symbolic link in its path, or anything that changed since it was scanned
- Items open in a running app (detected with `libproc`), unless you turn that check off
- Mac Cleaner's own files

Personal files, apps and app settings always go to the **Trash** and can be restored from **History**. Only regenerable data (caches, logs, temporary files, developer caches) can optionally be deleted immediately.

## macOS limitations (and what Mac Cleaner does instead)

| Limitation | Approach |
|---|---|
| CPU/GPU temperatures have no public API on Apple silicon | Shown as "not available through public APIs". Thermal *state* (`ProcessInfo.thermalState`) and battery temperature (IORegistry) are shown. |
| Other users' and root processes can't be inspected without privileges | Their resource usage is shown as unavailable; they're never offered for quitting. |
| Background items registered by other apps with `SMAppService` can't be queried or toggled | Listed as "managed by the app"; a button opens System Settings › Login Items. |
| System-wide launch daemons/agents (`/Library/Launch*`) need an administrator | Shown read-only with guidance. |
| Items in `/Library` belonging to an app usually need an administrator | Included in uninstall previews; if removal fails, Mac Cleaner explains how to remove them in Finder (which asks for your password). |
| Removing a cloud file's local copy for third-party File Provider domains | Uses `evictUbiquitousItem`; if the provider refuses, explains how to use Finder's "Remove Download". Cloud files are never deleted. |
| Access times are updated lazily on APFS | "Last opened" dates are labeled approximate. |
| APFS local snapshots hold space that isn't in any folder | Listed (read-only, `tmutil listlocalsnapshots`) and explained as "space not in scanned files". |
| Mac App Store apps can't be updated by third-party apps | Mac Cleaner links to the App Store page. Sparkle apps are opened so they can update themselves; Homebrew casks show the `brew upgrade` command. |
| macOS doesn't provide malware signatures to apps | Security checks persistence locations, code signatures, Gatekeeper status, quarantined downloads and a conservative adware rule list. It is **not** an antivirus; XProtect provides the built-in protection. |
| "Free RAM" buttons can't improve performance on macOS | Not implemented on purpose. Memory pressure, swap and heavy processes are shown with honest explanations. |
