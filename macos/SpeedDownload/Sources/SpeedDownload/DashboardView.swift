import SwiftUI
import AppKit

struct DashboardView: View {
    @EnvironmentObject private var engine: EngineModel
    @State private var selection: String? = "Downloads"
    @State private var showingAddDownload = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Downloads", systemImage: "arrow.down.circle.fill").tag("Downloads")
                Label("Queue", systemImage: "list.number").tag("Queue")
                Label("Completed", systemImage: "checkmark.circle").tag("Completed")
            }
            .listStyle(.sidebar)
            .navigationTitle("Speed Download")
            .safeAreaInset(edge: .bottom) { engineBadge.padding(16) }
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        connectionCard
                        if let error = engine.actionError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                        jobsContent
                    }
                    .padding(28)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await engine.connect() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!isConnected)
            }
        }
        .sheet(isPresented: $showingAddDownload) {
            AddDownloadView(isSubmitting: engine.isSubmitting) { url, name, destination in
                let added = await engine.addJob(url: url, name: name, destination: destination)
                if added { showingAddDownload = false }
                return added
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selection ?? "Downloads").font(.largeTitle.weight(.bold))
                Text("Your downloads, in one place.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { showingAddDownload = true } label: {
                Label("Add Download", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isConnected)
            .help(isConnected ? "Add a URL to the download queue." : "Connect to the engine to add a job.")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var jobsContent: some View {
        let visibleJobs = filteredJobs
        if visibleJobs.isEmpty {
            emptyDownloads
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(selection ?? "Downloads").font(.title2.weight(.semibold))
                    Spacer()
                    Text("\(visibleJobs.count) job\(visibleJobs.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(visibleJobs) { job in jobRow(job) }
            }
        }
    }

    private var filteredJobs: [DownloadJob] {
        switch selection {
        case "Queue": engine.jobs.filter { $0.state == "queued" || $0.state == "scheduled" }
        case "Completed": engine.jobs.filter { $0.state == "completed" }
        default: engine.jobs
        }
    }

    private func jobRow(_ job: DownloadJob) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: job.state == "completed" ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(job.state == "completed" ? .green : .blue)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 7) {
                Text(jobTitle(for: job))
                    .font(.headline)
                    .lineLimit(1)
                Text(job.url)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Label(job.destination, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(job.state.capitalized)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background((job.state == "completed" ? Color.green : Color.blue).opacity(0.1), in: Capsule())
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 1))
    }

    private func displayName(for rawURL: String) -> String {
        guard let url = URL(string: rawURL) else { return rawURL }
        let lastComponent = url.lastPathComponent
        return lastComponent.isEmpty ? (url.host ?? rawURL) : lastComponent
    }

    private func jobTitle(for job: DownloadJob) -> String {
        if let name = job.name, !name.isEmpty { return name }
        return displayName(for: job.url)
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Engine connection", systemImage: "bolt.horizontal.circle")
                    .font(.headline)
                Spacer()
                statusPill
            }
            Divider()
            switch engine.state {
            case .connecting:
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Connecting to the local Speed Download engine…")
                        .foregroundStyle(.secondary)
                }
            case .connected(let version, let instance, let session):
                HStack(spacing: 18) {
                    metric(title: "Engine", value: "v\(version)", icon: "cpu")
                    metric(title: "Instance", value: String(instance.prefix(8)), icon: "server.rack")
                    metric(title: "Session", value: String(session.prefix(8)), icon: "point.3.connected.trianglepath.dotted")
                }
                Text("Connected. Jobs are saved in the queue; transfer workers are still under development.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .disconnected(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Engine unavailable").font(.title3.weight(.semibold))
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Start `speed-download engine`, then refresh.")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary, lineWidth: 1))
    }

    private var emptyDownloads: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(isConnected ? "No jobs here yet" : "Connect to your engine")
                .font(.title3.weight(.semibold))
            Text(isConnected
                 ? "Add a URL to save it in your queue. Transfers will begin when the download worker is available."
                 : "Start the Speed Download engine to view and manage your saved jobs.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if isConnected {
                Button(action: { showingAddDownload = true }) {
                    Label("Add Download", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 54)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 5])).foregroundStyle(.quaternary))
    }

    private var engineBadge: some View {
        HStack(spacing: 8) {
            Circle().fill(isConnected ? .green : .orange).frame(width: 8, height: 8)
            Text(isConnected ? "Engine connected" : "Engine disconnected")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var statusPill: some View {
        Text(isConnected ? "Connected" : (isConnecting ? "Connecting" : "Offline"))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isConnected ? Color.green : Color.secondary)
            .background((isConnected ? Color.green : Color.gray).opacity(0.12), in: Capsule())
    }

    private var isConnected: Bool {
        if case .connected = engine.state { true } else { false }
    }

    private var isConnecting: Bool {
        if case .connecting = engine.state { true } else { false }
    }

    private func metric(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced).weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AddDownloadView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var name = ""
    @State private var destination = "\(NSHomeDirectory())/Downloads"
    @State private var validationError: String?
    let isSubmitting: Bool
    let submit: (String, String, String) async -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Add Download").font(.title2.weight(.bold))
                Text("Save a URL as a queued job. The file will not download until transfer support is available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Form {
                TextField("https://example.com/file.zip", text: $url)
                    .textFieldStyle(.roundedBorder)
                TextField("Name (optional)", text: $name)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    TextField("Destination folder", text: $destination)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: chooseDestination)
                }
            }
            if let validationError {
                Text(validationError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await save() }
                } label: {
                    if isSubmitting { ProgressView().controlSize(.small) }
                    else { Text("Add to Queue") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func save() async {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmedURL), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else {
            validationError = "Enter a valid HTTP or HTTPS URL."
            return
        }
        validationError = nil
        _ = await submit(trimmedURL, name.trimmingCharacters(in: .whitespacesAndNewlines), destination.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: destination, isDirectory: true)
        if panel.runModal() == .OK, let selectedURL = panel.url {
            destination = selectedURL.path
        }
    }
}
