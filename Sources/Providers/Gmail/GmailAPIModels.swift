import Foundation

/// Codable models mirroring the Gmail REST API v1 JSON shapes we consume.
enum GmailAPI {
    struct Profile: Codable {
        var emailAddress: String
        var historyId: String?
    }

    /// `users.history.list` response. Each record lists the messages it touched
    /// per change type; only the message ids are used.
    struct HistoryList: Codable {
        var history: [HistoryRecord]?
        var nextPageToken: String?
        var historyId: String?
    }

    struct HistoryRecord: Codable {
        var messagesAdded: [HistoryMessage]?
        var messagesDeleted: [HistoryMessage]?
        var labelsAdded: [HistoryMessage]?
        var labelsRemoved: [HistoryMessage]?
    }

    struct HistoryMessage: Codable {
        var message: MessageRef
    }

    // People API (contacts).
    struct PeopleList: Codable {
        var connections: [Person]?
        var otherContacts: [Person]?
        var nextPageToken: String?
    }

    struct Person: Codable {
        var names: [PersonName]?
        var emailAddresses: [PersonEmail]?
    }

    struct PersonName: Codable {
        var displayName: String?
    }

    struct PersonEmail: Codable {
        var value: String?
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
