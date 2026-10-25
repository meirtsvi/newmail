import SwiftUI
import AppKit

/// Middle pane: a sortable, multi-select Table of message headers with a
/// folder-title header bar. Sorting is driven by the column headers; hovering a
/// row reveals quick actions; right-click opens the shared context menu.
/// Holds the currently-hovered row id. It must be `@Observable` (not a plain `@State`
/// scalar) so the `Table` re-renders the affected cells: `Table` only re-runs its cell
/// builders for data/selection it tracks via Observation, so a plain `@State` change is
/// ignored by the rows — exactly how `vm.selection` reaches the cells.
@Observable final class RowHoverModel {
    var id: String?
    /// The row whose *Date* cell the cursor is over — the quick actions live there,
    /// so they only appear when you point at them.
    var dateColumnId: String?
}

struct MessageListView: View {
    @Environment(MailboxViewModel.self) private var vm
    @State private var hover = RowHoverModel()
    /// Drives keyboard focus onto the table (see the folder-change handler below).
    @FocusState private var tableFocused: Bool
    @State private var columnCustomization = TableColumnCustomization<MessageHeader>()
    /// Finds the backing NSTableView for palette scroll-to-row (see `scrollToMessage`).
    @State private var tableLocator = TableLocator()

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
        // Opening a folder — from the sidebar tree, from Favorites, or at launch —
        // hands keyboard focus to the message list, so ⌘A selects that folder's mail
        // without having to click a row first. Deferred a runloop because the click
        // that changed the selection leaves the sidebar's own table first responder,
        // and focus set inside the same pass is overwritten by it.
        .onChange(of: vm.currentFolder?.compositeId) { _, folder in
            guard folder != nil else { return }
            DispatchQueue.main.async { tableFocused = true }
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
    /// user pull the rest in on demand. An Inbox listing hides it until it holds
    /// at least 200 messages.
    @ViewBuilder
    private var loadOlderFooter: some View {
        if vm.canLoadMore,
           vm.isSearching || vm.currentFolder?.kind != .inbox || vm.displayedMessages.count >= 200 {
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
                if let listed = vm.listedCount {
                    Text("(\(listed))")
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

    /// Row pitch of the message list, in points (row plus the gap below it).
    private static let rowHeight: CGFloat = 28

    private var table: some View {
        @Bindable var vm = vm
        // Rows are native drag sources (`itemProvider`), so the table keeps its own
        // click, ⌘/⇧-click selection and drag handling. Per-cell SwiftUI drag and tap
        // gestures were left stuck after a drop (the drag session takes the mouse-up),
        // which swallowed later clicks and froze the sidebar. Row order matches
        // `displayedMessages`, already sorted by the view model.
        return Table(
            of: MessageHeader.self,
            selection: $vm.selection,
            sortOrder: $vm.sortOrder,
            columnCustomization: $columnCustomization
        ) {
            columns
        } rows: {
            ForEach(vm.displayedMessages) { msg in
                TableRow(msg).itemProvider { MessageDragPayload.itemProvider(ids: [msg.id]) }
            }
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
                // SwiftUI names the backing NSTableColumn after the column's
                // `customizationID`; fall back to the header title in case that
                // ever changes.
                isActionColumn: { $0.identifier.rawValue == "date" || $0.title == "Date" },
                setHovered: { setHovered($0, onDateColumn: $1) }
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
        // ⌘A selects every message in the list; ⌘Z undoes the last delete;
        // ⌥1–⌥4 run the quick actions (handled here so the chord never reaches
        // the table, whose built-in key handling would jump the selection).
        .onKeyPress(phases: .down) { press in
            if QuickActions.keyPress(press, vm: vm) == .handled { return .handled }
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
        // Home/End/PageUp/PageDown scroll the list *and* move the selection. The
        // backing NSTableView consumes these keys before SwiftUI's onKeyPress, so a
        // local event monitor intercepts them while the list is focused.
        .background(ListKeyNavigator(
            isMessageList: { $0.numberOfRows == vm.displayedMessages.count && !vm.displayedMessages.isEmpty },
            perform: { move, table in performListMove(move, in: table) }
        ))
        // Anchors the table locator in this view's window so the ⌘K palette's
        // pick can be scrolled into view (Table has no SwiftUI scroll-to API).
        .background(TableLocatorView(locator: tableLocator))
        .onChange(of: vm.scrollToMessageId) { _, id in scrollToMessage(id) }
        // Rows inserted into an already-laid-out table (new mail lands at the top)
        // are measured before their content is in, so they keep the default row
        // height and clip their text. Every row is the same height, so give the
        // table a fixed one: new rows then never need measuring.
        .onChange(of: vm.displayedMessages.count, initial: true) { _, count in
            DispatchQueue.main.async {
                guard let table = tableLocator.messageTable(rowCount: count) else { return }
                tableLocator.lockRowHeight(of: table, to: Self.rowHeight)
            }
        }
    }

    /// Scrolls the row of `id` (the ⌘K palette's pick) into view.
    private func scrollToMessage(_ id: String?) {
        guard let id else { return }
        vm.scrollToMessageId = nil
        let msgs = vm.displayedMessages
        guard let index = msgs.firstIndex(where: { $0.id == id }) else { return }
        // Next tick: runs after SwiftUI applies the selection change from the
        // palette (same reasoning as `performListMove`).
        DispatchQueue.main.async {
            guard let table = tableLocator.messageTable(rowCount: msgs.count),
                  index < table.numberOfRows else { return }
            let headerHeight = table.headerView?.bounds.height ?? 0
            var rect = table.rect(ofRow: index)
            rect.origin.y -= headerHeight
            rect.size.height += headerHeight
            table.scrollToVisible(rect)
        }
    }

    /// Moves the single selection to the top/bottom/one page away and scrolls the
    /// backing table so the new row is visible. `table` is the focused message list.
    @MainActor
    private func performListMove(_ move: ListMove, in table: NSTableView) {
        let msgs = vm.displayedMessages
        guard !msgs.isEmpty else { return }
        let currentIndex = vm.selection.first.flatMap { id in msgs.firstIndex { $0.id == id } } ?? 0
        // Overlap one row when paging, matching typical page-scroll behavior.
        let pageStep = max(1, table.rows(in: table.visibleRect).length - 1)
        let target: Int
        switch move {
        case .home: target = 0
        case .end: target = msgs.count - 1
        case .pageUp: target = max(0, currentIndex - pageStep)
        case .pageDown: target = min(msgs.count - 1, currentIndex + pageStep)
        }
        guard target >= 0, target < msgs.count else { return }
        vm.selection = [msgs[target].id]
        // Scroll on the next tick so it runs after SwiftUI applies the selection
        // change (otherwise its own relayout races ours and leaves a partial row).
        // Pad the target rect upward by the column-header height so the row clears
        // the floating header instead of hiding half-under it.
        DispatchQueue.main.async {
            guard target < table.numberOfRows else { return }
            let headerHeight = table.headerView?.bounds.height ?? 0
            var rect = table.rect(ofRow: target)
            rect.origin.y -= headerHeight
            rect.size.height += headerHeight
            table.scrollToVisible(rect)
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
        TableColumn(Text("\(Image(systemName: "tag"))").font(.caption),
                    value: \MessageHeader.categorySort) { msg in categoryCell(msg) }
            .width(16)
            .customizationID("category")
        if vm.currentFolder?.kind == .sent {
            TableColumn("To", value: \MessageHeader.toDisplay) { msg in toCell(msg) }
                .width(min: 120, ideal: 240)
                .customizationID("to")
        } else {
            TableColumn("From", value: \MessageHeader.from.display) { msg in fromCell(msg) }
                .width(min: 120, ideal: 240)
                .customizationID("from")
        }
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

    private func flagCell(_ msg: MessageHeader) -> some View {
        Group {
            if msg.isFlagged {
                Image(systemName: "flag.fill").font(.caption).foregroundStyle(.red).help("Flagged")
            }
        }
    }

    private func attachmentCell(_ msg: MessageHeader) -> some View {
        Group {
            if msg.hasAttachments {
                Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary).help("Has attachment")
            }
        }
    }

    /// Category column: calendar events keep their icon, newsletters get theirs,
    /// regular mail shows nothing. Calendar wins when a message is somehow both.
    private func categoryCell(_ msg: MessageHeader) -> some View {
        Group {
            if vm.isCalendarEvent(msg.id) {
                Image(systemName: "calendar").font(.caption).foregroundStyle(.secondary).help("Calendar event")
            } else if vm.isNewsletterMessage(msg) {
                Image(systemName: "newspaper").font(.caption).foregroundStyle(.secondary).help("Newsletter")
            }
        }
    }

    private func dateCell(_ msg: MessageHeader) -> some View {
        // Quick actions take over the date text, but only while the cursor is in
        // this row's Date column (tracked by TableHoverTracker). Everywhere else in
        // the row — and on the selected row — the date stays readable.
        let show = hover.dateColumnId == msg.id
        return Text(msg.date.mailListString)
            .foregroundStyle(.secondary)
            .font(msg.isRead ? .body : .body.weight(.semibold))
            .opacity(show ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                if show {
                    HoverActions(vm: vm, id: msg.id, isFlagged: msg.isFlagged)
                        .transition(.opacity)
                }
            }
    }

    /// Set by `TableHoverTracker` to the row currently under the cursor (nil when off
    /// any row), plus whether the cursor is in that row's Date column. Guarded so
    /// redundant moves within a row don't churn the observable.
    private func setHovered(_ id: String?, onDateColumn: Bool) {
        if hover.id != id { hover.id = id }
        let onDate = onDateColumn ? id : nil
        if hover.dateColumnId != onDate { hover.dateColumnId = onDate }
    }

    private func snoozedUntilCell(_ msg: MessageHeader) -> some View {
        Group {
            if let wake = vm.snoozedUntil(msg.id) {
                Text(wake.mailFullString).foregroundStyle(.secondary)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }

    private func fromCell(_ msg: MessageHeader) -> some View {
        HStack(spacing: 8) {
            Avatar(address: msg.from, size: 20)
            Text(msg.from.display)
                .font(msg.isRead ? .body : .body.weight(.bold))
                .lineLimit(1)
            Spacer(minLength: 4)
        }
    }

    /// Sent-folder replacement for `fromCell`: the recipients, with the first
    /// recipient's avatar.
    private func toCell(_ msg: MessageHeader) -> some View {
        HStack(spacing: 8) {
            Avatar(address: msg.to.first ?? msg.from, size: 20)
            Text(msg.toDisplay)
                .font(msg.isRead ? .body : .body.weight(.bold))
                .lineLimit(1)
            Spacer(minLength: 4)
        }
    }

    private func subjectCell(_ msg: MessageHeader) -> some View {
        Text(msg.subject)
            .font(msg.isRead ? .body : .body.weight(.semibold))
            .lineLimit(1)
    }
}

/// Reliable row hover for the message `Table`. A single tracking view sits on the
/// whole table (via `.background`), so — unlike a per-cell tracker — it is never torn
/// down when revealing the icons re-renders a cell. On mouse move it asks the
/// underlying `NSTableView` which row *and column* are under the cursor, and reports
/// that row's id along with whether the cursor is in the quick-actions column.
/// Click-through (`hitTest` → nil) so it never intercepts the row's drag or taps.
struct TableHoverTracker: NSViewRepresentable {
    /// Maps a table row index to the message id at that row (reads displayedMessages).
    let idForRow: (Int) -> String?
    /// True for the column whose cells reveal the quick actions (the Date column).
    let isActionColumn: (NSTableColumn) -> Bool
    /// Reports the hovered row id (nil when the cursor is off any row) and whether
    /// the cursor sits in that row's action column.
    let setHovered: (String?, Bool) -> Void

    func makeNSView(context: Context) -> TableHoverNSView {
        let v = TableHoverNSView()
        apply(to: v)
        return v
    }

    func updateNSView(_ v: TableHoverNSView, context: Context) {
        apply(to: v)
    }

    private func apply(to v: TableHoverNSView) {
        v.idForRow = idForRow
        v.isActionColumn = isActionColumn
        v.setHovered = setHovered
    }
}

final class TableHoverNSView: NSView {
    var idForRow: ((Int) -> String?)?
    var isActionColumn: ((NSTableColumn) -> Bool)?
    var setHovered: ((String?, Bool) -> Void)?
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
    override func mouseExited(with event: NSEvent) { setHovered?(nil, false) }

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
        guard let table = tableView(at: wp) else { setHovered?(nil, false); return }
        let point = table.convert(wp, from: nil)
        let row = table.row(at: point)
        guard row >= 0, let id = idForRow?(row) else { setHovered?(nil, false); return }
        let column = table.column(at: point)
        let onAction = column >= 0 && column < table.tableColumns.count
            && isActionColumn?(table.tableColumns[column]) == true
        setHovered?(id, onAction)
    }
}

/// A list-navigation key that both scrolls and moves the selection.
enum ListMove {
    case home, end, pageUp, pageDown

    init?(keyCode: UInt16) {
        switch keyCode {
        case 115: self = .home       // Home
        case 119: self = .end        // End
        case 116: self = .pageUp     // Page Up
        case 121: self = .pageDown   // Page Down
        default: return nil
        }
    }
}

/// Installs a local key-down monitor so Home/End/PageUp/PageDown move the message
/// list's selection (not just scroll). Acts only while the message-list NSTableView
/// is first responder — every other responder (sidebar, reading pane, text fields,
/// compose window) sees the key unchanged.
private struct ListKeyNavigator: NSViewRepresentable {
    let isMessageList: @MainActor (NSTableView) -> Bool
    let perform: @MainActor (ListMove, NSTableView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install(isMessageList: isMessageList, perform: perform)
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isMessageList = isMessageList
        context.coordinator.perform = perform
    }

    final class Coordinator {
        var isMessageList: (@MainActor (NSTableView) -> Bool)?
        var perform: (@MainActor (ListMove, NSTableView) -> Void)?
        private var monitor: Any?

        func install(isMessageList: @escaping @MainActor (NSTableView) -> Bool,
                     perform: @escaping @MainActor (ListMove, NSTableView) -> Void) {
            self.isMessageList = isMessageList
            self.perform = perform
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            // Ignore chords (⌘/⌃/⌥/⇧); fn+arrow (which yields Home/End on laptops)
            // sets only .function, which we allow.
            guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  let move = ListMove(keyCode: event.keyCode),
                  let table = Self.tableView(from: event.window?.firstResponder) else { return event }
            var consumed = false
            MainActor.assumeIsolated {
                if isMessageList?(table) == true {
                    perform?(move, table)
                    consumed = true
                }
            }
            return consumed ? nil : event
        }

        private static func tableView(from responder: NSResponder?) -> NSTableView? {
            if let table = responder as? NSTableView { return table }
            var view = responder as? NSView
            while let current = view {
                if let table = current as? NSTableView { return table }
                view = current.superview
            }
            return nil
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

/// Finds the message list's backing NSTableView from a hidden anchor view in the
/// same window. Same row-count heuristic as `ListKeyNavigator` (the sidebar is
/// also an NSTableView, but its row count is the folder tree's, not the list's).
@MainActor
final class TableLocator {
    weak var anchor: NSView?
    private var rowHeightObservation: NSKeyValueObservation?
    private weak var observedTable: NSTableView?

    /// Gives `table` a fixed row pitch of `height` points. SwiftUI's Table puts
    /// its own row height back after updates, so watch it and reapply.
    func lockRowHeight(of table: NSTableView, to height: CGFloat) {
        let apply = { [weak table] in
            guard let table else { return }
            let target = height - table.intercellSpacing.height
            if table.usesAutomaticRowHeights { table.usesAutomaticRowHeights = false }
            if table.rowHeight != target { table.rowHeight = target }
            // The columns fill the list's width; a horizontal scroller only
            // appears when they overshoot it by a few points.
            if table.enclosingScrollView?.hasHorizontalScroller == true {
                table.enclosingScrollView?.hasHorizontalScroller = false
            }
        }
        apply()
        guard observedTable !== table else { return }
        observedTable = table
        // Reapply synchronously, inside SwiftUI's own update, so the reset
        // height is never laid out or drawn — deferring it made the rows
        // visibly jump each time hover re-rendered the cells.
        // The reset briefly shrinks the table, and when scrolled to the bottom the
        // clip view clamps its offset to the shorter height — so after reapplying,
        // the list sits a page higher. Save the offset before the reset and put it
        // back. `reapplying` ignores the nested notifications from our own set.
        var savedOrigin: NSPoint?
        var reapplying = false
        rowHeightObservation = table.observe(\.rowHeight, options: [.prior]) { table, change in
            MainActor.assumeIsolated {
                guard !reapplying else { return }
                let clip = table.enclosingScrollView?.contentView
                if change.isPrior {
                    savedOrigin = clip?.bounds.origin
                    return
                }
                reapplying = true
                apply()
                reapplying = false
                if let clip, let origin = savedOrigin, clip.bounds.origin != origin {
                    clip.scroll(to: origin)
                    table.enclosingScrollView?.reflectScrolledClipView(clip)
                }
                savedOrigin = nil
            }
        }
    }

    func messageTable(rowCount: Int) -> NSTableView? {
        guard rowCount > 0 else { return nil }
        // Climb from the anchor and search each enclosing subtree, so the
        // nearest matching table (the message list, a sibling of the anchor)
        // wins before the walk ever widens to the sidebar's.
        var root = anchor?.superview
        while let current = root {
            if let t = firstTable(in: current, rowCount: rowCount) { return t }
            root = current.superview
        }
        return nil
    }

    private func firstTable(in view: NSView, rowCount: Int) -> NSTableView? {
        if let t = view as? NSTableView, t.numberOfRows == rowCount { return t }
        for sub in view.subviews {
            if let t = firstTable(in: sub, rowCount: rowCount) { return t }
        }
        return nil
    }
}

/// Invisible view that gives `TableLocator` a foothold in the window's hierarchy.
private struct TableLocatorView: NSViewRepresentable {
    let locator: TableLocator

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        locator.anchor = v
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        locator.anchor = nsView
    }
}

/// Colored initials avatar (no network lookups).
struct Avatar: View {
    let address: MailAddress
    var size: CGFloat = 26

    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: size, height: size)
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
