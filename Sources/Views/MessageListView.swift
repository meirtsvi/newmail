import SwiftUI

/// Middle pane: a sortable, multi-select Table of message headers with a
/// folder-title header bar. Sorting is driven by the column headers; hovering a
/// row reveals quick actions; right-click opens the shared context menu.
struct MessageListView: View {
    @Environment(MailboxViewModel.self) private var vm
    @State private var hoveredId: String?
    @State private var columnCustomization = TableColumnCustomization<MessageHeader>()

    private static let columnsKey = "messageColumnCustomization"

    var body: some View {
        @Bindable var vm = vm
        VStack(spacing: 0) {
            header
            Divider()
            table
        }
    }

    private var header: some View {
        HStack {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(vm.currentFolder?.name ?? "Mailbox")
                    .font(.title2.weight(.semibold))
                if let total = vm.currentFolder?.totalCount, total > 0 {
                    Text("(\(total))")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if vm.isLoading {
                ProgressView().controlSize(.small).padding(.leading, 4)
            }
            Spacer()
            if !vm.hasWriteScope {
                Button {
                    Task { await vm.signInForWriteAccess() }
                } label: {
                    if vm.isSigningIn {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Signing in…").font(.caption)
                        }
                    } else {
                        Label("Sign in with Google for write access", systemImage: "person.badge.key")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
                .disabled(vm.isSigningIn)
                .help("Authorize via Google OAuth (gmail.modify + gmail.send) to enable delete/move/snooze/send — and to check whether your organization allows this app.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var table: some View {
        @Bindable var vm = vm
        return Table(
            vm.displayedMessages,
            selection: $vm.selection,
            sortOrder: $vm.sortOrder,
            columnCustomization: $columnCustomization
        ) {
            columns
        }
        .onAppear(perform: loadColumns)
        .onChange(of: columnCustomization) { _, value in saveColumns(value) }
        .contextMenu(forSelectionType: String.self) { ids in
            MessageContextMenu(vm: vm, ids: ids.isEmpty ? Array(vm.selection) : Array(ids))
        } primaryAction: { ids in
            // Double-click (or Return) opens the message in its own window.
            if let id = ids.first { vm.openInWindow(id) }
        }
        .onChange(of: vm.selection) { _, sel in
            if sel.count == 1, let id = sel.first {
                Task { await vm.openMessage(id) }
            }
        }
        // Delete/Backspace removes the selected messages when the list is focused.
        .onDeleteCommand(perform: deleteSelection)
        // Forward-delete (fn+⌦) does the same.
        .onKeyPress(.deleteForward) {
            guard !vm.selection.isEmpty else { return .ignored }
            deleteSelection()
            return .handled
        }
    }

    private func deleteSelection() {
        let ids = Array(vm.selection)
        guard !ids.isEmpty else { return }
        Task { await vm.deleteMessages(ids) }
    }

    @TableColumnBuilder<MessageHeader, KeyPathComparator<MessageHeader>>
    private var columns: some TableColumnContent<MessageHeader, KeyPathComparator<MessageHeader>> {
        TableColumn("", value: \MessageHeader.readSort) { msg in unreadCell(msg) }
            .width(16)
        TableColumn("⚑", value: \MessageHeader.flagSort) { msg in flagCell(msg) }
            .width(24)
        TableColumn("◷", value: \MessageHeader.attachmentSort) { msg in attachmentCell(msg) }
            .width(24)
        TableColumn("From", value: \MessageHeader.from.display) { msg in fromCell(msg) }
            .width(min: 120, ideal: 240)
            .customizationID("from")
        TableColumn("Subject", value: \MessageHeader.subject) { msg in subjectCell(msg) }
            .customizationID("subject")
        TableColumn("Date", value: \MessageHeader.date) { msg in dateCell(msg) }
            .width(min: 60, ideal: 110)
            .customizationID("date")
        if vm.currentFolder?.kind == .snoozed {
            TableColumn("Snoozed Until") { msg in snoozedUntilCell(msg) }
                .width(min: 100, ideal: 150)
                .customizationID("snoozedUntil")
        }
    }

    // MARK: - Column width persistence

    private func loadColumns() {
        guard let data = UserDefaults.standard.data(forKey: Self.columnsKey),
              let decoded = try? JSONDecoder().decode(TableColumnCustomization<MessageHeader>.self, from: data)
        else { return }
        columnCustomization = decoded
    }

    private func saveColumns(_ value: TableColumnCustomization<MessageHeader>) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: Self.columnsKey)
        }
    }

    @ViewBuilder
    private func unreadCell(_ msg: MessageHeader) -> some View {
        Circle()
            .fill(msg.isRead ? Color.clear : Color.accentColor)
            .frame(width: 8, height: 8)
    }

    @ViewBuilder
    private func flagCell(_ msg: MessageHeader) -> some View {
        if msg.isFlagged {
            Image(systemName: "flag.fill").foregroundStyle(.red).help("Flagged")
        }
    }

    @ViewBuilder
    private func attachmentCell(_ msg: MessageHeader) -> some View {
        if msg.hasAttachments {
            Image(systemName: "paperclip").foregroundStyle(.secondary).help("Has attachment")
        }
    }

    @ViewBuilder
    private func dateCell(_ msg: MessageHeader) -> some View {
        Text(msg.date.mailListString)
            .foregroundStyle(.secondary)
            .font(msg.isRead ? .body : .body.weight(.semibold))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { setHover($0, id: msg.id) }
    }

    private func setHover(_ inside: Bool, id: String) {
        if inside { hoveredId = id }
        else if hoveredId == id { hoveredId = nil }
    }

    @ViewBuilder
    private func snoozedUntilCell(_ msg: MessageHeader) -> some View {
        if let wake = vm.snoozedUntil(msg.id) {
            Text(wake.mailFullString).foregroundStyle(.secondary)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    private func fromCell(_ msg: MessageHeader) -> some View {
        HStack(spacing: 8) {
            // The avatar is the drag handle (dragging the whole cell would steal
            // the click the Table needs for row selection).
            Avatar(address: msg.from)
                .onDrag {
                    let ids = vm.selection.contains(msg.id) ? Array(vm.selection) : [msg.id]
                    return MessageDragPayload.itemProvider(ids: ids)
                }
            Text(msg.from.display)
                .font(msg.isRead ? .body : .body.weight(.bold))
                .lineLimit(1)
            Spacer(minLength: 4)
            // Quick actions appear to the right of the From column when the row is
            // hovered or selected. (SwiftUI's Table doesn't reliably deliver hover
            // to cells, so the selected row is the dependable way to reach them.)
            if hoveredId == msg.id || vm.selection.contains(msg.id) {
                HoverActions(vm: vm, id: msg.id, isFlagged: msg.isFlagged)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { setHover($0, id: msg.id) }
    }

    private func subjectCell(_ msg: MessageHeader) -> some View {
        Text(msg.subject)
            .font(msg.isRead ? .body : .body.weight(.semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { setHover($0, id: msg.id) }
    }
}

/// Colored initials avatar (no network lookups).
struct Avatar: View {
    let address: MailAddress

    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: 26, height: 26)
            .overlay(
                Text(address.initials)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
            )
    }

    private var color: Color {
        let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .indigo, .red]
        let hash = abs(address.id.hashValue)
        return palette[hash % palette.count]
    }
}
