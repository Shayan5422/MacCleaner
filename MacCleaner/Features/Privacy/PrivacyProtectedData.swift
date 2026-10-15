import Foundation

/// The Privacy cleaner's own deny-list, checked when results are built and again
/// right before cleaning, in addition to `SafetyPolicy`.
///
/// Credentials, bookmarks, autofill, payment data, browser settings and extension
/// data are never removed, even if a scan result somehow pointed at them.
enum PrivacyProtectedData {
    /// Exact file or folder names that are never removed.
    static let protectedNames: Set<String> = [
        // Chromium family
        "Login Data", "Login Data For Account", "Web Data", "Account Web Data", "Bookmarks", "Bookmarks.bak",
        "Favicons", "Local State", "Preferences", "Secure Preferences", "Affiliation Database", "Sync Data",
        "trusted_vault.pb", "passkey_enclave_state", "Extension Cookies", "power_bookmarks",
        // Firefox
        "logins.json", "logins-backup.json", "key3.db", "key4.db", "cert8.db", "cert9.db", "pkcs11.txt",
        "signons.sqlite", "places.sqlite", "favicons.sqlite", "formhistory.sqlite", "prefs.js", "user.js",
        "permissions.sqlite", "handlers.json", "extensions.json", "extension-preferences.json",
        "extension-settings.json", "containers.json", "search.json.mozlz4", "profiles.ini", "installs.ini",
        "compatibility.ini", "times.json", "addons.json", "autofill-profiles.json", "credentialstate.sqlite",
        // Safari
        "Bookmarks.plist", "Form Values", "CloudTabs.db", "PasswordBreachStore.plist", "UserMediaPermissions.plist",
        "Keychains",
    ]

    /// Name prefixes that cover a protected file together with its companions
    /// ("Login Data-journal", "places.sqlite-wal", "key4.db-journal"...).
    static let protectedNamePrefixes: [String] = [
        "Login Data", "Web Data", "Account Web Data", "Bookmarks", "Favicons", "Affiliation Database",
        "logins", "signons", "key3.db", "key4.db", "cert8.db", "cert9.db", "places.sqlite", "favicons.sqlite",
        "formhistory.sqlite", "permissions.sqlite", "credentialstate.sqlite", "Extension Cookies", "CloudTabs.db",
    ]

    /// Folders whose contents are never removed, wherever they appear in a path.
    static let protectedFolderNames: Set<String> = [
        "Keychains", "Extensions", "Local Extension Settings", "Sync Extension Settings",
        "Managed Extension Settings", "Extension State", "Extension Rules", "Extension Scripts", "Sync Data",
        "permanent", "Safari Extensions", "Web Extensions",
    ]

    /// Why `path` must never be removed by the Privacy cleaner, or nil if it may be.
    static func denyReason(for path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard let name = components.last, !name.isEmpty else { return "The path is empty." }

        for component in components.dropLast() where protectedFolderNames.contains(component) {
            return "Items inside “\(component)” hold extensions, settings or credentials and are never removed."
        }
        for component in components where component.hasPrefix("chrome-extension") || component.hasPrefix("moz-extension") {
            return "Data that belongs to a browser extension is never removed."
        }
        if protectedNames.contains(name) || protectedFolderNames.contains(name) {
            return "“\(name)” can hold passwords, bookmarks, autofill or settings, so it is never removed."
        }
        if protectedNamePrefixes.contains(where: { name.hasPrefix($0) }) {
            return "“\(name)” belongs to a password, bookmark or settings database, so it is never removed."
        }
        let lowercased = name.lowercased()
        if lowercased.hasSuffix(".keychain") || lowercased.hasSuffix(".keychain-db") {
            return "Keychains are never removed."
        }
        return nil
    }

    static func isProtected(_ path: String) -> Bool {
        denyReason(for: path) != nil
    }
}
