import SwiftUI

@main
struct SpeedDownloadApp: App {
    @StateObject private var engine = EngineModel()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(engine)
                .frame(minWidth: 820, minHeight: 560)
                .task {
                    await engine.connect()
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { break }
                        await engine.maintainConnection()
                    }
                }
        }
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Reconnect to Engine") {
                    Task { await engine.connect() }
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
            }
        }
    }
}
