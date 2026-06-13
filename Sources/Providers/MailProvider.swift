import Foundation

/// Backend-agnostic mail interface. Gmail and (future) Microsoft Graph both
/// conform; the UI layer talks only to this protocol.
protocol MailProvider: AnyObject {
    var accountEmail: String { get }

    func loadProfile() async throws
    func listFolders() async throws -> [MailFolder]
    func listMessages(folderId: String, query: String?, pageToken: String?) async throws -> (headers: [MessageHeader], nextPageToken: String?)
    func search(query: String, pageToken: String?) async throws -> (headers: [MessageHeader], nextPageToken: String?)
    func fetchBody(id: String) async throws -> MessageBody

    func setRead(ids: [String], read: Bool) async throws
    func setFlagged(ids: [String], flagged: Bool) async throws
    func trash(ids: [String]) async throws
    func archive(ids: [String]) async throws
    func move(ids: [String], toFolderId: String, fromFolderId: String?) async throws

    /// Ensures a folder/label with the given name exists and returns its id.
    func ensureFolder(named: String) async throws -> String

    func send(rawMIME: Data) async throws
}
