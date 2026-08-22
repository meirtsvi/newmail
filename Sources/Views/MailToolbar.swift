import SwiftUI
import AppKit

/// The window toolbar mirroring the reference UI's quick-action row. All actions
/// operate on the current selection and route through the shared view model.
/// Every control has a `.help` tooltip shown on hover.
struct MailToolbar: ToolbarContent {
    @Bindable var vm: MailboxViewModel
    @AppStorage("darkModeEnabled") private var darkModeEnabled = false

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
            .help("Flag (⌥1)")

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
            .help("Delete (⌫ / ⌥4)")

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

            MoveButton(vm: vm, ids: ids)
                .disabled(!hasSelection)

            Menu {
                SnoozeMenu(vm: vm, ids: ids)
            } label: {
                Label("Snooze", systemImage: "clock")
            }
            .disabled(!hasSelection)
            .help("Snooze (⌥3)")

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

            Button { vm.cycleNewsletterFilter() } label: {
                Label("Newsletters", systemImage: newsletterFilterIcon)
            }
            .help(newsletterFilterHelp)

            Button { Task { await vm.generateDigest() } } label: {
                Label("Digest", systemImage: "sparkles")
            }
            .disabled(vm.isGeneratingDigest)
            .help("Generate a Hebrew digest of new newsletter items")
        }

        // Flexible space pushes the appearance toggle to the toolbar's right
        // edge, apart from the action buttons.
        ToolbarItem { Spacer() }

        ToolbarItem {
            Button {
                darkModeEnabled.toggle()
                AppAppearance.apply(darkMode: darkModeEnabled)
            } label: {
                Label(darkModeEnabled ? "Light Mode" : "Dark Mode",
                      systemImage: darkModeEnabled ? "sun.max" : "moon")
            }
            .help(darkModeEnabled ? "Switch to light mode" : "Switch to dark mode")
        }
    }

    /// Four-state filter icon: all mail / only digests / only newsletters /
    /// everything but newsletters.
    private var newsletterFilterIcon: String {
        switch vm.newsletterFilter {
        case .all: return "newspaper"
        case .onlyDigests: return "sparkles.rectangle.stack"
        case .onlyNewsletters: return "newspaper.fill"
        case .noNewsletters: return "newspaper.circle"
        }
    }

    private var newsletterFilterHelp: String {
        switch vm.newsletterFilter {
        case .all: return "Showing all mail — click to show only digests"
        case .onlyDigests: return "Showing only digests — click to show only newsletters"
        case .onlyNewsletters: return "Showing only newsletters — click to hide newsletters"
        case .noNewsletters: return "Hiding newsletters — click to show all mail"
        }
    }

    private var allSelectedRead: Bool {
        let chosen = vm.selectedHeaders
        return !chosen.isEmpty && chosen.allSatisfy { $0.isRead }
    }
}

/// The toolbar's Move control. A plain `View` rather than an inline `Menu` so it
/// can own the popover's presentation state — `ToolbarContent` is rebuilt with
/// every selection change, and the picker has to survive that.
private struct MoveButton: View {
    let vm: MailboxViewModel
    let ids: [String]
    @State private var showPicker = false

    var body: some View {
        Button { showPicker = true } label: {
            Label("Move", systemImage: "folder")
        }
        .help("Move to folder (⌥2 for quick move)")
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            MovePicker(vm: vm, ids: ids, isPresented: $showPicker)
        }
    }
}
