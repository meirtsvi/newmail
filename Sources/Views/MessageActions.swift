import SwiftUI

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
