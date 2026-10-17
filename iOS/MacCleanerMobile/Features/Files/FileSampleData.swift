#if DEBUG
import Foundation

/// Debug builds launched with `-seedSampleFiles` get a "Sample Files" folder in the app's Documents with a large file,
/// an old file, duplicates and empty folders, added to the folder list, so the Files page can be checked on a simulator.
/// Never compiled into release builds.
enum FileSampleData {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-seedSampleFiles") }

    /// The sample folder, created the first time; nil when not requested or already in place.
    @concurrent
    static func createIfRequested() async -> URL? {
        guard isRequested, let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let root = documents.appendingPathComponent("Sample Files", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: root.path) else { return nil }
        do {
            try create(in: root)
            return root
        } catch {
            print("Sample files weren't created: \(error)")
            return nil
        }
    }

    private static func create(in root: URL) throws {
        let fileManager = FileManager.default
        func folder(_ path: String) throws -> URL {
            let url = root.appendingPathComponent(path, isDirectory: true)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func write(_ data: Data, to path: String, modified: Date? = nil) throws {
            let url = root.appendingPathComponent(path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            if let modified { try fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        }
        func bytes(_ count: Int, seed: UInt8) -> Data {
            let block = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
            var data = Data(capacity: count)
            while data.count < count { data.append(block.prefix(count - data.count)) }
            return data
        }

        let twoYearsAgo = Calendar.current.date(byAdding: .year, value: -2, to: Date()) ?? Date()
        let scan = bytes(420_000, seed: 7)
        let photo = bytes(1_600_000, seed: 3)
        try write(bytes(72_000_000, seed: 1), to: "Videos/Holiday 2024.mov")
        try write(bytes(55_000_000, seed: 2), to: "Downloads/Xcode Sample.zip", modified: twoYearsAgo)
        try write(bytes(3_200_000, seed: 4), to: "Documents/Tax Return 2022.pdf", modified: twoYearsAgo)
        try write(scan, to: "Documents/Lease Scan.pdf")
        try write(scan, to: "Downloads/Lease Scan.pdf")
        try write(photo, to: "Photos/Beach.jpg")
        try write(photo, to: "Photos/Beach copy.jpg")
        try write(photo, to: "Downloads/Beach.jpg")
        try write(bytes(420_000, seed: 9), to: "Documents/Notes.pdf")
        _ = try folder("Projects/Old Drafts")
        _ = try folder("Empty Folder")
        try write(Data("keep".utf8), to: "Projects/Hidden Only/.keep")
    }
}
#endif
