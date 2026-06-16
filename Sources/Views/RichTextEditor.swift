import SwiftUI
import AppKit

/// Controls a rich-text NSTextView: applies formatting from the SwiftUI toolbar
/// and exports the content as HTML for sending.
@MainActor
final class RichTextController: ObservableObject {
    weak var textView: NSTextView?
    /// Invoked when the user presses Shift-Tab in the body, to move focus back to
    /// the preceding compose field.
    var onShiftTab: (() -> Void)?

    func setInitial(_ attributed: NSAttributedString) {
        textView?.textStorage?.setAttributedString(attributed)
    }

    /// Moves keyboard focus into the body editor (used to jump straight from the
    /// Subject field to the body, skipping the formatting buttons).
    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    func toggleBold() { toggleTrait(.boldFontMask) }
    func toggleItalic() { toggleTrait(.italicFontMask) }

    func toggleUnderline() {
        guard let tv = textView, let ts = tv.textStorage else { return }
        let range = tv.selectedRange()
        guard range.length > 0 else { return }
        var allUnderlined = true
        ts.enumerateAttribute(.underlineStyle, in: range) { value, _, _ in
            if (value as? Int ?? 0) == 0 { allUnderlined = false }
        }
        ts.addAttribute(.underlineStyle,
                        value: allUnderlined ? 0 : NSUnderlineStyle.single.rawValue,
                        range: range)
    }

    func applyLink(_ urlString: String) {
        guard let tv = textView, let ts = tv.textStorage,
              let url = URL(string: urlString) else { return }
        let range = tv.selectedRange()
        guard range.length > 0 else { return }
        ts.addAttribute(.link, value: url, range: range)
    }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        guard let tv = textView, let ts = tv.textStorage else { return }
        let range = tv.selectedRange()
        let manager = NSFontManager.shared
        guard range.length > 0 else { return }
        ts.enumerateAttribute(.font, in: range) { value, subRange, _ in
            let font = (value as? NSFont) ?? .systemFont(ofSize: NSFont.systemFontSize)
            let hasTrait = manager.traits(of: font).contains(trait)
            let newFont = hasTrait
                ? manager.convert(font, toNotHaveTrait: trait)
                : manager.convert(font, toHaveTrait: trait)
            ts.addAttribute(.font, value: newFont, range: subRange)
        }
    }

    func exportHTML() -> String {
        guard let ts = textView?.textStorage, ts.length > 0 else { return "" }
        let range = NSRange(location: 0, length: ts.length)
        let attrs: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        if let data = try? ts.data(from: range, documentAttributes: attrs) {
            return String(decoding: data, as: UTF8.self)
        }
        return ts.string
    }
}

struct RichTextEditor: NSViewRepresentable {
    @ObservedObject var controller: RichTextController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = true
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.delegate = context.coordinator
        controller.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    /// Routes Shift-Tab in the editor to the controller so compose can move focus
    /// back to the Subject field instead of inserting a back-tab.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let controller: RichTextController
        init(controller: RichTextController) { self.controller = controller }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertBacktab(_:)), let onShiftTab = controller.onShiftTab {
                onShiftTab()
                return true
            }
            return false
        }
    }
}
