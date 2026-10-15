import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Kinds of data the Storage Analyzer groups files into.
///
/// Classification uses the file extension: a fixed table for common types (so
/// results don't depend on which apps are installed), then `UTType`
/// conformance for everything else. Folder context refines it, for example
/// everything inside an iOS device backup counts as a backup.
enum StorageCategory: UInt8, CaseIterable, Sendable, Identifiable, Hashable, Comparable {
    case videos, audio, images, archives, diskImages, backups, applications, documents, developer, other

    var id: UInt8 { rawValue }

    static func < (lhs: StorageCategory, rhs: StorageCategory) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .videos: return "Videos"
        case .audio: return "Audio"
        case .images: return "Images"
        case .archives: return "Archives"
        case .diskImages: return "Disk Images & Installers"
        case .backups: return "Backups"
        case .applications: return "Applications"
        case .documents: return "Documents"
        case .developer: return "Developer"
        case .other: return "Other"
        }
    }

    /// Name of one item of this kind ("Video · last opened 8 months ago").
    var singularTitle: String {
        switch self {
        case .videos: return "Video"
        case .audio: return "Audio"
        case .images: return "Image"
        case .archives: return "Archive"
        case .diskImages: return "Disk image or installer"
        case .backups: return "Backup"
        case .applications: return "Application"
        case .documents: return "Document"
        case .developer: return "Developer file"
        case .other: return "File"
        }
    }

    var symbolName: String {
        switch self {
        case .videos: return "film"
        case .audio: return "music.note"
        case .images: return "photo"
        case .archives: return "archivebox"
        case .diskImages: return "opticaldiscdrive"
        case .backups: return "clock.arrow.circlepath"
        case .applications: return "app.badge"
        case .documents: return "doc.text"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .other: return "doc"
        }
    }

    /// Stable chart color, shared by the treemap, sunburst, legends and lists.
    var color: Color {
        switch self {
        case .videos: return ChartPalette.color(at: 3)
        case .audio: return ChartPalette.color(at: 4)
        case .images: return ChartPalette.color(at: 1)
        case .archives: return ChartPalette.color(at: 2)
        case .diskImages: return ChartPalette.color(at: 6)
        case .backups: return ChartPalette.color(at: 5)
        case .applications: return ChartPalette.color(at: 0)
        case .documents: return ChartPalette.color(at: 8)
        case .developer: return ChartPalette.color(at: 9)
        case .other: return ChartPalette.color(at: 7)
        }
    }

    /// Short advice shown with insights about this kind of data.
    var advice: String {
        switch self {
        case .videos: return "Videos are often the largest personal files. Move ones you want to keep to an external drive."
        case .audio: return "Audio libraries and recordings can grow quietly over time."
        case .images: return "Photos and image exports. Photos libraries are managed by the Photos app."
        case .archives: return "Archives are often downloaded once and extracted. Keep them only if you still need the original."
        case .diskImages: return "Installers and disk images are usually not needed after the app is installed."
        case .backups: return "Device and app backups. Manage iPhone and iPad backups in Finder › your device › Manage Backups."
        case .applications: return "Use the Uninstaller to remove apps together with their support files."
        case .documents: return "Documents, PDFs, spreadsheets and presentations."
        case .developer: return "Source code, build products and package caches. Developer Tools can clean regenerable caches."
        case .other: return "Files that don't belong to one of the other kinds."
        }
    }

    // MARK: - Classification

    /// Classifies a regular file by its name. `logicalSize` resolves ambiguous
    /// extensions (a large `.ts` file is a video, a small one TypeScript source).
    static func classify(fileName: String, logicalSize: Int64 = 0) -> StorageCategory {
        guard let ext = lowercasedExtension(of: fileName) else { return .other }
        switch ext {
        case "ts", "mts":
            return logicalSize >= 20_000_000 ? .videos : .developer
        case "raw":
            // Camera RAW photos are tens of megabytes; multi-gigabyte .raw files are VM disk images (Docker.raw).
            return logicalSize >= 1_000_000_000 ? .diskImages : .images
        default:
            break
        }
        if let known = extensionTable[ext] { return known }
        return UTTypeCategoryCache.shared.category(forExtension: ext)
    }

    /// Category of a package (a folder Finder shows as a single file).
    static func packageCategory(name: String) -> StorageCategory {
        guard let ext = lowercasedExtension(of: name) else { return .other }
        if let known = packageTable[ext] { return known }
        return .other
    }

    /// Lowercased extension without the dot, or nil when there is none.
    static func lowercasedExtension(of name: String) -> String? {
        let utf8 = name.utf8
        guard let dot = utf8.lastIndex(of: UInt8(ascii: ".")), dot != utf8.startIndex else { return nil }
        let start = utf8.index(after: dot)
        guard start != utf8.endIndex, utf8.distance(from: start, to: utf8.endIndex) <= 24 else { return nil }
        let ext = String(name[start...])
        // Fast path: most extensions are already lowercase ASCII.
        if ext.utf8.allSatisfy({ !($0 >= 65 && $0 <= 90) }) { return ext }
        return ext.lowercased()
    }

    static let extensionTable: [String: StorageCategory] = {
        var table: [String: StorageCategory] = [:]
        func add(_ category: StorageCategory, _ extensions: [String]) {
            for ext in extensions { table[ext] = category }
        }
        add(.videos, [
            "mp4", "m4v", "mov", "qt", "avi", "mkv", "wmv", "flv", "f4v", "webm", "mpg", "mpeg", "m2v", "mpe",
            "3gp", "3g2", "m2ts", "vob", "ogv", "divx", "xvid", "rm", "rmvb", "asf", "dv", "braw", "r3d",
            "mxf", "hevc", "h264", "h265", "insv", "lrv", "prproj",
        ])
        add(.audio, [
            "mp3", "m4a", "m4b", "m4p", "m4r", "aac", "wav", "wave", "aif", "aiff", "aifc", "flac", "alac",
            "ogg", "oga", "opus", "wma", "caf", "mid", "midi", "ape", "dsf", "dff", "wv", "amr", "au", "snd",
            "ac3", "dts", "mka", "aup3", "sesx",
        ])
        add(.images, [
            "jpg", "jpeg", "jpe", "jfif", "png", "gif", "heic", "heif", "hif", "tif", "tiff", "bmp", "webp",
            "avif", "jxl", "ico", "icns", "svg", "eps", "psd", "psb", "ai", "xcf", "exr", "hdr", "tga", "dds",
            "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "dng", "orf", "rw2", "raf", "srw", "pef",
            "x3f", "erf", "3fr", "kdc", "mrw", "iiq", "jp2", "j2k", "pict", "pct", "afphoto", "afdesign", "kra",
            "procreate", "clip", "pxm", "pxd", "sketch", "fig", "xd", "blend", "usdz", "obj", "fbx", "stl",
        ])
        add(.archives, [
            "zip", "zipx", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "lz", "lzma",
            "tlz", "zst", "tzst", "z", "lz4", "cpio", "sit", "sitx", "cab", "arj", "lzh", "lha", "ace", "aar",
        ])
        add(.diskImages, [
            "dmg", "iso", "img", "toast", "cdr", "sparseimage", "sparsebundle", "dmgpart", "pkg", "mpkg", "xip",
            "vmdk", "vdi", "vhd", "vhdx", "qcow2", "qcow", "hdd", "hds", "ipsw", "exe", "msi", "msix",
            "appimage", "deb", "rpm", "apk", "aab", "ipa", "nrg", "mdf", "mds", "wim", "esd", "ova", "ovf",
        ])
        add(.backups, [
            "bak", "backup", "bkp", "bck", "abbu", "backupbundle", "gho", "tib", "vbk", "nbu", "wbcat",
        ])
        add(.applications, ["app", "appex", "prefpane", "saver", "qlgenerator", "mdimporter", "plugin"])
        add(.documents, [
            "pdf", "doc", "docx", "docm", "dot", "dotx", "xls", "xlsx", "xlsm", "xlsb", "ppt", "pptx", "pptm",
            "pps", "ppsx", "key", "pages", "numbers", "odt", "ods", "odp", "odg", "rtf", "rtfd", "txt", "text",
            "md", "markdown", "csv", "tsv", "epub", "mobi", "azw", "azw3", "ibooks", "djvu", "cbz", "cbr", "tex",
            "bib", "eml", "emlx", "mbox", "msg", "vcf", "ics", "indd", "idml", "vsd", "vsdx", "xps", "oxps",
            "fb2", "chm", "html", "htm", "webarchive", "one", "gdoc", "gsheet", "gslides",
        ])
        add(.developer, [
            "swift", "m", "mm", "h", "hh", "hpp", "hxx", "c", "cc", "cpp", "cxx", "inl", "s", "asm", "py", "pyc",
            "pyo", "pyd", "ipynb", "js", "mjs", "cjs", "jsx", "tsx", "vue", "svelte", "java", "class", "jar",
            "war", "ear", "kt", "kts", "scala", "groovy", "gradle", "go", "rs", "rb", "gem", "php", "cs", "fs",
            "vb", "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd", "pl", "pm", "lua", "r", "dart", "ex", "exs",
            "erl", "hrl", "hs", "elm", "clj", "cljs", "sql", "graphql", "proto", "json", "jsonl", "yaml", "yml",
            "toml", "ini", "cfg", "conf", "xml", "lock", "o", "a", "so", "dylib", "tbd", "swiftmodule",
            "swiftinterface", "swiftdoc", "swiftsourceinfo", "pcm", "pch", "modulemap", "d", "dia", "xib",
            "nib", "storyboard", "pbxproj", "xcconfig", "xcscheme", "entitlements", "wasm", "map", "whl", "egg",
            "node", "pdb", "lib", "dll", "ninja", "cmake", "mk", "tf", "tfstate", "hcl", "bzl", "csproj", "sln",
            "mlmodel", "onnx", "pt", "pth", "safetensors", "gguf", "ckpt", "h5", "tflite", "npy", "npz",
            "parquet", "arrow", "feather", "pkl", "pickle", "xcresult", "ipa-symbols", "dsym", "hmap",
        ])
        return table
    }()

    static let packageTable: [String: StorageCategory] = {
        var table: [String: StorageCategory] = [:]
        func add(_ category: StorageCategory, _ extensions: [String]) {
            for ext in extensions { table[ext] = category }
        }
        add(.applications, [
            "app", "appex", "bundle", "plugin", "kext", "xpc", "qlgenerator", "mdimporter", "prefpane", "saver",
            "wdgt", "component", "vst", "vst3", "aaxplugin", "action", "workflow", "scptd",
        ])
        add(.images, ["photoslibrary", "photolibrary", "aplibrary", "migratedphotolibrary", "icon", "sketch", "lrdata"])
        add(.audio, ["musiclibrary", "band", "logicx"])
        add(.videos, ["tvlibrary", "imovielibrary", "fcpbundle", "theater", "dvdmedia"])
        add(.diskImages, ["sparsebundle", "dmgpart", "pkg", "mpkg", "pvm", "utm", "vmwarevm"])
        add(.backups, ["backupdb", "backupbundle"])
        add(.documents, ["pages", "numbers", "key", "rtfd", "lpdf"])
        add(.developer, [
            "xcodeproj", "xcworkspace", "xcarchive", "xcassets", "playground", "dsym", "framework",
            "docarchive", "doccarchive", "mlmodelc", "storyboardc", "nib", "car", "xcresult",
        ])
        return table
    }()

    // MARK: - Folder context

    /// Folder names whose whole contents are developer data (dependencies, build products, tool caches).
    static let developerFolderNames: Set<String> = [
        "node_modules", "DerivedData", ".git", "Pods", "Carthage", ".gradle", ".m2", ".cargo", ".rustup",
        ".npm", ".pnpm-store", ".yarn", ".bun", "__pycache__", ".venv", "venv", "site-packages", ".build",
        ".swiftpm", "CoreSimulator", "iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport",
        "visionOS DeviceSupport", ".android", ".nuget", ".pub-cache", ".dartServer", ".conda", "anaconda3",
        "miniconda3", ".pyenv", ".nvm", ".rbenv", ".gem", ".cocoapods", "xcuserdata", ".next", ".turbo",
    ]

    /// Category implied by a folder's location, inherited by everything inside it.
    ///
    /// - Parameters:
    ///   - name: The folder's name.
    ///   - parentPath: Path of the folder that contains it.
    ///   - inherited: The hint of the containing folder, if any.
    static func folderHint(name: String, parentPath: String, inherited: StorageCategory?) -> StorageCategory? {
        if let inherited { return inherited }
        if developerFolderNames.contains(name) { return .developer }
        if name == "Backups.backupdb" { return .backups }
        if name == "Backup", parentPath.hasSuffix("/Library/Application Support/MobileSync") { return .backups }
        if name == "Developer", parentPath.hasSuffix("/Library") { return .developer }
        return nil
    }
}

/// Caches `UTType` lookups for extensions that aren't in the fixed table.
/// Thread-safe: walker threads classify files concurrently.
private final class UTTypeCategoryCache: @unchecked Sendable {
    static let shared = UTTypeCategoryCache()

    private let lock = NSLock()
    private var cache: [String: StorageCategory] = [:]

    func category(forExtension ext: String) -> StorageCategory {
        if let cached = lock.withLock({ cache[ext] }) { return cached }
        let category = Self.lookUp(ext)
        lock.withLock {
            if cache.count > 4_096 { cache.removeAll(keepingCapacity: true) }
            cache[ext] = category
        }
        return category
    }

    private static func lookUp(_ ext: String) -> StorageCategory {
        guard let type = UTType(filenameExtension: ext), !type.isDynamic else { return .other }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .videos }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .diskImage) { return .diskImages }
        if type.conforms(to: .archive) { return .archives }
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return .applications }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .executable) { return .developer }
        if type.conforms(to: .pdf) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .text) || type.conforms(to: .compositeContent) || type.conforms(to: .emailMessage) {
            return .documents
        }
        return .other
    }
}

/// Folders that Finder shows as a single item. Extends Core's `PackageDetector`
/// with virtual-machine bundles, whose internal disk files must never be
/// listed (or removed) on their own.
enum StoragePackages {
    static let additionalExtensions: Set<String> = ["pvm", "utm", "vmwarevm", "lrdata", "dvdmedia", "xcresult"]

    static func isPackage(name: String) -> Bool {
        if PackageDetector.isPackage(name: name) { return true }
        guard let ext = StorageCategory.lowercasedExtension(of: name) else { return false }
        return additionalExtensions.contains(ext)
    }
}
