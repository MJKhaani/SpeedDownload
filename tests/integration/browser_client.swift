import Foundation

@main
struct BrowserClientRegression {
    static func main() throws {
        let manager = FileManager.default
        let inbox = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Speed Download/BrowserInbox", isDirectory: true)
        try manager.createDirectory(at: inbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func check(_ action: String, _ sources: [String]) throws {
            let token = UUID().uuidString
            let file = inbox.appendingPathComponent(token + ".json")
            defer { try? manager.removeItem(at: file) }
            var message: [String: Any] = ["version": 1, "action": action, "idempotency_key": token]
            if action == "batch" { message["urls"] = sources } else { message["url"] = sources[0] }
            try JSONSerialization.data(withJSONObject: message).write(to: file)
            let request = try BrowserHandoff.consume(token)
            precondition(request.sources == sources)
            precondition(!manager.fileExists(atPath: file.path), "Consumed requests must not remain in the inbox")
        }
        try check("add", ["https://example.test/file.zip"])
        try check("torrent", ["magnet:?xt=urn:btih:" + String(repeating: "a", count: 40)])
        try check("batch", ["https://example.test/one.zip", "https://example.test/two.zip"])
        do { try check("add", ["file:///etc/passwd"]); fatalError("Browser filesystem URLs must be rejected") }
        catch { }
        do { _ = try BrowserHandoff.consume("../invalid"); fatalError("Inbox traversal must be rejected") }
        catch { }
        print("PASS: client inbox single/torrent/batch delivery, consumption, and path validation")
    }
}
