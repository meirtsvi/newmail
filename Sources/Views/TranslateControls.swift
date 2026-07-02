import SwiftUI

/// Translate-to-Hebrew and Hebrew-summary toggle buttons, placed next to the
/// reply/forward controls in a message viewer. Both toggle the body in place;
/// a spinner shows while a Gemini request is running and the active mode is
/// highlighted.
/// Zoom-out / zoom-in buttons with a transient percentage readout ("90%",
/// "110%") shown between them whenever the level changes — via the buttons or
/// the ⌘+/⌘−/⌘0 shortcuts — fading out shortly after. Styling (borderless,
/// scale, tint) is inherited from the surrounding button row.
struct ZoomControls: View {
    @Binding var zoom: Double
    var range: ClosedRange<Double> = 0.5...3.0

    @State private var showLevel = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            Button { step(-0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            if showLevel {
                Text("\(Int((zoom * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .transition(.opacity)
            }
            Button { step(+0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
        }
        // Zoom changes made elsewhere (the ⌘ shortcuts) surface the readout too.
        .onChange(of: zoom) { _, _ in flash() }
    }

    /// Steps the zoom by ±0.1, snapped to one decimal so repeated steps don't
    /// accumulate floating-point drift into readouts like "109%".
    private func step(_ delta: Double) {
        let next = ((zoom + delta) * 10).rounded() / 10
        zoom = min(range.upperBound, max(range.lowerBound, next))
        // Flash even when clamped at the range edge (zoom unchanged, so
        // onChange won't fire) — the press still confirms the current level.
        flash()
    }

    private func flash() {
        hideTask?.cancel()
        withAnimation(.easeIn(duration: 0.1)) { showLevel = true }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) { showLevel = false }
        }
    }
}

struct TranslateControls: View {
    let model: BodyTranslationModel
    /// Message id — keys the persistent translation/summary cache.
    let messageId: String
    let html: String
    let plainText: String

    var body: some View {
        HStack(spacing: 14) {
            if model.isWorking {
                ProgressView().controlSize(.small)
            }
            Button { model.toggleTranslate(messageId: messageId, html: html) } label: {
                Image(systemName: "character.bubble")
            }
            .help(model.errorText ?? "Translate to Hebrew")
            .foregroundStyle(model.mode == .translated ? Color.accentColor : .secondary)

            Button { model.toggleSummary(messageId: messageId, plainText: plainText, html: html) } label: {
                Image(systemName: "list.bullet.rectangle")
            }
            .help(model.errorText ?? "Summarize in Hebrew (5 paragraphs)")
            .foregroundStyle(model.mode == .summary ? Color.accentColor : .secondary)
        }
        .disabled(model.isWorking)
        .buttonStyle(.borderless)
        .imageScale(.large)
    }
}
