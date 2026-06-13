import SwiftUI

/// One node in the folder hierarchy. `folder` is nil for synthesized parent
/// nodes (a nested label whose parent isn't itself a label).
struct FolderNode: Identifiable, Hashable {
    var id: String
    var name: String
    var folder: MailFolder?
    var children: [FolderNode]?
}

/// Left pane: Favorites section, then the account's folder tree (nested labels
/// shown hierarchically), each row with an unread badge.
struct SidebarView: View {
    @Environment(MailboxViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm
        List(selection: $vm.sidebarSelection) {
            if !vm.favorites.isEmpty {
                Section("Favorites") {
                    ForEach(vm.favorites) { folder in
                        row(folder).tag("fav:\(folder.id)")
                    }
                }
            }
            Section(vm.accountEmail.isEmpty ? "Mailbox" : vm.accountEmail) {
                OutlineGroup(folderTree(vm.folders), children: \.children) { node in
                    nodeRow(node)
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: vm.sidebarSelection) { _, newValue in
            guard let newValue else { return }
            Task { await vm.selectRow(newValue) }
        }
    }

    @ViewBuilder
    private func nodeRow(_ node: FolderNode) -> some View {
        if let folder = node.folder {
            row(folder).tag("acct:\(folder.id)")
        } else {
            // Synthesized parent (not a real label) — shown but not selectable.
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 18)
                Text(node.name).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func row(_ folder: MailFolder) -> some View {
        HStack(spacing: 8) {
            Image(systemName: folder.kind.icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(folder.name)
                .lineLimit(1)
            Spacer()
            if folder.unreadCount > 0 {
                Text("\(folder.unreadCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .contextMenu {
            if vm.isFavorite(folder.id) {
                Button("Remove from Favorites") { vm.toggleFavorite(folder.id) }
            } else {
                Button("Add to Favorites") { vm.toggleFavorite(folder.id) }
            }
        }
    }

    /// Builds a hierarchy from folder paths ("Work/Receipts"), synthesizing any
    /// missing intermediate nodes. System folders sort first (by kind), then
    /// custom labels alphabetically.
    private func folderTree(_ folders: [MailFolder]) -> [FolderNode] {
        final class Builder {
            var id: String
            var name: String
            var folder: MailFolder?
            var children: [String: Builder] = [:]
            init(id: String, name: String) { self.id = id; self.name = name }
        }

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
            // Real folders use the provider id; synthesized parents use a
            // distinct "path:" id so they can't collide with a folder id
            // (e.g. the Gmail label id "INBOX" vs a synthesized "INBOX" node).
            let nodeId = builder.folder?.id ?? "path:\(builder.id)"
            return FolderNode(
                id: nodeId, name: builder.name, folder: builder.folder,
                children: kids.isEmpty ? nil : kids
            )
        }
        return root.children.values.map(convert).sorted { sortKey($0) < sortKey($1) }
    }
}
