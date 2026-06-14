import SwiftUI

/// A labeled recipient text field (To / Cc) with inline address autocomplete.
/// Recipients are comma-separated; suggestions match the token currently being
/// typed (the text after the last comma). Arrow keys move the highlight, Return
/// or a click accepts, Escape dismisses.
struct RecipientField: View {
    let title: String
    @Binding var text: String
    /// Returns ranked suggestions for a partial address.
    let suggest: (String) -> [MailAddress]
    /// Focus this field when it appears (used for the To field on open).
    var focusOnAppear = false

    @FocusState private var focused: Bool
    @State private var matches: [MailAddress] = []
    @State private var highlighted = 0
    @State private var fieldHeight: CGFloat = 24

    private var showSuggestions: Bool { focused && !matches.isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
                .padding(.top, 3)
            field
        }
        // Raise the focused field (and its floating suggestion list) above the
        // sibling rows and the compose body so the dropdown is never clipped.
        .zIndex(focused ? 1 : 0)
    }

    private var field: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear { if focusOnAppear { focused = true } }
            .onChange(of: text) { _, _ in if focused { recompute() } }
            .onChange(of: focused) { _, isFocused in if !isFocused { matches = [] } }
            .onKeyPress(.downArrow) {
                guard showSuggestions else { return .ignored }
                highlighted = min(highlighted + 1, matches.count - 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard showSuggestions else { return .ignored }
                highlighted = max(highlighted - 1, 0)
                return .handled
            }
            .onKeyPress(.return) {
                guard showSuggestions, matches.indices.contains(highlighted) else { return .ignored }
                accept(matches[highlighted])
                return .handled
            }
            .onKeyPress(.tab) {
                guard showSuggestions, matches.indices.contains(highlighted) else { return .ignored }
                accept(matches[highlighted])
                return .handled
            }
            .onKeyPress(.escape) {
                guard showSuggestions else { return .ignored }
                matches = []
                return .handled
            }
            // Measure the field so the suggestion list can sit just beneath it.
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { fieldHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in fieldHeight = h }
                }
            )
            // Floating suggestion list, pinned just below the field. Drawn as an
            // overlay so it doesn't displace the rest of the compose form.
            .overlay(alignment: .topLeading) {
                if showSuggestions {
                    suggestionList
                        .offset(y: fieldHeight + 4)
                }
            }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, addr in
                Button {
                    accept(addr)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        if !addr.name.isEmpty {
                            Text(addr.name).font(.body)
                        }
                        Text(addr.email)
                            .font(addr.name.isEmpty ? .body : .caption)
                            .foregroundStyle(addr.name.isEmpty ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .background(index == highlighted ? Color.accentColor.opacity(0.18) : .clear)
                }
                .buttonStyle(.plain)
                .onHover { if $0 { highlighted = index } }
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .shadow(radius: 6, y: 2)
        .frame(width: 320)
    }

    private func recompute() {
        matches = suggest(currentToken)
        highlighted = 0
    }

    /// The address fragment currently being typed (after the last comma).
    private var currentToken: String {
        guard let comma = text.lastIndex(of: ",") else {
            return text.trimmingCharacters(in: .whitespaces)
        }
        return String(text[text.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
    }

    private func accept(_ addr: MailAddress) {
        let head: String
        if let comma = text.lastIndex(of: ",") {
            head = String(text[...comma]) + " "
        } else {
            head = ""
        }
        text = head + addr.email + ", "
        matches = []
    }
}
