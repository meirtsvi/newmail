import SwiftUI
import AppKit

/// Reusable action controls shared by the toolbar, row-hover overlay, and
/// right-click context menu — a single command surface over a set of message ids.
///
/// These take the view model explicitly rather than via `@Environment`: when a
/// menu is presented from the toolbar or a context menu, the observable
/// environment is not always propagated into that detached hosting context, and
/// reading it at render time traps. Passing `vm` down avoids that crash.

struct SnoozeMenu: View {
    let vm: MailboxViewModel
    let ids: [String]

    var body: some View {
        if vm.currentFolder?.kind == .snoozed {
            Button("Unsnooze") { Task { await vm.unsnoozeMessages(ids) } }
            Divider()
        }
        ForEach(SnoozeService.Preset.allCases) { preset in
            Button(preset.rawValue) {
                let wake = SnoozeService.wakeDate(for: preset)
                Task { await vm.snoozeMessages(ids, until: wake) }
            }
        }
        Divider()
        // A sheet can't present from inside a menu, so route through the view
        // model; ContentView shows the date/time picker.
        Button("Custom…") { vm.requestCustomSnooze(ids) }
    }
}

struct CustomSnoozeSheet: View {
    @Binding var date: Date
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Snooze until").font(.headline)
            // The graphical style doesn't reliably surface an editable hour field
            // when combined with .hourAndMinute, so pick the day graphically and
            // the time with a separate field picker (both bound to the same date).
            DatePicker("", selection: $date, in: Date()...,
                       displayedComponents: [.date])
                .datePickerStyle(.graphical)
                .labelsHidden()
            DatePicker("Time", selection: $date,
                       displayedComponents: [.hourAndMinute])
                .datePickerStyle(.field)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Snooze") { onConfirm(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

struct MoveMenu: View {
    let vm: MailboxViewModel
    let ids: [String]
    /// When true, list only the user's quick-move folders (used by the row's move
    /// icon); otherwise list every folder in the account (the right-click menu).
    var quickOnly = false

    private var folders: [MailFolder] {
        let all = quickOnly ? vm.quickMoveForCurrentAccount
                            : vm.currentFolders.filter { $0.kind != .inbox }
        // Never offer the folder that's already open: "moving" into it makes
        // Gmail add and remove the same label, which it rejects (400).
        return all.filter { $0.compositeId != vm.currentFolder?.compositeId }
    }

    var body: some View {
        ForEach(folders, id: \.compositeId) { folder in
            Button {
                Task { await vm.move(ids, to: folder) }
            } label: {
                Label(folder.name, systemImage: folder.kind.icon)
            }
        }
    }
}

/// The ⌥1–⌥4 quick actions on the selected message row. Flag and delete call the
/// same view-model methods the row's hover icons call; move and snooze open the
/// row icons' own SwiftUI menus by synthesizing a click on them, so the popup
/// appears exactly as (and where) it does when clicked with the mouse.
@MainActor
enum QuickActions {
    /// Runs the ⌥-digit quick action on the current selection (1 flag, 2 quick
    /// move, 3 snooze, 4 delete). Shared by both interception paths below.
    static func perform(_ digit: Int, vm: MailboxViewModel) {
        guard !vm.selection.isEmpty else { return }
        let ids = Array(vm.selection)
        switch digit {
        case 1: Task { await vm.toggleFlag(ids) }
        case 2: clickRowIcon(.move, vm: vm)
        case 3: clickRowIcon(.snooze, vm: vm)
        case 4: Task { await vm.deleteMessages(ids) }
        default: break
        }
    }

    /// `onKeyPress` hook for ⌥1–⌥4, attached to the message list and the window
    /// content. Returning `.handled` is what keeps the chord away from the focused
    /// Table/List — their built-in key handling jumps the selection, and it runs
    /// inside SwiftUI's own event interception, which an NSEvent monitor installed
    /// later can observe but not preempt.
    static func keyPress(_ press: KeyPress, vm: MailboxViewModel) -> KeyPress.Result {
        guard press.modifiers.contains(.option),
              !press.modifiers.contains(.command), !press.modifiers.contains(.control),
              let digit = press.key.character.wholeNumberValue, (1...4).contains(digit)
        else { return .ignored }
        // Leave Option-typing alone while a text field (e.g. search) is active.
        if NSApp.keyWindow?.firstResponder is NSTextView { return .ignored }
        perform(digit, vm: vm)
        return .handled
    }

    /// The hover-action icons on a row, right to left: trash, clock, folder, flag
    /// (see `HoverActions` / `dateCell` — they're shown whenever the row is
    /// selected). Values are the icon center's distance from the date cell's
    /// trailing edge.
    private enum RowIcon: CGFloat {
        case snooze = 35
        case move = 57
    }

    /// Synthesizes a mouse click on one of the selected row's action icons — the
    /// same code path as the mouse, so the menu opens exactly where it does when
    /// clicked. The icons live at the trailing edge of the date column (the last
    /// column), visible because the row is selected.
    private static func clickRowIcon(_ icon: RowIcon, vm: MailboxViewModel) {
        guard let window = NSApp.keyWindow, let content = window.contentView,
              let table = messageTable(in: content, rowCount: vm.displayedMessages.count),
              let row = vm.displayedMessages.firstIndex(where: { vm.selection.contains($0.id) }),
              row < table.numberOfRows, table.numberOfColumns > 0 else { return }
        table.scrollRowToVisible(row)
        let cell = table.frameOfCell(atColumn: table.numberOfColumns - 1, row: row)
        let point = table.convert(NSPoint(x: cell.maxX - icon.rawValue, y: cell.midY), to: nil)
        // Queue down then up so it plays back like a real click (the menu opens
        // on the down and keeps tracking after the up, exactly like the mouse).
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    /// The message list's backing NSTableView, told apart from the sidebar's by
    /// its row count matching the displayed messages (same heuristic as
    /// `TableLocator`).
    private static func messageTable(in view: NSView, rowCount: Int) -> NSTableView? {
        guard rowCount > 0 else { return nil }
        if let table = view as? NSTableView, table.numberOfRows == rowCount { return table }
        for sub in view.subviews {
            if let found = messageTable(in: sub, rowCount: rowCount) { return found }
        }
        return nil
    }
}

/// Fallback for the ⌥1–⌥4 quick actions when *nothing* in the window has focus
/// (e.g. right after launch): SwiftUI's `onKeyPress` doesn't fire then, so a local
/// key monitor steps in. It acts only while the window itself is first responder —
/// whenever a view has focus, the `onKeyPress` path above owns the chord (and no
/// focused list can jump, since the monitor only runs when none is focused).
struct QuickActionKeyHandler: NSViewRepresentable {
    let vm: MailboxViewModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.anchor = view
        context.coordinator.vm = vm
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.vm = vm
    }

    final class Coordinator {
        weak var anchor: NSView?
        var vm: MailboxViewModel?
        private var monitor: Any?

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        /// Physical key codes for the 1–4 keys (layout-independent).
        private static let actionKeyCodes: Set<UInt16> = [18, 19, 20, 21]

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard Self.actionKeyCodes.contains(event.keyCode),
                  event.modifierFlags.contains(.option),
                  event.modifierFlags.intersection([.command, .control]).isEmpty,
                  let window = event.window, window === anchor?.window,
                  window.firstResponder === window else { return event }
            if event.type == .keyDown, !event.isARepeat {
                MainActor.assumeIsolated {
                    if let vm {
                        QuickActions.perform(Int(event.keyCode) - 17, vm: vm)  // 18…21 → 1…4
                    }
                }
            }
            return nil
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

/// Compact icon buttons revealed when hovering a message row: flag, move, snooze, delete.
/// The icon currently under the cursor is emphasized (bold + full-opacity).
struct HoverActions: View {
    let vm: MailboxViewModel
    let id: String
    let isFlagged: Bool
    @State private var hoveredSymbol: String?

    var body: some View {
        HStack(spacing: 4) {
            iconButton(isFlagged ? "flag.fill" : "flag", help: isFlagged ? "Unflag" : "Flag") {
                Task { await vm.toggleFlag([id]) }
            }
            Menu {
                MoveMenu(vm: vm, ids: [id], quickOnly: true)
            } label: {
                icon("folder")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Move to folder")
            .onHover { hoveredSymbol = $0 ? "folder" : (hoveredSymbol == "folder" ? nil : hoveredSymbol) }

            Menu {
                SnoozeMenu(vm: vm, ids: [id])
            } label: {
                icon("clock")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Snooze")
            .onHover { hoveredSymbol = $0 ? "clock" : (hoveredSymbol == "clock" ? nil : hoveredSymbol) }

            iconButton("trash", help: "Delete") {
                Task { await vm.deleteMessages([id]) }
            }
        }
        .buttonStyle(.borderless)
        .imageScale(.medium)
        .padding(.horizontal, 4)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { icon(symbol) }
            .help(help)
            .onHover { hoveredSymbol = $0 ? symbol : (hoveredSymbol == symbol ? nil : hoveredSymbol) }
    }

    /// An icon that turns bold + primary when it is the one being hovered.
    private func icon(_ symbol: String) -> some View {
        let isHovered = hoveredSymbol == symbol
        return Image(systemName: symbol)
            .fontWeight(isHovered ? .bold : .regular)
            .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
    }
}

/// The right-click menu for a selection of messages.
struct MessageContextMenu: View {
    let vm: MailboxViewModel
    let ids: [String]

    var body: some View {
        if !ids.isEmpty {
            Button("Reply") { vm.selection = Set(ids); vm.startReply(all: false) }
            Button("Reply All") { vm.selection = Set(ids); vm.startReply(all: true) }
            Button("Forward") { vm.selection = Set(ids); vm.startForward() }
            if ids.count == 1 {
                Button("Edit") { vm.editMessage(ids[0]) }
                Button("Open All Links") { vm.openAllLinks(in: ids[0]) }
            }
            Divider()
            if vm.currentFolder?.kind == .junk {
                Button("Mark as Not Spam") { Task { await vm.markNotSpam(ids) } }
                Divider()
            }
            // A single message offers only the toggle opposite its current state;
            // a multi-selection offers both so a mixed group can be set either way.
            if ids.count == 1 {
                if vm.messages.first(where: { $0.id == ids[0] })?.isRead == true {
                    Button("Mark Unread") { Task { await vm.markRead(ids, read: false) } }
                } else {
                    Button("Mark Read") { Task { await vm.markRead(ids, read: true) } }
                }
            } else {
                Button("Mark Read") { Task { await vm.markRead(ids, read: true) } }
                Button("Mark Unread") { Task { await vm.markRead(ids, read: false) } }
            }
            Button("Flag") { Task { await vm.toggleFlag(ids) } }
            if ids.count == 1, let entry = vm.newsletterMenuEntry(for: ids[0]) {
                switch entry {
                case .add(let title):
                    Button(title) { Task { await vm.addNewsletterRule(forMessage: ids[0]) } }
                case .remove(let title):
                    Button(title) { Task { await vm.removeNewsletterRule(forMessage: ids[0]) } }
                }
            }
            Menu("Move to") { MoveMenu(vm: vm, ids: ids) }
            Menu("Snooze") { SnoozeMenu(vm: vm, ids: ids) }
            Divider()
            Button("Archive") { Task { await vm.archiveMessages(ids) } }
            Button("Delete", role: .destructive) { Task { await vm.deleteMessages(ids) } }
        }
    }
}
