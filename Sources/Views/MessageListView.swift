import SwiftUI
import AppKit

/// Middle pane: a sortable, multi-select Table of message headers with a
/// folder-title header bar. Sorting is driven by the column headers; hovering a
/// row reveals quick actions; right-click opens the shared context menu.
/// Holds the currently-hovered row id. It must be `@Observable` (not a plain `@State`
/// scalar) so the `Table` re-renders the affected cells: `Table` only re-runs its cell
/// builders for data/selection it tracks via Observation, so a plain `@State` change is
/// ignored by the rows — exactly how `vm.selection` reaches the cells.
@Observable final class RowHoverModel { var id: String? }

struct MessageListView: View {
    @Environment(MailboxViewModel.self) private var vm
    @State private var hover = RowHoverModel()
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
            if vm.isSearching && vm.displayedMessages.isEmpty && !vm.isSearchInProgress {
                emptyResults
            } else {
                table
                loadOlderFooter
            }
        }
    }

    /// Shown when a completed search returned nothing, so the pane reads as "no
    /// matches" rather than a blank list that looks stuck.
    private var emptyResults: some View {
        ContentUnavailableView {
            Label("No results", systemImage: "magnifyingglass")
        } description: {
            Text("No messages match “\(vm.searchText)”.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        // Reliable row hover: one tracker over the whole table (not per cell), so it
        // survives the cell re-renders that revealing the quick actions triggers.
        .background(
            TableHoverTracker(
                idForRow: { row in
                    let msgs = vm.displayedMessages
                    return row >= 0 && row < msgs.count ? msgs[row].id : nil
                },
                setHovered: { setHovered($0) }
            )
            .allowsHitTesting(false)
        )
        .onAppear(perform: loadColumns)
        .onChange(of: columnCustomization) { _, value in saveColumns(value) }
        // Re-sorting via a column header replaces the sort order with just that
        // column, dropping the unique `id` tiebreaker. Re-append it so rows sharing
        // a value (e.g. the same timestamp) never compare equal — otherwise a click
        // can resolve to the wrong tied row.
        .onChange(of: vm.sortOrder) { _, order in
            if !order.contains(where: { $0.keyPath == \MessageHeader.id }) {
                vm.sortOrder = order + [KeyPathComparator(\MessageHeader.id)]
            }
        }
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
        // ⌘A selects every message in the list; ⌘Z undoes the last delete.
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            switch press.key {
            case KeyEquivalent("a"):
                vm.selection = Set(vm.displayedMessages.map(\.id))
                return .handled
            case KeyEquivalent("z"):
                Task { await vm.undoLastDelete() }
                return .handled
            default:
                return .ignored
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
        TableColumn(Text("\(Image(systemName: "circle.fill"))").font(.caption2),
                    value: \MessageHeader.readSort) { msg in unreadCell(msg) }
            .width(12)
            .customizationID("unread")
        TableColumn(Text("\(Image(systemName: "flag.fill"))").font(.caption),
                    value: \MessageHeader.flagSort) { msg in flagCell(msg) }
            .width(16)
            .customizationID("flag")
        TableColumn(Text("\(Image(systemName: "paperclip"))").font(.caption),
                    value: \MessageHeader.attachmentSort) { msg in attachmentCell(msg) }
            .width(16)
            .customizationID("attachment")
        TableColumn(Text("\(Image(systemName: "calendar"))").font(.caption),
                    value: \MessageHeader.calendarSort) { msg in calendarCell(msg) }
            .width(16)
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
            onOpen: { vm.openInWindow(msg.id) }
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
                Image(systemName: "flag.fill").font(.caption).foregroundStyle(.red).help("Flagged")
            }
        }
        .modifier(rowInteraction(msg))
    }

    private func attachmentCell(_ msg: MessageHeader) -> some View {
        Group {
            if msg.hasAttachments {
                Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary).help("Has attachment")
            }
        }
        .modifier(rowInteraction(msg))
    }

    private func calendarCell(_ msg: MessageHeader) -> some View {
        Group {
            if vm.isCalendarEvent(msg.id) {
                Image(systemName: "calendar").font(.caption).foregroundStyle(.secondary).help("Calendar event")
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

    /// Set by `TableHoverTracker` to the row currently under the cursor (nil when off
    /// any row). Guarded so redundant moves within a row don't churn @State.
    private func setHovered(_ id: String?) {
        if hover.id != id { hover.id = id }
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
        let show = hover.id == msg.id || vm.selection.contains(msg.id)
        return HStack(spacing: 8) {
            Avatar(address: msg.from)
            Text(msg.from.display)
                .font(msg.isRead ? .body : .body.weight(.bold))
                .lineLimit(1)
            Spacer(minLength: 4)
            // Quick actions appear to the right of the From column when the row is
            // hovered (via TableHoverTracker) or selected.
            if show {
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
/// Hover is NOT handled here — see `TableHoverTracker` on the Table itself, because
/// SwiftUI's `.onHover` (and any per-cell tracking) fights `Table`'s cell recycling.
private struct RowInteraction: ViewModifier {
    let onDrag: () -> NSItemProvider
    let onClick: () -> Void
    let onOpen: () -> Void

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onDrag(onDrag)
            .simultaneousGesture(TapGesture(count: 2).onEnded(onOpen))
            .simultaneousGesture(TapGesture(count: 1).onEnded(onClick))
    }
}

/// Reliable row hover for the message `Table`. A single tracking view sits on the
/// whole table (via `.background`), so — unlike a per-cell tracker — it is never torn
/// down when revealing the icons re-renders a cell. On mouse move it asks the
/// underlying `NSTableView` which row is under the cursor and reports that row's id.
/// Click-through (`hitTest` → nil) so it never intercepts the row's drag or taps.
struct TableHoverTracker: NSViewRepresentable {
    /// Maps a table row index to the message id at that row (reads displayedMessages).
    let idForRow: (Int) -> String?
    /// Reports the hovered row id (nil when the cursor is off any row).
    let setHovered: (String?) -> Void

    func makeNSView(context: Context) -> TableHoverNSView {
        let v = TableHoverNSView()
        v.idForRow = idForRow
        v.setHovered = setHovered
        return v
    }

    func updateNSView(_ v: TableHoverNSView, context: Context) {
        v.idForRow = idForRow
        v.setHovered = setHovered
    }
}

final class TableHoverNSView: NSView {
    var idForRow: ((Int) -> String?)?
    var setHovered: ((String?) -> Void)?
    private var area: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // click-through

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(a)
        area = a
    }

    override func mouseMoved(with event: NSEvent) { update(event) }
    override func mouseEntered(with event: NSEvent) { update(event) }
    override func mouseExited(with event: NSEvent) { setHovered?(nil) }

    /// The NSTableView under the given window point. The sidebar is also an
    /// NSTableView, so we pick the one whose frame actually contains the cursor —
    /// that's always the message list when hovering messages.
    private func tableView(at windowPoint: NSPoint) -> NSTableView? {
        guard let content = window?.contentView else { return nil }
        var match: NSTableView?
        func walk(_ v: NSView) {
            if let t = v as? NSTableView, t.convert(t.bounds, to: nil).contains(windowPoint) {
                match = t
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(content)
        return match
    }

    private func update(_ event: NSEvent) {
        let wp = event.locationInWindow
        guard let table = tableView(at: wp) else { setHovered?(nil); return }
        let row = table.row(at: table.convert(wp, from: nil))
        setHovered?(row >= 0 ? idForRow?(row) : nil)
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
