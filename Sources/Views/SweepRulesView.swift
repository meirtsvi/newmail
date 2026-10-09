import SwiftUI

/// Editor for sweep rules: each rule is a name, a set of sender addresses, and a
/// target folder. Every rule whose folder is in the current account shows up as
/// a chip in the move bar. Edits save immediately.
struct SweepRulesView: View {
    @Environment(MailboxViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    let initialRuleId: UUID?

    @State private var selectedId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sweep Rules").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            HStack(spacing: 0) {
                ruleList.frame(width: 180)
                Divider()
                if let id = selectedId, vm.sweepRules.contains(where: { $0.id == id }) {
                    SweepRuleEditor(ruleId: id).id(id)
                } else {
                    Text(vm.sweepRules.isEmpty ? "Add a rule with +" : "Select a rule")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 640, height: 480)
        .onAppear { selectedId = initialRuleId ?? vm.sweepRules.first?.id }
    }

    private var ruleList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedId) {
                ForEach(vm.sweepRules) { rule in
                    Text(rule.name.isEmpty ? "Untitled" : rule.name).tag(rule.id)
                }
            }
            Divider()
            HStack(spacing: 4) {
                Button {
                    selectedId = vm.addSweepRule(name: "New Rule").id
                } label: { Image(systemName: "plus") }
                .help("Add a rule")
                Button {
                    guard let id = selectedId else { return }
                    vm.deleteSweepRule(id)
                    selectedId = vm.sweepRules.first?.id
                } label: { Image(systemName: "minus") }
                .disabled(selectedId == nil)
                .help("Delete the selected rule")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }
}

/// Edits one rule in place in `vm.sweepRules`.
private struct SweepRuleEditor: View {
    @Environment(MailboxViewModel.self) private var vm
    let ruleId: UUID

    @State private var senderQuery = ""
    @State private var folderQuery = ""

    private var rule: SweepRule? { vm.sweepRules.first { $0.id == ruleId } }

    private func edit(_ change: (inout SweepRule) -> Void) {
        guard var r = rule else { return }
        change(&r)
        vm.updateSweepRule(r)
    }

    var body: some View {
        if let rule {
            Form {
                Section("Name") {
                    TextField("Name", text: Binding(
                        get: { rule.name },
                        set: { name in edit { $0.name = name } }
                    ))
                    .labelsHidden()
                }
                Section("Senders") { senders(rule) }
                Section("Move to") { folderPicker(rule) }
            }
            .formStyle(.grouped)
        }
    }

    // MARK: Senders

    @ViewBuilder
    private func senders(_ rule: SweepRule) -> some View {
        ForEach(rule.addresses, id: \.self) { address in
            HStack {
                Text(address)
                Spacer()
                Button {
                    edit { $0.addresses.removeAll { $0 == address } }
                } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove \(address)")
            }
        }
        TextField("Search contacts or type an address", text: $senderQuery)
            .onSubmit { addSender(senderSuggestions(rule).first?.email ?? senderQuery) }
        ForEach(senderSuggestions(rule)) { suggestion in
            Button { addSender(suggestion.email) } label: {
                Text(suggestion.nameAndEmail).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }

    /// Contact matches for the search field, minus addresses already in the rule.
    private func senderSuggestions(_ rule: SweepRule) -> [MailAddress] {
        let term = senderQuery.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return [] }
        let existing = Set(rule.addresses.map { $0.lowercased() })
        return vm.contactSuggestions(term, limit: 8).filter { !existing.contains($0.email.lowercased()) }
    }

    private func addSender(_ raw: String) {
        let email = raw.trimmingCharacters(in: .whitespaces)
        guard email.contains("@") else { return }
        edit { r in
            if !r.addresses.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) {
                r.addresses.append(email)
            }
        }
        senderQuery = ""
    }

    // MARK: Target folder

    @ViewBuilder
    private func folderPicker(_ rule: SweepRule) -> some View {
        TextField("Filter folders", text: $folderQuery)
        ForEach(vm.sessions) { session in
            let folders = matchingFolders(session.account.id)
            if !folders.isEmpty {
                Text(session.account.displayName.isEmpty ? session.account.email : session.account.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(folders, id: \.compositeId) { folder in
                    Button {
                        edit { $0.targetFolderId = folder.compositeId }
                    } label: {
                        HStack {
                            Label(folder.path.isEmpty ? folder.name : folder.path, systemImage: folder.kind.icon)
                            Spacer()
                            if folder.compositeId == rule.targetFolderId {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The account's folders except the Inbox, system folders first then by name,
    /// narrowed by the filter (folders starting with the term first).
    private func matchingFolders(_ accountId: String) -> [MailFolder] {
        let all = (vm.foldersByAccount[accountId] ?? [])
            .filter { $0.kind != .inbox }
            .sorted { ($0.kind.sortWeight, $0.name) < ($1.kind.sortWeight, $1.name) }
        let term = folderQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return all }
        let hits = all.filter { $0.name.lowercased().contains(term) }
        return hits.filter { $0.name.lowercased().hasPrefix(term) }
            + hits.filter { !$0.name.lowercased().hasPrefix(term) }
    }
}
