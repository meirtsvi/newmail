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
    func archive(ids: [String]) async throws
    func move(ids: [String], toFolderId: String, fromFolderId: String?) async throws

    /// Marks messages as not spam: removes them from Junk and files them in the Inbox.
    func markNotSpam(ids: [String]) async throws

    /// Ensures a folder/label with the given name exists and returns its id.
    func ensureFolder(named: String) async throws -> String

    func send(rawMIME: Data) async throws
}
