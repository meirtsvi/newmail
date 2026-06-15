import Foundation

/// An image part pulled from a message, with its bytes already fetched. Either
/// referenced inline from the HTML via `cid:` (then it replaces the placeholder)
/// or a standalone image (then it's previewed below the body).
struct InlineImage {
    var cid: String?        // bare Content-ID (no angle brackets), if any
    var mime: String
    var data: Data
    var filename: String
    var attachmentId: String?
}

/// Provider-agnostic assembly of a message's display HTML: embeds inline images,
/// linkifies bare URLs, and appends previews for image attachments that aren't
/// referenced inline. Shared by the Gmail and Graph providers.
enum BodyHTML {
    /// - Parameters:
    ///   - rawHTML: the message's HTML part (may be empty).
    ///   - plainText: the text/plain alternative (used when there's no HTML).
    ///   - images: every image part of the message, bytes included.
    ///   - messageId: owning message id (for the returned attachment chips).
    /// - Returns: the display HTML plus chips for standalone (non-inline) images.
    static func assemble(
        rawHTML: String,
        plainText: String,
        images: [InlineImage],
        messageId: String
    ) -> (html: String, imageAttachments: [MailAttachment]) {
        // Embed cid: images into the HTML first (so the URL substitution happens
        // inside tags, which the linkifier then skips over).
        var html = rawHTML
        var usedCIDs: Set<String> = []
        if !html.isEmpty {
            let dataURIByCID = Dictionary(
                images.compactMap { img -> (String, String)? in
                    guard let cid = img.cid, !cid.isEmpty else { return nil }
                    return (cid, dataURI(img))
                },
                uniquingKeysWith: { first, _ in first }
            )
            let embedded = PlainTextHTML.embedInlineImages(in: html, dataURIByCID: dataURIByCID)
            html = PlainTextHTML.linkifyHTMLBody(embedded.html)
            usedCIDs = embedded.used
        } else if !plainText.isEmpty {
            html = PlainTextHTML.render(plainText)
        }

        // Preview images that weren't shown inline, and surface them as chips so
        // they can still be downloaded.
        var previews = ""
        var chips: [MailAttachment] = []
        for img in images {
            if let cid = img.cid, usedCIDs.contains(cid) { continue }
            previews += "<div style=\"margin-top:8px\"><img src=\"\(dataURI(img))\" style=\"max-width:100%;height:auto\"></div>"
            if !img.filename.isEmpty, let attId = img.attachmentId {
                chips.append(MailAttachment(
                    id: attId, messageId: messageId, filename: img.filename,
                    mimeType: img.mime, sizeBytes: img.data.count
                ))
            }
        }
        html += previews
        return (html, chips)
    }

    private static func dataURI(_ img: InlineImage) -> String {
        let mime = img.mime.isEmpty ? "image/png" : img.mime
        return "data:\(mime);base64,\(img.data.base64EncodedString())"
    }
}
