import SwiftUI
import WebKit

/// Holds the live `WKWebView` for an `HTMLEditorView` so the surrounding view can
/// pull the edited HTML back out on demand.
@MainActor
final class HTMLEditorController: ObservableObject {
    fileprivate weak var webView: WKWebView?
    /// Invoked when the user presses Shift-Tab in the body, to move focus back to
    /// the Subject field (mirrors `RichTextController.onShiftTab`).
    var onShiftTab: (() -> Void)?

    /// Reports the `@mention` being typed at the caret (nil when there isn't one),
    /// mirroring `RichTextController.onMention`.
    var onMention: ((MentionContext?) -> Void)?

    /// Offers a keystroke to the mention popup while it is showing; true means the
    /// popup took it.
    var onMentionKey: ((MentionKey) -> Bool)?

    /// Invoked when "Edit" is picked in a link's popup, mirroring
    /// `RichTextController.onEditLink`.
    var onEditLink: ((_ text: String, _ url: String) -> Void)?

    /// The Open/Edit popup shown when a link in the body is clicked.
    private let linkPopover = LinkActionPopover()

    /// Moves keyboard focus into the body editor (used to jump straight from the
    /// Subject field to the body). Makes the WebView first responder, then focuses
    /// the editable document body.
    func focus() {
        guard let webView else { return }
        webView.window?.makeFirstResponder(webView)
        webView.evaluateJavaScript("if (document.body) { document.body.focus(); }")
    }

    /// Display-only zoom of the editor, mirroring the rich-text editor's range.
    /// Published so the formatting bar's zoom control can show the current level.
    static let zoomRange: ClosedRange<CGFloat> = 0.5...3.0
    @Published private(set) var zoom: CGFloat = 1.0

    func setZoom(_ value: CGFloat) {
        zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, value))
        webView?.pageZoom = zoom
    }

    // MARK: - Formatting commands
    //
    // The editing surface is a `designMode` document, so the toolbar drives it with
    // `document.execCommand` rather than the AppKit calls `RichTextController` uses.

    func toggleBold() { exec("bold") }
    func toggleItalic() { exec("italic") }
    func toggleUnderline() { exec("underline") }
    func toggleSuperscript() { exec("superscript") }
    func toggleBulletList() { exec("insertUnorderedList") }
    func toggleNumberedList() { exec("insertOrderedList") }
    func alignLeft() { exec("justifyLeft") }
    func alignRight() { exec("justifyRight") }
    func makeLeftToRight() { setDirection("ltr") }
    func makeRightToLeft() { setDirection("rtl") }

    /// The selected text, used to pre-fill the link prompt's text field.
    func selectedText() async -> String {
        guard let webView else { return "" }
        return (try? await webView.evaluateJavaScript("window.getSelection().toString()") as? String) ?? ""
    }

    /// Replaces the selection (or inserts at the caret) with `text` linked to
    /// `urlString`, matching the rich-text editor.
    func insertLink(_ urlString: String, text: String) {
        run("""
        var link = document.createElement('a');
        link.href = \(Self.jsString(urlString));
        link.textContent = \(Self.jsString(text));
        document.execCommand('insertHTML', false, link.outerHTML);
        """)
    }

    /// Inserts the clipboard's plain text, so it picks up the formatting at the
    /// insertion point instead of carrying the source's styling.
    func pasteMatchingStyle() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        exec("insertText", value: text)
    }

    /// Changes the color of the selected text. The color is resolved in the light
    /// appearance, so "Automatic" (`NSColor.textColor`) is saved as black rather than
    /// baking the dark-mode white into the message — the same choice the rich-text
    /// HTML exporter makes.
    func setFontColor(_ color: NSColor) {
        exec("foreColor", value: Self.hex(color), styleWithCSS: true)
    }

    /// Changes the background (highlight) color of the selected text; nil clears it.
    func setBackgroundColor(_ color: NSColor?) {
        exec("hiliteColor", value: color.map(Self.hex) ?? "transparent", styleWithCSS: true)
    }

    /// `color` as a CSS hex string, resolved in the light appearance.
    private static func hex(_ color: NSColor) -> String {
        var resolved = NSColor.black
        let light = NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
        light.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? .black
        }
        return String(format: "#%02X%02X%02X",
                      Int((resolved.redComponent * 255).rounded()),
                      Int((resolved.greenComponent * 255).rounded()),
                      Int((resolved.blueComponent * 255).rounded()))
    }

    /// Changes the family of the selected text. "System" maps to the same font stack
    /// the editor stylesheet and the message viewer use.
    func setFontFamily(_ family: String) {
        let css = family == RichTextController.systemFamily
            ? "-apple-system, \"SF Pro Text\", Helvetica, Arial, sans-serif"
            : family
        exec("fontName", value: css, styleWithCSS: true)
    }

    /// Changes the size of the selected text (`__nmSetFontSize` in `formatScript`).
    func setFontSize(_ size: CGFloat) {
        run("window.__nmSetFontSize(\(Int(size)));")
    }

    // MARK: - Caret format & format painter

    /// The formatting at the caret, reported by the page as the caret moves or
    /// the document changes, so the toolbar reflects the letter being edited.
    @Published private(set) var format = CaretFormat(family: RichTextController.systemFamily,
                                                     size: RichTextController.defaultSize)

    /// True while the format painter holds copied formatting; the page applies it
    /// to the next mouse selection and reports back.
    @Published private(set) var isPainting = false

    /// Copies the formatting at the caret, or cancels a pending paint.
    func togglePainter() {
        isPainting.toggle()
        run(isPainting
            ? "window.__nmPainter = window.__nmFormat(); window.__nmPainterCursor(\(Self.jsString(Self.paintCursorCSS)));"
            : "window.__nmPainter = null; window.__nmPainterCursor(null);")
    }

    /// The paintbrush cursor as a CSS `cursor` value, falling back to the I-beam.
    private static let paintCursorCSS: String = {
        guard let png = PaintCursor.png2x else { return "text" }
        let hot = PaintCursor.hotSpot
        return "-webkit-image-set(url(\"data:image/png;base64,\(png.base64EncodedString())\") 2x) "
            + "\(Int(hot.x)) \(Int(hot.y)), text"
    }()

    fileprivate func painterApplied() { isPainting = false }

    /// Takes the page's computed style for the caret: `family` is a CSS font
    /// stack, the colors are `rgb()`/`rgba()` strings, `size` is in pixels.
    fileprivate func updateFormat(_ body: [String: Any]) {
        let updated = CaretFormat(
            family: Self.pickerFamily(fromStack: body["family"] as? String ?? ""),
            size: CGFloat(body["size"] as? Double ?? Double(RichTextController.defaultSize)),
            color: Self.color(fromCSS: body["color"] as? String ?? ""),
            background: Self.color(fromCSS: body["background"] as? String ?? ""),
            bold: body["bold"] as? Bool ?? false,
            italic: body["italic"] as? Bool ?? false,
            underline: body["underline"] as? Bool ?? false
        )
        if updated != format { format = updated }
    }

    /// The first family of a CSS font stack, as the toolbar's picker names it: the
    /// system stack maps to "System", a listed family to its listed spelling.
    private static func pickerFamily(fromStack stack: String) -> String {
        let first = (stack.split(separator: ",").first.map(String.init) ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        if first.isEmpty || first == "-apple-system" || first == "system-ui" || first == "SF Pro Text" {
            return RichTextController.systemFamily
        }
        return RichTextController.fontFamilies.first { $0.caseInsensitiveCompare(first) == .orderedSame } ?? first
    }

    /// Parses a computed `rgb(r, g, b)` / `rgba(r, g, b, a)`; nil for an empty or
    /// fully transparent color.
    private static func color(fromCSS css: String) -> NSColor? {
        guard let open = css.firstIndex(of: "("), let close = css.lastIndex(of: ")") else { return nil }
        let parts = css[css.index(after: open)..<close].split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 3 else { return nil }
        let alpha = parts.count > 3 ? parts[3] : 1
        guard alpha > 0 else { return nil }
        return NSColor(srgbRed: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: alpha)
    }

    /// Sets the writing direction of the block holding the selection. Any inline
    /// text alignment is cleared so the new direction actually governs the layout.
    private func setDirection(_ direction: String) {
        run("""
        var sel = window.getSelection();
        if (!sel || !sel.rangeCount) return;
        var node = sel.getRangeAt(0).commonAncestorContainer;
        if (node.nodeType !== 1) node = node.parentElement;
        var block = node && node.closest('p, div, li, td, th, blockquote, body');
        if (block) {
          block.setAttribute('dir', '\(direction)');
          block.style.textAlign = '';
        }
        """)
    }

    // MARK: - Link popup

    /// Shows the Open/Edit popup above a clicked link. `rect` is the link's box
    /// in CSS pixels, viewport space; the page keeps the anchor as
    /// `window.__nmClickedLink` so Edit can select it.
    fileprivate func showLinkPopover(href: String, text: String, rect: CGRect) {
        guard let webView, let url = URL(string: href) else { return }
        let scale = webView.pageZoom
        var anchor = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                            width: rect.width * scale, height: rect.height * scale)
        if !webView.isFlipped { anchor.origin.y = webView.bounds.height - anchor.maxY }
        linkPopover.show(relativeTo: anchor, of: webView, onOpen: {
            NSWorkspace.shared.open(url)
        }, onEdit: { [weak self] in
            guard let self else { return }
            self.run("""
            var a = window.__nmClickedLink;
            if (!a || !a.isConnected) return;
            var range = document.createRange();
            range.selectNode(a);
            var selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            """)
            self.onEditLink?(text, href)
        })
    }

    // MARK: - Mentions

    /// Tells the page whether the mention popup is on screen, so its keydown hook
    /// knows whether to hand the arrows and Return over to it. Runs without taking
    /// first responder — the caret must stay exactly where the user left it.
    func setMentionActive(_ active: Bool) {
        webView?.evaluateJavaScript("window.__nmMentionActive = \(active);")
    }

    /// Replaces the `@mention` at the caret with the contact's name, linked to their
    /// address. Done with `insertHTML` over a selection covering the token so the
    /// change joins the document's own undo stack.
    func insertMention(name: String, email: String) {
        let label = name.isEmpty ? email : name
        run("""
        var token = window.__nmMentionToken && window.__nmMentionToken();
        if (!token) return;
        var range = document.createRange();
        range.setStart(token.node, token.at);
        range.setEnd(token.node, token.caret);
        var selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        var link = document.createElement('a');
        link.href = 'mailto:' + \(Self.jsString(email));
        link.textContent = \(Self.jsString(label));
        // The trailing space keeps the caret outside the anchor, so what's typed
        // next isn't swallowed into the link.
        document.execCommand('insertHTML', false, link.outerHTML + '&nbsp;');
        """)
    }

    private func exec(_ command: String, value: String? = nil, styleWithCSS: Bool = false) {
        let argument = value.map(Self.jsString) ?? "null"
        run("""
        document.execCommand('styleWithCSS', false, \(styleWithCSS));
        document.execCommand('\(command)', false, \(argument));
        """)
    }

    /// Runs an editing script against the document. The WebView is made first
    /// responder again first: clicking a toolbar menu or picker can take focus away
    /// from it, and the command has to land on the selection the user left behind.
    private func run(_ js: String) {
        guard let webView else { return }
        webView.window?.makeFirstResponder(webView)
        webView.evaluateJavaScript("(function () {\n\(js)\n})()")
    }

    /// Quotes a Swift string as a JavaScript string literal.
    private static func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
              let quoted = String(data: data, encoding: .utf8) else { return "''" }
        return quoted
    }

    /// The current document HTML, faithful to what was loaded: the original DOM
    /// edited in place, so styles, fonts, image sizes, and spacing survive intact.
    /// Strips the editor-only affordances (designMode, helper stylesheet) first.
    func exportHTML() async -> String {
        guard let webView else { return "" }
        let js = """
        (function () {
          var s = document.getElementById('nm-editor-only');
          if (s) s.remove();
          var c = document.getElementById('nm-painter-cursor');
          if (c) c.remove();
          document.designMode = 'off';
          return '<!DOCTYPE html>\\n' + document.documentElement.outerHTML;
        })()
        """
        let result = try? await webView.evaluateJavaScript(js)
        return (result as? String) ?? ""
    }
}

/// A WKWebView that loads a message's original HTML and makes it editable in place
/// via `document.designMode`. Unlike the NSAttributedString-based `RichTextEditor`,
/// this preserves the source HTML/CSS exactly (used only for "Edit message", where
/// faithfully keeping a richly-formatted message's layout matters).
struct HTMLEditorView: NSViewRepresentable {
    let html: String
    let controller: HTMLEditorController

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // The page itself runs no scripts; we only drive editing via designMode and
        // native evaluateJavaScript. JS stays enabled so those calls take effect.
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Shift-Tab in the body posts back here so compose can move focus to Subject;
        // "mention" carries the `@name` being typed and the keys its popup claims.
        config.userContentController.add(context.coordinator, name: "shiftTab")
        config.userContentController.add(context.coordinator, name: "mention")
        config.userContentController.add(context.coordinator, name: "link")
        config.userContentController.add(context.coordinator, name: "format")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        controller.webView = webView
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    // The HTML is loaded once in makeNSView; reloading on every SwiftUI update would
    // wipe the user's edits, so updates are intentionally a no-op.
    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let controller: HTMLEditorController
        init(controller: HTMLEditorController) { self.controller = controller }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Turn on whole-document editing and add an editor-only stylesheet (kept
            // out of the saved HTML by exportHTML) so images don't overflow the pane
            // and the text shows in the same system font the reading pane applies
            // (HTMLView.wrap) — without it WebKit falls back to Times for messages
            // that don't set their own font. The saved HTML stays bare either way;
            // the viewer re-applies the same defaults at display time.
            // The capturing keydown listener routes Shift-Tab back to native (via the
            // shiftTab message handler) instead of letting designMode swallow it, so
            // focus returns to the Subject field.
            let js = """
            document.designMode = 'on';
            if (!document.getElementById('nm-editor-only')) {
              var s = document.createElement('style');
              s.id = 'nm-editor-only';
              s.textContent = 'img{max-width:100%;height:auto;} body{margin:8px;' +
                'font:-apple-system-body;' +
                'font-family:-apple-system,"SF Pro Text",Helvetica,Arial,sans-serif;' +
                'line-height:1.5;word-wrap:break-word;}';
              (document.head || document.documentElement).appendChild(s);
            }
            document.addEventListener('keydown', function (e) {
              if (e.key === 'Tab' && e.shiftKey) {
                e.preventDefault();
                window.webkit.messageHandlers.shiftTab.postMessage('');
                return;
              }
              // While the address popup is up it owns these keys, exactly as it does
              // in the rich-text editor; designMode never sees them.
              if (window.__nmMentionActive &&
                  ['ArrowDown', 'ArrowUp', 'Enter', 'Escape', 'Tab'].indexOf(e.key) >= 0) {
                e.preventDefault();
                window.webkit.messageHandlers.mention.postMessage({ key: e.key });
              }
            }, true);
            // Pasted image data would be inserted as webkit-fake-url:// references,
            // which only resolve inside this live WebView — the image would vanish
            // from the saved copy. Insert such pastes as data: URIs instead; the
            // save path re-embeds those as normal inline (cid:) attachments.
            document.addEventListener('paste', function (e) {
              var data = e.clipboardData;
              if (!data || !data.items) return;
              // Pastes that carry HTML keep the default behavior: their images are
              // real URLs that survive saving.
              if (Array.prototype.indexOf.call(data.types || [], 'text/html') >= 0) return;
              var files = [];
              for (var i = 0; i < data.items.length; i++) {
                var item = data.items[i];
                if (item.kind === 'file' && /^image\\//.test(item.type)) {
                  var f = item.getAsFile();
                  if (f) files.push(f);
                }
              }
              if (!files.length) return;
              e.preventDefault();
              files.forEach(function (file) {
                var reader = new FileReader();
                reader.onload = function () {
                  document.execCommand('insertHTML', false, '<img src="' + reader.result + '">');
                };
                reader.readAsDataURL(file);
              });
            }, true);
            if (document.body) { document.body.focus(); }
            """
            webView.evaluateJavaScript(js)
            webView.evaluateJavaScript(Self.mentionScript)
            webView.evaluateJavaScript(Self.linkScript)
            webView.evaluateJavaScript(Self.formatScript)
        }

        /// Reports the caret's computed formatting (`__nmFormat`) whenever the
        /// selection or the document changes, and runs the format painter: a
        /// format copied into `__nmPainter` is applied to the next selection made
        /// with the mouse. A click that leaves no selection keeps it armed.
        private static let formatScript = """
        window.__nmFormat = function () {
          var sel = window.getSelection();
          if (!sel || !sel.rangeCount) return null;
          var range = sel.getRangeAt(0);
          var node = range.startContainer;
          if (node.nodeType === 1 && node.childNodes[range.startOffset]) node = node.childNodes[range.startOffset];
          if (node.nodeType !== 1) node = node.parentElement;
          if (!node) return null;
          var cs = getComputedStyle(node);
          // Highlight and underline aren't inherited in computed style, so they're
          // looked for on the ancestors up to (not including) the body.
          var background = '', underline = false, sup = false;
          for (var n = node; n && n.nodeType === 1 && n !== document.body; n = n.parentElement) {
            var s = getComputedStyle(n);
            if (!background && s.backgroundColor !== 'rgba(0, 0, 0, 0)' && s.backgroundColor !== 'transparent') {
              background = s.backgroundColor;
            }
            if (/underline/.test(s.textDecorationLine)) underline = true;
            if (s.verticalAlign === 'super' || n.tagName === 'SUP') sup = true;
          }
          return {
            family: cs.fontFamily, size: parseFloat(cs.fontSize) || 16,
            color: cs.color, background: background,
            bold: cs.fontWeight === 'bold' || parseInt(cs.fontWeight, 10) >= 600,
            italic: cs.fontStyle === 'italic', underline: underline, sup: sup
          };
        };
        // execCommand('fontSize') only speaks the legacy 1–7 scale, so the
        // selection is stamped with size 7 and those tags are rewritten to the
        // exact pixel size; size-7 tags the original message already had are
        // marked first so they're left alone.
        window.__nmSetFontSize = function (px) {
          var existing = document.querySelectorAll('font[size="7"]');
          for (var i = 0; i < existing.length; i++) existing[i].setAttribute('data-nm-keep', '');
          document.execCommand('styleWithCSS', false, false);
          document.execCommand('fontSize', false, '7');
          var made = document.querySelectorAll('font[size="7"]:not([data-nm-keep])');
          for (var j = 0; j < made.length; j++) {
            made[j].removeAttribute('size');
            made[j].style.fontSize = px + 'px';
          }
          for (var k = 0; k < existing.length; k++) existing[k].removeAttribute('data-nm-keep');
        };
        window.__nmApplyFormat = function (f) {
          document.execCommand('styleWithCSS', false, true);
          document.execCommand('fontName', false, f.family);
          document.execCommand('foreColor', false, f.color);
          document.execCommand('hiliteColor', false, f.background || 'transparent');
          var states = { bold: f.bold, italic: f.italic, underline: f.underline, superscript: f.sup };
          for (var cmd in states) {
            if (document.queryCommandState(cmd) !== states[cmd]) document.execCommand(cmd, false, null);
          }
          window.__nmSetFontSize(f.size);
        };
        // The brush cursor lives in its own stylesheet, removed on disarm and by
        // exportHTML, so it never reaches the saved message.
        window.__nmPainterCursor = function (css) {
          var old = document.getElementById('nm-painter-cursor');
          if (old) old.remove();
          if (!css) return;
          var s = document.createElement('style');
          s.id = 'nm-painter-cursor';
          s.textContent = 'html, html * { cursor: ' + css + ' !important; }';
          (document.head || document.documentElement).appendChild(s);
        };
        window.__nmFormatPost = function () {
          var f = window.__nmFormat();
          if (f) window.webkit.messageHandlers.format.postMessage(f);
        };
        document.addEventListener('selectionchange', window.__nmFormatPost, true);
        document.addEventListener('input', window.__nmFormatPost, true);
        document.addEventListener('mouseup', function () {
          // After the click's own selection handling has settled.
          setTimeout(function () {
            var f = window.__nmPainter;
            var sel = window.getSelection();
            if (!f || !sel || sel.isCollapsed) return;
            window.__nmPainter = null;
            window.__nmPainterCursor(null);
            window.__nmApplyFormat(f);
            window.webkit.messageHandlers.format.postMessage({ painterApplied: true });
            window.__nmFormatPost();
          }, 0);
        }, true);
        window.__nmFormatPost();
        """

        /// Turns typed and pasted URLs into links, and reports clicks on links so
        /// native code can show the Open/Edit popup (designMode never follows them).
        /// A typed URL is linked once the whitespace or line break after it goes in.
        private static let linkScript = """
        window.__nmLinkifyBeforeCaret = function () {
          var sel = window.getSelection();
          if (!sel || !sel.rangeCount || !sel.isCollapsed) return;
          sel.modify('move', 'backward', 'character');
          var r = sel.getRangeAt(0);
          var node = r.endContainer;
          if (node.nodeType === 3 && !(node.parentElement && node.parentElement.closest('a'))) {
            var text = node.data.substring(0, r.endOffset);
            var m = /(?:https?:\\/\\/|www\\.)[^\\s<>"]+$/i.exec(text);
            if (m && (m.index === 0 || /\\s/.test(text.charAt(m.index - 1)))) {
              // Trailing punctuation ends the sentence, not the URL.
              var url = m[0].replace(/[.,;:!?)\\]]+$/, '');
              var range = document.createRange();
              range.setStart(node, m.index);
              range.setEnd(node, m.index + url.length);
              sel.removeAllRanges();
              sel.addRange(range);
              document.execCommand('createLink', false, /^www\\./i.test(url) ? 'http://' + url : url);
              sel.collapseToEnd();
              for (var i = 0; i <= m[0].length - url.length; i++) sel.modify('move', 'forward', 'character');
              return;
            }
          }
          sel.modify('move', 'forward', 'character');
        };
        document.addEventListener('input', function (e) {
          if ((e.inputType === 'insertText' && e.data && /\\s/.test(e.data)) ||
              e.inputType === 'insertParagraph' || e.inputType === 'insertLineBreak') {
            window.__nmLinkifyBeforeCaret();
          }
        }, true);
        document.addEventListener('paste', function (e) {
          var data = e.clipboardData;
          if (!data || Array.prototype.indexOf.call(data.types || [], 'text/html') >= 0) return;
          var text = (data.getData('text/plain') || '').trim();
          if (!/^(?:https?:\\/\\/|www\\.)[^\\s<>"]+$/i.test(text)) return;
          e.preventDefault();
          var link = document.createElement('a');
          link.href = /^www\\./i.test(text) ? 'http://' + text : text;
          link.textContent = text;
          document.execCommand('insertHTML', false, link.outerHTML);
        }, true);
        document.addEventListener('click', function (e) {
          var a = e.target && e.target.closest && e.target.closest('a[href]');
          if (!a) return;
          e.preventDefault();
          window.__nmClickedLink = a;
          var rect = a.getBoundingClientRect();
          window.webkit.messageHandlers.link.postMessage({
            href: a.getAttribute('href'), text: a.textContent,
            x: rect.left, y: rect.top, width: rect.width, height: rect.height
          });
        }, true);
        """

        /// Finds the `@name` at the caret and reports it (with the `@`'s on-screen
        /// box) whenever it changes. `__nmMentionToken` is left on `window` so
        /// `insertMention` can re-find the same token when the user picks someone.
        /// The rule matches `MentionScanner`: the `@` starts a word, and nothing
        /// after it is whitespace or a second `@`.
        private static let mentionScript = """
        window.__nmMentionToken = function () {
          var selection = window.getSelection();
          if (!selection || !selection.rangeCount || !selection.isCollapsed) return null;
          var range = selection.getRangeAt(0);
          var node = range.endContainer;
          if (node.nodeType !== 3) return null;
          var text = node.data.substring(0, range.endOffset);
          var at = text.lastIndexOf('@');
          if (at < 0) return null;
          var query = text.substring(at + 1);
          if (query.length > \(MentionScanner.maxQueryLength) || /[\\s@]/.test(query)) return null;
          if (at > 0 && !/\\s/.test(text.charAt(at - 1))) return null;
          return { node: node, at: at, caret: range.endOffset, query: query };
        };
        window.__nmMentionPost = function () {
          var token = window.__nmMentionToken();
          // Posting only on change keeps a dismissed popup dismissed until the
          // query actually moves on, and spares the bridge every caret twitch.
          var state = token ? token.query : '';
          if (state === window.__nmMentionLast) return;
          window.__nmMentionLast = state;
          if (!token) {
            window.webkit.messageHandlers.mention.postMessage({ query: null });
            return;
          }
          var box = document.createRange();
          box.setStart(token.node, token.at);
          box.setEnd(token.node, token.at + 1);
          var rect = box.getBoundingClientRect();
          window.webkit.messageHandlers.mention.postMessage({
            query: token.query, x: rect.left, y: rect.top, height: rect.height
          });
        };
        document.addEventListener('input', window.__nmMentionPost, true);
        document.addEventListener('selectionchange', window.__nmMentionPost, true);
        """

        private static let mentionKeys: [String: MentionKey] = [
            "ArrowDown": .down, "ArrowUp": .up, "Enter": .accept, "Tab": .accept, "Escape": .dismiss,
        ]

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if message.name == "shiftTab" { controller.onShiftTab?() }
            if message.name == "format", let body = message.body as? [String: Any] {
                if body["painterApplied"] != nil { controller.painterApplied() }
                else { controller.updateFormat(body) }
                return
            }
            if message.name == "link", let body = message.body as? [String: Any],
               let href = body["href"] as? String {
                let rect = CGRect(x: body["x"] as? Double ?? 0, y: body["y"] as? Double ?? 0,
                                  width: body["width"] as? Double ?? 0, height: body["height"] as? Double ?? 0)
                controller.showLinkPopover(href: href, text: body["text"] as? String ?? "", rect: rect)
                return
            }
            guard message.name == "mention", let body = message.body as? [String: Any] else { return }
            if let key = body["key"] as? String {
                if let mention = Self.mentionKeys[key] { _ = controller.onMentionKey?(mention) }
                return
            }
            guard let query = body["query"] as? String else {
                controller.onMention?(nil)
                return
            }
            // The page reports CSS pixels in viewport space — the same top-left
            // origin SwiftUI overlays use — so only the display zoom has to be
            // undone to reach view points.
            let scale = message.webView?.pageZoom ?? 1
            let anchor = CGRect(x: (body["x"] as? Double ?? 0) * scale,
                                y: (body["y"] as? Double ?? 0) * scale,
                                width: 1,
                                height: (body["height"] as? Double ?? 0) * scale)
            controller.onMention?(MentionContext(query: query, anchor: anchor))
        }
    }
}
