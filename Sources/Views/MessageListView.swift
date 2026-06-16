import SwiftUI
import AppKit

/// Middle pane: a sortable, multi-select Table of message headers with a
/// folder-title header bar. Sorting is driven by the column headers; hovering a
/// row reveals quick actions; right-click opens the shared context menu.
struct MessageListView: View {
    @Environment(MailboxViewModel.self) private var vm
    @State private var hoveredId: String?
    /// Anchor row for ⇧-click range selection (the last plainly/⌘-clicked row).
    @State private var selectionAnchor: String?
    /// Drives keyboard focus onto the table. Because selection is set manually (the
    /// cell-wide `.onDrag` swallows the mouse-down the Table would use to select and
    /// focus itself), a click leaves the list unfocused — the row highlights gray and
    /// arrow keys do nothing. Setting this on every click restores focus.
    @FocusState private var tableFocused: Bool
    @State private var columnCustomization = TableColumnCustomization<MessageHeader>()

    private static let columnsKey = "messageColumnCustomization"

    var body: some View {
        @Bindable var vm = vm
        VStack(spacing: 0) {
            header
            Divider()
            table
            loadOlderFooter
        }
    }

    /// Footer shown while the current folder has more pages on the server. The
    /// initial open auto-pages up to a target (see `loadMessages`); this lets the
    /// user pull the rest in on demand.
    @ViewBuilder
    private var loadOlderFooter: some View {
        if vm.canLoadMore {
            Divider()
            Button {
                Task { await vm.loadMore() }
            } label: {
                HStack(spacing: 6) {
                    if vm.isLoading { ProgressView().controlSize(.small) }
                    Text(vm.isLoading ? "Loading…" : "Load older messages")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .disabled(vm.isLoading)
            .padding(.vertical, 8)
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
        // Every cell fills its row and is a drag source (see `rowInteraction`), so a
        // press-drag anywhere on a row moves the message(s) — single or multi — and the
        // Table never falls back to its rubber-band multi-row selection. The price of a
        // cell-wide `.onDrag` is that it eats the mouse-down the Table would use to
        // select the row, so selection is driven manually in `handleClick`. Row order
        // matches `displayedMessages`, already sorted by the view model.
        return Table(
            vm.displayedMessages,
            selection: $vm.selection,
            sortOrder: $vm.sortOrder,
            columnCustomization: $columnCustomization
        ) {
            columns
        }
        .focused($tableFocused)
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
        // ⌘A selects every message in the current folder's list.
        .onKeyPress(phases: .down) { press in
            guard press.key == KeyEquivalent("a"), press.modifiers.contains(.command) else {
                return .ignored
            }
            vm.selection = Set(vm.displayedMessages.map(\.id))
            return .handled
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
        TableColumn(Text("\(Image(systemName: "circle.fill"))").font(.caption2),
                    value: \MessageHeader.readSort) { msg in unreadCell(msg) }
            .width(18)
        TableColumn(Text("\(Image(systemName: "flag.fill"))").font(.body),
                    value: \MessageHeader.flagSort) { msg in flagCell(msg) }
            .width(24)
        TableColumn(Text("\(Image(systemName: "paperclip"))").font(.body),
                    value: \MessageHeader.attachmentSort) { msg in attachmentCell(msg) }
            .width(24)
        TableColumn(Text("\(Image(systemName: "calendar"))").font(.body),
                    value: \MessageHeader.calendarSort) { msg in calendarCell(msg) }
            .width(24)
            .customizationID("calendar")
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

    /// Drag payload for a row: the whole selection if this message is part of it,
    /// otherwise just this message. `rowInteraction` puts this on every cell so the
    /// entire row is a drag source.
    private func rowDrag(_ msg: MessageHeader) -> NSItemProvider {
        let ids = vm.selection.contains(msg.id) ? Array(vm.selection) : [msg.id]
        return MessageDragPayload.itemProvider(ids: ids)
    }

    /// Shared per-cell treatment: fill the row, drag the message(s) from anywhere,
    /// and select on click. Selection is manual because the cell-wide `.onDrag`
    /// swallows the click the Table would otherwise use to select the row.
    private func rowInteraction(_ msg: MessageHeader) -> RowInteraction {
        RowInteraction(
            onDrag: { rowDrag(msg) },
            onClick: { handleClick(msg) },
            onOpen: { vm.openInWindow(msg.id) },
            onHover: { setHover($0, id: msg.id) }
        )
    }

    /// Click-to-select, mirroring the usual list behaviour: a plain click selects
    /// one row, ⌘ toggles it, ⇧ extends a range from the anchor (last plain/⌘ click).
    private func handleClick(_ msg: MessageHeader) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if vm.selection.contains(msg.id) { vm.selection.remove(msg.id) }
            else { vm.selection.insert(msg.id) }
            selectionAnchor = msg.id
        } else if flags.contains(.shift), let anchor = selectionAnchor {
            vm.selection = Set(rangeIds(from: anchor, to: msg.id))
        } else {
            vm.selection = [msg.id]
            selectionAnchor = msg.id
        }
        // Take keyboard focus so the selection highlights blue and arrow keys work.
        tableFocused = true
    }

    /// Ids of the displayed rows between two messages, inclusive (order-independent).
    private func rangeIds(from: String, to: String) -> [String] {
        let ids = vm.displayedMessages.map(\.id)
        guard let a = ids.firstIndex(of: from), let b = ids.firstIndex(of: to) else { return [to] }
        return Array(ids[min(a, b)...max(a, b)])
    }

    @ViewBuilder
    private func unreadCell(_ msg: MessageHeader) -> some View {
        Circle()
            .fill(msg.isRead ? Color.clear : Color.accentColor)
            .frame(width: 8, height: 8)
            .modifier(rowInteraction(msg))
    }

    private func flagCell(_ msg: MessageHeader) -> some View {
        Group {
            if msg.isFlagged {
                Image(systemName: "flag.fill").foregroundStyle(.red).help("Flagged")
            }
        }
        .modifier(rowInteraction(msg))
    }

    private func attachmentCell(_ msg: MessageHeader) -> some View {
        Group {
            if msg.hasAttachments {
                Image(systemName: "paperclip").foregroundStyle(.secondary).help("Has attachment")
            }
        }
        .modifier(rowInteraction(msg))
    }

    private func calendarCell(_ msg: MessageHeader) -> some View {
        Group {
            if vm.isCalendarEvent(msg.id) {
                Image(systemName: "calendar").foregroundStyle(.secondary).help("Calendar event")
            }
        }
        .modifier(rowInteraction(msg))
    }

    private func dateCell(_ msg: MessageHeader) -> some View {
        Text(msg.date.mailListString)
            .foregroundStyle(.secondary)
            .font(msg.isRead ? .body : .body.weight(.semibold))
            .modifier(rowInteraction(msg))
    }

    private func setHover(_ inside: Bool, id: String) {
        if inside { hoveredId = id }
        else if hoveredId == id { hoveredId = nil }
    }

    private func snoozedUntilCell(_ msg: MessageHeader) -> some View {
        Group {
            if let wake = vm.snoozedUntil(msg.id) {
                Text(wake.mailFullString).foregroundStyle(.secondary)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .modifier(rowInteraction(msg))
    }

    private func fromCell(_ msg: MessageHeader) -> some View {
        HStack(spacing: 8) {
            Avatar(address: msg.from)
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
        .modifier(rowInteraction(msg))
    }

    private func subjectCell(_ msg: MessageHeader) -> some View {
        Text(msg.subject)
            .font(msg.isRead ? .body : .body.weight(.semibold))
            .lineLimit(1)
            .modifier(rowInteraction(msg))
    }
}

/// Per-cell interaction shared by every column: fill the row, drag the message(s)
/// from anywhere in the row, open on double-click, and route single-clicks to
/// manual selection. A cell-wide `.onDrag` eats the click the Table would use for
/// native selection, so `onClick` re-implements it. `simultaneousGesture` lets the
/// tap and the drag coexist — a stationary click selects, a press-drag drags.
private struct RowInteraction: ViewModifier {
    let onDrag: () -> NSItemProvider
    let onClick: () -> Void
    let onOpen: () -> Void
    let onHover: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover(perform: onHover)
            .onDrag(onDrag)
            .simultaneousGesture(TapGesture(count: 2).onEnded(onOpen))
            .simultaneousGesture(TapGesture(count: 1).onEnded(onClick))
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
