import Foundation

/// Downloads message bodies (and attachments up to
/// `AttachmentCache.maxPrefetchBytes`) for every cached message in the sync
/// window, newest first, so mail can be read offline without having been
/// opened. Runs in the background after each sync pass; stops when the
/// connection drops and picks up where it left off next time. Also prunes
/// bodies that have fallen out of the window.
@MainActor
final class BodyPrefetcher {
    /// Messages fetched in parallel.
    private static let concurrency = 4
    private static let pruneInterval: TimeInterval = 3600

    /// Called with each fetched body (the view model notes calendar invites).
    var onBody: ((MessageBody) -> Void)?

    private let store: MailStore
    private var running = false
    /// Messages whose body couldn't be fetched (deleted meanwhile, etc.); not
    /// retried until relaunch.
    private var failed: Set<String> = []
    private var lastPrune: Date = .distantPast

    init(store: MailStore) {
        self.store = store
    }

    /// Works through the backlog until it's empty, the connection drops, or
    /// `isOnline` turns false. A call while one is running is ignored.
    func run(providers: [String: MailProvider], isOnline: @escaping () -> Bool) async {
        guard !running else { return }
        running = true
        defer { running = false }
        await pruneIfDue()
        guard isOnline() else { return }
        // The whole backlog is listed once per run: the scan covers every message in
        // the sync window, too slow to repeat for every few dozen fetches.
        let backlog = await MailStore.messagesNeedingBodies(since: SyncEngine.windowStart, skip: failed, limit: .max)
        guard !backlog.isEmpty else { return }
        var lostConnection = false
        var index = 0
        while index < backlog.count {
            let slice = Array(backlog[index..<min(index + Self.concurrency, backlog.count)])
            index += Self.concurrency
            let results = await withTaskGroup(of: (String, Result<MessageBody, Error>)?.self) { group in
                for item in slice {
                    guard let provider = providers[item.accountId] else { continue }
                    group.addTask {
                        do {
                            return (item.id, .success(try await provider.fetchBody(id: item.id)))
                        } catch {
                            return (item.id, .failure(error))
                        }
                    }
                }
                var out: [(String, Result<MessageBody, Error>)] = []
                for await result in group { if let result { out.append(result) } }
                return out
            }
            for item in slice where providers[item.accountId] == nil { failed.insert(item.id) }
            var gone: [String] = []
            for (id, result) in results {
                switch result {
                case .success(let body):
                    store.saveBody(body)
                    onBody?(body)
                    if let provider = providers[slice.first { $0.id == id }?.accountId ?? ""] {
                        if await !prefetchAttachments(body.attachments, provider: provider) {
                            lostConnection = true
                        }
                    }
                case .failure(MailError.api(404, _)):
                    // Deleted (or, on Outlook, moved under a new id) on the server
                    // since it was cached: drop the stale row so it isn't retried
                    // on every launch.
                    gone.append(id)
                case .failure(let error):
                    if NetworkMonitor.isConnectivityError(error) {
                        lostConnection = true
                    } else {
                        failed.insert(id)
                    }
                }
            }
            store.deleteMessages(ids: gone)
            if lostConnection || !isOnline() { return }
        }
    }

    /// Saves the message's small attachments to disk. Returns false if the
    /// connection dropped.
    private func prefetchAttachments(_ attachments: [MailAttachment], provider: MailProvider) async -> Bool {
        for att in attachments where att.sizeBytes <= AttachmentCache.maxPrefetchBytes && !AttachmentCache.contains(att) {
            do {
                let data = try await provider.fetchAttachment(messageId: att.messageId, attachmentId: att.id)
                AttachmentCache.store(data, for: att)
            } catch {
                if NetworkMonitor.isConnectivityError(error) { return false }
            }
        }
        return true
    }

    /// Hourly: drops bodies, translations and attachment files of mail older
    /// than the window (their headers stay; opening one fetches it again).
    private func pruneIfDue() async {
        guard Date().timeIntervalSince(lastPrune) >= Self.pruneInterval else { return }
        lastPrune = Date()
        let pruned = await MailStore.pruneBodies(before: SyncEngine.windowStart)
        await Task.detached(priority: .utility) { AttachmentCache.remove(messageIds: pruned) }.value
    }
}
