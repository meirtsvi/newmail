import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Controls a rich-text NSTextView: applies formatting from the SwiftUI toolbar
/// and exports the content as HTML for sending.
@MainActor
final class RichTextController: ObservableObject {
    weak var textView: NSTextView?
    /// Invoked when the user presses Shift-Tab in the body, to move focus back to
    /// the preceding compose field.
    var onShiftTab: (() -> Void)?

    /// Images pasted or dropped into the body, in document order. Derived from the
    /// text storage so it stays in sync when an image is deleted in the editor.
    @Published private(set) var inlineImages: [ComposeInlineImage] = []

    /// Prefix for a pasted image's token; the full token doubles as its Content-ID
    /// and MIME filename.
    private static let inlineTokenPrefix = "nm-inline-"

    func setInitial(_ attributed: NSAttributedString) {
        textView?.textStorage?.setAttributedString(attributed)
    }

    /// Loads existing HTML (e.g. a saved draft) into the editor as editable rich
    /// text. Leaves the editor empty if the HTML can't be parsed.
    func setInitialHTML(_ html: String) {
        guard let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil)
        else { return }
        textView?.textStorage?.setAttributedString(attributed)
        refreshInlineImages()
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

    /// Left-aligns the selected paragraphs (or the paragraph being typed). Uses
    /// NSText's built-in action so paragraph boundaries and undo are handled for us.
    func alignLeft() { textView?.alignLeft(nil) }

    /// Right-aligns the selected paragraphs (or the paragraph being typed).
    func alignRight() { textView?.alignRight(nil) }

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

    // MARK: Inline images

    /// Inserts a pasted/dropped image (PNG data) at the caret as an inline
    /// attachment the user can see, tracked for `cid:` embedding at send time.
    func insertImage(_ data: Data, mime: String) {
        guard let tv = textView, let ts = tv.textStorage else { return }
        let token = "\(Self.inlineTokenPrefix)\(UUID().uuidString.lowercased()).png"
        let attachment = InlineImageAttachment(token: token, pngData: data)
        // Constrain very large images to a sensible on-screen width so a big
        // screenshot doesn't blow out the editor.
        if let image = attachment.image {
            let maxWidth: CGFloat = 360
            let size = image.size
            if size.width > maxWidth, size.width > 0 {
                let scale = maxWidth / size.width
                attachment.bounds = CGRect(x: 0, y: 0, width: maxWidth, height: (size.height * scale).rounded())
            }
        }
        let attrString = NSAttributedString(attachment: attachment)
        let range = tv.selectedRange()
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        ts.replaceCharacters(in: range, with: attrString)
        // Carry the body font so text typed after the image keeps the default look.
        tv.typingAttributes[.font] = Self.defaultFont
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location + 1, length: 0))
        refreshInlineImages()
    }

    /// Removes a tracked inline image from the body by its token.
    func removeInlineImage(_ token: String) {
        guard let tv = textView, let ts = tv.textStorage else { return }
        var target: NSRange?
        ts.enumerateAttribute(.attachment, in: NSRange(location: 0, length: ts.length)) { value, range, stop in
            if let att = value as? InlineImageAttachment, att.token == token {
                target = range
                stop.pointee = true
            }
        }
        guard let range = target, tv.shouldChangeText(in: range, replacementString: "") else { return }
        ts.replaceCharacters(in: range, with: "")
        tv.didChangeText()
        refreshInlineImages()
    }

    /// Rebuilds `inlineImages` from the text storage's image attachments, in
    /// document order. The text storage is the single source of truth, so deleting
    /// an image in the editor drops it here too.
    func refreshInlineImages() {
        guard let ts = textView?.textStorage else { return }
        var found: [ComposeInlineImage] = []
        ts.enumerateAttribute(.attachment, in: NSRange(location: 0, length: ts.length)) { value, _, _ in
            guard let att = value as? InlineImageAttachment,
                  !found.contains(where: { $0.id == att.token }) else { return }
            found.append(ComposeInlineImage(id: att.token, mime: "image/png", data: att.pngData))
        }
        if found.map(\.id) != inlineImages.map(\.id) { inlineImages = found }
    }

    /// The body HTML with each inline image's `<img>` src rewritten to `cid:…`,
    /// plus the images (in document order) to send as related parts.
    func exportBody() -> (html: String, images: [ComposeInlineImage]) {
        refreshInlineImages()
        let html = exportHTML()
        guard !inlineImages.isEmpty else { return (html, []) }
        let rewritten = Self.rewriteImageSources(in: html, to: inlineImages.map(\.cid))
        return (rewritten, inlineImages)
    }

    /// Rewrites the src of each `<img>` tag (in order) to `cid:<cid>`. The HTML
    /// export emits one `<img>` per image attachment in document order, so a
    /// positional mapping is robust regardless of how the exporter named the src.
    private static func rewriteImageSources(in html: String, to cids: [String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<img\\b[^>]*>", options: [.caseInsensitive]) else { return html }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }
        var result = ""
        var lastEnd = 0
        for (index, match) in matches.enumerated() {
            let r = match.range
            result += ns.substring(with: NSRange(location: lastEnd, length: r.location - lastEnd))
            let tag = ns.substring(with: r)
            result += index < cids.count ? setSrc(of: tag, to: "cid:\(cids[index])") : tag
            lastEnd = r.location + r.length
        }
        result += ns.substring(with: NSRange(location: lastEnd, length: ns.length - lastEnd))
        return result
    }

    /// Replaces an `<img>` tag's existing src (double- or single-quoted) with a new
    /// value, injecting one if the tag has none.
    private static func setSrc(of imgTag: String, to newSrc: String) -> String {
        for pattern in ["src\\s*=\\s*\"[^\"]*\"", "src\\s*=\\s*'[^']*'"] {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let ns = imgTag as NSString
                if let m = regex.firstMatch(in: imgTag, range: NSRange(location: 0, length: ns.length)) {
                    return ns.replacingCharacters(in: m.range, with: "src=\"\(newSrc)\"")
                }
            }
        }
        if let range = imgTag.range(of: "<img", options: .caseInsensitive) {
            return imgTag.replacingCharacters(in: range, with: "<img src=\"\(newSrc)\"")
        }
        return imgTag
    }
}

/// A pasted/dropped image attachment that carries its `cid:` token and PNG bytes
/// as real properties — so they survive in the text storage (unlike a fileWrapper's
/// `preferredFilename`, which AppKit overwrites when `image` is set).
final class InlineImageAttachment: NSTextAttachment {
    let token: String
    let pngData: Data
    init(token: String, pngData: Data) {
        self.token = token
        self.pngData = pngData
        super.init(data: nil, ofType: nil)
        self.image = NSImage(data: pngData)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// An NSTextView that turns pasted or dropped images into inline attachments,
/// reporting the PNG data so the controller can track it for `cid:` embedding.
final class ComposeTextView: NSTextView {
    var onImage: ((Data) -> Void)?

    override func paste(_ sender: Any?) {
        if let data = Self.pngImageData(from: NSPasteboard.general) {
            onImage?(data)
            return
        }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if let data = Self.pngImageData(from: sender.draggingPasteboard) {
            onImage?(data)
            return true
        }
        return super.performDragOperation(sender)
    }

    /// The first image on a pasteboard as PNG — whether it arrived as raw image
    /// data (screenshot / copied image) or an image file (Finder drag). Returns nil
    /// for text or non-image content so normal paste/drop falls through to NSTextView.
    static func pngImageData(from pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        if let tiff = pb.data(forType: .tiff) { return pngData(fromTIFF: tiff) }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           let url = urls.first, let data = try? Data(contentsOf: url) {
            return url.pathExtension.lowercased() == "png" ? data : NSImage(data: data).flatMap(png(from:))
        }
        return nil
    }

    private static func pngData(fromTIFF tiff: Data) -> Data? {
        NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    private static func png(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return pngData(fromTIFF: tiff)
    }
}

struct RichTextEditor: NSViewRepresentable {
    @ObservedObject var controller: RichTextController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let contentSize = scrollView.contentSize
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(containerSize: NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = ComposeTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: textContainer)
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        textView.isRichText = true
        textView.importsGraphics = true   // register image drag types so drops are offered
        textView.allowsUndo = true
        textView.font = RichTextController.defaultFont
        textView.typingAttributes[.font] = RichTextController.defaultFont
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.delegate = context.coordinator
        textView.onImage = { [weak controller] data in
            // paste/drag are delivered on the main thread.
            MainActor.assumeIsolated { controller?.insertImage(data, mime: "image/png") }
        }

        scrollView.documentView = textView
        controller.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    /// Routes Shift-Tab in the editor to the controller so compose can move focus
    /// back to the Subject field instead of inserting a back-tab, and keeps the
    /// inline-image list in sync as the body is edited.
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

        func textDidChange(_ notification: Notification) {
            controller.refreshInlineImages()
        }
    }
}
