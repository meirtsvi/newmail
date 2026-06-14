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
            MessageListView()
                .frame(minWidth: 440, idealWidth: 540)
        } detail: {
            MessagePreviewView()
                .frame(minWidth: 380)
        }
        .toolbar { MailToolbar(vm: vm) }
        .searchable(text: $vm.searchText, placement: .toolbar, prompt: "Search mail")
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
