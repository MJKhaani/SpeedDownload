import AppKit
import Security
import ServiceManagement
import SwiftUI
import UserNotifications

private enum PreferencesPane: String, CaseIterable, Identifiable {
    case general = "General"
    case downloads = "Downloads"
    case connections = "Connections"
    case proxy = "Proxy"
    case bandwidth = "Bandwidth"
    case schedule = "Scheduler"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .downloads: "arrow.down.circle"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .proxy: "network"
        case .bandwidth: "speedometer"
        case .schedule: "calendar"
        }
    }
}

struct PreferencesView: View {
    @EnvironmentObject private var engine: EngineModel
    @AppStorage("notifyOnCompletion") private var notifyOnCompletion = false
    @AppStorage("notifyOnFailure") private var notifyOnFailure = false
    @State private var launchAtLogin = false
    @State private var selectedPane: PreferencesPane? = .general
    @State private var settings = EngineSettings()
    @State private var lastPersistedSettings: EngineSettings?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var proxyType = "http"
    @State private var proxyHost = ""
    @State private var proxyPort = ""
    @State private var proxyUsesAuthentication = false
    @State private var proxyUsername = ""
    @State private var proxyPassword = ""
    @State private var pendingSave: Task<Void, Never>?
    @State private var pendingCredentialSave: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedPane) {
                ForEach(PreferencesPane.allCases) { pane in
                    Group {
                        if selectedPane == pane {
                            paneContent(pane)
                        } else {
                            Color.clear
                        }
                    }
                        .tabItem { Label(pane.rawValue, systemImage: pane.symbol) }
                        .tag(Optional(pane))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if isLoading {
                Text("Loading preferences…")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 10)
            } else if isSaving {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Saving Preferences…")
                }
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 18).padding(.vertical, 8)
            } else if let statusMessage {
                Text(statusMessage)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 18).padding(.vertical, 8)
            }
        }
        .frame(width: 650, height: paneHeight)
        .background(PreferencesWindowSizer(pane: selectedPane, contentHeight: paneHeight))
        .task {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            await engine.ensureConnected()
            await load()
        }
        .onChange(of: settings) { _, value in
            scheduleSave(value)
        }
        .onChange(of: notifyOnCompletion) { _, enabled in
            guard enabled else { return }
            Task {
                let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
                if !granted { notifyOnCompletion = false }
            }
        }
        .onChange(of: notifyOnFailure) { _, enabled in
            guard enabled else { return }
            Task {
                let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
                if !granted { notifyOnFailure = false }
            }
        }
        .onChange(of: launchAtLogin) { _, enabled in
            guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
                errorMessage = "Could not change Login Items: \(error.localizedDescription)"
            }
        }
        .onChange(of: settings.proxyMode) { _, _ in updateProxyEndpoint() }
        .onChange(of: proxyType) { _, _ in updateProxyEndpoint() }
        .onChange(of: proxyHost) { _, _ in updateProxyEndpoint() }
        .onChange(of: proxyPort) { _, _ in updateProxyEndpoint() }
        .onChange(of: proxyUsesAuthentication) { _, enabled in
            settings.proxyAuthenticationRequired = enabled
            saveProxyCredentials()
        }
        .onChange(of: proxyUsername) { _, _ in saveProxyCredentials() }
        .onChange(of: proxyPassword) { _, _ in saveProxyCredentials() }
        .onDisappear {
            pendingSave?.cancel()
            pendingCredentialSave?.cancel()
        }
        .disabled(isLoading)
    }

    @ViewBuilder private func paneContent(_ pane: PreferencesPane) -> some View {
        switch pane {
        case .general: generalPane
        case .downloads: downloadsPane
        case .connections: connectionsPane
        case .proxy: proxyPane
        case .bandwidth: bandwidthPane
        case .schedule: schedulerPane
        }
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Queue") {
                VStack(alignment: .leading, spacing: 8) {
                    Stepper(value: $settings.maxConcurrentTasks, in: 1...32) {
                        LabeledContent("Maximum simultaneous downloads", value: "\(settings.maxConcurrentTasks)")
                    }
                    Text("Controls how many downloads can run at the same time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Diagnostics") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Enable engine debug log", isOn: $settings.debugLogEnabled)
                    Text("Records engine actions and errors in engine-debug.log in your Speed Download Application Support folder. URLs and credentials are omitted.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Notifications") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Notify when a download completes", isOn: $notifyOnCompletion)
                    Toggle("Notify when a download fails", isOn: $notifyOnFailure)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Startup") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Open Speed Download at login", isOn: $launchAtLogin)
                    Text("macOS manages this in System Settings → General → Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .preferencesPanePadding()
    }

    private var downloadsPane: some View {
        GroupBox("Save downloads to") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Default location") {
                    HStack {
                        Text(settings.defaultDownloadFolder.isEmpty ? "Downloads folder not set" : settings.defaultDownloadFolder)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            .foregroundStyle(settings.defaultDownloadFolder.isEmpty ? .secondary : .primary)
                        Spacer(minLength: 8)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Text("New downloads use this folder unless you choose a different location.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .preferencesPanePadding()
    }

    private var connectionsPane: some View {
        GroupBox("Per-download connections") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Parallel downloading", selection: Binding(
                    get: { settings.multipartMode ?? "auto" },
                    set: { settings.multipartMode = $0 }
                )) {
                    Text("Off").tag("off")
                    Text("Automatic").tag("auto")
                    Text("Fixed").tag("fixed")
                }
                Stepper(value: $settings.defaultConnectionsPerTask, in: 1...32) {
                    LabeledContent("Maximum connections", value: "\(settings.defaultConnectionsPerTask)")
                }
                .disabled(settings.multipartMode == "off")
                Text("The server may limit the number of connections available for a download.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Automatic reduces connections after server rate limits. Fixed keeps your chosen count. Off uses one stream.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .preferencesPanePadding()
    }

    private var proxyPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Proxy") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Connect using", selection: $settings.proxyMode) {
                        Text("System proxy settings").tag("system")
                        Text("A proxy I specify").tag("custom")
                        Text("No proxy").tag("disabled")
                    }
                    if settings.proxyMode == "system" {
                        Text("The engine uses macOS HTTP and HTTPS proxy settings and common host exceptions. Automatic proxy scripts, SOCKS, and proxy authentication are not yet supported.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if settings.proxyMode == "custom" {
                        Picker("Type", selection: $proxyType) {
                            Text("HTTP").tag("http")
                            Text("HTTPS").tag("https")
                            Text("SOCKS5 (not yet supported)").tag("socks5")
                        }
                        TextField("Server address", text: $proxyHost, prompt: Text("proxy.example.com or 192.0.2.1"))
                        TextField("Port", text: $proxyPort, prompt: Text("8080"))
                        if !proxyPort.isEmpty && !(1...65535).contains(Int(proxyPort) ?? 0) {
                            Text("Enter a port from 1 to 65535.").font(.caption).foregroundStyle(.red)
                        }
                        if proxyType == "socks5" {
                            Text("SOCKS5 transfers are not available yet. The engine will refuse a transfer rather than bypass the proxy.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if settings.proxyMode == "custom" {
                GroupBox("Authentication") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Proxy requires a username and password", isOn: $proxyUsesAuthentication)
                        if proxyUsesAuthentication {
                            TextField("Username", text: $proxyUsername)
                            SecureField("Password", text: $proxyPassword)
                            Text("Credentials are saved in your macOS Keychain. The engine will refuse requests through this proxy until authenticated proxy transfers are supported.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .preferencesPanePadding()
    }

    private var bandwidthPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Global download speed limit") {
                VStack(alignment: .leading, spacing: 8) {
                    bandwidthPicker("Maximum speed", value: $settings.bandwidthLimitBytesPerSecond)
                    Text("Used by default. Unlimited uses the full available connection speed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Scheduled limited speed") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Use limited speed on a schedule", isOn: $settings.bandwidthScheduleEnabled)
                    VStack(alignment: .leading, spacing: 8) {
                        bandwidthPicker("Limited speed", value: $settings.scheduledBandwidthLimitBytesPerSecond)
                        Text("The global limit applies outside the selected hours.")
                            .font(.caption).foregroundStyle(.secondary)
                        BandwidthScheduleGrid(slots: $settings.bandwidthScheduleSlots)
                        HStack(spacing: 16) {
                            ScheduleLegend(color: Color(nsColor: .quaternaryLabelColor), title: "Global limit")
                            ScheduleLegend(color: .orange, title: "Limited speed")
                            Spacer()
                            Text("Mac time zone").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!settings.bandwidthScheduleEnabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .preferencesPanePadding()
    }

    private var schedulerPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox("Queue schedule") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Schedule queue activity", isOn: $settings.queueScheduleEnabled)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Choose the hours when the queue can run. Each cell represents one hour.")
                            .font(.caption).foregroundStyle(.secondary)
                        QueueScheduleGrid(slots: $settings.queueScheduleSlots)
                        HStack(spacing: 16) {
                            ScheduleLegend(color: .accentColor, title: "Active")
                            ScheduleLegend(color: Color(nsColor: .quaternaryLabelColor), title: "Off")
                            Spacer()
                            Text("Mac time zone").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!settings.queueScheduleEnabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .preferencesPanePadding()
    }

    private func load() async {
        defer {
            isLoading = false
            if lastPersistedSettings != nil { scheduleSave(settings) }
        }
        do {
            let loaded = try await engine.loadSettings()
            lastPersistedSettings = loaded
            settings = loaded
            loadProxyFields()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleSave(_ newSettings: EngineSettings) {
        guard !isLoading, newSettings != lastPersistedSettings else { return }
        if newSettings.proxyMode == "custom" && (newSettings.proxyURL?.isEmpty ?? true) {
            statusMessage = "Enter a proxy server address and port to save this setting."
            return
        }
        statusMessage = nil
        errorMessage = nil
        pendingSave?.cancel()
        pendingSave = Task {
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            await save(newSettings)
        }
    }

    private func save(_ value: EngineSettings) async {
        isSaving = true
        defer { isSaving = false }
        do {
            let saved = try await engine.saveSettings(value)
            guard !Task.isCancelled else { return }
            lastPersistedSettings = saved
            settings = saved
            statusMessage = "Saved"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the default folder for new downloads."
        if panel.runModal() == .OK, let url = panel.url {
            settings.defaultDownloadFolder = url.path
        }
    }

    private var paneHeight: CGFloat {
        switch selectedPane ?? .general {
        case .general: 545
        case .downloads: 270
        case .connections: 345
        case .proxy: settings.proxyMode == "custom" ? (proxyUsesAuthentication ? 515 : 445) : (settings.proxyMode == "system" ? 330 : 280)
        case .bandwidth: 670
        case .schedule: 560
        }
    }

    private func bandwidthPicker(_ title: String, value: Binding<UInt64>) -> some View {
        Picker(title, selection: value) {
            ForEach([0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 30, 50, 100], id: \.self) { speed in
                Text(speed == 0 ? "Unlimited" : "\(speed) MB/s")
                    .tag(UInt64(speed) * 1_000_000)
            }
        }
        .pickerStyle(.menu)
    }

    private func loadProxyFields() {
        if let endpoint = settings.proxyURL, let components = URLComponents(string: endpoint) {
            proxyType = components.scheme ?? "http"
            proxyHost = components.host ?? ""
            proxyPort = components.port.map(String.init) ?? ""
        }
        if let saved = ProxyCredentialStore.load() {
            proxyUsesAuthentication = true
            settings.proxyAuthenticationRequired = true
            proxyUsername = saved.username
            proxyPassword = saved.password
        } else {
            proxyUsesAuthentication = settings.proxyAuthenticationRequired
        }
    }

    private func updateProxyEndpoint() {
        guard !isLoading, settings.proxyMode == "custom",
              !proxyHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let port = Int(proxyPort), (1...65535).contains(port) else { return }
        var endpoint = URLComponents()
        endpoint.scheme = proxyType
        endpoint.host = proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
        endpoint.port = port
        settings.proxyURL = endpoint.url?.absoluteString
    }

    private func saveProxyCredentials() {
        guard !isLoading else { return }
        pendingCredentialSave?.cancel()
        let usesAuthentication = proxyUsesAuthentication
        let username = proxyUsername
        let password = proxyPassword
        pendingCredentialSave = Task {
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            guard !Task.isCancelled else { return }
            persistProxyCredentials(usesAuthentication: usesAuthentication, username: username, password: password)
        }
    }

    private func persistProxyCredentials(usesAuthentication: Bool, username: String, password: String) {
        do {
            if usesAuthentication {
                try ProxyCredentialStore.save(username: username, password: password)
            } else {
                try ProxyCredentialStore.delete()
            }
            errorMessage = nil
        } catch {
            errorMessage = "Could not save proxy credentials to Keychain: \(error.localizedDescription)"
        }
    }
}

private let scheduleDays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

private extension View {
    func preferencesPanePadding() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 20)
            .padding(.top, 14)
    }
}

private struct QueueScheduleGrid: View {
    @Binding var slots: [Bool]

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let labelWidth: CGFloat = 46
                let rowHeight: CGFloat = 13
                let headerHeight: CGFloat = 21
                let gap: CGFloat = 3
                let columnWidth = (size.width - labelWidth - 6 * gap) / 7
                for day in 0..<7 {
                    let x = labelWidth + CGFloat(day) * (columnWidth + gap)
                    context.draw(Text(scheduleDays[day]).font(.caption2), at: CGPoint(x: x + columnWidth / 2, y: 9))
                }
                for hour in 0..<24 {
                    let y = headerHeight + CGFloat(hour) * rowHeight
                    context.draw(Text(String(format: "%02d:00", hour)).font(.system(size: 10, design: .monospaced)),
                                 at: CGPoint(x: 22, y: y + 7))
                    for day in 0..<7 {
                        let x = labelWidth + CGFloat(day) * (columnWidth + gap)
                        let rect = CGRect(x: x, y: y, width: columnWidth, height: 12)
                        let active = slots.count == 168 && slots[day * 24 + hour]
                        context.fill(Path(roundedRect: rect, cornerRadius: 2),
                                     with: .color(active ? .accentColor : Color(nsColor: .quaternaryLabelColor).opacity(0.55)))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { gesture in
                guard slots.count == 168 else { return }
                let labelWidth: CGFloat = 46
                let gap: CGFloat = 3
                let columnWidth = (geometry.size.width - labelWidth - 6 * gap) / 7
                guard columnWidth > 0 else { return }
                let day = Int((gesture.location.x - labelWidth) / (columnWidth + gap))
                let hour = Int((gesture.location.y - 21) / 13)
                guard gesture.location.x >= labelWidth,
                      (0..<7).contains(day), (0..<24).contains(hour) else { return }
                slots[day * 24 + hour].toggle()
            })
        }
        .frame(height: 21 + 24 * 13)
        .accessibilityLabel("Weekly queue schedule. Click a cell to switch between active and off.")
        .padding(.vertical, 4)
    }
}

private struct BandwidthScheduleGrid: View {
    @Binding var slots: [BandwidthScheduleMode]

    var body: some View {
        GeometryReader { geometry in
        Canvas { context, size in
            let labelWidth: CGFloat = 46
            let rowHeight: CGFloat = 11
            let headerHeight: CGFloat = 21
            let gap: CGFloat = 3
            let columnWidth = (size.width - labelWidth - 6 * gap) / 7
            for day in 0..<7 {
                let x = labelWidth + CGFloat(day) * (columnWidth + gap)
                context.draw(Text(scheduleDays[day]).font(.caption2), at: CGPoint(x: x + columnWidth / 2, y: 9))
            }
            for hour in 0..<24 {
                let y = headerHeight + CGFloat(hour) * rowHeight
                context.draw(Text(String(format: "%02d:00", hour)).font(.system(size: 10, design: .monospaced)),
                             at: CGPoint(x: 22, y: y + 7))
                for day in 0..<7 {
                    let x = labelWidth + CGFloat(day) * (columnWidth + gap)
                    let rect = CGRect(x: x, y: y, width: columnWidth, height: 10)
                    let active = slots.count == 168 && slots[day * 24 + hour] == .limited
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(active ? .orange : Color(nsColor: .quaternaryLabelColor).opacity(0.55)))
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onEnded { gesture in
            guard slots.count == 168 else { return }
            let labelWidth: CGFloat = 46
            let gap: CGFloat = 3
            let columnWidth = (gesture.startLocation.x >= labelWidth) ?
                (geometry.size.width - labelWidth - 6 * gap) / 7 : 0
            guard columnWidth > 0 else { return }
            let day = Int((gesture.location.x - labelWidth) / (columnWidth + gap))
            let hour = Int((gesture.location.y - 21) / 11)
            guard (0..<7).contains(day), (0..<24).contains(hour) else { return }
            let index = day * 24 + hour
            slots[index] = slots[index] == .limited ? .globalLimit : .limited
        })
        }
        .frame(height: 21 + 24 * 11)
        .accessibilityLabel("Weekly bandwidth schedule. Click a cell to switch between global and limited speed.")
        .padding(.vertical, 4)
    }
}

private struct ScheduleLegend: View {
    let color: Color
    let title: String

    var body: some View {
        Label(title, systemImage: "square.fill")
            .labelStyle(.titleAndIcon)
            .symbolRenderingMode(.palette)
            .foregroundStyle(color, color)
            .font(.caption)
    }
}

private struct PreferencesWindowSizer: NSViewRepresentable {
    let pane: PreferencesPane?
    let contentHeight: CGFloat

    final class Coordinator {
        var lastPane: PreferencesPane?
        var lastHeight: CGFloat = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            guard coordinator.lastPane != pane || abs(coordinator.lastHeight - contentHeight) > 1 else { return }
            coordinator.lastPane = pane
            coordinator.lastHeight = contentHeight
            let target = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 650, height: contentHeight)).height
            guard abs(window.frame.height - target) > 1 else { return }
            var frame = window.frame
            let top = frame.maxY
            frame.size.height = target
            frame.origin.y = top - target
            window.setFrame(frame, display: true, animate: false)
        }
    }
}

private enum ProxyCredentialStore {
    private static let service = "com.mjkhaani.SpeedDownload.proxy"
    private static let account = "manual-proxy"

    static func load() -> (username: String, password: String)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let text = String(data: data, encoding: .utf8),
              let separator = text.firstIndex(of: "\n") else { return nil }
        return (String(text[..<separator]), String(text[text.index(after: separator)...]))
    }

    static func save(username: String, password: String) throws {
        let data = Data("\(username)\n\(password)".utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData as String] = data
            let added = SecItemAdd(insertion as CFDictionary, nil)
            guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
