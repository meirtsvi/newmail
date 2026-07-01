import SwiftUI

/// Translate-to-Hebrew and Hebrew-summary toggle buttons, placed next to the
/// reply/forward controls in a message viewer. Both toggle the body in place;
/// a spinner shows while a Gemini request is running and the active mode is
/// highlighted.
struct TranslateControls: View {
    let model: BodyTranslationModel
    let html: String
    let plainText: String

    var body: some View {
        HStack(spacing: 14) {
            if model.isWorking {
                ProgressView().controlSize(.small)
            }
            Button { model.toggleTranslate(html: html) } label: {
                Image(systemName: "character.bubble")
            }
            .help(model.errorText ?? "Translate to Hebrew")
            .foregroundStyle(model.mode == .translated ? Color.accentColor : .secondary)

            Button { model.toggleSummary(plainText: plainText, html: html) } label: {
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
