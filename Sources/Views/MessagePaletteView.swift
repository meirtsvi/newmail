import SwiftUI

/// ⌘K quick-open palette over the loaded message list: type to filter by
/// subject, sender, or snippet; ↑/↓ moves the highlight; Return (or a click)
/// makes the pick the list selection — opening it in the reading pane — and
/// scrolls its row into view. Escape closes without changing anything.
struct MessagePaletteView: View {
    @Environment(MailboxViewModel.self) private var vm
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    /// Cap the visible matches so the palette stays snappy on huge folders.
    private static let maxMatches = 50

    private var matches: [MessageHeader] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = vm.displayedMessages
        guard !q.isEmpty else { return Array(all.prefix(Self.maxMatches)) }
        return Array(all.lazy.filter { header in
            header.subject.localizedCaseInsensitiveContains(q)
                || header.from.name.localizedCaseInsensitiveContains(q)
                || header.from.email.localizedCaseInsensitiveContains(q)
                || header.snippet.localizedCaseInsensitiveContains(q)
        }.prefix(Self.maxMatches))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Jump to message…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { choose(at: highlighted) }
            }
            .padding(12)
            Divider()
            if matches.isEmpty {
                Text(vm.displayedMessages.isEmpty ? "No messages in this list."
                                                  : "No messages match “\(query)”.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                resultsList
            }
        }
        .frame(width: 560)
        // The highlight index is only meaningful within one result set.
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onAppear { fieldFocused = true }
        // ↑/↓ move the highlight from the text field without leaving it.
        .onKeyPress(.upArrow) {
            highlighted = max(0, highlighted - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            highlighted = min(max(0, matches.count - 1), highlighted + 1)
            return .handled
        }
        .onKeyPress(.escape) {
            vm.showMessagePalette = false
            return .handled
        }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, header in
                        row(header, isHighlighted: index == highlighted)
                            .id(index)
                            .onTapGesture { choose(at: index) }
                            .onHover { if $0 { highlighted = index } }
                    }
                }
            }
            .frame(maxHeight: 360)
            .onChange(of: highlighted) { _, index in proxy.scrollTo(index) }
        }
    }

    private func row(_ header: MessageHeader, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Avatar(address: header.from)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(header.from.display)
                        .fontWeight(header.isRead ? .regular : .semibold)
                        .lineLimit(1)
                    Spacer()
                    Text(header.date, format: .dateTime.day().month().year())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(header.subject.isEmpty ? "(no subject)" : header.subject)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(isHighlighted ? Color.accentColor.opacity(0.18) : .clear)
    }

    /// Selects the picked message in the list (opening it in the reading pane)
    /// and asks the list to scroll its row into view.
    private func choose(at index: Int) {
        guard matches.indices.contains(index) else { return }
        let id = matches[index].id
        vm.showMessagePalette = false
        vm.selection = [id]
        vm.scrollToMessageId = id
    }
}
