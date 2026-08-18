import SwiftUI

/// One node in the folder hierarchy. `folder` is nil for synthesized parent
/// nodes (a nested label whose parent isn't itself a label).
struct FolderNode: Identifiable, Hashable {
    var id: String
    var name: String
    var folder: MailFolder?
    var children: [FolderNode]?
}

/// One visible line of the flattened folder tree: a node plus its nesting depth.
private struct FlatFolderRow: Identifiable {
    let node: FolderNode
    let depth: Int
    var id: String { node.id }
}

/// Left pane: Favorites section, then one section per account (each an
/// expandable folder tree with unread badges), then an "Add account" button.
struct SidebarView: View {
    @Environment(MailboxViewModel.self) private var vm

    /// Pending "New Folder" / "New Sub-folder" target: the account to create in
    /// and the parent folder (nil for a top-level folder).
    private struct CreateTarget: Identifiable {
        let accountId: String
        let parent: MailFolder?
        var id: String { (parent?.compositeId ?? "") + "\u{1}" + accountId }
    }

    @State private var createTarget: CreateTarget?
    @State private var newFolderName = ""
    @State private var deleteTarget: MailFolder?
    /// Ids of the tree nodes whose children are showing.
    @State private var expandedNodes: Set<String> = []

    var body: some View {
        @Bindable var vm = vm
        List(selection: $vm.sidebarSelection) {
            if !vm.favorites.isEmpty {
                Section("Favorites") {
                    ForEach(vm.favorites, id: \.compositeId) { folder in
                        row(folder, accountSuffix: favoriteSuffix(folder)).tag("fav:\(folder.compositeId)")
                    }
                    .onMove { vm.moveFavorite(fromOffsets: $0, toOffset: $1) }
                }
            }

            ForEach(vm.sessions) { session in
                Section {
                    // A flattened tree rather than an `OutlineGroup`: inside a
                    // selectable List the outline rows hang on to their selected
                    // highlight, so every sub-folder visited stays lit up.
                    ForEach(visibleRows(vm.foldersByAccount[session.account.id] ?? [])) { entry in
                        treeRow(entry).tag(entry.node.id)
                    }
                } header: {
                    Text(session.account.displayName.isEmpty ? session.account.email : session.account.displayName)
                        .contextMenu {
                            Button("New Folder…") {
                                newFolderName = ""
                                createTarget = CreateTarget(accountId: session.account.id, parent: nil)
                            }
                            Divider()
                            Button("Remove Account", role: .destructive) {
                                vm.removeAccount(session.account.id)
                            }
                        }
                }
            }

            Section {
                // The app supports a single Google identity (one stored token),
                // so the connect offer disappears once it's signed in — re-auth
                // lives in Settings → Account.
                if !vm.hasConnectedGoogleAccount {
                    Button {
                        Task { await vm.signInForWriteAccess() }
                    } label: {
                        Label(vm.isSigningIn ? "Adding…" : "Add Google Account", systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isSigningIn)
                }
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
        .alert(createTarget?.parent == nil ? "New Folder" : "New Sub-folder",
               isPresented: Binding(get: { createTarget != nil },
                                    set: { if !$0 { createTarget = nil } })) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) { createTarget = nil }
            Button("Create") {
                if let target = createTarget {
                    let name = newFolderName
                    Task { await vm.createFolder(named: name, under: target.parent, accountId: target.accountId) }
                }
                createTarget = nil
            }
        } message: {
            if let parent = createTarget?.parent {
                Text("Inside “\(parent.name)”.")
            }
        }
        .alert("Delete “\(deleteTarget?.name ?? "")”?",
               isPresented: Binding(get: { deleteTarget != nil },
                                    set: { if !$0 { deleteTarget = nil } }),
               presenting: deleteTarget) { folder in
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                Task { await vm.deleteFolder(folder) }
                deleteTarget = nil
            }
        } message: { folder in
            let subCount = vm.descendantCount(of: folder)
            if subCount > 0 {
                Text("This also deletes its \(subCount) sub-folder\(subCount == 1 ? "" : "s") and the messages they contain (on Outlook).")
            } else {
                Text("This deletes the messages it contains (on Outlook).")
            }
        }
    }

    /// Flattens an account's folder tree down to the rows currently on show.
    private func visibleRows(_ folders: [MailFolder]) -> [FlatFolderRow] {
        var rows: [FlatFolderRow] = []
        func walk(_ nodes: [FolderNode], depth: Int) {
            for node in nodes {
                rows.append(FlatFolderRow(node: node, depth: depth))
                if let children = node.children, expandedNodes.contains(node.id) {
                    walk(children, depth: depth + 1)
                }
            }
        }
        walk(folderTree(folders), depth: 0)
        return rows
    }

    private func treeRow(_ entry: FlatFolderRow) -> some View {
        HStack(spacing: 2) {
            disclosure(entry.node)
            nodeRow(entry.node)
        }
        .padding(.leading, CGFloat(entry.depth) * 14)
    }

    /// The expand/collapse chevron, or a matching blank for a leaf folder.
    @ViewBuilder
    private func disclosure(_ node: FolderNode) -> some View {
        if node.children != nil {
            Button {
                if expandedNodes.contains(node.id) { expandedNodes.remove(node.id) }
                else { expandedNodes.insert(node.id) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expandedNodes.contains(node.id) ? 90 : 0))
                    .frame(width: 13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(width: 13, height: 1)
        }
    }

    @ViewBuilder
    private func nodeRow(_ node: FolderNode) -> some View {
        if let folder = node.folder {
            // Tagged by the caller with the node id, which already carries the
            // "acct:" prefix `selectRow` expects.
            row(folder)
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
            // Drafts badge the number of drafts (total items); every other folder
            // badges its unread count.
            let badge = folder.kind == .drafts ? folder.totalCount : folder.unreadCount
            if badge > 0 {
                Text("\(badge)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .modifier(FolderDropTarget(vm: vm, folder: folder))
        .contextMenu {
            if vm.isFavorite(folder) {
                Button("Remove from Favorites") { vm.toggleFavorite(folder) }
            } else {
                Button("Add to Favorites") { vm.toggleFavorite(folder) }
            }
            if folder.kind == .custom {
                Divider()
                Button("New Sub-folder…") {
                    newFolderName = ""
                    createTarget = CreateTarget(accountId: folder.accountId, parent: folder)
                }
                Button("Delete Folder…", role: .destructive) { deleteTarget = folder }
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
            // The node id doubles as the List's selection value (see `nodeRow`).
            // Real folders use the account-scoped composite id behind the "acct:"
            // prefix `selectRow` expects; synthesized parents use a distinct
            // "path:" id so they can't collide — and so they're ignored on click.
            let nodeId = builder.folder.map { "acct:\($0.compositeId)" }
                ?? "\(accountId)\u{1}path:\(builder.id)"
            return FolderNode(
                id: nodeId, name: builder.name, folder: builder.folder,
                children: kids.isEmpty ? nil : kids
            )
        }
        return root.children.values.map(convert).sorted { sortKey($0) < sortKey($1) }
    }
}
