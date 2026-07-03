import SwiftUI

/// Root 3-pane layout: Sidebar | Message list | Preview, with the toolbar,
/// search field, and error alert. (Compose opens in its own window.)
struct ContentView: View {
    @Environment(MailboxViewModel.self) private var vm
    @State private var customSnoozeDate = Date().addingTimeInterval(3600)

    var body: some View {
        @Bindable var vm = vm
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 220)
        } content: {
            VStack(spacing: 0) {
                // Always visible so it's ready the instant you switch folders —
                // tap a chip to move the selection, or drag messages onto one.
                MoveBarView()
                Divider()
                MessageListView()
                Divider()
                StatusBar()
            }
            // navigationSplitViewColumnWidth (not .frame) is what actually
            // constrains the split-view divider drag on macOS; with only a
            // .frame minWidth the divider can be dragged past the limit and
            // the fixed-width pane overflows under its neighbor.
            .navigationSplitViewColumnWidth(min: 440, ideal: 540)
        } detail: {
            MessagePreviewView()
                // 440 keeps the header's fixed controls (zoom, reply, forward,
                // delete, translate) on screen even with the sender name fully
                // truncated.
                .navigationSplitViewColumnWidth(min: 440, ideal: 600)
        }
        .toolbar {
            MailToolbar(vm: vm)
            // Wide search field on the leading side, right after the compose button.
            ToolbarItem(placement: .navigation) {
                ToolbarSearchField(vm: vm)
            }
        }
        // Drop the window title so the search field and action buttons reclaim that
        // space and the whole toolbar fits without an overflow (») menu.
        .toolbar(removing: .title)
        // Escape clears the search field and reloads the folder's full list.
        .onKeyPress(.escape) {
            guard !vm.searchText.isEmpty else { return .ignored }
            Task { await vm.clearSearch() }
            return .handled
        }
        // ⌘F focuses the search field (ToolbarSearchField observes this toggle).
        .onKeyPress(keys: ["f"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            vm.focusSearchRequested.toggle()
            return .handled
        }
        // The custom-snooze picker is the only remaining sheet (the message
        // detail view now opens in its own resizable window).
        .sheet(item: $vm.activeSheet) { sheet in
            switch sheet {
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

/// Centered toolbar search field (replaces the system `.searchable`) with a
/// scope menu (current folder / all folders) and an inline clear button.
private struct ToolbarSearchField: View {
    @Bindable var vm: MailboxViewModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if vm.isSearchInProgress {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            TextField("Search mail — try from:, to:, subject:", text: $vm.searchText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { Task { await vm.runSearch() } }
                .onKeyPress(.escape) {
                    guard !vm.searchText.isEmpty else { return .ignored }
                    Task { await vm.clearSearch() }
                    return .handled
                }
                // 620 (was 700) makes room for the Newsletters + Digest toolbar
                // buttons; any wider and the search field falls into the » menu.
                .frame(minWidth: 620)
            if !vm.searchText.isEmpty {
                Button { Task { await vm.clearSearch() } } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Menu {
                Picker("Scope", selection: $vm.searchScope) {
                    ForEach(SearchScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                // Combobox-style label that shows the active scope's text, so the
                // current search reach is visible without opening the menu.
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(vm.searchScope.rawValue)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Search scope")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 900)
        // Re-run the search when the scope changes while a query is active.
        .onChange(of: vm.searchScope) { _, _ in
            if !vm.searchText.isEmpty { Task { await vm.runSearch() } }
        }
        // ⌘F (handled in ContentView) toggles this to pull focus here.
        .onChange(of: vm.focusSearchRequested) { _, _ in focused = true }
    }
}

/// Thin bottom bar showing non-modal connection / sync status. Connection and
/// load errors land here (orange) instead of interrupting with an alert.
struct StatusBar: View {
    @Environment(MailboxViewModel.self) private var vm

    var body: some View {
        HStack(spacing: 6) {
            statusContent
            Spacer()
            if let folder = vm.currentFolder, folder.totalCount > 0 {
                Text("\(folder.totalCount) messages")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if vm.statusMessage != nil {
                Button {
                    Task { await vm.sync() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Retry")
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(.bar)
    }

    @ViewBuilder
    private var statusContent: some View {
        if let status = vm.statusMessage {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(status)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(status)
        } else if vm.isCleaningUp {
            ProgressView().controlSize(.small)
            Text(vm.cleanupProgress ?? "Cleaning up conversation…").foregroundStyle(.secondary)
        } else if let result = vm.cleanupResult {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
            Text(result).foregroundStyle(.secondary).lineLimit(1)
        } else if vm.isGeneratingDigest {
            ProgressView().controlSize(.small)
            Text(vm.digestProgress ?? "Generating digest…").foregroundStyle(.secondary)
        } else if let result = vm.digestResult {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
            Text(result).foregroundStyle(.secondary).lineLimit(1)
        } else if vm.isSearchInProgress {
            ProgressView().controlSize(.small)
            Text("Searching…").foregroundStyle(.secondary)
        } else if vm.isSearching, let summary = vm.searchResultSummary {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            Text(summary).foregroundStyle(.secondary).lineLimit(1)
        } else if vm.isLoading {
            ProgressView().controlSize(.small)
            Text("Updating…").foregroundStyle(.secondary)
        } else {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
            Text(vm.accountEmail.isEmpty ? "Ready" : vm.accountEmail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
