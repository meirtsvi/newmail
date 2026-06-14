import SwiftUI
import UniformTypeIdentifiers

/// Encodes/decodes the set of message ids carried by a row drag. Ids are joined
/// by newline (provider ids never contain one) and ride as plain text so the
/// `.onDrop(of: [.text])` folder targets can read them.
enum MessageDragPayload {
    static func itemProvider(ids: [String]) -> NSItemProvider {
        NSItemProvider(object: ids.joined(separator: "\n") as NSString)
    }

    /// Loads ids from dropped providers and hands them to `completion` on the
    /// main actor. Returns whether a provider was accepted.
    static func load(_ providers: [NSItemProvider], _ completion: @escaping ([String]) -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let string = obj as? String else { return }
            let ids = string.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            guard !ids.isEmpty else { return }
            Task { @MainActor in completion(ids) }
        }
        return true
    }
}

/// Makes a folder row accept a drop of dragged messages (move). Only eligible
/// folders (same account, not the open folder) take the drop and highlight.
/// Apply with `.modifier(FolderDropTarget(vm:folder:))`.
struct FolderDropTarget: ViewModifier {
    let vm: MailboxViewModel
    let folder: MailFolder
    @State private var targeted = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if vm.isDropTarget(folder) {
            content
                .onDrop(of: [.text], isTargeted: $targeted) { providers in
                    MessageDragPayload.load(providers) { ids in
                        Task { await vm.moveDropped(ids, to: folder) }
                    }
                }
                .background(targeted ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4))
        } else {
            content
        }
    }
}

/// Contextual bar above the status bar: tap a folder to move the selected
/// messages there. The visible folders are a user-configured set (gear button).
struct MoveBarView: View {
    @Environment(MailboxViewModel.self) private var vm
    @State private var showConfig = false

    var body: some View {
        HStack(spacing: 8) {
            let folders = vm.quickMoveForCurrentAccount
            if folders.isEmpty {
                Button { showConfig = true } label: {
                    Label("Choose quick-move folders…", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(folders, id: \.compositeId) { folder in
                            chip(folder)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
            Button { showConfig = true } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Configure quick-move folders")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .sheet(isPresented: $showConfig) { QuickMoveConfigView() }
    }

    private func chip(_ folder: MailFolder) -> some View {
        Button {
            Task { await vm.moveDropped(Array(vm.selection), to: folder) }
        } label: {
            Label(folder.name, systemImage: folder.kind.icon)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Move \(vm.selection.count) selected to \(folder.name)")
        .modifier(FolderDropTarget(vm: vm, folder: folder))
    }
}

/// Checklist of every account's folders; ticked folders appear in the move bar.
struct QuickMoveConfigView: View {
    @Environment(MailboxViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Quick-Move Folders").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            List {
                ForEach(vm.sessions) { session in
                    Section(session.account.displayName.isEmpty ? session.account.email : session.account.displayName) {
                        ForEach(folders(for: session.account.id), id: \.compositeId) { folder in
                            Toggle(isOn: Binding(
                                get: { vm.isQuickMove(folder) },
                                set: { _ in vm.toggleQuickMove(folder) }
                            )) {
                                Label(folder.name, systemImage: folder.kind.icon)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 360, height: 460)
    }

    /// Folders offered as move targets: everything except the Inbox, system
    /// folders first (by kind) then custom folders alphabetically.
    private func folders(for accountId: String) -> [MailFolder] {
        (vm.foldersByAccount[accountId] ?? [])
            .filter { $0.kind != .inbox }
            .sorted { ($0.kind.sortWeight, $0.name) < ($1.kind.sortWeight, $1.name) }
    }
}
