import Foundation
import CryptoKit

/// On-disk copies of small attachments, downloaded ahead of time so they open
/// offline. Files live under Application Support/newmail/attachments/<message>/,
/// named by a hash of the attachment's filename and size: Gmail mints a new
/// attachment id on every fetch, so the id can't be the key.
enum AttachmentCache {
    /// Attachments up to this size are downloaded ahead of time.
    static let maxPrefetchBytes = 5 * 1024 * 1024

    private static let root: URL = URL.applicationSupportDirectory
        .appending(path: "newmail", directoryHint: .isDirectory)
        .appending(path: "attachments", directoryHint: .isDirectory)

    static func data(for att: MailAttachment) -> Data? {
        try? Data(contentsOf: fileURL(for: att))
    }

    static func contains(_ att: MailAttachment) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: att).path)
    }

    static func store(_ data: Data, for att: MailAttachment) {
        let url = fileURL(for: att)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Removes every cached attachment of the given messages.
    static func remove(messageIds: [String]) {
        for id in messageIds {
            try? FileManager.default.removeItem(at: root.appending(path: hash(id), directoryHint: .isDirectory))
        }
    }

    private static func fileURL(for att: MailAttachment) -> URL {
        root.appending(path: hash(att.messageId), directoryHint: .isDirectory)
            .appending(path: hash("\(att.filename)\u{1}\(att.sizeBytes)"))
    }

    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
