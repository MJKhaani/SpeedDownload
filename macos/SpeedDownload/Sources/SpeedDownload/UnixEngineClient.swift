import Darwin
import Foundation

struct HelloResult: Sendable {
    let engineVersion: String
    let engineInstanceID: String
    let sessionID: String
}

struct UnixEngineClient: Sendable {
    private let maxFrameSize = 1_048_576

    func hello() throws -> HelloResult {
        let runtime = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let socketPath = URL(fileURLWithPath: runtime)
            .appendingPathComponent("speed-download", isDirectory: true)
            .appendingPathComponent("engine.sock")
            .path
        let fd = try connect(path: socketPath)
        defer { Darwin.close(fd) }

        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) {
            Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "hello-1",
            "method": "engine.hello",
            "params": [
                "protocol": ["major": 1, "minor": 0],
                "client": ["kind": "macos-gui", "version": "0.1.0"],
                "features": [],
            ],
        ]
        let payload = try JSONSerialization.data(withJSONObject: request)
        guard !payload.isEmpty, payload.count <= maxFrameSize else { throw ClientError.frameTooLarge }
        var frame = UInt32(payload.count).littleEndian
        var output = Data(bytes: &frame, count: MemoryLayout<UInt32>.size)
        output.append(payload)
        try writeAll(fd: fd, data: output)

        let header = try readExactly(fd: fd, count: 4)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard length > 0, length <= maxFrameSize else { throw ClientError.invalidFrame }
        let responseData = try readExactly(fd: fd, count: Int(length))
        let envelope = try JSONDecoder().decode(HelloEnvelope.self, from: responseData)
        if let error = envelope.error { throw ClientError.remote(error.message) }
        guard envelope.id == .string("hello-1"), let result = envelope.result else {
            throw ClientError.invalidResponse
        }
        return HelloResult(
            engineVersion: result.engineVersion,
            engineInstanceID: result.engineInstanceID,
            sessionID: result.sessionID
        )
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

private struct HelloEnvelope: Decodable {
    struct RemoteError: Decodable { let message: String }
    struct Result: Decodable {
        struct ProtocolVersion: Decodable { let major: Int; let minor: Int }
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

    let id: String
    let result: Result?
    let error: RemoteError?
}

private enum ClientError: LocalizedError {
    case frameTooLarge
    case invalidFrame
    case invalidResponse
    case connectionClosed
    case socketPathTooLong
    case remote(String)
    case posix(String)

    var errorDescription: String? {
        switch self {
        case .frameTooLarge: "The engine message is too large."
        case .invalidFrame: "The engine returned an invalid IPC frame."
        case .invalidResponse: "The engine returned an invalid handshake response."
        case .connectionClosed: "The engine closed the connection."
        case .socketPathTooLong: "The engine socket path is too long for macOS."
        case .remote(let message): "The engine rejected the handshake: \(message)"
        case .posix(let message): message
        }
    }
}
