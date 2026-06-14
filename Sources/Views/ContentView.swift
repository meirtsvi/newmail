import SwiftUI

/// Root 3-pane layout: Sidebar | Message list | Preview, with the toolbar,
/// search field, compose sheet, and error alert.
struct ContentView: View {
    @Environment(MailboxViewModel.self) private var vm
    @State private var customSnoozeDate = Date().addingTimeInterval(3600)

    var body: some View {
        @Bindable var vm = vm
        NavigationSplitView {
            SidebarView()
                .frame(minWidth: 220)
        } content: {
            VStack(spacing: 0) {
                MessageListView()
                Divider()
                StatusBar()
            }
            .frame(minWidth: 440, idealWidth: 540)
        } detail: {
            MessagePreviewView()
                .frame(minWidth: 380)
        }
        .toolbar { MailToolbar(vm: vm) }
        .searchable(text: $vm.searchText, placement: .toolbar,
                    prompt: "Search mail — try from:, to:, subject:")
        .searchScopes($vm.searchScope) {
            ForEach(SearchScope.allCases) { scope in
                Text(scope.rawValue).tag(scope)
            }
        }
        .onSubmit(of: .search) {
            Task { await vm.runSearch() }
        }
        // A single sheet driven by an enum — reliably presents compose, the
        // message window, and the custom-snooze picker.
        .sheet(item: $vm.activeSheet) { sheet in
            switch sheet {
            case .compose(let request):
                ComposeView(request: request).environment(vm)
            case .message(let header):
                MessageDetailView(header: header).environment(vm)
            case .customSnooze(let ids):
                CustomSnoozeSheet(date: $customSnoozeDate) {
                    Task { await vm.snoozeMessages(ids, until: customSnoozeDate) }
                }
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { vm.errorMessage != nil },
                set: { if !$0 { vm.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .alert(
            "Accounts",
            isPresented: Binding(
                get: { vm.authMessage != nil },
                set: { if !$0 { vm.authMessage = nil } }
            )
        ) {
            Button("OK") { vm.authMessage = nil }
        } message: {
            Text(vm.authMessage ?? "")
        }
    }
}

/// Thin bottom bar showing non-modal connection / sync status. Connection and
/// load errors land here (orange) instead of interrupting with an alert.
struct StatusBar: View {
    @Environment(MailboxViewModel.self) private var vm

    var body: some View {
        HStack(spacing: 6) {
            if let status = vm.statusMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(status)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(status)
                Spacer()
                Button {
                    Task { await vm.sync() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Retry")
            } else if vm.isLoading {
                ProgressView().controlSize(.small)
                Text("Updating…").foregroundStyle(.secondary)
                Spacer()
            } else {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
                Text(vm.accountEmail.isEmpty ? "Ready" : vm.accountEmail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(.bar)
    }
}
