import Foundation

/// Gives Safari its blocking rules: the list the app last built from abuse.ch's feeds (in the shared
/// App Group container), or the small list bundled with the extension until then.
final class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    static let appGroup = "group.com.maccleaner.MacCleaner.mobile"

    func beginRequest(with context: NSExtensionContext) {
        let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)?
            .appendingPathComponent("blockerList.json")
        let url = shared.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? Bundle.main.url(forResource: "blockerList", withExtension: "json")
        let item = NSExtensionItem()
        if let url, let attachment = NSItemProvider(contentsOf: url) {
            item.attachments = [attachment]
        }
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }
}
