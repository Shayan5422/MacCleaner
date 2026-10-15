import Foundation
import UserNotifications

/// Posts native notifications and routes clicks back into the app.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationService()

    static let sectionKey = "section"

    /// Called on the main actor when the person clicks a notification that names a section.
    @MainActor var onOpenSection: ((AppSection) -> Void)?

    private var center: UNUserNotificationCenter? {
        // Notification APIs require a real app bundle; unit-test and command-line hosts don't have one.
        Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
    }

    func activate() {
        center?.delegate = self
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func isAuthorized() async -> Bool {
        guard let center else { return false }
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    /// Posts a notification if the person allowed notifications.
    func post(title: String, body: String, identifier: String = UUID().uuidString, section: AppSection? = nil) async {
        guard let center else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let section { content.userInfo = [Self.sectionKey: section.rawValue] }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await center.add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo[Self.sectionKey] as? String,
              let section = AppSection(rawValue: raw) else { return }
        await MainActor.run {
            onOpenSection?(section)
        }
    }
}
