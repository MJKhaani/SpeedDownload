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

    private var isConnected: Bool {
        if case .connected = state { true } else { false }
    }

    func connect() async {
        attempt += 1
        let currentAttempt = attempt
        state = .connecting
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                let client = UnixEngineClient()
                let hello = try client.hello()
                let jobs = try client.listJobs()
                return (hello, jobs)
            }.value
            guard currentAttempt == attempt else { return }
            jobs = snapshot.1
            state = .connected(
                engineVersion: snapshot.0.engineVersion,
                instanceID: snapshot.0.engineInstanceID,
                sessionID: snapshot.0.sessionID
            )
        } catch {
            guard currentAttempt == attempt else { return }
            state = .disconnected(error.localizedDescription)
        }
    }

    func refreshJobs() async {
        guard isConnected else { return }
        do {
            jobs = try await Task.detached(priority: .utility) {
                try UnixEngineClient().listJobs()
            }.value
            actionError = nil
        } catch {
            actionError = "Could not refresh downloads: \(error.localizedDescription)"
        }
    }

    func addJob(url: String, name: String, destination: String) async -> Bool {
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
                    idempotencyKey: UUID().uuidString
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
