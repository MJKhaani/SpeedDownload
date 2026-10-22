import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DashboardView: View {
    @EnvironmentObject private var engine: EngineModel
    @State private var selection: String? = "All Downloads"
    @State private var selectedJobID: String?
    @State private var showingAddDownload = false
    @State private var incomingDownloadURL = ""
    @State private var showingTaskInspector = false
    @State private var searchText = ""
    @AppStorage("transferSortOrder") private var sortOrderRaw = "queue"

    private let sections = ["All Downloads", "Unfinished", "Completed", "Failed"]
    private enum SortOrder: String, CaseIterable {
        case queue, name, size, status

        var title: String {
            switch self {
            case .queue: "Queue Order"
            case .name: "Name"
            case .size: "Size"
            case .status: "Status"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Library") {
                    ForEach(sections, id: \.self) { section in
                        Label(section, systemImage: icon(for: section))
                            .badge(count(for: section))
                            .tag(section)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Speed Download")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
            .safeAreaInset(edge: .bottom) { engineBadge.padding(16) }
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selection ?? "All Downloads").font(.title2.weight(.semibold))
                        Text("\(filteredJobs.count) transfer\(filteredJobs.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        ForEach(SortOrder.allCases, id: \.self) { order in
                            Button {
                                sortOrderRaw = order.rawValue
                            } label: {
                                if sortOrderRaw == order.rawValue {
                                    Label(order.title, systemImage: "checkmark")
                                } else {
                                    Text(order.title)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .menuStyle(.borderlessButton)
                    .help("Sort transfers")
                    .accessibilityLabel("Sort transfers")
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                if let error = engine.actionError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 10)
                }
                if filteredJobs.isEmpty {
                    ContentUnavailableView(isConnected ? "No transfers" : "Engine unavailable",
                        systemImage: isConnected ? "arrow.down.circle" : "bolt.horizontal.circle",
                        description: Text(connectionError ?? (isConnected ? "Add a URL to place a download in your queue." : "The app starts the local engine when it is available.")))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedJobID) {
                        ForEach(filteredJobs) { job in
                            transferRow(job)
                                .tag(job.jobID)
                                .contextMenu { actionMenu(for: job) }
                        }
                    }
                    .listStyle(.plain)
                }
                HStack(spacing: 7) {
                    Circle().fill(connectionError == nil ? (isConnected ? .green : .orange) : .red).frame(width: 7, height: 7)
                    Text(connectionStatus).foregroundStyle(.secondary)
                        .help(connectionError ?? connectionStatus)
                    Spacer()
                    Label(downloadRate(engine.totalDownloadBytesPerSecond), systemImage: "arrow.down")
                        .monospacedDigit()
                        .help("Total download speed across active transfers")
                    Menu {
                        ForEach(speedLimits, id: \.self) { limit in
                            Button {
                                Task { await engine.setGlobalSpeedLimit(limit) }
                            } label: {
                                if engine.cachedSettings?.bandwidthLimitBytesPerSecond == limit {
                                    Label(speedLimitTitle(limit), systemImage: "checkmark")
                                } else {
                                    Text(speedLimitTitle(limit))
                                }
                            }
                        }
                    } label: {
                        Label("Limit: \(speedLimitTitle(engine.cachedSettings?.bandwidthLimitBytesPerSecond ?? 0))", systemImage: "speedometer")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(!isConnected || engine.cachedSettings == nil)
                    .help("Global download speed limit")
                    Divider().frame(height: 14)
                    Text("\(engine.jobs.filter { $0.state == "downloading" }.count) active · \(engine.jobs.filter { $0.state == "queued" }.count) queued")
                        .foregroundStyle(.secondary)
                }
                .font(.caption).padding(.horizontal, 14).padding(.vertical, 9)
                .background(.bar)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationSplitViewColumnWidth(min: 500, ideal: 900)
            .inspector(isPresented: $showingTaskInspector) {
                Group {
                    if let job = selectedJob {
                        transferDetails(job)
                    } else {
                        ContentUnavailableView("Select a transfer", systemImage: "arrow.down.doc", description: Text("Transfer details and actions appear here."))
                    }
                }
                .inspectorColumnWidth(min: 280, ideal: 320, max: 380)
            }
            .navigationSubtitle("Manage and monitor your transfers")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await engine.refreshJobs() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { incomingDownloadURL = ""; showingAddDownload = true } label: {
                        Label("Add Download", systemImage: "plus").labelStyle(.iconOnly)
                    }
                    .help("Add Download")
                    .disabled(!isConnected)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter transfers")
        .onDrop(of: [UTType.url.identifier, UTType.plainText.identifier], isTargeted: nil, perform: handleDownloadDrop)
        .sheet(isPresented: $showingAddDownload) {
            AddDownloadView(
                initialURL: incomingDownloadURL,
                isSubmitting: engine.isSubmitting,
                probeURL: { url in try await engine.probe(url: url) },
                submit: { url, name, destination, priority, checksum, selectedFiles, infoHash in
                    let added = await engine.addJob(url: url, name: name, destination: destination, priority: priority, expectedSHA256: checksum, selectedTorrentFiles: selectedFiles, torrentInfoHash: infoHash)
                    if added { showingAddDownload = false }
                    return added
                }
            )
        }
        .task { reconcileSelection(with: filteredJobs) }
        .onChange(of: engine.jobs) { _, _ in reconcileSelection(with: filteredJobs) }
        .onChange(of: selection) { _, _ in reconcileSelection(with: filteredJobs) }
        .onChange(of: searchText) { _, _ in reconcileSelection(with: filteredJobs) }
        .onReceive(NotificationCenter.default.publisher(for: .speedDownloadNewTransfer)) { _ in
            incomingDownloadURL = ""
            showingAddDownload = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .speedDownloadClipboardTransfer)) { notification in
            guard let value = notification.object as? String, value.utf8.count <= 8192 else { return }
            incomingDownloadURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
            showingAddDownload = true
        }
        .onOpenURL { incoming in
            if incoming.scheme?.lowercased() == "magnet", incoming.absoluteString.utf8.count <= 8192 {
                incomingDownloadURL = incoming.absoluteString
                showingAddDownload = true
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            guard incoming.scheme?.lowercased() == "speeddownload",
                  incoming.host?.lowercased() == "add",
                  let source = URLComponents(url: incoming, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
                  source.utf8.count <= 8192,
                  let sourceURL = URL(string: source),
                  (["http", "https", "ftp", "ftps"].contains(sourceURL.scheme?.lowercased() ?? "") && sourceURL.host != nil || source.lowercased().hasPrefix("magnet:?")) else { return }
            incomingDownloadURL = source
            showingAddDownload = true
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func handleDownloadDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: NSURL.self) {
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let value = object as? URL else { return }
                DispatchQueue.main.async { offerDownloadURL(value.absoluteString) }
            }
            return true
        }
        if provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let value = object as? String else { return }
                DispatchQueue.main.async { offerDownloadURL(value) }
            }
            return true
        }
        return false
    }

    private func offerDownloadURL(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 8192,
              let parsed = URL(string: value),
              (["http", "https", "ftp", "ftps"].contains(parsed.scheme?.lowercased() ?? "") && parsed.host != nil || value.lowercased().hasPrefix("magnet:?")) else { return }
        incomingDownloadURL = value
        showingAddDownload = true
        NSApp.activate(ignoringOtherApps: true)
    }

    private var filteredJobs: [DownloadJob] {
        let jobs: [DownloadJob]
        switch selection {
        case "Unfinished": jobs = engine.jobs.filter { !["completed", "failed", "canceled"].contains($0.state) }
        case "Completed": jobs = engine.jobs.filter { $0.state == "completed" }
        case "Failed": jobs = engine.jobs.filter { $0.state == "failed" }
        default: jobs = engine.jobs
        }
        let matching = searchText.isEmpty ? jobs : jobs.filter {
            jobTitle(for: $0).localizedCaseInsensitiveContains(searchText) || $0.url.localizedCaseInsensitiveContains(searchText)
        }
        guard let order = SortOrder(rawValue: sortOrderRaw), order != .queue else { return matching }
        return matching.enumerated().sorted { left, right in
            let comparison: ComparisonResult
            switch order {
            case .queue:
                comparison = .orderedSame
            case .name:
                comparison = jobTitle(for: left.element).localizedStandardCompare(jobTitle(for: right.element))
            case .size:
                let leftSize = left.element.totalBytes.flatMap(UInt64.init)
                let rightSize = right.element.totalBytes.flatMap(UInt64.init)
                if leftSize == rightSize { comparison = .orderedSame }
                else if leftSize == nil { comparison = .orderedDescending }
                else if rightSize == nil { comparison = .orderedAscending }
                else if let leftSize, let rightSize {
                    comparison = leftSize > rightSize ? .orderedAscending : .orderedDescending
                } else { comparison = .orderedSame }
            case .status:
                let leftState = statusSortRank(left.element.state)
                let rightState = statusSortRank(right.element.state)
                comparison = leftState == rightState ? .orderedSame : (leftState < rightState ? .orderedAscending : .orderedDescending)
            }
            return comparison == .orderedSame ? left.offset < right.offset : comparison == .orderedAscending
        }.map { $0.element }
    }

    private func statusSortRank(_ state: String) -> Int {
        switch state {
        case "downloading": 0
        case "connecting", "resolving", "verifying": 1
        case "queued": 2
        case "retry_wait": 3
        case "scheduled": 4
        case "paused": 5
        case "failed": 6
        case "completed": 7
        case "canceled": 8
        default: 9
        }
    }

    private var selectedJob: DownloadJob? { filteredJobs.first { $0.jobID == selectedJobID } }
    private let speedLimits: [UInt64] = [0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 30, 50, 100].map { UInt64($0) * 1_000_000 }
    private func speedLimitTitle(_ value: UInt64) -> String {
        value == 0 ? "Unlimited" : "\(value / 1_000_000) MB/s"
    }
    private func downloadRate(_ value: UInt64) -> String {
        "\(ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .decimal))/s"
    }
    private func reconcileSelection(with jobs: [DownloadJob]) {
        if let selectedJobID, jobs.contains(where: { $0.jobID == selectedJobID }) { return }
        selectedJobID = jobs.first?.jobID
    }
    private var isConnected: Bool { if case .connected = engine.state { true } else { false } }
    private func count(for section: String) -> Int {
        switch section {
        case "All Downloads": engine.jobs.count
        case "Unfinished": engine.jobs.filter { !["completed", "failed", "canceled"].contains($0.state) }.count
        case "Completed": engine.jobs.filter { $0.state == "completed" }.count
        default: engine.jobs.filter { $0.state == "failed" }.count
        }
    }
    private func icon(for section: String) -> String {
        switch section { case "All Downloads": "tray.full"; case "Unfinished": "arrow.down.circle"; case "Completed": "checkmark.circle"; default: "exclamationmark.circle" }
    }
    private func jobTitle(for job: DownloadJob) -> String {
        if let name = job.name, !name.isEmpty { return name }
        guard let url = URL(string: job.url) else { return job.url }
        return url.lastPathComponent.isEmpty ? (url.host ?? job.url) : url.lastPathComponent
    }

    private func completedFileURL(for job: DownloadJob) -> URL {
        let filename: String
        if let name = job.name, !name.isEmpty {
            filename = name
        } else {
            // Match the engine's on-disk fallback, which uses the raw URI
            // path rather than the decoded name shown in the list.
            let rawPath = URLComponents(string: job.url)?.percentEncodedPath ?? ""
            let candidate = String(rawPath.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
            filename = candidate.isEmpty || candidate == "." || candidate == ".." || candidate.contains("\\")
                ? "download-\(job.jobID.prefix(8)).bin" : candidate
        }
        return URL(fileURLWithPath: job.destination, isDirectory: true).appendingPathComponent(filename)
    }

    private func sourceHost(for job: DownloadJob) -> String {
        URLComponents(string: job.url)?.host ?? job.url
    }

    private func stateTitle(for job: DownloadJob) -> String {
        switch job.state {
        case "downloading": job.receivedBytes == nil ? "Connecting" : "Downloading"
        case "queued": "Waiting"
        case "retry_wait": "Waiting to retry"
        default: job.state.capitalized
        }
    }

    private func transferRow(_ job: DownloadJob) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: AssociatedApplicationIcon.image(for: jobTitle(for: job)))
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(jobTitle(for: job))
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(sourceHost(for: job))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(stateTitle(for: job)).lineLimit(1)
                    Spacer(minLength: 0)
                    if job.state == "downloading" {
                        Text(downloadRate(engine.jobBytesPerSecond[job.jobID] ?? 0))
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let total = job.totalBytes.flatMap(UInt64.init), total > 0,
                   let received = (job.receivedBytes ?? job.completedBytes).flatMap(UInt64.init) {
                    ProgressView(value: Double(min(received, total)), total: Double(total))
                        .accessibilityLabel("\(jobTitle(for: job)) progress")
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(min(received, UInt64(Int64.max))), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(min(total, UInt64(Int64.max))), countStyle: .file))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: 174)
            if let control = rowControl(for: job) {
                Button {
                    Task { await engine.controlJob(job, action: control.action) }
                } label: {
                    Image(systemName: control.symbol).frame(width: 20, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(engine.isSubmitting)
                .help(control.title)
                .accessibilityLabel("\(control.title): \(jobTitle(for: job))")
            } else {
                Color.clear.frame(width: 20, height: 24)
            }
            Button {
                if showingTaskInspector && selectedJobID == job.jobID {
                    showingTaskInspector = false
                } else {
                    selectedJobID = job.jobID
                    showingTaskInspector = true
                }
            } label: {
                Image(systemName: "info.circle").frame(width: 20, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Show transfer details")
            .accessibilityLabel("Show details for \(jobTitle(for: job))")
        }
        .frame(minHeight: 48)
        .padding(.vertical, 3)
    }

    private func rowControl(for job: DownloadJob) -> (title: String, symbol: String, action: String)? {
        return switch job.state {
        case "downloading": ("Pause Transfer", "pause.fill", "pause")
        case "paused": ("Resume Transfer", "play.fill", "resume")
        case "queued": ("Start Transfer", "play.fill", "start")
        case "scheduled": ("Pause Transfer", "pause.fill", "pause")
        case "retry_wait": ("Retry Now", "play.fill", "start")
        case "failed": ("Retry Transfer", "arrow.clockwise", "retry")
        default: nil
        }
    }

    private func transferDetails(_ job: DownloadJob) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 9) {
                    Image(nsImage: AssociatedApplicationIcon.image(for: jobTitle(for: job)))
                        .resizable().interpolation(.high)
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                    Text(jobTitle(for: job))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Menu {
                        actionMenu(for: job)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Transfer actions")
                }

                Divider()
                VStack(spacing: 7) {
                    inspectorField("Status", stateTitle(for: job))
                    if job.state == "downloading", let peers = job.torrentPeerCount {
                        inspectorField("Peers", "\(peers) discovered")
                        if let seeds = job.torrentSeederCount {
                            inspectorField("Seeds", "\(seeds) reported by tracker")
                        }
                        if let leechers = job.torrentLeecherCount {
                            inspectorField("Leechers", "\(leechers) reported by tracker")
                        }
                    }
                    if job.state == "retry_wait", let retryAt = job.retryAtUnixMS.flatMap(Double.init) {
                        inspectorField("Retry", "\(job.retryAttempts ?? 0) of 3 · \(Date(timeIntervalSince1970: retryAt / 1000).formatted(date: .omitted, time: .shortened))")
                    }
                    if let priority = job.priority, priority != 0 {
                        inspectorField("Priority", priority > 0 ? "High" : "Low")
                    }
                    if let limit = job.bandwidthLimitBytesPerSecond, limit > 0 {
                        inspectorField("Speed limit", speedLimitTitle(limit))
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("Source").foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                        Text(sourceHost(for: job))
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .help(job.url)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(job.url, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy full URL")
                            .accessibilityLabel("Copy full URL")
                    }
                    inspectorField("Save to", compactFolder(job.destination))
                        .help(job.destination)
                    if let checksum = job.expectedSHA256 {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text("SHA-256").foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                            Text(job.state == "completed" ? "Verified" : "Check on completion")
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .help(checksum)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(checksum, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless)
                                .help("Copy SHA-256 checksum")
                                .accessibilityLabel("Copy SHA-256 checksum")
                        }
                    }
                }
                .font(.caption)

                if let error = job.errorMessage {
                    Divider()
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                if let total = job.totalBytes.flatMap(UInt64.init), total > 0,
                   let received = (job.receivedBytes ?? job.completedBytes).flatMap(UInt64.init) {
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Progress").font(.caption.weight(.semibold))
                            Spacer()
                            Text("\(Int(Double(min(received, total)) / Double(total) * 100))%")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(min(received, total)), total: Double(total))
                            .accessibilityLabel("Transfer progress")
                        HStack {
                            Text("\(formattedBytes(received)) of \(formattedBytes(total))")
                            Spacer()
                            if job.state == "downloading" {
                                Text(downloadRate(engine.jobBytesPerSecond[job.jobID] ?? 0))
                                    .monospacedDigit()
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }

                if let workers = job.workers, !workers.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connections (\(workers.count))")
                            .font(.caption.weight(.semibold))
                        ForEach(workers.sorted { $0.workerID < $1.workerID }) { worker in
                            let length = max(1, worker.end - worker.start)
                            HStack(spacing: 6) {
                                Text("\(worker.workerID)")
                                    .frame(width: 18, alignment: .leading)
                                ProgressView(value: Double(min(worker.downloaded, length)), total: Double(length))
                                    .accessibilityLabel("Connection \(worker.workerID) progress")
                                Text("\(Int(Double(min(worker.downloaded, length)) / Double(length) * 100))%")
                                    .frame(width: 34, alignment: .trailing)
                                    .monospacedDigit()
                                Text(downloadRate(engine.workerBytesPerSecond[job.jobID]?[worker.workerID] ?? 0))
                                    .frame(width: 76, alignment: .trailing)
                                    .monospacedDigit()
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Connection \(worker.workerID): \(formattedBytes(worker.downloaded)) of \(formattedBytes(length))")
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func inspectorField(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        }
    }

    private func compactFolder(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        return path
    }

    private func formattedBytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .file)
    }

    @ViewBuilder private func actionButtons(for job: DownloadJob) -> some View {
        if job.state == "downloading" {
            Button("Pause Transfer", systemImage: "pause.fill") { Task { await engine.controlJob(job, action: "pause") } }.disabled(engine.isSubmitting)
        } else if job.state == "paused" {
            Button("Resume Transfer", systemImage: "play.fill") { Task { await engine.controlJob(job, action: "resume") } }.disabled(engine.isSubmitting)
        } else if job.state == "retry_wait" {
            Button("Retry Now", systemImage: "arrow.clockwise") { Task { await engine.controlJob(job, action: "start") } }.disabled(engine.isSubmitting)
            Button("Pause Retry", systemImage: "pause.fill") { Task { await engine.controlJob(job, action: "pause") } }.disabled(engine.isSubmitting)
        } else if job.state == "failed" {
            Button("Retry Transfer", systemImage: "arrow.clockwise") { Task { await engine.controlJob(job, action: "retry") } }.disabled(engine.isSubmitting)
        } else if job.state == "queued" {
            Button("Start Transfer", systemImage: "play.fill") { Task { await engine.controlJob(job, action: "start") } }.disabled(engine.isSubmitting)
        } else if job.state == "scheduled" {
            Button("Pause Transfer", systemImage: "pause.fill") { Task { await engine.controlJob(job, action: "pause") } }.disabled(engine.isSubmitting)
        }
        if ["downloading", "queued", "scheduled", "paused", "retry_wait"].contains(job.state) {
            Button("Cancel Transfer", systemImage: "xmark.circle", role: .destructive) { Task { await engine.controlJob(job, action: "cancel") } }.disabled(engine.isSubmitting)
        }
        if job.state == "completed" {
            Button("Open Download", systemImage: "doc") {
                NSWorkspace.shared.open(completedFileURL(for: job))
            }
            .disabled(!FileManager.default.fileExists(atPath: completedFileURL(for: job).path))
            Button("Reveal in Finder", systemImage: "folder") {
                NSWorkspace.shared.selectFile(completedFileURL(for: job).path, inFileViewerRootedAtPath: job.destination)
            }
            .disabled(!FileManager.default.fileExists(atPath: completedFileURL(for: job).path))
        }
        if !["resolving", "connecting", "downloading", "verifying"].contains(job.state) {
            Button("Remove from List", systemImage: "trash", role: .destructive) {
                Task { await engine.deleteJob(job) }
            }.disabled(engine.isSubmitting)
        }
    }

    @ViewBuilder private func actionMenu(for job: DownloadJob) -> some View {
        actionButtons(for: job)
        if !["completed", "canceled"].contains(job.state) {
            Menu("Download Speed") {
                ForEach(speedLimits, id: \.self) { limit in
                    Button {
                        Task { await engine.setJobSpeedLimit(job, bytesPerSecond: limit) }
                    } label: {
                        let title = limit == 0 ? "No per-download limit" : speedLimitTitle(limit)
                        if (job.bandwidthLimitBytesPerSecond ?? 0) == limit {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
            }
            .disabled(engine.isSubmitting)
        }
    }

    private var engineBadge: some View {
        Label(connectionStatus, systemImage: isConnected ? "checkmark.circle.fill" : "bolt.horizontal.circle")
            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            .help(connectionError ?? connectionStatus)
    }

    private var connectionStatus: String {
        switch engine.state {
        case .connecting: "Connecting to local engine…"
        case .connected: "Engine connected"
        case .disconnected: "Engine disconnected"
        }
    }

    private var connectionError: String? {
        if case .disconnected(let message) = engine.state { return message }
        return nil
    }
}

@MainActor
private enum AssociatedApplicationIcon {
    static let cache = NSCache<NSString, NSImage>()

    static func image(for filename: String) -> NSImage {
        let fileExtension = (filename as NSString).pathExtension.lowercased()
        let key = (fileExtension.isEmpty ? "public.data" : fileExtension) as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let workspace = NSWorkspace.shared
        let icon: NSImage
        if !fileExtension.isEmpty,
           let application = workspace.urlForApplication(toOpen: URL(fileURLWithPath: "/tmp/SpeedDownload.\(fileExtension)")) {
            icon = workspace.icon(forFile: application.path)
        } else {
            icon = workspace.icon(for: UTType(filenameExtension: fileExtension) ?? .data)
        }
        cache.setObject(icon, forKey: key)
        return icon
    }
}

private struct AddDownloadView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var engine: EngineModel
    @State private var url = ""
    @State private var name = ""
    @State private var destination = "\(NSHomeDirectory())/Downloads"
    @State private var priority = 0
    @State private var expectedSHA256 = ""
    @State private var validationError: String?
    @State private var probeResult: DownloadProbe?
    @State private var probeError: String?
    @State private var isProbing = false
    @State private var lastSuggestedName: String?
    @State private var selectedTorrentFiles: Set<String> = []
    let initialURL: String
    let isSubmitting: Bool
    let probeURL: (String) async throws -> DownloadProbe
    let submit: (String, String, String, Int, String?, [String]?, String?) async -> Bool

    private var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Download").font(.title2.weight(.semibold))
                Text("Inspect a link, then choose its name, priority, and destination.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Form {
                Section("Download source") {
                    HStack {
                        TextField("URL", text: $url, prompt: Text("https://example.com/file.zip or magnet:?xt=…"))
                            .textFieldStyle(.roundedBorder)
                        Button("Choose Torrent…", action: chooseTorrent)
                    }
                    probeSummary
                }
                Section("File") {
                    TextField("File name", text: $name, prompt: Text("Suggested after URL check"))
                    HStack(spacing: 8) {
                        TextField("Destination folder", text: $destination).textFieldStyle(.roundedBorder)
                        Button("Choose…", action: chooseDestination)
                    }
                }
                Picker("Queue Priority", selection: $priority) {
                    Text("Low").tag(-1); Text("Normal").tag(0); Text("High").tag(1)
                }
                Section("Verification") {
                    TextField("SHA-256 checksum (optional)", text: $expectedSHA256)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                    Text("If provided, the engine checks the completed file against this value.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let validationError { Text(validationError).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button { Task { await save() } } label: {
                    if isSubmitting { ProgressView().controlSize(.small) } else { Text("Add to Queue") }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            if !initialURL.isEmpty && url.isEmpty { url = initialURL }
            if let folder = engine.cachedSettings?.defaultDownloadFolder, !folder.isEmpty {
                destination = folder
            }
        }
        .task(id: trimmedURL) { await inspectURL(trimmedURL) }
        .onChange(of: initialURL) { _, newValue in
            if !newValue.isEmpty { url = newValue }
        }
    }

    @ViewBuilder private var probeSummary: some View {
        if isProbing {
            Label("Checking link with Speed Download…", systemImage: "magnifyingglass")
                .font(.callout).foregroundStyle(.secondary)
        } else if let probeResult {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: probeResult.httpVersion == "BitTorrent" ? "point.3.connected.trianglepath.dotted" : "doc.zipper")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayFilename(probeResult.suggestedName))
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(formattedSize(probeResult.totalBytes))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }

                HStack(spacing: 6) {
                    if probeResult.httpVersion == "BitTorrent" {
                        capabilityBadge("BitTorrent", supported: true)
                        capabilityBadge("Piece verification", supported: true)
                    } else {
                        capabilityBadge(probeResult.rangeSupported ? "Byte ranges" : "Single stream", supported: true)
                        if probeResult.resumeSupported { capabilityBadge("Resume", supported: true) }
                        if probeResult.multipartSupported { capabilityBadge("Parallel", supported: true) }
                    }
                }

                Text(summaryMessage(for: probeResult))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let files = probeResult.torrentFiles, let count = probeResult.torrentFileCount, count > 1 {
                    DisclosureGroup("Files (\(count))") {
                        VStack(alignment: .leading, spacing: 5) {
                            if count == files.count {
                                HStack(spacing: 12) {
                                    Button("Select All") { selectedTorrentFiles = Set(files.map(\.path)) }
                                    Button("Select None") { selectedTorrentFiles.removeAll() }
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            }
                            if files.count > 10 {
                                ScrollView(.vertical) {
                                    LazyVStack(alignment: .leading, spacing: 5) {
                                        torrentFileRows(files, complete: count == files.count)
                                    }
                                }
                                .frame(height: 240)
                            } else {
                                VStack(alignment: .leading, spacing: 5) {
                                    torrentFileRows(files, complete: count == files.count)
                                }
                            }
                            if count > files.count {
                                Text("Showing the first \(files.count) files")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("All files are included. This torrent exceeds the file selection preview limit.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 5)
                    }
                    .font(.callout)
                }

                DisclosureGroup("Connection details") {
                    VStack(spacing: 6) {
                        probeDetail("Redirected to", value: probeResult.finalURL)
                        probeDetail("Protocol", value: ["FTP", "FTPS", "BitTorrent"].contains(probeResult.httpVersion) ? probeResult.httpVersion : "\(probeResult.httpVersion) · \(statusDescription(probeResult.statusCode))")
                        if let contentType = probeResult.contentType {
                            probeDetail("File type", value: contentType)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.callout)
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
        } else if let probeError {
            Label(probeError, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange)
        } else if !trimmedURL.isEmpty {
            Text("Enter a link or choose a .torrent file to inspect the download.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func torrentFileRows(_ files: [DownloadProbe.TorrentFile], complete: Bool) -> some View {
        ForEach(Array(files.enumerated()), id: \.offset) { _, file in
            HStack(spacing: 8) {
                if complete {
                    Toggle("Include \(file.path)", isOn: Binding(
                        get: { selectedTorrentFiles.contains(file.path) },
                        set: { enabled in
                            if enabled { selectedTorrentFiles.insert(file.path) }
                            else { selectedTorrentFiles.remove(file.path) }
                        }
                    ))
                    .labelsHidden()
                }
                Text(file.path).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(formattedSize(file.length)).foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private func inspectURL(_ value: String) async {
        probeResult = nil
        probeError = nil
        selectedTorrentFiles = []
        guard !value.isEmpty else { isProbing = false; return }
        guard let parsed = URL(string: value),
              (["http", "https", "ftp", "ftps"].contains(parsed.scheme?.lowercased() ?? "") && parsed.host != nil || value.lowercased().hasPrefix("magnet:?") || value.lowercased().hasPrefix("torrent-file:///")) else {
            isProbing = false
            probeError = "Enter a valid link or choose a .torrent file."
            return
        }
        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        guard !Task.isCancelled else { return }
        isProbing = true
        defer { isProbing = false }
        do {
            let result = try await probeURL(value)
            guard !Task.isCancelled, trimmedURL == value else { return }
            probeResult = result
            selectedTorrentFiles = Set(result.torrentFiles?.map(\.path) ?? [])
            probeError = nil
            let suggestedName = displayFilename(result.suggestedName)
            let currentName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentName.isEmpty || currentName == lastSuggestedName || currentName == result.suggestedName ||
                currentName.removingPercentEncoding == suggestedName {
                name = suggestedName
            }
            lastSuggestedName = suggestedName
        } catch {
            guard !Task.isCancelled, trimmedURL == value else { return }
            probeError = "\(error.localizedDescription) You can still add it to the queue."
        }
    }

    private func formattedSize(_ value: String?) -> String {
        guard let value, let bytes = Int64(value) else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func displayFilename(_ value: String) -> String {
        guard let decoded = value.removingPercentEncoding,
              !decoded.isEmpty, decoded != ".", decoded != "..",
              !decoded.contains("/"), !decoded.contains("\\"),
              !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return value }
        return decoded
    }

    private func capabilityBadge(_ title: String, supported: Bool) -> some View {
        Label(title, systemImage: supported ? "checkmark.circle.fill" : "circle")
            .font(.caption)
            .foregroundStyle(supported ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: Capsule())
    }

    private func summaryMessage(for probe: DownloadProbe) -> String {
        if probe.httpVersion == "BitTorrent" { return probe.message }
        if ["FTP", "FTPS"].contains(probe.httpVersion) { return probe.message }
        if probe.multipartSupported { return "Parallel downloads and resume are available." }
        if probe.resumeSupported { return "This download can resume if interrupted." }
        if probe.rangeSupported { return "Byte ranges are supported; resume is not confirmed." }
        return "This server will use a single connection."
    }

    private func statusDescription(_ status: Int) -> String {
        switch status {
        case 200: "200 OK"
        case 206: "206 Partial content"
        default: "HTTP \(status)"
        }
    }

    private func probeDetail(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func save() async {
        let trimmedURL = self.trimmedURL
        guard let parsed = URL(string: trimmedURL),
              (["http", "https", "ftp", "ftps"].contains(parsed.scheme?.lowercased() ?? "") && parsed.host != nil || trimmedURL.lowercased().hasPrefix("magnet:?") || trimmedURL.lowercased().hasPrefix("torrent-file:///")) else {
            validationError = "Enter a valid link or choose a .torrent file."; return
        }
        let path = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            validationError = "Choose an existing folder for downloaded files."; return
        }
        let checksum = expectedSHA256.trimmingCharacters(in: .whitespacesAndNewlines)
        guard checksum.isEmpty || (checksum.utf8.count == 64 && checksum.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }) else {
            validationError = "SHA-256 must contain exactly 64 hexadecimal characters."; return
        }
        validationError = nil
        var selectedFiles: [String]? = nil
        if let probeResult, let files = probeResult.torrentFiles,
           let count = probeResult.torrentFileCount, count > 1, count == files.count {
            guard !selectedTorrentFiles.isEmpty else {
                validationError = "Select at least one file from the torrent."; return
            }
            if selectedTorrentFiles.count < count {
                guard checksum.isEmpty else {
                    validationError = "A whole-download SHA-256 checksum cannot be used with file selection."; return
                }
                selectedFiles = files.map(\.path).filter { selectedTorrentFiles.contains($0) }
            }
        }
        let added = await submit(trimmedURL, name.trimmingCharacters(in: .whitespacesAndNewlines), path, priority, checksum.isEmpty ? nil : checksum.lowercased(), selectedFiles, probeResult?.torrentInfoHash)
        if !added { validationError = engine.actionError ?? "Could not add this download." }
    }
    private func chooseDestination() {
        let panel = NSOpenPanel(); panel.title = "Choose Download Folder"; panel.prompt = "Choose Folder"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: destination, isDirectory: true)
        if panel.runModal() == .OK, let selectedURL = panel.url { destination = selectedURL.path }
    }
    private func chooseTorrent() {
        let panel = NSOpenPanel()
        panel.title = "Choose Torrent File"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let torrentType = UTType(filenameExtension: "torrent") { panel.allowedContentTypes = [torrentType] }
        if panel.runModal() == .OK, let selectedURL = panel.url,
           var components = URLComponents(url: selectedURL, resolvingAgainstBaseURL: false) {
            components.scheme = "torrent-file"
            if let source = components.url?.absoluteString { url = source }
        }
    }
}
