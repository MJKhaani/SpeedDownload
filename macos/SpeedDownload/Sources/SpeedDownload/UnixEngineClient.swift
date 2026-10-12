import Darwin
import Foundation

struct HelloResult: Sendable {
    let engineVersion: String
    let engineInstanceID: String
    let sessionID: String
}

struct DownloadJob: Decodable, Identifiable, Sendable, Equatable {
    let jobID: String
    let url: String
    let name: String?
    let destination: String
    let state: String
    let revision: String
    let errorMessage: String?
    let completedBytes: String?
    let totalBytes: String?

    var id: String { jobID }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case url, name, destination, state, revision
        case errorMessage = "error_message"
        case completedBytes = "completed_bytes"
        case totalBytes = "total_bytes"
    }
}

struct JobListResult: Decodable, Sendable {
    let jobs: [DownloadJob]
    let total: String
    let nextOffset: String?

    enum CodingKeys: String, CodingKey {
        case jobs, total
        case nextOffset = "next_offset"
    }
}

struct AddJobResult: Decodable, Sendable {
    let jobID: String
    let state: String
    let revision: String
    let duplicate: Bool

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case state, revision, duplicate
    }
}

struct UnixEngineClient: Sendable {
    private let maxFrameSize = 1_048_576

    func hello() throws -> HelloResult {
        let fd = try openConnection()
        defer { Darwin.close(fd) }
        return try negotiate(fd: fd)
    }

    func listJobs() throws -> [DownloadJob] {
        let fd = try openConnection()
        defer { Darwin.close(fd) }
        _ = try negotiate(fd: fd)
        var jobs: [DownloadJob] = []
        var offset = 0
        while true {
            let response: JobListResult = try request(
                fd: fd,
                id: "jobs-list-\(UUID().uuidString)",
                method: "jobs.list",
                params: ["offset": offset, "limit": 50]
            )
            jobs.append(contentsOf: response.jobs)
            guard let nextOffset = response.nextOffset else { return jobs }
            guard let next = Int(nextOffset), next > offset else { throw ClientError.invalidResponse }
            offset = next
        }
    }

    func addJob(url: String, name: String?, destination: String, idempotencyKey: String) throws -> AddJobResult {
        let fd = try openConnection()
        defer { Darwin.close(fd) }
        _ = try negotiate(fd: fd)
        var params: [String: Any] = [
            "url": url,
            "destination": destination,
            "idempotency_key": idempotencyKey,
        ]
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["name"] = name
        }
        return try request(
            fd: fd,
            id: "jobs-add-\(UUID().uuidString)",
            method: "jobs.add",
            params: params
        )
    }

    func controlJob(jobID: String, action: String, expectedRevision: String) throws -> AddJobResult {
        let fd = try openConnection()
        defer { Darwin.close(fd) }
        _ = try negotiate(fd: fd)
        return try request(
            fd: fd,
            id: "jobs-control-\(UUID().uuidString)",
            method: "jobs.control",
            params: ["job_id": jobID, "action": action, "expected_revision": expectedRevision]
        )
    }

    static func isRevisionConflict(_ error: Error) -> Bool {
        guard case ClientError.remote(_, let code, _) = error else { return false }
        return code == -32015
    }

    private func openConnection() throws -> Int32 {
        let runtime = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let socketPath = URL(fileURLWithPath: runtime)
            .appendingPathComponent("speed-download", isDirectory: true)
            .appendingPathComponent("engine.sock")
            .path
        let fd = try connect(path: socketPath)
        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) {
            Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        return fd
    }

    private func negotiate(fd: Int32) throws -> HelloResult {
        let envelope: RPCEnvelope<HelloEnvelope.Result> = try request(
            fd: fd,
            id: "hello-\(UUID().uuidString)",
            method: "engine.hello",
            params: [
                "protocol": ["major": 1, "minor": 0],
                "client": ["kind": "macos-gui", "version": "0.1.0"],
                "features": [],
            ]
        )
        guard let result = envelope.result else { throw ClientError.invalidResponse }
        return HelloResult(
            engineVersion: result.engineVersion,
            engineInstanceID: result.engineInstanceID,
            sessionID: result.sessionID
        )
    }

    private func request<Result: Decodable & Sendable>(
        fd: Int32,
        id: String,
        method: String,
        params: [String: Any]
    ) throws -> RPCEnvelope<Result> {
        let payload = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ])
        guard !payload.isEmpty, payload.count <= maxFrameSize else { throw ClientError.frameTooLarge }
        var frame = UInt32(payload.count).littleEndian
        var output = Data(bytes: &frame, count: MemoryLayout<UInt32>.size)
        output.append(payload)
        try writeAll(fd: fd, data: output)

        let header = try readExactly(fd: fd, count: 4)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard length > 0, length <= maxFrameSize else { throw ClientError.invalidFrame }
        let data = try readExactly(fd: fd, count: Int(length))
        let envelope = try JSONDecoder().decode(RPCEnvelope<Result>.self, from: data)
        guard envelope.id == id else { throw ClientError.invalidResponse }
        if let error = envelope.error { throw ClientError.remote(method: method, code: error.code, message: error.message) }
        return envelope
    }

    private func connect(path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError() }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= pathCapacity else {
            Darwin.close(fd)
            throw ClientError.socketPathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = posixError()
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    private func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw ClientError.invalidFrame }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(fd, base.advanced(by: sent), bytes.count - sent, 0)
                guard count > 0 else { throw posixError() }
                sent += count
            }
        }
    }

    private func readExactly(fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { throw ClientError.invalidFrame }
            var received = 0
            while received < count {
                let amount = Darwin.recv(fd, base.advanced(by: received), count - received, 0)
                guard amount > 0 else { throw amount == 0 ? ClientError.connectionClosed : posixError() }
                received += amount
            }
        }
        return data
    }

    private func posixError() -> ClientError {
        ClientError.posix(String(cString: strerror(errno)))
    }
}

private struct RPCEnvelope<Result: Decodable & Sendable>: Decodable, Sendable {
    struct RemoteError: Decodable, Sendable { let code: Int; let message: String }
    let id: String
    let result: Result?
    let error: RemoteError?
}

private enum HelloEnvelope {
    struct Result: Decodable, Sendable {
        struct ProtocolVersion: Decodable, Sendable { let major: Int; let minor: Int }
        let protocolVersion: ProtocolVersion
        let engineVersion: String
        let engineInstanceID: String
        let sessionID: String

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol"
            case engineVersion = "engine_version"
            case engineInstanceID = "engine_instance_id"
            case sessionID = "session_id"
        }
    }
}

private enum ClientError: LocalizedError {
    case frameTooLarge
    case invalidFrame
    case invalidResponse
    case connectionClosed
    case socketPathTooLong
    case remote(method: String, code: Int, message: String)
    case posix(String)

    var errorDescription: String? {
        switch self {
        case .frameTooLarge: "The engine message is too large."
        case .invalidFrame: "The engine returned an invalid IPC frame."
        case .invalidResponse: "The engine returned an invalid RPC response."
        case .connectionClosed: "The engine closed the connection."
        case .socketPathTooLong: "The engine socket path is too long for macOS."
        case .remote(let method, _, let message): "The engine rejected \(method): \(message)"
        case .posix(let message): message
        }
    }
}
