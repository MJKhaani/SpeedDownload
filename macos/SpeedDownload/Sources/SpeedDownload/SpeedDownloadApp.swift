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
        WindowGroup {
            DashboardView()
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .environmentObject(engine)
                .frame(minWidth: 820, minHeight: 560)
                .task {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    engine.startConnectionLoop()
                }
        }
        .defaultSize(width: 1040, height: 700)
        .handlesExternalEvents(matching: ["*"])
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != currentPID }) {
            existing.activate(options: [.activateAllWindows])
            DispatchQueue.main.async { NSApp.terminate(nil) }
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

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
}
