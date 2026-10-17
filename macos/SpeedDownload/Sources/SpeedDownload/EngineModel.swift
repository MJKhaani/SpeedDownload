import Combine
import Foundation
import UserNotifications

@MainActor
final class EngineModel: ObservableObject {
    enum State: Equatable {
        case connecting
        case connected(engineVersion: String, instanceID: String, sessionID: String)
        case disconnected(String)
    }

    @Published private(set) var state: State = .connecting
    @Published private(set) var jobs: [DownloadJob] = []
    @Published private(set) var jobBytesPerSecond: [String: UInt64] = [:]
    @Published private(set) var workerBytesPerSecond: [String: [UInt32: UInt64]] = [:]
    @Published private(set) var actionError: String?
    @Published private(set) var isSubmitting = false
    @Published private(set) var cachedSettings: EngineSettings?
    private var previousSamples: [String: (bytes: UInt64, workers: [UInt32: UInt64], time: Date)] = [:]
    private var isChangingSpeedLimit = false
    private var attempt = 0
    private var engineProcess: Process?
    private var isConnecting = false
    private var hasLoadedSnapshot = false
    private var jobCursor = "0"

    private var isConnected: Bool {
        if case .connected = state { true } else { false }
    }

    func connect() async {
        if isConnecting {
            while isConnecting && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return
        }
        isConnecting = true
        defer { isConnecting = false }
        attempt += 1
        let currentAttempt = attempt
        state = .connecting
        do {
            let snapshot = try await connectOrStartEngine()
            guard currentAttempt == attempt else { return }
            applyJobs(snapshot.1)
            jobCursor = "0"
            state = .connected(engineVersion: snapshot.0.engineVersion, instanceID: snapshot.0.engineInstanceID, sessionID: snapshot.0.sessionID)
            Task { _ = try? await self.loadSettings() }
        } catch {
            guard currentAttempt == attempt else { return }
            state = .disconnected(error.localizedDescription)
        }
    }

    func ensureConnected() async {
        if isConnected { return }
        await connect()
    }

    private func connectOrStartEngine() async throws -> (HelloResult, [DownloadJob]) {
        do { return try await loadSnapshot() } catch {
            if error as? EngineLaunchError == .outdated {
                let existingJobs = try? await Task.detached(priority: .utility) {
                    try UnixEngineClient().listJobs()
                }.value
                guard let existingJobs,
                      !existingJobs.contains(where: { ["resolving", "connecting", "downloading", "verifying"].contains($0.state) }) else {
                    throw EngineLaunchError.outdated
                }
                Self.terminateOutdatedBundledEngine()
                for _ in 0..<20 {
                    if !Self.socketIsReachable(engineSocketPath()) { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            try startEngineIfAvailable()
            var lastError = error
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(250))
                do { return try await loadSnapshot() } catch { lastError = error }
            }
            throw lastError
        }
    }

    private func loadSnapshot() async throws -> (HelloResult, [DownloadJob]) {
        try await Task.detached(priority: .userInitiated) {
            let client = UnixEngineClient()
            let hello = try client.hello()
            guard hello.supportedFeatures.contains("jobs.probe"),
                  hello.supportedFeatures.contains("jobs.worker-progress"),
                  hello.supportedFeatures.contains("jobs.probe-filename-decoding"),
                  hello.supportedFeatures.contains("jobs.change-wait"),
                  hello.supportedFeatures.contains("jobs.per-job-bandwidth"),
                  hello.supportedFeatures.contains("settings.persisted-v2"),
                  hello.supportedFeatures.contains("settings.weekly-schedules"),
                  hello.supportedFeatures.contains("torrents.magnet-v1-single-file"),
                  hello.supportedFeatures.contains("torrents.local-file-v1-single-file") else {
                throw EngineLaunchError.outdated
            }
            return (hello, try client.listJobs())
        }.value
    }

    private func startEngineIfAvailable() throws {
        if let engineProcess, engineProcess.isRunning { return }
        let candidates = engineExecutableCandidates()
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw EngineLaunchError.notInstalled
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["engine"]
        process.environment = ProcessInfo.processInfo.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        engineProcess = process
    }

    private func engineExecutableCandidates() -> [URL] {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["SPEED_DOWNLOAD_ENGINE_PATH"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let helper = Bundle.main.url(forAuxiliaryExecutable: "speed-download") { candidates.append(helper) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/speed-download"))
        var directory = Bundle.main.bundleURL
        for _ in 0..<8 {
            candidates.append(directory.appendingPathComponent("zig-out/bin/speed-download"))
            directory.deleteLastPathComponent()
        }
        return candidates
    }

    private func engineSocketPath() -> String {
        let runtime = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: runtime).appendingPathComponent("speed-download/engine.sock").path
    }

    nonisolated private static func terminateOutdatedBundledEngine() {
        let runtime = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let socketPath = URL(fileURLWithPath: runtime).appendingPathComponent("speed-download/engine.sock").path
        guard let lsof = ["/usr/sbin/lsof", "/usr/bin/lsof"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let sockets = run(lsof, ["-n", "-Fpcn", "-U"]) else { return }
        var currentPID: Int32?
        var owners: [Int32] = []
        for line in sockets.split(whereSeparator: \.isNewline) {
            if line.first == "p", let pid = Int32(line.dropFirst()) { currentPID = pid }
            if line.first == "n", String(line.dropFirst()) == socketPath, let currentPID { owners.append(currentPID) }
        }
        let currentHelper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/speed-download").standardizedFileURL.path
        let overrideHelper = ProcessInfo.processInfo.environment["SPEED_DOWNLOAD_ENGINE_PATH"]
        for pid in Set(owners) where pid != ProcessInfo.processInfo.processIdentifier {
            guard let output = run(lsof, ["-a", "-p", String(pid), "-d", "txt", "-Fn"]),
                  output.split(whereSeparator: \.isNewline).map({ String($0.dropFirst()) }).contains(where: { executable in
                      let path = executable.replacingOccurrences(of: " (deleted)", with: "")
                      return path == currentHelper || path == overrideHelper || path.hasSuffix("/Contents/Helpers/speed-download")
                  }) else { continue }
            _ = Darwin.kill(pid, SIGTERM)
        }
    }

    nonisolated private static func socketIsReachable(_ path: String) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    nonisolated private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }

    func refreshJobs() async {
        guard isConnected else { return }
        do {
            let refreshed = try await Task.detached(priority: .utility) {
                try UnixEngineClient().listJobs()
            }.value
            applyJobs(refreshed)
            actionError = nil
        } catch {
            state = .disconnected(error.localizedDescription)
        }
    }

    var totalDownloadBytesPerSecond: UInt64 {
        jobBytesPerSecond.values.reduce(0, +)
    }

    private func applyJobs(_ refreshed: [DownloadJob]) {
        if hasLoadedSnapshot {
            let oldStates = Dictionary(uniqueKeysWithValues: jobs.map { ($0.jobID, $0.state) })
            for job in refreshed where oldStates[job.jobID] != nil && oldStates[job.jobID] != job.state {
                let isComplete = job.state == "completed" && UserDefaults.standard.bool(forKey: "notifyOnCompletion")
                let isFailed = job.state == "failed" && UserDefaults.standard.bool(forKey: "notifyOnFailure")
                guard isComplete || isFailed else { continue }
                let content = UNMutableNotificationContent()
                content.title = isComplete ? "Download complete" : "Download failed"
                if let name = job.name, !name.isEmpty {
                    content.body = name
                } else {
                    content.body = URL(string: job.url)?.lastPathComponent ?? "Your download"
                }
                content.sound = .default
                let notification = UNNotificationRequest(identifier: "download-\(job.jobID)-\(job.revision)", content: content, trigger: nil)
                UNUserNotificationCenter.current().add(notification)
            }
        }
        hasLoadedSnapshot = true
        let now = Date()
        var nextSamples: [String: (bytes: UInt64, workers: [UInt32: UInt64], time: Date)] = [:]
        var nextJobRates: [String: UInt64] = [:]
        var nextWorkerRates: [String: [UInt32: UInt64]] = [:]
        for job in refreshed where job.state == "downloading" {
            let bytes = UInt64(job.receivedBytes ?? job.completedBytes ?? "0") ?? 0
            let workers = Dictionary(uniqueKeysWithValues: (job.workers ?? []).map { ($0.workerID, $0.downloaded) })
            if let previous = previousSamples[job.jobID] {
                let elapsed = now.timeIntervalSince(previous.time)
                if elapsed > 0.1 {
                    nextJobRates[job.jobID] = rate(from: previous.bytes, to: bytes, elapsed: elapsed)
                    nextWorkerRates[job.jobID] = workers.mapValues { _ in 0 }
                    for (workerID, value) in workers {
                        if let old = previous.workers[workerID] {
                            nextWorkerRates[job.jobID]?[workerID] = rate(from: old, to: value, elapsed: elapsed)
                        }
                    }
                }
            }
            nextSamples[job.jobID] = (bytes, workers, now)
        }
        previousSamples = nextSamples
        jobBytesPerSecond = nextJobRates
        workerBytesPerSecond = nextWorkerRates
        jobs = refreshed
    }

    private func rate(from old: UInt64, to new: UInt64, elapsed: TimeInterval) -> UInt64 {
        guard new >= old else { return 0 }
        return UInt64(Double(new - old) / elapsed)
    }

    func setGlobalSpeedLimit(_ bytesPerSecond: UInt64) async {
        guard !isChangingSpeedLimit else { return }
        isChangingSpeedLimit = true
        defer { isChangingSpeedLimit = false }
        do {
            var settings = try await loadSettings()
            settings.bandwidthLimitBytesPerSecond = bytesPerSecond
            _ = try await saveSettings(settings)
            actionError = nil
        } catch {
            actionError = "Could not change the download limit: \(error.localizedDescription)"
        }
    }

    func probe(url: String) async throws -> DownloadProbe {
        do {
            return try await Task.detached(priority: .utility) {
                try UnixEngineClient().probe(url: url)
            }.value
        } catch {
            guard UnixEngineClient.isEngineOutdated(error) else { throw error }
            await connect()
            guard isConnected else { throw error }
            return try await Task.detached(priority: .utility) {
                try UnixEngineClient().probe(url: url)
            }.value
        }
    }

    func loadSettings() async throws -> EngineSettings {
        if let cachedSettings { return cachedSettings }
        let loaded = try await Task.detached(priority: .utility) { try UnixEngineClient().getSettings() }.value
        cachedSettings = loaded
        return loaded
    }

    func saveSettings(_ settings: EngineSettings) async throws -> EngineSettings {
        let saved = try await Task.detached(priority: .userInitiated) { try UnixEngineClient().updateSettings(settings) }.value
        cachedSettings = saved
        return saved
    }

    func maintainConnection() async {
        if isConnected {
            let connectionAttempt = attempt
            do {
                let cursor = jobCursor
                let change = try await Task.detached(priority: .utility) {
                    try UnixEngineClient().waitForJobChange(after: cursor)
                }.value
                guard isConnected, connectionAttempt == attempt else { return }
                jobCursor = change.cursor
                if change.changed { await refreshJobs() }
            } catch {
                if connectionAttempt == attempt { state = .disconnected(error.localizedDescription) }
            }
        } else {
            await connect()
        }
    }

    func addJob(url: String, name: String, destination: String, priority: Int = 0, expectedSHA256: String? = nil) async -> Bool {
        guard !isSubmitting else { return false }
        isSubmitting = true
        actionError = nil
        defer { isSubmitting = false }
        do {
            let client = UnixEngineClient()
            _ = try await Task.detached(priority: .userInitiated) {
                try client.addJob(
                    url: url,
                    name: name,
                    destination: destination,
                    idempotencyKey: UUID().uuidString,
                    priority: priority,
                    expectedSHA256: expectedSHA256
                )
            }.value
            do {
                let refreshed = try await Task.detached(priority: .userInitiated) {
                    try client.listJobs()
                }.value
                applyJobs(refreshed)
            } catch {
                actionError = "Job saved, but the list could not be refreshed: \(error.localizedDescription)"
            }
            return true
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }

    func controlJob(_ job: DownloadJob, action: String) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        actionError = nil
        defer { isSubmitting = false }
        do {
            let client = UnixEngineClient()
            _ = try await Task.detached(priority: .userInitiated) {
                try client.controlJob(jobID: job.jobID, action: action, expectedRevision: job.revision)
            }.value
            let refreshed = try await Task.detached(priority: .userInitiated) {
                try client.listJobs()
            }.value
            applyJobs(refreshed)
        } catch {
            if UnixEngineClient.isRevisionConflict(error) {
                do {
                    let refreshed = try await Task.detached(priority: .userInitiated) {
                        try UnixEngineClient().listJobs()
                    }.value
                    applyJobs(refreshed)
                    actionError = "This job changed elsewhere. The list has been refreshed; review its current state before trying again."
                } catch {
                    actionError = error.localizedDescription
                }
            } else {
                actionError = error.localizedDescription
            }
        }
    }

    func setJobSpeedLimit(_ job: DownloadJob, bytesPerSecond: UInt64) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        actionError = nil
        defer { isSubmitting = false }
        do {
            let client = UnixEngineClient()
            try await Task.detached(priority: .userInitiated) {
                try client.setJobBandwidthLimit(jobID: job.jobID, expectedRevision: job.revision, bytesPerSecond: bytesPerSecond)
            }.value
            let refreshed = try await Task.detached(priority: .userInitiated) { try client.listJobs() }.value
            applyJobs(refreshed)
        } catch {
            actionError = error.localizedDescription
            await refreshJobs()
        }
    }

    func deleteJob(_ job: DownloadJob, deletePartial: Bool = false) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        actionError = nil
        defer { isSubmitting = false }
        do {
            try await Task.detached(priority: .userInitiated) {
                try UnixEngineClient().deleteJob(jobID: job.jobID, expectedRevision: job.revision, deletePartial: deletePartial)
            }.value
            let refreshed = try await Task.detached(priority: .userInitiated) {
                try UnixEngineClient().listJobs()
            }.value
            applyJobs(refreshed)
        } catch {
            actionError = error.localizedDescription
            await refreshJobs()
        }
    }
}

private enum EngineLaunchError: LocalizedError, Equatable {
    case notInstalled
    case outdated
    var errorDescription: String? {
        switch self {
        case .notInstalled: "The Speed Download engine was not found in this app or at SPEED_DOWNLOAD_ENGINE_PATH."
        case .outdated: "The running Speed Download engine is outdated. Let active downloads finish, then restart the engine."
        }
    }
}
