import Foundation

/// Codable models for the Microsoft Graph v1.0 mail surface.
enum GraphAPI {

    struct User: Codable {
        var mail: String?
        var userPrincipalName: String?
        var displayName: String?
    }

    struct MailFolder: Codable {
        var id: String
        var displayName: String
        var parentFolderId: String?
        var childFolderCount: Int?
        var unreadItemCount: Int?
        var totalItemCount: Int?
        var wellKnownName: String?
    }

    struct MailFolderList: Codable {
        var value: [MailFolder]
        var nextLink: String?
        enum CodingKeys: String, CodingKey {
            case value
            case nextLink = "@odata.nextLink"
        }
    }

    struct EmailAddress: Codable {
        var name: String?
        var address: String?
    }

    struct Recipient: Codable {
        var emailAddress: EmailAddress?
    }

    struct FollowupFlag: Codable {
        var flagStatus: String?
    }

    struct ItemBody: Codable {
        var contentType: String?
        var content: String?
    }

    struct Message: Codable {
        var id: String
        var conversationId: String?
        var subject: String?
        var bodyPreview: String?
        var receivedDateTime: String?
        var isRead: Bool?
        var hasAttachments: Bool?
        var from: Recipient?
        var sender: Recipient?
        var toRecipients: [Recipient]?
        var flag: FollowupFlag?
        var parentFolderId: String?
        var body: ItemBody?
    }

    struct MessageList: Codable {
        var value: [Message]
        var nextLink: String?
        enum CodingKeys: String, CodingKey {
            case value
            case nextLink = "@odata.nextLink"
        }
    }

    struct Attachment: Codable {
        var id: String
        var name: String?
        var contentType: String?
        var size: Int?
        var isInline: Bool?
    }

    struct AttachmentList: Codable {
        var value: [Attachment]
    }
}
