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

    struct InternetMessageHeader: Codable {
        var name: String?
        var value: String?
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
        var ccRecipients: [Recipient]?
        var flag: FollowupFlag?
        var parentFolderId: String?
        var body: ItemBody?
        var internetMessageHeaders: [InternetMessageHeader]?
        var internetMessageId: String?
        /// MAPI properties requested via `$expand` (the last-verb property).
        var singleValueExtendedProperties: [ExtendedProperty]?
        /// Present (with a reason) on delta-query entries for messages that left
        /// the folder; such entries carry nothing but the id.
        var removed: Removed?

        struct Removed: Codable { var reason: String? }

        enum CodingKeys: String, CodingKey {
            case id, conversationId, subject, bodyPreview, receivedDateTime, isRead, hasAttachments
            case from, sender, toRecipients, ccRecipients, flag, parentFolderId, body
            case internetMessageHeaders, internetMessageId, singleValueExtendedProperties
            case removed = "@removed"
        }
    }

    struct ExtendedProperty: Codable {
        var id: String
        var value: String?
    }

    struct MessageList: Codable {
        var value: [Message]
        var nextLink: String?
        /// Only on the last page of a delta query: where the next sync resumes.
        var deltaLink: String?
        enum CodingKeys: String, CodingKey {
            case value
            case nextLink = "@odata.nextLink"
            case deltaLink = "@odata.deltaLink"
        }
    }

    struct Contact: Codable {
        var displayName: String?
        var emailAddresses: [EmailAddress]?
    }

    struct ContactList: Codable {
        var value: [Contact]
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
        var contentId: String?
        var contentBytes: String?
    }

    struct AttachmentList: Codable {
        var value: [Attachment]
    }
}
