import SwiftUI
import UniformTypeIdentifiers

/// Encodes/decodes the set of message ids carried by a row drag. Ids are joined
/// by newline (provider ids never contain one) and ride as plain text so the
/// `.onDrop(of: [.text])` folder targets can read them.
enum MessageDragPayload {
    static func itemProvider(ids: [String]) -> NSItemProvider {
        NSItemProvider(object: ids.joined(separator: "\n") as NSString)
    }

    /// Loads ids from every dropped provider (a multi-row drag carries one per
    /// row) and hands them to `completion` once, on the main actor. Returns
    /// whether a provider was accepted.
    static func load(_ providers: [NSItemProvider], _ completion: @escaping ([String]) -> Void) -> Bool {
        guard !providers.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var ids: [String] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                defer { group.leave() }
                guard let string = obj as? String else { return }
                let found = string.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                lock.withLock { ids.append(contentsOf: found) }
            }
        }
        group.notify(queue: .main) {
            guard !ids.isEmpty else { return }
            completion(ids)
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
    @State private var showSweepRules = false
    /// Each chip's frame in the strip's own (unscrolled) coordinates, and the
    /// strip's width: together they say which chips are cut off right now.
    @State private var chipFrames: [String: CGRect] = [:]
    @State private var stripWidth: CGFloat = 0
    fileprivate static let strip = "moveStrip"

    var body: some View {
        HStack(spacing: 8) {
            let folders = vm.quickMoveForCurrentAccount
            let rules = vm.sweepRulesForCurrentAccount
            if folders.isEmpty && rules.isEmpty {
                Button { showConfig = true } label: {
                    Label("Choose quick-move folders…", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                Spacer()
            } else {
                // One line of chips, each as wide as its name, that scrolls
                // sideways when they don't all fit — the bar stays one chip tall
                // however many folders are configured.
                // No indicator: the chip cut off at the edge already says it scrolls,
                // and the knob sat on top of the chips.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(rules) { rule in
                            sweepChip(rule).modifier(TrackFrame(id: Self.key(rule), frames: $chipFrames))
                        }
                        ForEach(folders, id: \.compositeId) { folder in
                            chip(folder).modifier(TrackFrame(id: folder.compositeId, frames: $chipFrames))
                        }
                    }
                }
                .coordinateSpace(name: Self.strip)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stripWidth = $0 }
                .frame(maxWidth: .infinity, alignment: .leading)
                overflowMenu(rules: rules.filter { isHidden(Self.key($0)) },
                             folders: folders.filter { isHidden($0.compositeId) })
            }
            Menu {
                Button("Quick-Move Folders…") { showConfig = true }
                Button("Sweep Rules…") { showSweepRules = true }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .layoutPriority(1)
            .help("Configure quick-move folders and sweep rules")
            // The editor opens either from this menu or from a message's
            // "Add Sender to Sweep Rule ▸ New Rule…" (which sets the rule id).
            .sheet(isPresented: Binding(
                get: { showSweepRules || vm.sweepEditorRuleId != nil },
                set: { if !$0 { showSweepRules = false; vm.sweepEditorRuleId = nil } }
            )) { SweepRulesView(initialRuleId: vm.sweepEditorRuleId) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .sheet(isPresented: $showConfig) { QuickMoveConfigView() }
    }

    private static func key(_ rule: SweepRule) -> String { "rule:" + rule.id.uuidString }

    /// True when the chip isn't wholly inside the strip (scrolled past either edge).
    private func isHidden(_ id: String) -> Bool {
        guard let frame = chipFrames[id], stripWidth > 0 else { return false }
        return frame.minX < -0.5 || frame.maxX > stripWidth + 0.5
    }

    /// "»" at the end of the strip, offering the chips that are cut off or
    /// scrolled out of sight; shown only while there are some.
    @ViewBuilder
    private func overflowMenu(rules: [SweepRule], folders: [MailFolder]) -> some View {
        if !rules.isEmpty || !folders.isEmpty {
            Menu {
                ForEach(rules) { rule in
                    let count = vm.sweepMatches(rule).count
                    Button {
                        Task { await vm.runSweep(rule) }
                    } label: {
                        Label("\(rule.name.isEmpty ? vm.sweepTarget(rule)?.name ?? "" : rule.name) (\(count))",
                              systemImage: "wand.and.stars")
                    }
                    .disabled(count == 0)
                }
                ForEach(folders, id: \.compositeId) { folder in
                    let suffix = vm.quickMoveSuffix(folder)
                    Button {
                        Task { await vm.moveDropped(Array(vm.selection), to: folder) }
                    } label: {
                        Label(folder.name + (suffix.map { " · " + $0 } ?? ""), systemImage: folder.kind.icon)
                    }
                }
            } label: {
                Image(systemName: "chevron.right.2")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .layoutPriority(1)
            .help("\(rules.count + folders.count) more quick-move folder\(rules.count + folders.count == 1 ? "" : "s")")
        }
    }

    /// A rule chip: moves every loaded message from the rule's senders at once.
    private func sweepChip(_ rule: SweepRule) -> some View {
        let count = vm.sweepMatches(rule).count
        let folderName = vm.sweepTarget(rule)?.name ?? ""
        return Button {
            Task { await vm.runSweep(rule) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "wand.and.stars")
                Text(rule.name.isEmpty ? folderName : rule.name)
                    .lineLimit(1)
                if count > 0 {
                    Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(Color(nsColor: .textColor))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .fixedSize()
            .background(Color(nsColor: .textBackgroundColor), in: Self.chipShape)
            .overlay(Self.chipShape.stroke(Color.accentColor.opacity(0.7)))
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .opacity(count == 0 ? 0.6 : 1)
        .help("Move \(count) message\(count == 1 ? "" : "s") from \(rule.addresses.joined(separator: ", ")) to \(folderName)")
    }

    private func chip(_ folder: MailFolder) -> some View {
        let suffix = vm.quickMoveSuffix(folder)
        return Button {
            Task { await vm.moveDropped(Array(vm.selection), to: folder) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: folder.kind.icon)
                // Same-named folders on two accounts show the account after the name.
                (Text(folder.name) + Text(suffix.map { " · " + $0 } ?? "").foregroundStyle(.secondary))
                    .lineLimit(1)
            }
            .font(.caption)
            // The editor's own colours: white card with black text in light mode,
            // and the inverse in dark mode.
            .foregroundStyle(Color(nsColor: .textColor))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .fixedSize()
            .background(Color(nsColor: .textBackgroundColor), in: Self.chipShape)
            .overlay(Self.chipShape.stroke(.quaternary))
        }
        .buttonStyle(.plain)
        .help("Move \(vm.selection.count) selected to \(folder.name)\(suffix.map { " (\($0))" } ?? "")")
        .modifier(FolderDropTarget(vm: vm, folder: folder))
    }

    private static let chipShape = RoundedRectangle(cornerRadius: 5)
}

/// Records a chip's frame in the move strip's coordinate space under `id`.
private struct TrackFrame: ViewModifier {
    let id: String
    @Binding var frames: [String: CGRect]

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(MoveBarView.strip))
        } action: { frames[id] = $0 }
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

    /// Folders offered as move targets: system folders first (by kind) then
    /// custom folders alphabetically.
    private func folders(for accountId: String) -> [MailFolder] {
        (vm.foldersByAccount[accountId] ?? [])
            .sorted { ($0.kind.sortWeight, $0.name) < ($1.kind.sortWeight, $1.name) }
    }
}
