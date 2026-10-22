import Darwin
import Foundation

struct HelloResult: Sendable {
    let engineVersion: String
    let engineInstanceID: String
    let sessionID: String
    let supportedFeatures: [String]
}

struct DownloadJob: Decodable, Identifiable, Sendable, Equatable {
    let jobID: String
    let url: String
    let name: String?
    let destination: String
    let state: String
    let revision: String
    let errorMessage: String?
    let retryAttempts: Int?
    let retryAtUnixMS: String?
    let completedBytes: String?
    let receivedBytes: String?
    let totalBytes: String?
    let requestedControl: String?
    let priority: Int?
    let bandwidthLimitBytesPerSecond: UInt64?
    let expectedSHA256: String?
    let workers: [DownloadWorker]?
    let torrentPeerCount: UInt32?
    let torrentSeederCount: UInt32?
    let torrentLeecherCount: UInt32?

    var id: String { jobID }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case url, name, destination, state, revision
        case errorMessage = "error_message"
        case retryAttempts = "retry_attempts"
        case retryAtUnixMS = "retry_at_unix_ms"
        case completedBytes = "completed_bytes"
        case receivedBytes = "received_bytes"
        case totalBytes = "total_bytes"
        case requestedControl = "requested_control"
        case priority
        case bandwidthLimitBytesPerSecond = "bandwidth_limit_bytes_per_second"
        case expectedSHA256 = "expected_sha256"
        case workers
        case torrentPeerCount = "torrent_peer_count"
        case torrentSeederCount = "torrent_seeder_count"
        case torrentLeecherCount = "torrent_leecher_count"
    }
}

struct DownloadWorker: Decodable, Sendable, Equatable, Identifiable {
    let workerID: UInt32
    let start: UInt64
    let end: UInt64
    let downloaded: UInt64

    var id: UInt32 { workerID }

    enum CodingKeys: String, CodingKey {
        case workerID = "worker_id"
        case start, end, downloaded
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

struct JobChangeResult: Decodable, Sendable {
    let cursor: String
    let changed: Bool
}

struct JobSubscriptionEvent: Decodable, Sendable {
    let subscriptionID: String
    let engineInstanceID: String
    let seq: String
    let cursor: String
    let resyncRequired: Bool
    let jobs: [DownloadJob]?

    enum CodingKeys: String, CodingKey {
        case subscriptionID = "subscription_id"
        case engineInstanceID = "engine_instance_id"
        case seq, cursor
        case resyncRequired = "resync_required"
        case jobs
    }
}

/// Owns one authenticated connection. EngineModel gives it a single reader.
final class JobSubscription: @unchecked Sendable {
    private let fd: Int32
    let id: String
    let engineInstanceID: String
    private var lastSequence: UInt64 = 0

    init(fd: Int32, id: String, engineInstanceID: String) {
        self.fd = fd
        self.id = id
        self.engineInstanceID = engineInstanceID
    }

    deinit { Darwin.close(fd) }

    func nextEvent() throws -> JobSubscriptionEvent? {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = Darwin.poll(&descriptor, 1, 5_000)
        guard ready >= 0 else { throw ClientError.posix(String(cString: strerror(errno))) }
        if ready == 0 { return nil }
        let data = try UnixEngineClient.readFrame(fd: fd)
        let notice = try JSONDecoder().decode(SubscriptionNotification.self, from: data)
        guard notice.method == "events.changed",
              notice.params.subscriptionID == id,
              notice.params.engineInstanceID == engineInstanceID,
              let sequence = UInt64(notice.params.seq), sequence == lastSequence + 1 else {
            throw ClientError.invalidResponse
        }
        lastSequence = sequence
        return notice.params
    }
}

private struct SubscriptionNotification: Decodable {
    let method: String
    let params: JobSubscriptionEvent
}

private struct JobSubscriptionResult: Decodable, Sendable {
    let subscriptionID: String
    let engineInstanceID: String

    enum CodingKeys: String, CodingKey {
        case subscriptionID = "subscription_id"
        case engineInstanceID = "engine_instance_id"
    }
}

struct DownloadProbe: Decodable, Sendable {
    struct TorrentFile: Decodable, Sendable {
        let path: String
        let length: String
    }
    let finalURL: String
    let suggestedName: String
    let totalBytes: String?
    let statusCode: Int
    let httpVersion: String
    let contentType: String?
    let rangeSupported: Bool
    let resumeSupported: Bool
    let multipartSupported: Bool
    let message: String
    let torrentFileCount: Int?
    let torrentFiles: [TorrentFile]?
    let torrentInfoHash: String?

    enum CodingKeys: String, CodingKey {
        case finalURL = "final_url"
        case suggestedName = "suggested_name"
        case totalBytes = "total_bytes"
        case statusCode = "status_code"
        case httpVersion = "http_version"
        case contentType = "content_type"
        case rangeSupported = "range_supported"
        case resumeSupported = "resume_supported"
        case multipartSupported = "multipart_supported"
        case message
        case torrentFileCount = "torrent_file_count"
        case torrentFiles = "torrent_files"
        case torrentInfoHash = "torrent_info_hash"
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

private struct SetJobBandwidthResult: Decodable, Sendable {
    let jobID: String
    let revision: String
    let bandwidthLimitBytesPerSecond: UInt64

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case revision
        case bandwidthLimitBytesPerSecond = "bandwidth_limit_bytes_per_second"
    }
}

private struct DeleteJobResult: Decodable, Sendable {
    let deleted: Bool
}

struct EngineSettings: Codable, Sendable, Equatable {
    var schemaVersion = 2
    var maxConcurrentTasks = 4
    var defaultConnectionsPerTask = 4
    var multipartMode: String? = nil
    var defaultDownloadFolder = ""
    var proxyMode = "system"
    var proxyURL: String?
    var proxyAuthenticationRequired = false
    var bandwidthLimitBytesPerSecond: UInt64 = 0
    var queueScheduleEnabled = false
    var queueScheduleSlots: [Bool] = Array(repeating: true, count: 168)
    var bandwidthScheduleEnabled = false
    var scheduledBandwidthLimitBytesPerSecond: UInt64 = 0
    var bandwidthScheduleSlots: [BandwidthScheduleMode] = Array(repeating: .globalLimit, count: 168)
    var debugLogEnabled = false

    init() {}

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try fields.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
        maxConcurrentTasks = try fields.decodeIfPresent(Int.self, forKey: .maxConcurrentTasks) ?? 4
        defaultConnectionsPerTask = try fields.decodeIfPresent(Int.self, forKey: .defaultConnectionsPerTask) ?? 4
        multipartMode = try fields.decodeIfPresent(String.self, forKey: .multipartMode)
        defaultDownloadFolder = try fields.decodeIfPresent(String.self, forKey: .defaultDownloadFolder) ?? ""
        proxyMode = try fields.decodeIfPresent(String.self, forKey: .proxyMode) ?? "system"
        proxyURL = try fields.decodeIfPresent(String.self, forKey: .proxyURL)
        proxyAuthenticationRequired = try fields.decodeIfPresent(Bool.self, forKey: .proxyAuthenticationRequired) ?? false
        bandwidthLimitBytesPerSecond = try fields.decodeIfPresent(UInt64.self, forKey: .bandwidthLimitBytesPerSecond) ?? 0
        queueScheduleEnabled = try fields.decodeIfPresent(Bool.self, forKey: .queueScheduleEnabled) ?? false
        queueScheduleSlots = try fields.decodeIfPresent([Bool].self, forKey: .queueScheduleSlots) ?? Array(repeating: true, count: 168)
        bandwidthScheduleEnabled = try fields.decodeIfPresent(Bool.self, forKey: .bandwidthScheduleEnabled) ?? false
        scheduledBandwidthLimitBytesPerSecond = try fields.decodeIfPresent(UInt64.self, forKey: .scheduledBandwidthLimitBytesPerSecond) ?? 0
        bandwidthScheduleSlots = try fields.decodeIfPresent([BandwidthScheduleMode].self, forKey: .bandwidthScheduleSlots) ?? Array(repeating: .globalLimit, count: 168)
        debugLogEnabled = try fields.decodeIfPresent(Bool.self, forKey: .debugLogEnabled) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case maxConcurrentTasks = "max_concurrent_tasks"
        case defaultConnectionsPerTask = "default_connections_per_task"
        case multipartMode = "multipart_mode"
        case defaultDownloadFolder = "default_download_folder"
        case proxyMode = "proxy_mode"
        case proxyURL = "proxy_url"
        case proxyAuthenticationRequired = "proxy_authentication_required"
        case bandwidthLimitBytesPerSecond = "bandwidth_limit_bytes_per_second"
        case queueScheduleEnabled = "queue_schedule_enabled"
        case queueScheduleSlots = "queue_schedule_slots"
        case bandwidthScheduleEnabled = "bandwidth_schedule_enabled"
        case scheduledBandwidthLimitBytesPerSecond = "scheduled_bandwidth_limit_bytes_per_second"
        case bandwidthScheduleSlots = "bandwidth_schedule_slots"
        case debugLogEnabled = "debug_log_enabled"
    }
}

enum BandwidthScheduleMode: String, Codable, Sendable {
    case globalLimit = "global_limit"
    case limited
}

struct UnixEngineClient: Sendable {
    private let maxFrameSize = 1_048_576

    // Hello returns the intersection of requested and supported capabilities.
    // Keep connection requirements and the handshake request in sync.
    static let requiredFeatures = [
        "jobs.probe", "jobs.worker-progress", "jobs.probe-filename-decoding",
        "jobs.change-wait", "jobs.per-job-bandwidth", "settings.persisted-v2",
        "settings.weekly-schedules", "torrents.magnet-v1-single-file",
        "torrents.local-file-v1-single-file",
    ]
    private static let requestedFeatures = requiredFeatures + [
        "jobs.change-stream-v1", "torrents.file-selection-v1",
    ]

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
            let envelope: RPCEnvelope<JobListResult> = try request(
                fd: fd,
                id: "jobs-list-\(UUID().uuidString)",
                method: "jobs.list",
                params: ["offset": offset, "limit": 50]
            )
            guard let response = envelope.result else { throw ClientError.invalidResponse }
            jobs.append(contentsOf: response.jobs)
            guard let nextOffset = response.nextOffset else { return jobs }
            guard let next = Int(nextOffset), next > offset else { throw ClientError.invalidResponse }
            offset = next
        }
    }

    func waitForJobChange(after cursor: String) throws -> JobChangeResult {
        let fd = try openConnection()
        defer { Darwin.close(fd) }
        let hello = try negotiate(fd: fd)
        guard hello.supportedFeatures.contains("jobs.change-wait") else { throw ClientError.engineOutdated }
        let envelope: RPCEnvelope<JobChangeResult> = try request(
            fd: fd,
            id: "jobs-wait-\(UUID().uuidString)",
            method: "jobs.wait",
            params: ["cursor": cursor]
        )
        guard let result = envelope.result else { throw ClientError.invalidResponse }
        return result
    }

    func subscribeToJobs() throws -> JobSubscription {
        let fd = try openConnection()
        do {
            let hello = try negotiate(fd: fd)
            guard hello.supportedFeatures.contains("jobs.change-stream-v1") else { throw ClientError.engineOutdated }
            let envelope: RPCEnvelope<JobSubscriptionResult> = try request(
                fd: fd,
                id: "jobs-subscribe-\(UUID().uuidString)",
                method: "jobs.subscribe",
                params: ["max_updates_per_second": 5]
            )
            guard let result = envelope.result, result.engineInstanceID == hello.engineInstanceID else {
                throw ClientError.invalidResponse
            }
            return JobSubscription(fd: fd, id: result.subscriptionID, engineInstanceID: result.engineInstanceID)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    func addJob(url: String, name: String?, destination: String, idempotencyKey: String, priority: Int = 0, expectedSHA256: String? = nil, selectedTorrentFiles: [String]? = nil, torrentInfoHash: String? = nil) throws -> AddJobResult {
        let fd = try openConnection()
        defer { Darwin.close(fd) }
        let hello = try negotiate(fd: fd)
        if selectedTorrentFiles != nil && !hello.supportedFeatures.contains("torrents.file-selection-v1") {
            throw ClientError.engineOutdated
        }
        var params: [String: Any] = [
            "url": url,
            "destination": destination,
            "idempotency_key": idempotencyKey,
            "priority": priority,
        ]
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["name"] = name
        }
        if let expectedSHA256 { params["expected_sha256"] = expectedSHA256 }
        if let selectedTorrentFiles { params["selected_torrent_files"] = selectedTorrentFiles }
        if let torrentInfoHash { params["torrent_info_hash"] = torrentInfoHash }
        let envelope: RPCEnvelope<AddJobResult> = try request(
            fd: fd,
            id: "jobs-add-\(UUID().uuidString)",
            method: "jobs.add",
            params: params
        )
        guard let result = envelope.result else { throw ClientError.invalidResponse }
        return result
    }

    func probe(url: String) throws -> DownloadProbe {
        let fd = try openConnection()
        defer { Darwin.close(fd) }
        let hello = try negotiate(fd: fd)
        guard hello.supportedFeatures.contains("jobs.probe"),
              hello.supportedFeatures.contains("jobs.worker-progress"),
              hello.supportedFeatures.contains("jobs.probe-filename-decoding") else { throw ClientError.engineOutdated }
        let envelope: RPCEnvelope<DownloadProbe> = try request(
            fd: fd,
            id: "jobs-probe-\(UUID().uuidString)",
            method: "jobs.probe",
            params: ["url": url]
        )
        guard let result = envelope.result else { throw ClientError.invalidResponse }
        return result
    }

    func getSettings() throws -> EngineSettings {
        let fd = try openConnection(); defer { Darwin.close(fd) }
        _ = try negotiate(fd: fd)
        let envelope: RPCEnvelope<EngineSettings> = try request(fd: fd, id: "settings-get-\(UUID().uuidString)", method: "settings.get", params: [:])
        guard let result = envelope.result else { throw ClientError.invalidResponse }
        return result
    }

    func updateSettings(_ settings: EngineSettings) throws -> EngineSettings {
        let fd = try openConnection(); defer { Darwin.close(fd) }
        _ = try negotiate(fd: fd)
        let encoded = try JSONEncoder().encode(settings)
        let object = try JSONSerialization.jsonObject(with: encoded)
        let envelope: RPCEnvelope<EngineSettings> = try request(fd: fd, id: "settings-update-\(UUID().uuidString)", method: "settings.update", params: ["settings": object])
        guard let result = envelope.result else { throw ClientError.invalidResponse }
        return result
    }

    func controlJob(jobID: String, action: String, expectedRevision: String) throws -> AddJobResult {
        let fd = try openConnection()
        defer { Darwin.close(fd) }
        _ = try negotiate(fd: fd)
        let envelope: RPCEnvelope<AddJobResult> = try request(
            fd: fd,
            id: "jobs-control-\(UUID().uuidString)",
            method: "jobs.control",
            params: ["job_id": jobID, "action": action, "expected_revision": expectedRevision]
        )
        guard let result = envelope.result else { throw ClientError.invalidResponse }
        return result
    }

    func setJobBandwidthLimit(jobID: String, expectedRevision: String, bytesPerSecond: UInt64) throws {
        let fd = try openConnection()
        defer { Darwin.close(fd) }
        let hello = try negotiate(fd: fd)
        guard hello.supportedFeatures.contains("jobs.per-job-bandwidth") else { throw ClientError.engineOutdated }
        let envelope: RPCEnvelope<SetJobBandwidthResult> = try request(
            fd: fd,
            id: "jobs-bandwidth-\(UUID().uuidString)",
            method: "jobs.set-bandwidth",
            params: [
                "job_id": jobID,
                "expected_revision": expectedRevision,
                "bandwidth_limit_bytes_per_second": bytesPerSecond,
            ]
        )
        guard envelope.result != nil else { throw ClientError.invalidResponse }
    }

    func deleteJob(jobID: String, expectedRevision: String, deletePartial: Bool = false) throws {
        let fd = try openConnection()
        defer { Darwin.close(fd) }
        _ = try negotiate(fd: fd)
        let envelope: RPCEnvelope<DeleteJobResult> = try request(
            fd: fd,
            id: "jobs-delete-\(UUID().uuidString)",
            method: "jobs.delete",
            params: ["job_id": jobID, "expected_revision": expectedRevision, "delete_partial": deletePartial]
        )
        guard envelope.result?.deleted == true else { throw ClientError.invalidResponse }
    }

    static func isRevisionConflict(_ error: Error) -> Bool {
        guard case ClientError.remote(_, let code, _) = error else { return false }
        return code == -32015
    }

    static func isEngineOutdated(_ error: Error) -> Bool {
        guard case ClientError.engineOutdated = error else { return false }
        return true
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
                "features": Self.requestedFeatures,
            ]
        )
        guard let result = envelope.result else { throw ClientError.invalidResponse }
        return HelloResult(
            engineVersion: result.engineVersion,
            engineInstanceID: result.engineInstanceID,
            sessionID: result.sessionID,
            supportedFeatures: result.features
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

    fileprivate static func readFrame(fd: Int32) throws -> Data {
        let client = UnixEngineClient()
        let header = try client.readExactly(fd: fd, count: 4)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard length > 0, Int(length) <= client.maxFrameSize else { throw ClientError.invalidFrame }
        return try client.readExactly(fd: fd, count: Int(length))
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
        let features: [String]

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol"
            case engineVersion = "engine_version"
            case engineInstanceID = "engine_instance_id"
            case sessionID = "session_id"
            case features
        }
    }
}

private enum ClientError: LocalizedError {
    case frameTooLarge
    case invalidFrame
    case invalidResponse
    case connectionClosed
    case socketPathTooLong
    case engineOutdated
    case remote(method: String, code: Int, message: String)
    case posix(String)

    var errorDescription: String? {
        switch self {
        case .frameTooLarge: "The engine message is too large."
        case .invalidFrame: "The engine returned an invalid IPC frame."
        case .invalidResponse: "The engine returned an invalid RPC response."
        case .connectionClosed: "The engine closed the connection."
        case .socketPathTooLong: "The engine socket path is too long for macOS."
        case .engineOutdated: "The running engine is outdated and does not support link inspection. Quit its previous process and reopen Speed Download."
        case .remote(let method, _, let message): "The engine rejected \(method): \(message)"
        case .posix(let message): message
        }
    }
}
