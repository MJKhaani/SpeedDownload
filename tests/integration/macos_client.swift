// Compile with UnixEngineClient.swift and EngineModel.swift, then run against a
// disposable engine (TMPDIR and SPEED_DOWNLOAD_STATE_DIR must point at its data).
import Foundation

@main
struct MacOSClientConnectionRegression {
    @MainActor
    static func main() async {
        let model = EngineModel()
        await model.connect()
        guard case .connected(_, let initialInstance, _) = model.state else {
            fatalError("GUI could not connect to the current engine: \(model.state)")
        }
        await model.connect()
        guard case .connected(_, let reconnectedInstance, _) = model.state,
              initialInstance == reconnectedInstance else {
            fatalError("GUI restarted a compatible engine during reconnection: \(model.state)")
        }
        model.startConnectionLoop()
        model.startConnectionLoop()
        for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(20)) }
        guard case .connected = model.state else {
            fatalError("Multiple window startup lost the connection: \(model.state)")
        }
        print("PASS: GUI connects, reconnects, and shares one responsive connection loop across windows")
    }
}
