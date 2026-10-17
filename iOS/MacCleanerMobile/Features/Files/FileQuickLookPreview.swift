import QuickLook
import SwiftUI

/// Files to show in Quick Look, starting at `index`.
struct FilePreviewRequest: Identifiable {
    let id = UUID()
    var urls: [URL]
    var index: Int
}

/// Quick Look for files on disk, in a navigation bar with a Done button, for presenting in a sheet.
/// Swiping sideways moves between the files.
struct FileQuickLookPreview: UIViewControllerRepresentable {
    var request: FilePreviewRequest
    var onDone: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(urls: request.urls)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.currentPreviewItemIndex = min(max(0, request.index), max(0, request.urls.count - 1))
        let coordinator = context.coordinator
        coordinator.onDone = onDone
        preview.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { _ in coordinator.onDone() })
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        context.coordinator.onDone = onDone
        if context.coordinator.urls != request.urls {
            context.coordinator.urls = request.urls
            (controller.viewControllers.first as? QLPreviewController)?.reloadData()
        }
    }

    @MainActor
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var urls: [URL]
        var onDone: () -> Void = {}

        init(urls: [URL]) {
            self.urls = urls
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            urls.count
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            urls[index] as NSURL
        }
    }
}
