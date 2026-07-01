import Foundation
import Observation

/// Per-viewer state for the Hebrew translate/summarize toggles. Each message
/// viewer (reading pane, popped-out window) owns one; call `reset()` when the
/// displayed message changes so cached results don't leak across messages.
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

    /// The HTML to render for the current mode; falls back to the original while a
    /// result isn't ready yet.
    func displayHTML(original: String) -> String {
        switch mode {
        case .original: return original
        case .translated: return translatedHTML ?? original
        case .summary: return summaryHTML ?? original
        }
    }

    /// Clears cached results and cancels any in-flight work. Call when the
    /// displayed message changes.
    func reset() {
        task?.cancel()
        task = nil
        mode = .original
        translatedHTML = nil
        summaryHTML = nil
        errorText = nil
        isWorking = false
    }

    func toggleTranslate(html: String) {
        if mode == .translated { mode = .original; return }
        if translatedHTML != nil { mode = .translated; return }
        run(assign: \.translatedHTML, showAs: .translated) {
            try await TranslationService.shared.translateHTMLToHebrew(html)
        }
    }

    func toggleSummary(plainText: String, html: String) {
        if mode == .summary { mode = .original; return }
        if summaryHTML != nil { mode = .summary; return }
        run(assign: \.summaryHTML, showAs: .summary) {
            try await TranslationService.shared.summarizeInHebrew(plainText: plainText, html: html)
        }
    }

    private func run(
        assign keyPath: ReferenceWritableKeyPath<BodyTranslationModel, String?>,
        showAs mode: Mode,
        _ work: @escaping () async throws -> String
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
