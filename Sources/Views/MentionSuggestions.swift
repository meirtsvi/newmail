import AppKit
import SwiftUI

/// The address dropdown shared by the To/Cc fields and the body's `@mention`
/// popup: a compact list of "Name / address" rows with one highlighted.
struct AddressSuggestionList: View {
    let matches: [MailAddress]
    let highlighted: Int
    /// Called when a row is clicked; the hover callback moves the highlight so the
    /// pointer and the keyboard agree on which row Return would take.
    let onPick: (MailAddress) -> Void
    let onHover: (Int) -> Void

    static let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, addr in
                Button {
                    onPick(addr)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        if !addr.name.isEmpty {
                            Text(addr.name).font(.body)
                        }
                        Text(addr.email)
                            .font(addr.name.isEmpty ? .body : .caption)
                            .foregroundStyle(addr.name.isEmpty ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .background(index == highlighted ? Color.accentColor.opacity(0.18) : .clear)
                }
                .buttonStyle(.plain)
                .onHover { if $0 { onHover(index) } }
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .shadow(radius: 6, y: 2)
        .frame(width: Self.width)
    }
}

/// An `@mention` being typed in the message body.
struct MentionContext: Equatable {
    /// What follows the `@`, matched against the address book.
    var query: String
    /// The `@` character's rect in the body editor's coordinate space (top-left
    /// origin), so the popup can be pinned just below it.
    var anchor: CGRect
}

/// A keystroke the mention popup claims while it is on screen. The body editors
/// forward these instead of handling them so the popup behaves like the To/Cc one.
enum MentionKey { case up, down, accept, dismiss }

/// Finds the `@name` being typed at the caret. Shared by both body editors so they
/// recognize a mention by exactly the same rule.
enum MentionScanner {
    /// Long enough for a full name, short enough that an errant `@` earlier in the
    /// paragraph stops matching once you've typed past it.
    static let maxQueryLength = 32

    /// The `@…` run ending at `caret`, or nil when there isn't one. The `@` has to
    /// start a word, so an address typed inline (`someone@example.com`) is left alone.
    static func token(in text: NSString, caret: Int) -> (range: NSRange, query: String)? {
        guard caret > 0, caret <= text.length else { return nil }
        var index = caret - 1
        while index >= 0, caret - index <= maxQueryLength + 1 {
            let character = text.character(at: index)
            if character == 0x40 { break }  // "@"
            if isBreak(character) { return nil }
            index -= 1
        }
        guard index >= 0, text.character(at: index) == 0x40 else { return nil }
        if index > 0, !isBreak(text.character(at: index - 1)) { return nil }
        let range = NSRange(location: index, length: caret - index)
        let query = text.substring(with: NSRange(location: index + 1, length: range.length - 1))
        return (range, query)
    }

    /// Whitespace (including the non-breaking space editors leave behind) ends the
    /// token; so does a second `@`, which means we're inside an address.
    private static func isBreak(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return true }
        return scalar == "@" || CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}
