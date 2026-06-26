import Cocoa
import UniformTypeIdentifiers

/// macOS Share extension: when the user shares an image or PDF, copy the file(s)
/// into the App Group container shared with newmail and wake the app, which opens a
/// new compose with them attached. The extension itself shows no UI — it stages the
/// files and finishes.
final class ShareViewController: NSViewController {
    /// Must match `com.apple.security.application-groups` in both targets' entitlements.
    private static let appGroupID = "group.com.meirt.newmail"

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        Task {
            await stageSharedFiles()
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    private func stageSharedFiles() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty,
              let container = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else { return }

        // One subdirectory per share, so the app can pick up each batch atomically.
        let batch = container
            .appendingPathComponent("SharedInbox", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)

        var staged = false
        for provider in providers {
            guard let src = await loadFile(provider) else { continue }
            let dst = uniqueURL(in: batch, named: src.lastPathComponent)
            if (try? FileManager.default.copyItem(at: src, to: dst)) != nil { staged = true }
        }
        guard staged else { try? FileManager.default.removeItem(at: batch); return }

        // Best effort: bring newmail forward so it picks the files up immediately. If
        // the sandbox blocks this, the app also scans the container when it next
        // becomes active.
        if let url = URL(string: "newmail://share") { NSWorkspace.shared.open(url) }
    }

    /// Loads the shared item as a file URL (valid only inside the completion), copied
    /// to the extension's temp dir so it survives to be staged.
    private func loadFile(_ provider: NSItemProvider) async -> URL? {
        let types = [UTType.image, UTType.pdf, UTType.fileURL, UTType.item]
        guard let type = types.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let dst = tmp.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.copyItem(at: url, to: dst)
                continuation.resume(returning: FileManager.default.fileExists(atPath: dst.path) ? dst : nil)
            }
        }
    }

    private func uniqueURL(in dir: URL, named name: String) -> URL {
        let candidate = dir.appendingPathComponent(name.isEmpty ? "attachment" : name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        let unique = "\(stem)-\(UUID().uuidString.prefix(8))"
        return dir.appendingPathComponent(ext.isEmpty ? unique : "\(unique).\(ext)")
    }
}
