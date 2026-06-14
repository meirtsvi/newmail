import AppKit
import Quartz

/// Drives the shared Quick Look panel to preview one or more downloaded files
/// (the "Preview" / "Preview All" attachment actions).
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookController()

    private var urls: [URL] = []

    func preview(_ urls: [URL], startIndex: Int = 0) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.makeKeyAndOrderFront(nil)
        panel.currentPreviewItemIndex = max(0, min(startIndex, urls.count - 1))
        panel.reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem {
        urls[index] as NSURL
    }
}
