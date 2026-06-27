import Foundation

/// Converts a plain-text message body into safe HTML for display: escapes markup
/// and turns bare URLs into clickable links. Used by providers when a message has
/// no HTML part. Links open in the default browser via `HTMLView`'s navigation
/// handling.
enum PlainTextHTML {
    /// Wraps linkified, escaped text in a wrapping `<pre>` block (preserves the
    /// original line breaks/spacing of a plain-text email).
    static func render(_ text: String) -> String {
        "<pre style=\"white-space:pre-wrap;font-family:-apple-system,sans-serif\">\(linkify(text))</pre>"
    }

    /// Escapes HTML and wraps any detected URLs in anchor tags. Uses
    /// `NSDataDetector` so it handles bare `www.` hosts, trailing punctuation, and
    /// query strings correctly.
    static func linkify(_ text: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return escape(text)
        }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        detector.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let range = match.range
            if range.location > cursor {
                out += escape(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            }
            let shown = ns.substring(with: range)
            let href = match.url?.absoluteString ?? shown
            out += "<a href=\"\(escapeAttribute(href))\">\(escape(shown))</a>"
            cursor = range.location + range.length
        }
        if cursor < ns.length { out += escape(ns.substring(from: cursor)) }
        return out
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ s: String) -> String {
        escape(s).replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - HTML bodies

    /// Linkifies bare URLs that appear as plain text *inside* an HTML body — many
    /// senders paste a raw URL without wrapping it in an anchor, so it renders as
    /// dead text. Walks the markup, linkifying only text nodes and leaving tags
    /// (and the contents of existing `<a>`/`<script>`/`<style>` elements) untouched,
    /// so existing links and attributes are never corrupted.
    static func linkifyHTMLBody(_ html: String) -> String {
        let ns = html as NSString
        let len = ns.length
        var out = ""
        out.reserveCapacity(html.count + 64)
        var i = 0
        var skipDepth = 0   // inside <a>/<script>/<style>: don't linkify text
        while i < len {
            if ns.character(at: i) == 0x3C { // '<'
                var j = i + 1
                while j < len && ns.character(at: j) != 0x3E { j += 1 } // until '>'
                let tagEnd = min(j, len - 1)
                let tag = ns.substring(with: NSRange(location: i, length: tagEnd - i + 1))
                out += tag
                let lower = tag.lowercased()
                if lower.hasPrefix("<a ") || lower == "<a>" || lower.hasPrefix("<script") || lower.hasPrefix("<style") {
                    skipDepth += 1
                } else if lower.hasPrefix("</a") || lower.hasPrefix("</script") || lower.hasPrefix("</style") {
                    if skipDepth > 0 { skipDepth -= 1 }
                }
                i = tagEnd + 1
            } else {
                var j = i
                while j < len && ns.character(at: j) != 0x3C { j += 1 } // until '<'
                let text = ns.substring(with: NSRange(location: i, length: j - i))
                out += skipDepth == 0 ? linkifyMatchesOnly(text) : text
                i = j
            }
        }
        return out
    }

    /// Wraps detected URLs in a text node with anchors, leaving every other byte
    /// unchanged (the surrounding HTML is already valid, so we must not re-escape).
    private static func linkifyMatchesOnly(_ text: String) -> String {
        guard text.contains("://") || text.range(of: "www.", options: .caseInsensitive) != nil else { return text }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        detector.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let range = match.range
            if range.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            }
            let shown = ns.substring(with: range)
            // A URL written as text may carry the HTML entity &amp; for its query
            // separators; decode that for the href so the link resolves correctly.
            let href = shown.replacingOccurrences(of: "&amp;", with: "&")
            out += "<a href=\"\(escapeAttribute(href))\">\(shown)</a>"
            cursor = range.location + range.length
        }
        if cursor < ns.length { out += ns.substring(from: cursor) }
        return out
    }

    /// Replaces `cid:` references with the supplied `data:` URIs (keyed by the
    /// bare Content-ID), so inline images embedded as attachments render in place
    /// instead of as broken placeholders. Returns which Content-IDs were used.
    static func embedInlineImages(in html: String, dataURIByCID: [String: String]) -> (html: String, used: Set<String>) {
        var out = html
        var used: Set<String> = []
        for (cid, uri) in dataURIByCID where !cid.isEmpty {
            let token = "cid:\(cid)"
            if out.range(of: token, options: .caseInsensitive) != nil {
                out = out.replacingOccurrences(of: token, with: uri, options: .caseInsensitive)
                used.insert(cid)
            }
        }
        return (out, used)
    }

    /// Footer-link markers matched case-insensitively against both the URL and the
    /// visible link text, so "Open All Links" doesn't fire off unsubscribe requests
    /// or open boilerplate (privacy policy, terms, "our values", manage preferences…).
    private static let skipMarkers = [
        "unsubscribe", "unsub", "optout", "opt-out", "opt_out", "remove",
        "privacy", "terms", "values", "ethics", "preference", "cookie", "view in browser", "view online"
    ]

    /// Collects every http(s) link in a message body for "Open All Links": pulls
    /// the `href` targets out of the HTML anchors (the visible text often differs
    /// from the destination, so the href is what matters) and falls back to
    /// detecting bare URLs in the plain-text part when there's no HTML. Results are
    /// http/https only (so `mailto:`/`tel:`/`cid:` are skipped), skip opt-out and
    /// boilerplate links (matched on URL *and* link text), and de-duplicated in order.
    static func extractLinks(html: String, plainText: String) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        func add(_ string: String, text: String = "") {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return }
            let haystack = (url.absoluteString + " " + text).lowercased()
            if skipMarkers.contains(where: haystack.contains) { return }
            if seen.insert(url.absoluteString).inserted { urls.append(url) }
        }
        if !html.isEmpty,
           let re = try? NSRegularExpression(
               pattern: "<a\\b[^>]*\\bhref\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')[^>]*>(.*?)</a>",
               options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let ns = html as NSString
            re.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match else { return }
                let hrefRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
                guard hrefRange.location != NSNotFound else { return }
                let href = ns.substring(with: hrefRange).replacingOccurrences(of: "&amp;", with: "&")
                let text = match.range(at: 3).location != NSNotFound
                    ? stripTags(ns.substring(with: match.range(at: 3))) : ""
                add(href, text: text)
            }
        } else if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let ns = plainText as NSString
            detector.enumerateMatches(in: plainText, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                if let url = match?.url { add(url.absoluteString) }
            }
        }
        return urls
    }

    /// Reduces an anchor's inner HTML to plain text for marker matching: drops any
    /// nested tags (e.g. `<span>`, `<img>`) and collapses common whitespace entities.
    private static func stripTags(_ html: String) -> String {
        let noTags = html.replacingOccurrences(
            of: "<[^>]+>", with: " ", options: .regularExpression)
        return noTags.replacingOccurrences(of: "&nbsp;", with: " ")
    }

    /// Extracts the inner content of an HTML document's `<body>` (NSAttributedString's
    /// HTML export wraps everything in a full document; we splice the fragment into
    /// a composed message). Returns the input unchanged when there's no `<body>`.
    static func bodyFragment(_ html: String) -> String {
        guard let bodyTag = html.range(of: "<body", options: .caseInsensitive),
              let gt = html.range(of: ">", range: bodyTag.upperBound..<html.endIndex) else { return html }
        let start = gt.upperBound
        let end = html.range(of: "</body>", options: .caseInsensitive)?.lowerBound ?? html.endIndex
        guard start <= end else { return html }
        return String(html[start..<end])
    }
}
