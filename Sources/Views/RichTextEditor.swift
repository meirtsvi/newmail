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

    /// The label used for the default UI/system font in the family picker; it has no
    /// real family name, so it's special-cased when applied.
    static let systemFamily = "System"

    /// The default body font for new compose/reply/forward messages.
    static let defaultFamily = "Arial"
    static let defaultSize: CGFloat = 16
    static var defaultFont: NSFont {
        NSFont(name: defaultFamily, size: defaultSize) ?? .systemFont(ofSize: defaultSize)
    }

    /// Font families offered in the compose toolbar (kept short and cross-platform).
    static let fontFamilies = [
        systemFamily, "Helvetica", "Arial", "Times New Roman",
        "Georgia", "Courier New", "Verdana", "Menlo",
    ]

    /// Point sizes offered in the compose toolbar.
    static let fontSizes: [CGFloat] = [9, 10, 11, 12, 13, 14, 16, 18, 24, 36]

    /// Changes the family of the selected text (or of new typing if nothing is
    /// selected), preserving each run's size and bold/italic traits.
    func setFontFamily(_ family: String) {
        applyFont { font in
            if family == Self.systemFamily { return .systemFont(ofSize: font.pointSize) }
            return NSFontManager.shared.convert(font, toFamily: family)
        }
    }

    /// Changes the size of the selected text (or of new typing if nothing is selected).
    func setFontSize(_ size: CGFloat) {
        applyFont { NSFontManager.shared.convert($0, toSize: size) }
    }

    /// Applies a font transform to the selection, or — when the selection is empty —
    /// to the typing attributes so the next characters typed pick it up.
    private func applyFont(_ transform: (NSFont) -> NSFont) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let fallback = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        if range.length == 0 {
            let current = (tv.typingAttributes[.font] as? NSFont) ?? fallback
            tv.typingAttributes[.font] = transform(current)
            return
        }
        guard let ts = tv.textStorage else { return }
        ts.enumerateAttribute(.font, in: range) { value, subRange, _ in
            ts.addAttribute(.font, value: transform((value as? NSFont) ?? fallback), range: subRange)
        }
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
        textView.font = RichTextController.defaultFont
        textView.typingAttributes[.font] = RichTextController.defaultFont
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
