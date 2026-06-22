import Foundation

/// Backend-agnostic mail interface. Gmail and (future) Microsoft Graph both
/// conform; the UI layer talks only to this protocol.
protocol MailProvider: AnyObject {
    var accountEmail: String { get }

    func loadProfile() async throws
    func listFolders() async throws -> [MailFolder]
    func folderCount(id: String) async throws -> (unread: Int, total: Int)
    func listMessages(folderId: String, query: String?, pageToken: String?) async throws -> (headers: [MessageHeader], nextPageToken: String?)
    func search(query: String, pageToken: String?) async throws -> (headers: [MessageHeader], nextPageToken: String?)
    func fetchBody(id: String) async throws -> MessageBody
    func fetchAttachment(messageId: String, attachmentId: String) async throws -> Data

    /// Ids of messages in the folder that carry a calendar invitation, detected via
    /// a cheap server-side query (no per-message body fetch). May be a subset for
    /// invites that can't be matched server-side (those are still caught on open).
    func calendarInviteIds(folderId: String) async throws -> Set<String>

    func setRead(ids: [String], read: Bool) async throws
    func setFlagged(ids: [String], flagged: Bool) async throws
    func trash(ids: [String]) async throws

    /// Reverses a `trash` (⌘Z undo): restores the messages to `toFolderId`, the
    /// folder they were deleted from. Must be called with the same ids passed to
    /// `trash`; providers whose ids change on trash track the mapping internally.
    func untrash(ids: [String], toFolderId: String) async throws
    func archive(ids: [String]) async throws
    func move(ids: [String], toFolderId: String, fromFolderId: String?) async throws

    /// Marks messages as not spam: removes them from Junk and files them in the Inbox.
    func markNotSpam(ids: [String]) async throws

    /// Ensures a folder/label with the given name exists and returns its id.
    func ensureFolder(named: String) async throws -> String

    /// Creates a folder/label named `name` and returns its id. If `parentId` is
    /// non-nil the new folder is nested under that folder.
    func createFolder(named name: String, parentId: String?) async throws -> String

    /// Deletes the folder/label with the given id, along with all of its
    /// descendants (sub-folders).
    func deleteFolder(id: String) async throws

    func send(rawMIME: Data) async throws

    /// Saves a draft from the message MIME, returning the draft's id. Pass `id: nil`
    /// to create a new draft, or an existing id to replace it in place; the returned
    /// id must be used for subsequent saves and the eventual delete (it may differ
    /// from the one passed in for providers that recreate the draft).
    func saveDraft(id: String?, rawMIME: Data) async throws -> String

    /// Removes a draft (used after the message is sent, or to discard it).
    func deleteDraft(id: String) async throws

    /// Resolves the provider-specific draft id for a message that lives in the
    /// Drafts folder, so reopening it for editing replaces/deletes the original
    /// instead of creating a duplicate. Gmail draft ids differ from message ids;
    /// where a draft *is* a message, this returns the message id. Nil if no
    /// matching draft is found.
    func draftId(forMessageId messageId: String) async throws -> String?

    // MARK: - Cross-account move

    /// The original RFC822/MIME bytes of a message, used to re-create it faithfully
    /// in another account (preserving sender, date, headers, and attachments).
    func exportRawMessage(id: String) async throws -> Data

    /// Imports raw RFC822/MIME into `toFolderId` (a label/folder of *this* account) as a
    /// real received message — not a draft, not sent — preserving the original sender,
    /// date, and headers. Pass `markUnread` to land it unread. Returns the new id.
    func importRawMessage(_ raw: Data, toFolderId: String, markUnread: Bool) async throws -> String

    /// Permanently removes messages from the server (used to delete the source copy
    /// after it has been successfully imported into another account).
    func permanentlyDelete(ids: [String]) async throws
}

// Default implementations so each provider only implements the directions it
// supports. A cross-account move only exports/deletes from the source and imports
// into the destination, so the unused half stays absent and these throw clearly.
extension MailProvider {
    func exportRawMessage(id: String) async throws -> Data {
        throw MailError.other("Exporting messages isn't supported for this account.")
    }
    func importRawMessage(_ raw: Data, toFolderId: String, markUnread: Bool) async throws -> String {
        throw MailError.other("Importing messages isn't supported for this account.")
    }
    func permanentlyDelete(ids: [String]) async throws {
        throw MailError.other("Permanent delete isn't supported for this account.")
    }
}
