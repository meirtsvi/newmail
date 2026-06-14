import SwiftUI

/// One node in the folder hierarchy. `folder` is nil for synthesized parent
/// nodes (a nested label whose parent isn't itself a label).
struct FolderNode: Identifiable, Hashable {
    var id: String
    var name: String
    var folder: MailFolder?
    var children: [FolderNode]?
}

/// Left pane: Favorites section, then one section per account (each an
/// expandable folder tree with unread badges), then an "Add account" button.
struct SidebarView: View {
    @Environment(MailboxViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm
        List(selection: $vm.sidebarSelection) {
            if !vm.favorites.isEmpty {
                Section("Favorites") {
                    ForEach(vm.favorites, id: \.compositeId) { folder in
                        row(folder, accountSuffix: favoriteSuffix(folder)).tag("fav:\(folder.compositeId)")
                    }
                }
            }

            ForEach(vm.sessions) { session in
                Section {
                    OutlineGroup(folderTree(vm.foldersByAccount[session.account.id] ?? []), children: \.children) { node in
                        nodeRow(node)
                    }
                } header: {
                    Text(session.account.displayName.isEmpty ? session.account.email : session.account.displayName)
                        .contextMenu {
                            Button("Remove Account", role: .destructive) {
                                vm.removeAccount(session.account.id)
                            }
                        }
                }
            }

            Section {
                Button {
                    Task { await vm.addMicrosoftAccount() }
                } label: {
                    Label(vm.isSigningIn ? "Adding…" : "Add Microsoft Account", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .disabled(vm.isSigningIn)
            }
        }
        .listStyle(.sidebar)
        .onChange(of: vm.sidebarSelection) { _, newValue in
            guard let newValue, newValue.hasPrefix("fav:") || newValue.hasPrefix("acct:") else { return }
            Task { await vm.selectRow(newValue) }
        }
    }

    @ViewBuilder
    private func nodeRow(_ node: FolderNode) -> some View {
        if let folder = node.folder {
            row(folder).tag("acct:\(folder.compositeId)")
        } else {
            // Synthesized parent (not a real folder) — shown but not selectable.
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 18)
                Text(node.name).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// When two favorites share a leaf name (e.g. "Inbox" on multiple accounts),
    /// disambiguate by appending the owning account's email.
    private func favoriteSuffix(_ folder: MailFolder) -> String? {
        let collides = vm.favorites.contains {
            $0.compositeId != folder.compositeId && $0.name == folder.name
        }
        guard collides else { return nil }
        return vm.sessions.first { $0.account.id == folder.accountId }?.account.email
    }

    private func row(_ folder: MailFolder, accountSuffix: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: folder.kind.icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(folder.name)
                .lineLimit(1)
            if let accountSuffix {
                Text("(\(accountSuffix))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if folder.unreadCount > 0 {
                Text("\(folder.unreadCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .contextMenu {
            if vm.isFavorite(folder) {
                Button("Remove from Favorites") { vm.toggleFavorite(folder) }
            } else {
                Button("Add to Favorites") { vm.toggleFavorite(folder) }
            }
        }
    }

    /// Builds a hierarchy from folder paths ("Work/Receipts"), synthesizing any
    /// missing intermediate nodes. System folders sort first (by kind), then
    /// custom folders alphabetically. Node ids are prefixed with the account id
    /// so two accounts' identical folder ids (e.g. "INBOX") never collide.
    private func folderTree(_ folders: [MailFolder]) -> [FolderNode] {
        final class Builder {
            var id: String
            var name: String
            var folder: MailFolder?
            var children: [String: Builder] = [:]
            init(id: String, name: String) { self.id = id; self.name = name }
        }

        let accountId = folders.first?.accountId ?? ""
        let root = Builder(id: "", name: "")
        for folder in folders {
            let components = folder.pathComponents
            guard !components.isEmpty else { continue }
            var node = root
            var pathSoFar = ""
            for (index, component) in components.enumerated() {
                pathSoFar = pathSoFar.isEmpty ? component : pathSoFar + "/" + component
                let child = node.children[component] ?? {
                    let made = Builder(id: pathSoFar, name: component)
                    node.children[component] = made
                    return made
                }()
                node = child
                if index == components.count - 1 {
                    node.folder = folder
                }
            }
        }

        func sortKey(_ node: FolderNode) -> (Int, String) {
            (node.folder?.kind.sortWeight ?? 99, node.name)
        }
        func convert(_ builder: Builder) -> FolderNode {
            let kids = builder.children.values.map(convert).sorted {
                sortKey($0) < sortKey($1)
            }
            // Real folders use the account-scoped composite id; synthesized
            // parents use a distinct "path:" id so they can't collide.
            let nodeId = builder.folder?.compositeId ?? "\(accountId)\u{1}path:\(builder.id)"
            return FolderNode(
                id: nodeId, name: builder.name, folder: builder.folder,
                children: kids.isEmpty ? nil : kids
            )
        }
        return root.children.values.map(convert).sorted { sortKey($0) < sortKey($1) }
    }
}
