import Foundation

/// Codable models mirroring the Gmail REST API v1 JSON shapes we consume.
enum GmailAPI {
    struct Profile: Codable {
        var emailAddress: String
    }

    struct LabelsList: Codable {
        var labels: [Label]
    }

    struct Label: Codable {
        var id: String
        var name: String
        var type: String?           // "system" | "user"
        var messagesUnread: Int?
        var messagesTotal: Int?
        var messageListVisibility: String?
        var labelListVisibility: String?
    }

    struct MessagesList: Codable {
        var messages: [MessageRef]?
        var nextPageToken: String?
        var resultSizeEstimate: Int?
    }

    struct MessageRef: Codable {
        var id: String
        var threadId: String
    }

    struct Message: Codable {
        var id: String
        var threadId: String
        var labelIds: [String]?
        var snippet: String?
        var internalDate: String?   // ms since epoch, as a string
        var payload: Part?
    }

    struct Part: Codable {
        var partId: String?
        var mimeType: String?
        var filename: String?
        var headers: [Header]?
        var body: Body?
        var parts: [Part]?
    }

    struct Header: Codable {
        var name: String
        var value: String
    }

    struct Body: Codable {
        var attachmentId: String?
        var size: Int?
        var data: String?           // base64url
    }

    struct CreatedLabel: Codable {
        var id: String
        var name: String
    }
}
