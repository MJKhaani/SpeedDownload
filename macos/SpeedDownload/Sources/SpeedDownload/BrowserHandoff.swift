import Darwin
import Foundation

/// Only the native browser host writes these bounded, private client requests.
/// The browser bridge has no engine connection and cannot supply a file path.
struct BrowserHandoff: Decodable {
    let version: Int
    let action: String
    let url: String?
    let urls: [String]?
    let referenceURL: String?
    let idempotencyKey: String

    enum CodingKeys: String, CodingKey {
        case version, action, url, urls
        case referenceURL = "reference_url"
        case idempotencyKey = "idempotency_key"
    }

    var sources: [String] { urls ?? url.map { [$0] } ?? [] }

    private static var inbox: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Speed Download/BrowserInbox", isDirectory: true)
    }

    /// Recover requests written before a failed client launch. Only review them;
    /// adding jobs still requires confirmation in the client dialog.
    static func pendingTokens() -> [String] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let entries = FileManager.default.enumerator(at: inbox, includingPropertiesForKeys: keys,
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { return [] }
        var pending: [(String, Date)] = []
        for case let file as URL in entries {
            guard file.pathExtension == "json", UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
                  let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            pending.append((file.deletingPathExtension().lastPathComponent, values.contentModificationDate ?? .distantPast))
            if pending.count == 100 { break }
        }
        return pending.sorted { $0.1 < $1.1 }.map { $0.0 }
    }

    static func consume(_ token: String) throws -> BrowserHandoff {
        guard UUID(uuidString: token) != nil else { throw CocoaError(.fileReadInvalidFileName) }
        let file = inbox.appendingPathComponent(token + ".json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 256 * 1024 else {
            throw CocoaError(.fileReadNoPermission)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let request = try JSONDecoder().decode(BrowserHandoff.self, from: Data(contentsOf: file))
        guard request.version == 1, request.idempotencyKey == token,
              ["add", "torrent", "batch"].contains(request.action),
              (request.action == "batch" ? (request.url == nil && request.urls != nil) : (request.url != nil && request.urls == nil)),
              !request.sources.isEmpty, request.sources.count <= 100,
              request.sources.reduce(0, { $0 + $1.utf8.count }) <= 128 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        if let reference = request.referenceURL {
            guard reference.utf8.count <= 8192, let page = URL(string: reference),
                  ["http", "https"].contains(page.scheme?.lowercased() ?? ""), page.host != nil,
                  page.user == nil, page.password == nil, page.fragment == nil,
                  reference.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        for source in request.sources {
            guard source.utf8.count <= 8192, let parsed = URL(string: source),
                  source.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  (parsed.scheme?.lowercased() == "magnet" ||
                   (["http", "https"].contains(parsed.scheme?.lowercased() ?? "") && parsed.host != nil && parsed.user == nil && parsed.password == nil && parsed.fragment == nil)) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        return request
    }
}
