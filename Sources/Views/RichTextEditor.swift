import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Controls a rich-text NSTextView: applies formatting from the SwiftUI toolbar
/// and exports the content as HTML for sending.
@MainActor
final class RichTextController: ObservableObject {
    weak var textView: NSTextView?
    /// The enclosing scroll view, used for display-only zoom (magnification).
    weak var scrollView: NSScrollView?
    /// Invoked when the user presses Shift-Tab in the body, to move focus back to
    /// the preceding compose field.
    var onShiftTab: (() -> Void)?

    /// Invoked when non-image files (e.g. a pasted or dropped PDF) land in the
    /// body, so compose can add them to its attachment list instead of inlining
    /// them as pictures.
    var onAttachFiles: (([URL]) -> Void)?

    /// Images pasted or dropped into the body, in document order. Derived from the
    /// text storage so it stays in sync when an image is deleted in the editor.
    @Published private(set) var inlineImages: [ComposeInlineImage] = []

    /// On-screen height of the laid-out body text (insets and display zoom
    /// included), so compose can grow the editor and shrink the quoted original
    /// as the reply gets longer.
    @Published private(set) var contentHeight: CGFloat = 0

    /// Recomputes `contentHeight` from the current layout. Called after every
    /// edit, after loading initial content, and when the zoom or width changes.
    func refreshContentHeight() {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        lm.ensureLayout(for: tc)
        let height = (lm.usedRect(for: tc).height + tv.textContainerInset.height * 2) * zoom
        if abs(height - contentHeight) > 0.5 { contentHeight = height }
    }

    /// Prefix for a pasted image's token; the full token doubles as its Content-ID
    /// and MIME filename.
    private static let inlineTokenPrefix = "nm-inline-"

    func setInitial(_ attributed: NSAttributedString) {
        textView?.textStorage?.setAttributedString(attributed)
        refreshContentHeight()
    }

    /// Loads existing HTML (e.g. a saved draft) into the editor as editable rich
    /// text. Inline images (which arrive as `data:` URLs) are re-adopted as tracked
    /// `InlineImageAttachment`s so they re-export as `cid:` related parts on send.
    /// Leaves the editor empty if the HTML can't be parsed.
    func setInitialHTML(_ html: String) {
        guard let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil)
        else { return }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        Self.adoptInlineImages(in: mutable)
        textView?.textStorage?.setAttributedString(mutable)
        // Carry the body font so text typed after a loaded draft keeps the default look.
        textView?.typingAttributes[.font] = Self.defaultFont
        refreshInlineImages()
        refreshContentHeight()
    }

    /// Moves keyboard focus into the body editor (used to jump straight from the
    /// Subject field to the body, skipping the formatting buttons).
    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    /// Display-only zoom of the editor viewport, mirroring the reading view's range
    /// and 0.1 step. It magnifies only how large the text appears on screen — the
    /// font sizes in the exported (sent) message are untouched.
    static let zoomRange: ClosedRange<CGFloat> = 0.5...3.0
    /// Published so the formatting bar's zoom control can show the current level.
    @Published private(set) var zoom: CGFloat = 1.0

    func zoomIn() { setZoom(zoom + 0.1) }
    func zoomOut() { setZoom(zoom - 0.1) }

    func setZoom(_ value: CGFloat) {
        zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, value))
        scrollView?.magnification = zoom
        refreshContentHeight()
    }

    func toggleBold() { toggleTrait(.boldFontMask) }
    func toggleItalic() { toggleTrait(.italicFontMask) }

    func toggleUnderline() {
        guard let tv = textView, let ts = tv.textStorage else { return }
        let range = tv.selectedRange()
        // No selection: flip the typing attribute so what's typed next is
        // (un)underlined — "underline mode", matching every mail client's ⌘U.
        guard range.length > 0 else {
            let current = (tv.typingAttributes[.underlineStyle] as? Int) ?? 0
            tv.typingAttributes[.underlineStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            return
        }
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

    /// Sets the base writing direction of the selected paragraphs to left-to-right.
    func makeLeftToRight() { textView?.makeBaseWritingDirectionLeftToRight(nil) }

    /// Sets the base writing direction of the selected paragraphs to right-to-left.
    func makeRightToLeft() { textView?.makeBaseWritingDirectionRightToLeft(nil) }

    /// List layout mirroring TextEdit's: the marker sits at the first tab stop and
    /// the item text (including wrapped lines, via headIndent) at the second.
    private static let listMarkerTab: CGFloat = 11
    private static let listTextIndent: CGFloat = 36

    /// Toggles a bulleted list on the selected paragraphs (or the one being typed).
    func toggleBulletList() { toggleList(markerFormat: .disc) }

    /// Toggles a numbered list on the selected paragraphs. The trailing period in
    /// the format string renders items as "1." rather than a bare "1".
    func toggleNumberedList() { toggleList(markerFormat: NSTextList.MarkerFormat("{decimal}.")) }

    /// The literal tab-wrapped marker at the start of a list paragraph. The visible
    /// bullet/number is plain text; the paragraph style's NSTextList is what drives
    /// Return-key list continuation and the <ul>/<ol> HTML export (which strips the
    /// literal marker on the way out).
    private static let listMarkerPattern = try! NSRegularExpression(pattern: "^\\t[^\\t\\n]*\\t")

    /// A hand-typed list prefix at the start of a paragraph — "1. " or "- " — that
    /// Return upgrades to a real list item.
    private static let typedListPrefixPattern = try! NSRegularExpression(pattern: "^(1\\.|-)[ \u{00A0}]+")

    /// A copy of `style` turned into this list's paragraph style.
    private static func listStyle(basedOn style: NSParagraphStyle, list: NSTextList) -> NSMutableParagraphStyle {
        let result = style.mutableCopy() as! NSMutableParagraphStyle
        result.textLists = [list]
        result.firstLineHeadIndent = 0
        result.headIndent = listTextIndent
        result.tabStops = [
            NSTextTab(textAlignment: .natural, location: listMarkerTab),
            NSTextTab(textAlignment: .natural, location: listTextIndent),
        ]
        return result
    }

    /// Called when Return is pressed: if the paragraph being typed reads like the
    /// start of a hand-typed list — "1. text" or "- text" with the caret at the end
    /// — it becomes a real numbered/bulleted list item, so the newline that follows
    /// continues the list with the next marker.
    func upgradeTypedListPrefix() {
        guard let tv = textView, let ts = tv.textStorage else { return }
        let sel = tv.selectedRange()
        guard sel.length == 0 else { return }
        let string = ts.string as NSString
        var start = 0, end = 0, contentsEnd = 0
        string.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: sel)
        guard sel.location == contentsEnd, contentsEnd > start else { return }
        let paragraph = NSRange(location: start, length: end - start)
        let style = (ts.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle) ?? .default
        guard style.textLists.isEmpty else { return }
        let text = string.substring(with: paragraph)
        guard let match = Self.typedListPrefixPattern.firstMatch(
            in: text, range: NSRange(location: 0, length: (text as NSString).length)),
            // Only with text after the prefix — a bare "1." or "-" stays literal.
            NSMaxRange(match.range) < contentsEnd - start
        else { return }

        let format: NSTextList.MarkerFormat = (text as NSString).hasPrefix("-")
            ? .disc : NSTextList.MarkerFormat("{decimal}.")
        let list = NSTextList(markerFormat: format, options: 0)
        let item = NSMutableAttributedString(attributedString: ts.attributedSubstring(from: paragraph))
        // The plain-string replace keeps the typed prefix's attributes on the marker.
        item.replaceCharacters(in: match.range, with: "\t\(list.marker(forItemNumber: 1))\t")
        let newStyle = Self.listStyle(basedOn: style, list: list)
        item.addAttribute(.paragraphStyle, value: newStyle, range: NSRange(location: 0, length: item.length))

        guard tv.shouldChangeText(in: paragraph, replacementString: item.string) else { return }
        ts.replaceCharacters(in: paragraph, with: item)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: sel.location + item.length - paragraph.length, length: 0))
        tv.typingAttributes[.paragraphStyle] = newStyle
        refreshContentHeight()
    }

    /// Applies or removes a list across every paragraph touched by the selection.
    /// A uniform toggle: only if all paragraphs are already in this exact format is
    /// the list removed; otherwise it's (re)applied, converting other formats.
    private func toggleList(markerFormat: NSTextList.MarkerFormat) {
        guard let tv = textView, let ts = tv.textStorage else { return }
        let selection = tv.selectedRange()
        let fullRange = (ts.string as NSString).paragraphRange(for: selection)
        let base = ts.attributedSubstring(from: fullRange)

        // The selected paragraphs, as ranges within `base`.
        let baseString = base.string as NSString
        var paragraphs: [NSRange] = []
        var location = 0
        repeat {
            let r = baseString.paragraphRange(for: NSRange(location: location, length: 0))
            paragraphs.append(r)
            location = NSMaxRange(r)
        } while location < baseString.length

        let typingStyle = (tv.typingAttributes[.paragraphStyle] as? NSParagraphStyle) ?? .default
        let styleOf: (NSRange) -> NSParagraphStyle = { r in
            r.length > 0
                ? (base.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle) ?? .default
                : typingStyle
        }
        let turningOff = paragraphs.allSatisfy { styleOf($0).textLists.first?.markerFormat == markerFormat }

        // One shared NSTextList so AppKit treats the paragraphs as a single list.
        let list = NSTextList(markerFormat: markerFormat, options: 0)
        let result = NSMutableAttributedString()
        var lastStyle = typingStyle
        for (item, range) in paragraphs.enumerated() {
            let paragraph = NSMutableAttributedString(attributedString: base.attributedSubstring(from: range))
            var style = styleOf(range).mutableCopy() as! NSMutableParagraphStyle
            // Strip the old literal marker when leaving a list or switching formats.
            if !style.textLists.isEmpty,
               let m = Self.listMarkerPattern.firstMatch(in: paragraph.string, range: NSRange(location: 0, length: paragraph.length)) {
                paragraph.deleteCharacters(in: m.range)
            }
            if turningOff {
                style.textLists = []
                style.headIndent = 0
                style.firstLineHeadIndent = 0
                style.tabStops = NSParagraphStyle.default.tabStops
            } else {
                style = Self.listStyle(basedOn: style, list: list)
                let font = paragraph.length > 0
                    ? (paragraph.attribute(.font, at: 0, effectiveRange: nil) as? NSFont) ?? Self.defaultFont
                    : (tv.typingAttributes[.font] as? NSFont) ?? Self.defaultFont
                paragraph.insert(NSAttributedString(
                    string: "\t\(list.marker(forItemNumber: item + 1))\t",
                    attributes: [.font: font]), at: 0)
            }
            paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
            lastStyle = style
            result.append(paragraph)
        }

        guard tv.shouldChangeText(in: fullRange, replacementString: result.string) else { return }
        ts.replaceCharacters(in: fullRange, with: result)
        tv.didChangeText()

        let delta = result.length - fullRange.length
        if selection.length == 0 {
            let caret = min(max(selection.location + delta, fullRange.location), fullRange.location + result.length)
            tv.setSelectedRange(NSRange(location: caret, length: 0))
        } else {
            tv.setSelectedRange(NSRange(location: fullRange.location, length: result.length))
        }
        // After the selection change so it isn't recomputed away: keep typing in the
        // affected paragraph on (or off) the list.
        tv.typingAttributes[.paragraphStyle] = lastStyle
        refreshContentHeight()
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

    /// Changes the color of the selected text, or — when nothing is selected — of the
    /// typing attributes so the next characters typed pick it up.
    func setFontColor(_ color: NSColor) {
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            tv.typingAttributes[.foregroundColor] = color
            return
        }
        tv.textStorage?.addAttribute(.foregroundColor, value: color, range: range)
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
        // No selection: flip the typing attribute so what's typed next carries
        // the trait — "bold mode", matching every mail client's ⌘B.
        guard range.length > 0 else {
            let current = (tv.typingAttributes[.font] as? NSFont) ?? Self.defaultFont
            tv.typingAttributes[.font] = manager.traits(of: current).contains(trait)
                ? manager.convert(current, toNotHaveTrait: trait)
                : manager.convert(current, toHaveTrait: trait)
            return
        }
        // First decide a single direction for the whole selection: only if every run
        // already has the trait do we remove it; otherwise we add it everywhere. This
        // makes the button a uniform on/off toggle instead of flipping each run
        // independently (which left mixed selections half-on, half-off).
        var allHaveTrait = true
        ts.enumerateAttribute(.font, in: range) { value, _, _ in
            let font = (value as? NSFont) ?? .systemFont(ofSize: NSFont.systemFontSize)
            if !manager.traits(of: font).contains(trait) { allHaveTrait = false }
        }
        ts.enumerateAttribute(.font, in: range) { value, subRange, _ in
            let font = (value as? NSFont) ?? .systemFont(ofSize: NSFont.systemFontSize)
            let newFont = allHaveTrait
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

    /// Replaces the plain image attachments the HTML importer creates (one per
    /// `data:` `<img>`) with tracked `InlineImageAttachment`s carrying the PNG bytes,
    /// so `exportBody` re-emits them as `cid:` related parts instead of dropping them
    /// or inlining raw data. Same-length attribute swap, so ranges stay valid.
    private static func adoptInlineImages(in text: NSMutableAttributedString) {
        var replacements: [(range: NSRange, attachment: InlineImageAttachment)] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let att = value as? NSTextAttachment, !(att is InlineImageAttachment),
                  let png = pngBytes(from: att) else { return }
            let token = "\(inlineTokenPrefix)\(UUID().uuidString.lowercased()).png"
            let inline = InlineImageAttachment(token: token, pngData: png)
            if att.bounds.width > 0, att.bounds.height > 0 { inline.bounds = att.bounds }
            replacements.append((range, inline))
        }
        for r in replacements {
            text.addAttribute(.attachment, value: r.attachment, range: r.range)
        }
    }

    /// Best-effort PNG bytes for an HTML-imported image attachment, trying its file
    /// wrapper, its image, then its cell image.
    private static func pngBytes(from att: NSTextAttachment) -> Data? {
        if let data = att.fileWrapper?.regularFileContents, let png = pngBytes(fromImageData: data) { return png }
        if let image = att.image, let png = pngBytes(from: image) { return png }
        if let cellImage = (att.attachmentCell as? NSTextAttachmentCell)?.image, let png = pngBytes(from: cellImage) { return png }
        return nil
    }

    private static func pngBytes(fromImageData data: Data) -> Data? {
        NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }

    private static func pngBytes(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return pngBytes(fromImageData: tiff)
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
    var onFiles: (([URL]) -> Void)?

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        // A copied file that isn't an image (e.g. a PDF) becomes an attachment,
        // not an inline picture — even when the pasteboard also carries an image
        // preview of it, which would otherwise be inlined by pngImageData below.
        let files = Self.nonImageFileURLs(from: pb)
        if !files.isEmpty {
            onFiles?(files)
            return
        }
        if let data = Self.pngImageData(from: pb) {
            onImage?(data)
            return
        }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let files = Self.nonImageFileURLs(from: pb)
        if !files.isEmpty {
            onFiles?(files)
            return true
        }
        if let data = Self.pngImageData(from: pb) {
            onImage?(data)
            return true
        }
        return super.performDragOperation(sender)
    }

    /// File URLs on the pasteboard that are not images — e.g. a copied or dragged
    /// PDF or document. These are surfaced as real attachments; image files fall
    /// through so they keep their inline-picture behavior.
    static func nonImageFileURLs(from pb: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else { return [] }
        return urls.filter { url in
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                ?? UTType(filenameExtension: url.pathExtension)
            return !(type?.conforms(to: .image) ?? false)
        }
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
        // Display-only zoom: the formatting bar's zoom buttons drive magnification.
        scrollView.allowsMagnification = true
        scrollView.minMagnification = RichTextController.zoomRange.lowerBound
        scrollView.maxMagnification = RichTextController.zoomRange.upperBound

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
        textView.onFiles = { [weak controller] urls in
            MainActor.assumeIsolated { controller?.onAttachFiles?(urls) }
        }

        scrollView.documentView = textView
        controller.textView = textView
        controller.scrollView = scrollView
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
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // "1. text" / "- text" becomes a real list item before the newline
                // goes in, so the default insertNewline continues the list.
                controller.upgradeTypedListPrefix()
            }
            return false
        }

        func textDidChange(_ notification: Notification) {
            controller.refreshInlineImages()
            controller.refreshContentHeight()
        }
    }
}
