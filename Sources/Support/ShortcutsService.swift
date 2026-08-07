import AppKit

/// Runs a macOS Shortcut on a URL picked out of a message body.
///
/// The URL is handed over two ways at once, so shortcuts written either way work
/// without being edited: it is placed on the clipboard (for shortcuts that start
/// with a "Get Clipboard" action) *and* passed as the shortcut's text input.
enum ShortcutsService {
    /// Names of the installed shortcuts, newest reading of `shortcuts list`.
    /// Cached because the context menu is built synchronously on right-click and
    /// can't wait on a process launch. Main-thread only.
    private(set) static var installed: [String] = []

    /// Names ticked in Settings → Shortcuts. Only these are offered on a link;
    /// with none ticked the menu shows no shortcut item at all.
    static var chosen: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: chosenKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: chosenKey) }
    }

    static let chosenKey = "shortcutsInLinkMenu"

    /// The shortcuts the link menu should offer, in the order Shortcuts lists them.
    /// Anything ticked but since deleted from the Shortcuts app drops out here.
    static var menuShortcuts: [String] {
        let chosen = chosen
        return installed.filter { chosen.contains($0) }
    }

    private static let queue = DispatchQueue(label: "com.meirt.newmail.shortcuts")

    /// Reloads `installed` in the background. Safe to call often; the result only
    /// affects the *next* menu that opens.
    static func refresh() {
        queue.async {
            let names = list()
            DispatchQueue.main.async { installed = names }
        }
    }

    /// Reads the installed shortcuts for the Settings list, off the main thread.
    static func load() async -> [String] {
        await withCheckedContinuation { continuation in
            queue.async {
                let names = list()
                DispatchQueue.main.async {
                    installed = names
                    continuation.resume(returning: names)
                }
            }
        }
    }

    /// Reads shortcut names from the `shortcuts` CLI. Returns an empty list when
    /// the tool is missing or refuses to talk to the Shortcuts service (which is
    /// what happens in a sandboxed build), so the menu simply shows no items.
    private static func list() -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        task.arguments = ["list"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Puts `url` on the clipboard, then runs the named shortcut on it.
    static func run(_ name: String, on url: URL) {
        let text = url.absoluteString

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: text),
        ]
        guard let runURL = components.url else { return }
        NSWorkspace.shared.open(runURL)
    }
}
