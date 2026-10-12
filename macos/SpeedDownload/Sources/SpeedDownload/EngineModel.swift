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
    private var attempt = 0

    func connect() async {
        attempt += 1
        let currentAttempt = attempt
        state = .connecting
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try UnixEngineClient().hello()
            }.value
            guard currentAttempt == attempt else { return }
            state = .connected(
                engineVersion: result.engineVersion,
                instanceID: result.engineInstanceID,
                sessionID: result.sessionID
            )
        } catch {
            guard currentAttempt == attempt else { return }
            state = .disconnected(error.localizedDescription)
        }
    }
}
