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
                // An even grid of same-sized cells that wraps onto as many rows as
                // it takes, so no chip is ever clipped off the right edge — the bar
                // grows taller instead.
                ChipGridLayout(spacing: 6, rowSpacing: 4) {
                    ForEach(folders, id: \.compositeId) { folder in
                        chip(folder)
                    }
                }
                // Claim the row's leftover width (and no more), so the layout
                // wraps to it instead of running past the right edge.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { showConfig = true } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .layoutPriority(1)
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
            HStack(spacing: 5) {
                Image(systemName: folder.kind.icon)
                Text(Self.wrappedName(folder.name))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .font(.caption)
            // The editor's own colours: white card with black text in light mode,
            // and the inverse in dark mode.
            .foregroundStyle(Color(nsColor: .textColor))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            // Fill the cell the grid hands out, so every chip is the same size.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: Self.chipShape)
            .overlay(Self.chipShape.stroke(.quaternary))
        }
        .buttonStyle(.plain)
        .help("Move \(vm.selection.count) selected to \(folder.name)")
        .modifier(FolderDropTarget(vm: vm, folder: folder))
    }

    private static let chipShape = RoundedRectangle(cornerRadius: 5)

    /// Breaks a multi-word folder name over two lines so its chip stays narrow
    /// enough to sit alongside the others. The split point is the word boundary
    /// closest to the middle of the name, which keeps the two lines even.
    static func wrappedName(_ name: String) -> String {
        let words = name.split(separator: " ").map(String.init)
        guard words.count > 1 else { return name }
        let half = name.count / 2
        var best = 1
        var bestDistance = Int.max
        var prefixLength = 0
        for index in 0..<(words.count - 1) {
            prefixLength += words[index].count + (index > 0 ? 1 : 0)
            let distance = abs(prefixLength - half)
            if distance < bestDistance {
                bestDistance = distance
                best = index + 1
            }
        }
        return words[..<best].joined(separator: " ") + "\n" + words[best...].joined(separator: " ")
    }
}

/// Lays subviews out as a grid of identically-sized cells — the cell is as big as
/// the largest subview — fitting as many columns as the proposed width allows and
/// wrapping onto further rows. Uniform cells keep the bar symmetric no matter how
/// uneven the folder names are.
struct ChipGridLayout: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let cell = cellSize(subviews)
        let available = proposal.width ?? .infinity
        let columns = columnCount(width: available, cell: cell.width, count: subviews.count)
        let rows = (subviews.count + columns - 1) / columns
        let packed = CGFloat(columns) * cell.width + CGFloat(columns - 1) * spacing
        return CGSize(
            // Claim the whole row when one is offered, so `placeSubviews` gets the
            // real width to spread the columns across.
            width: available.isFinite ? max(available, cell.width) : packed,
            height: CGFloat(rows) * cell.height + CGFloat(rows - 1) * rowSpacing
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        var cell = cellSize(subviews)
        let columns = columnCount(width: bounds.width, cell: cell.width, count: subviews.count)
        // Share out the width left over by the last whole column, so the grid ends
        // flush with the bar instead of trailing an uneven gap.
        if bounds.width.isFinite, columns > 1 || bounds.width > cell.width {
            cell.width = max(cell.width, (bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        }
        for index in subviews.indices {
            let origin = CGPoint(
                x: bounds.minX + CGFloat(index % columns) * (cell.width + spacing),
                y: bounds.minY + CGFloat(index / columns) * (cell.height + rowSpacing)
            )
            subviews[index].place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(cell))
        }
    }

    /// The largest subview's size — every cell gets this one.
    private func cellSize(_ subviews: Subviews) -> CGSize {
        subviews.reduce(into: CGSize.zero) { size, subview in
            let ideal = subview.sizeThatFits(.unspecified)
            size.width = max(size.width, ideal.width)
            size.height = max(size.height, ideal.height)
        }
    }

    private func columnCount(width: CGFloat, cell: CGFloat, count: Int) -> Int {
        guard cell > 0, width.isFinite else { return max(1, count) }
        return max(1, min(count, Int((width + spacing) / (cell + spacing))))
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
