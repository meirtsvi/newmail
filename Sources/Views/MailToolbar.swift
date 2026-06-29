import SwiftUI

/// The window toolbar mirroring the reference UI's quick-action row. All actions
/// operate on the current selection and route through the shared view model.
/// Every control has a `.help` tooltip shown on hover.
struct MailToolbar: ToolbarContent {
    @Bindable var vm: MailboxViewModel

    private var ids: [String] { Array(vm.selection) }
    private var hasSelection: Bool { !vm.selection.isEmpty }

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { vm.startNewMail() } label: {
                Label("New Mail", systemImage: "square.and.pencil")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help("New Mail (⌘N)")
        }

        ToolbarItemGroup {
            Button { Task { await vm.toggleFlag(ids) } } label: {
                Label("Flag", systemImage: "flag")
            }
            .disabled(!hasSelection)
            .help("Flag")

            Button { vm.startReply(all: false) } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!hasSelection)
            .help("Reply (⌘R)")

            Button { vm.startReply(all: true) } label: {
                Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!hasSelection)
            .help("Reply All (⇧⌘R)")

            Button { vm.startForward() } label: {
                Label("Forward", systemImage: "arrowshape.turn.up.right")
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!hasSelection)
            .help("Forward (⌘F)")

            Button { if let id = ids.first { vm.editMessage(id) } } label: {
                Label("Edit", systemImage: "pencil")
            }
            .disabled(vm.selection.count != 1)
            .help("Edit message")

            Button { Task { await vm.deleteMessages(ids) } } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!hasSelection)
            .help("Delete (⌫)")

            Menu {
                Button { Task { await vm.cleanupConversation() } } label: {
                    Label("Cleanup Selected", systemImage: "wand.and.rays")
                }
                .disabled(vm.selection.count != 1)

                Button { Task { await vm.cleanupFolder() } } label: {
                    Label("Cleanup Folder", systemImage: "folder")
                }
                .disabled(vm.messages.isEmpty)
            } label: {
                Label("Cleanup", systemImage: "wand.and.rays")
            } primaryAction: {
                Task { await vm.cleanupConversation() }
            }
            .disabled(vm.isCleaningUp)
            .help("Cleanup")

            Menu {
                MoveMenu(vm: vm, ids: ids)
            } label: {
                Label("Move", systemImage: "folder")
            }
            .disabled(!hasSelection)
            .help("Move to folder")

            Menu {
                SnoozeMenu(vm: vm, ids: ids)
            } label: {
                Label("Snooze", systemImage: "clock")
            }
            .disabled(!hasSelection)
            .help("Snooze")

            Button { Task { await vm.markRead(ids, read: !allSelectedRead) } } label: {
                Label(allSelectedRead ? "Mark Unread" : "Mark Read",
                      systemImage: allSelectedRead ? "envelope.badge" : "envelope.open")
            }
            .disabled(!hasSelection)
            .help(allSelectedRead ? "Mark as Unread" : "Mark as Read")

            Button { Task { await vm.sync() } } label: {
                Label("Sync", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .help("Sync (⌥⌘R)")
        }
    }

    private var allSelectedRead: Bool {
        let chosen = vm.selectedHeaders
        return !chosen.isEmpty && chosen.allSatisfy { $0.isRead }
    }
}
