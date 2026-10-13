import Combine
import Foundation

@MainActor
final class EngineModel: ObservableObject {
    enum State: Equatable {
        case connecting
        case connected(engineVersion: String, instanceID: String, sessionID: String)
        case disconnected(String)
    }

    @Published private(set) var state: State = .connecting
    @Published private(set) var jobs: [DownloadJob] = []
    @Published private(set) var actionError: String?
    @Published private(set) var isSubmitting = false
    private var attempt = 0
    private var engineProcess: Process?

    private var isConnected: Bool {
        if case .connected = state { true } else { false }
    }

    func connect() async {
        attempt += 1
        let currentAttempt = attempt
        state = .connecting
        do {
            let snapshot = try await connectOrStartEngine()
            guard currentAttempt == attempt else { return }
            jobs = snapshot.1
            state = .connected(engineVersion: snapshot.0.engineVersion, instanceID: snapshot.0.engineInstanceID, sessionID: snapshot.0.sessionID)
        } catch {
            guard currentAttempt == attempt else { return }
            state = .disconnected(error.localizedDescription)
        }
    }

    private func connectOrStartEngine() async throws -> (HelloResult, [DownloadJob]) {
        do { return try await loadSnapshot() } catch {
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

    func refreshJobs() async {
        guard isConnected else { return }
        do {
            jobs = try await Task.detached(priority: .utility) {
                try UnixEngineClient().listJobs()
            }.value
            actionError = nil
        } catch {
            state = .disconnected(error.localizedDescription)
        }
    }

    func maintainConnection() async {
        if isConnected {
            await refreshJobs()
        } else {
            await connect()
        }
    }

    func addJob(url: String, name: String, destination: String, priority: Int = 0) async -> Bool {
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
                    priority: priority
                )
            }.value
            do {
                let refreshed = try await Task.detached(priority: .userInitiated) {
                    try client.listJobs()
                }.value
                jobs = refreshed
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
            jobs = try await Task.detached(priority: .userInitiated) {
                try client.listJobs()
            }.value
        } catch {
            if UnixEngineClient.isRevisionConflict(error) {
                do {
                    jobs = try await Task.detached(priority: .userInitiated) {
                        try UnixEngineClient().listJobs()
                    }.value
                    actionError = "This job changed elsewhere. The list has been refreshed; review its current state before trying again."
                } catch {
                    actionError = error.localizedDescription
                }
            } else {
                actionError = error.localizedDescription
            }
        }
    }
}

private enum EngineLaunchError: LocalizedError {
    case notInstalled
    var errorDescription: String? { "The Speed Download engine was not found in this app or at SPEED_DOWNLOAD_ENGINE_PATH." }
}
