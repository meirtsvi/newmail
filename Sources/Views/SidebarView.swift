import SwiftUI

/// Left pane: Favorites section, then the account's folder tree, each row with
/// an unread badge. Rows use unique tags ("fav:" / "acct:") so the same folder
/// can appear in both sections without selection ambiguity.
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
                ForEach(vm.folders) { folder in
                    row(folder).tag("acct:\(folder.id)")
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: vm.sidebarSelection) { _, newValue in
            guard let newValue else { return }
            Task { await vm.selectRow(newValue) }
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
}
