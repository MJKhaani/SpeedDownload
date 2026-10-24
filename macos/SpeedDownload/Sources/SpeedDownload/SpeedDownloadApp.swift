import Darwin
import AppKit
import SwiftUI

extension Notification.Name {
    static let speedDownloadNewTransfer = Notification.Name("SpeedDownload.NewTransfer")
    static let speedDownloadClipboardTransfer = Notification.Name("SpeedDownload.ClipboardTransfer")
}

@main
struct SpeedDownloadApp: App {
    @StateObject private var engine = EngineModel()
    @NSApplicationDelegateAdaptor(SpeedDownloadAppDelegate.self) private var appDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Speed Download", id: "main") {
            DashboardView()
                .background(MainWindowActivation { appDelegate.openMainWindow = $0 })
                .environmentObject(engine)
                .frame(minWidth: 820, minHeight: 560)
                .task {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    engine.startConnectionLoop()
                }
        }
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Download…") {
                    NotificationCenter.default.post(name: .speedDownloadNewTransfer, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Add Download from Clipboard") {
                    guard let value = NSPasteboard.general.string(forType: .string),
                          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    NotificationCenter.default.post(name: .speedDownloadClipboardTransfer, object: value)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandGroup(after: .appInfo) {
                SettingsLink {
                    Text("Settings…")
                }
                .keyboardShortcut(",", modifiers: .command)
                Button("Reconnect to Engine") {
                    Task { await engine.connect() }
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
            }
        }

        Settings {
            PreferencesView()
                .environmentObject(engine)
        }
    }
}

@MainActor
private final class SpeedDownloadAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var instanceLock: Int32 = -1
    var openMainWindow: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Speed Download")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            instanceLock = Darwin.open(directory.appendingPathComponent("client.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard instanceLock >= 0, flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else {
                NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                    .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?
                    .activate(options: [.activateAllWindows])
                NSApp.terminate(nil)
                return
            }
        } catch {
            NSApp.terminate(nil)
            return
        }

    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let logoURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/logo.png")
            button.image = NSImage(contentsOf: logoURL)
            button.image?.size = NSSize(width: 18, height: 18)
            button.image?.isTemplate = false
            button.toolTip = "Speed Download"
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Speed Download", action: #selector(showMainWindow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Speed Download", action: #selector(quitApp), keyEquivalent: "q"))
        for menuItem in menu.items { menuItem.target = self }
        item.menu = menu
        statusItem = item
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { ClientOpenRequests.shared.append(url) }
        showMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openMainWindow?()
        if let window = NSApp.windows.first(where: { $0.title == "Speed Download" }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
}

/// Retains cold-launch URL events until the one dashboard is ready.
@MainActor
final class ClientOpenRequests: ObservableObject {
    static let shared = ClientOpenRequests()
    @Published private(set) var urls: [URL] = []
    func append(_ url: URL) {
        guard urls.count < 100 else { return }
        urls.append(url)
    }
    func take() -> [URL] {
        let result = urls
        if !result.isEmpty { urls = [] }
        return result
    }
}

private struct MainWindowActivation: View {
    @Environment(\.openWindow) private var openWindow
    let register: (@escaping () -> Void) -> Void
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear { register { openWindow(id: "main") } }
    }
}
