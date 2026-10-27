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
        if let controlDirectory = ProcessInfo.processInfo.environment["SPEED_DOWNLOAD_TEST_CONTROL_DIR"] {
            let root = URL(fileURLWithPath: controlDirectory, isDirectory: true)
            let ready = root.appendingPathComponent("client-ready")
            let restarted = root.appendingPathComponent("engine-restarted")
            guard FileManager.default.createFile(atPath: ready.path, contents: Data()) else {
                fatalError("Could not signal the engine restart fixture")
            }
            let deadline = Date().addingTimeInterval(20)
            while !FileManager.default.fileExists(atPath: restarted.path) && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard FileManager.default.fileExists(atPath: restarted.path) else {
                fatalError("The fixture did not restart the engine")
            }
            await model.connect()
            guard case .connected(_, let newInstance, _) = model.state,
                  newInstance != initialInstance else {
                fatalError("GUI did not attach to the restarted engine: \(model.state)")
            }
        }
        model.startConnectionLoop()
        model.startConnectionLoop()
        for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(20)) }
        guard case .connected = model.state else {
            fatalError("Multiple window startup lost the connection: \(model.state)")
        }
        print("PASS: GUI connects, reconnects after engine restart, and shares one responsive connection loop across windows")
    }
}
