import Foundation

/// Gives Safari its blocking rules: the list the app last built from abuse.ch's feeds (in the shared
/// App Group container), or the small list bundled with the extension until there is one.
final class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    static let appGroup = "group.com.maccleaner.MacCleaner.mobile"
    static let listName = "blockerList.json"

    func beginRequest(with context: NSExtensionContext) {
        let item = NSExtensionItem()
        if let url = Self.listURL(), let attachment = NSItemProvider(contentsOf: url) {
            item.attachments = [attachment]
        }
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }

    /// The app's list when it looks complete, otherwise the bundled one.
    static func listURL() -> URL? {
        if let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(listName), looksComplete(shared) {
            return shared
        }
        return Bundle.main.url(forResource: "blockerList", withExtension: "json")
    }

    /// A JSON array: it starts with "[" and ends with "]". The app writes the list atomically, so
    /// this only has to catch a missing, empty or foreign file, without reading all the rules.
    static func looksComplete(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64), let size = try? handle.seekToEnd(), size >= 2,
              (try? handle.seek(toOffset: size > 64 ? size - 64 : 0)) != nil,
              let tail = try? handle.readToEnd() else { return false }
        return firstVisibleByte(head) == UInt8(ascii: "[") && firstVisibleByte(tail.reversed()) == UInt8(ascii: "]")
    }

    private static func firstVisibleByte<Bytes: Sequence<UInt8>>(_ bytes: Bytes) -> UInt8? {
        bytes.first { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }
    }
}
