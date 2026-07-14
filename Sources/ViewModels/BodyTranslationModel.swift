import Foundation
import Observation

/// Per-viewer state for the Hebrew translate/summarize toggles. Each message
/// viewer (reading pane, popped-out window) owns one; call `reset()` when the
/// displayed message changes so cached results don't leak across messages.
///
/// Results are also persisted per message id (see `CachedTranslation`), so a
/// translation produced once — here or pre-computed for a newsletter message —
/// shows instantly on every later toggle, in any viewer, across launches.
/// The Gemini call itself runs in a task shared across viewers (`sharedWork`)
/// that `reset()` doesn't cancel: switching messages mid-translation lets the
/// work finish and land in the store, so coming back shows it instantly, and
/// toggling again while it's still running joins the same call.
@MainActor
@Observable
final class BodyTranslationModel {
    enum Mode { case original, translated, summary }

    private(set) var mode: Mode = .original
    private(set) var isWorking = false
    private(set) var errorText: String?

    private var translatedHTML: String?
    private var summaryHTML: String?
    private var task: Task<Void, Never>?
    @ObservationIgnored private lazy var store = MailStore()

    /// In-flight Gemini work keyed by message id + kind, shared by every model
    /// instance so a message never pays for the same translation twice.
    private static var inflight: [String: Task<String, Error>] = [:]

    /// Returns the running task for `key`, or starts `work` as a new one. The
    /// task saves its result to the store itself, so it is useful even if every
    /// viewer that awaited it has moved on to another message.
    private static func sharedWork(
        key: String, _ work: @escaping @MainActor () async throws -> String
    ) -> Task<String, Error> {
        if let running = inflight[key] { return running }
        let task = Task { @MainActor in
            defer { inflight[key] = nil }
            return try await work()
        }
        inflight[key] = task
        return task
    }

    /// The HTML to render for the current mode; falls back to the original while a
    /// result isn't ready yet.
    func displayHTML(original: String) -> String {
        switch mode {
        case .original: return original
        case .translated: return translatedHTML ?? original
        case .summary: return summaryHTML ?? original
        }
    }

    /// Clears this viewer's state when the displayed message changes. Only the
    /// observing task is cancelled — the shared Gemini work keeps running and
    /// caches its result for when the message is shown again.
    func reset() {
        task?.cancel()
        task = nil
        mode = .original
        translatedHTML = nil
        summaryHTML = nil
        errorText = nil
        isWorking = false
    }

    func toggleTranslate(messageId: String, html: String) {
        if mode == .translated { mode = .original; return }
        if translatedHTML != nil { mode = .translated; return }
        if let cached = store.cachedTranslation(id: messageId).translated {
            translatedHTML = cached
            mode = .translated
            return
        }
        run(assign: \.translatedHTML, showAs: .translated) { [store] in
            try await Self.sharedWork(key: messageId + ":translate") {
                let result = try await TranslationService.shared.translateHTMLToHebrew(html)
                store.saveTranslation(id: messageId, translated: result)
                return result
            }.value
        }
    }

    func toggleSummary(messageId: String, plainText: String, html: String) {
        if mode == .summary { mode = .original; return }
        if summaryHTML != nil { mode = .summary; return }
        if let cached = store.cachedTranslation(id: messageId).summary {
            summaryHTML = cached
            mode = .summary
            return
        }
        run(assign: \.summaryHTML, showAs: .summary) { [store] in
            try await Self.sharedWork(key: messageId + ":summary") {
                let result = try await TranslationService.shared.summarizeInHebrew(plainText: plainText, html: html)
                store.saveTranslation(id: messageId, summary: result)
                return result
            }.value
        }
    }

    private func run(
        assign keyPath: ReferenceWritableKeyPath<BodyTranslationModel, String?>,
        showAs mode: Mode,
        _ work: @escaping @MainActor () async throws -> String
    ) {
        guard !isWorking else { return }
        isWorking = true
        errorText = nil
        task = Task {
            do {
                let result = try await work()
                if Task.isCancelled { return }
                self[keyPath: keyPath] = result
                self.mode = mode
            } catch is CancellationError {
                // superseded by reset(); leave state to the reset
            } catch {
                self.errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            self.isWorking = false
        }
    }
}
