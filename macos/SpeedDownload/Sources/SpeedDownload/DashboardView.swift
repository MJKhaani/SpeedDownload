import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DashboardView: View {
    @EnvironmentObject private var engine: EngineModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    private let restoredSidebarVisible: Bool
    private let restoredInspectorVisible: Bool
    @AppStorage("alwaysShowSidebar") private var alwaysShowSidebar = false
    @AppStorage("showAllDownloads") private var showAllDownloads = true
    @AppStorage("showUnfinished") private var showUnfinished = true
    @AppStorage("showCompleted") private var showCompleted = true
    @AppStorage("showFailed") private var showFailed = true
    @State private var queueDraftNames: [String: String] = [:]
    @State private var editingQueueID: String?
    @FocusState private var focusedQueueID: String?
    @FocusState private var addButtonFocused: Bool
    @State private var hoveredQueueID: String?
    @State private var settingsQueue: DownloadQueue?
    @State private var queuePendingRemoval: DownloadQueue?
    @State private var selection: String? = "All Downloads"
    @State private var selectedJobID: String?
    @State private var showingAddDownload = false
    @State private var incomingDownloadURL = ""
    @State private var incomingIsTorrent = false
    @State private var incomingBatch: [String] = []
    @State private var incomingDestination: String?
    @State private var incomingPriority = 0
    @State private var incomingReferenceURL: String?
    @State private var incomingRefreshJobID: String?
    @State private var handoffError: String?
    private struct PendingDownload: Equatable, Identifiable {
        var id: String { ([source, String(torrent), refreshJobID ?? "", referenceURL ?? ""] + batch).joined(separator: "\n") }
        let source: String
        let torrent: Bool
        var batch: [String] = []
        var destination: String? = nil
        var priority: Int = 0
        var referenceURL: String? = nil
        var refreshJobID: String? = nil
    }
    @State private var pendingDownloadURLs: [PendingDownload] = []
    @State private var handledRequests: [String] = []
    @State private var showingTaskInspector = false
    @State private var sidebarWidth: CGFloat = 220
    @State private var inspectorWidth: CGFloat = 320
    @State private var hoveredJobID: String?
    @State private var searchText = ""
    @AppStorage("transferSortOrder") private var sortOrderRaw = "queue"

    private let sections = ["All Downloads", "Unfinished", "Completed", "Failed"]

    init() {
        let defaults = UserDefaults.standard
        let savedSidebar = defaults.object(forKey: "dashboardSidebarVisible") as? Bool ?? false
        let savedInspector = defaults.object(forKey: "dashboardInspectorVisible") as? Bool ?? false
        restoredSidebarVisible = savedSidebar
        restoredInspectorVisible = savedInspector
        _columnVisibility = State(initialValue: savedSidebar || defaults.bool(forKey: "alwaysShowSidebar") ? .all : .detailOnly)
        _showingTaskInspector = State(initialValue: savedInspector)
        let savedSidebarWidth = defaults.double(forKey: "dashboardSidebarWidth")
        let savedInspectorWidth = defaults.double(forKey: "dashboardInspectorWidth")
        _sidebarWidth = State(initialValue: (180...260).contains(savedSidebarWidth) ? savedSidebarWidth : 220)
        _inspectorWidth = State(initialValue: (280...380).contains(savedInspectorWidth) ? savedInspectorWidth : 320)
    }
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

    private var sidebarContent: some View {
        List(selection: $selection) {
            Section("Library") {
                ForEach(sections, id: \.self) { section in
                    if showSection(section) {
                        Label(section, systemImage: icon(for: section))
                            .badge(count(for: section))
                            .tag(section)
                            .overlay(alignment: .leading) {
                                QueueDragSource(name: section, select: { selection = section }, remove: { hideSection(section) })
                                    .frame(width: 150, height: 24)
                                    .help("Drag outside the window to hide this sidebar item")
                            }
                    }
                }
            }
            Section("Queues") {
                ForEach(engine.cachedSettings?.queues ?? [.main]) { queue in
                    queueSidebarRow(queue)
                        .tag("Queue:\(queue.id)")
                }
            }
        }
        .listStyle(.sidebar)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: SidebarWidthPreference.self, value: geometry.size.width)
        })
        .navigationTitle("Speed Download")
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { Task { await addQueue() } } label: { Image(systemName: "plus") }
                    .help("Add queue")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(.bar)
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedSectionTitle).font(.title2.weight(.semibold))
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
                        .font(.system(size: 11))
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.mini)
                .fixedSize()
                .focusable(false)
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
            .background(GeometryReader { geometry in
                Color.clear.preference(key: InspectorWidthPreference.self, value: geometry.size.width)
            })
        }
        .navigationSubtitle("Manage and monitor your transfers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await engine.resumeQueue() } } label: { Label("Resume Queue", systemImage: "play.fill") }
                    .help("Resume paused downloads and start waiting downloads")
                    .disabled(!isConnected || engine.isSubmitting)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { newDownload() } label: {
                    Label("Add Download", systemImage: "plus").labelStyle(.iconOnly)
                }
                .help("Add Download")
                .disabled(!isConnected)
                .focused($addButtonFocused)
            }
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
        } detail: {
            mainContent
        }
        .navigationSplitViewStyle(.balanced)
        .modifier(PaneSizingModifier(columnVisibility: columnVisibility,
                                     showingInspector: showingTaskInspector,
                                     sidebarWidth: $sidebarWidth, inspectorWidth: $inspectorWidth,
                                     restoredSidebarVisible: restoredSidebarVisible,
                                     restoredInspectorVisible: restoredInspectorVisible))
        .sheet(item: $settingsQueue) { queue in
            QueueSettingsView(queue: queue) { updated in
                Task { await engine.updateQueue(updated) }
            }
        }
        .confirmationDialog("Remove \(queuePendingRemoval?.name ?? "queue")?", isPresented: Binding(
            get: { queuePendingRemoval != nil }, set: { if !$0 { queuePendingRemoval = nil } }
        )) {
            Button("Move its downloads to main and remove queue", role: .destructive) {
                guard let queue = queuePendingRemoval else { return }
                removeQueue(queue)
            }
            Button("Cancel", role: .cancel) { queuePendingRemoval = nil }
        } message: {
            Text("Unfinished downloads will remain available in main.")
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter transfers")
        .onDrop(of: [UTType.url.identifier, UTType.fileURL.identifier, UTType.plainText.identifier], isTargeted: nil, perform: handleDownloadDrop)
        .sheet(item: Binding(
            get: { showingAddDownload ? PendingDownload(source: incomingDownloadURL, torrent: incomingIsTorrent, batch: incomingBatch, destination: incomingDestination, priority: incomingPriority, referenceURL: incomingReferenceURL, refreshJobID: incomingRefreshJobID) : nil },
            set: { if $0 == nil { showingAddDownload = false } }
        ), onDismiss: showNextPendingDownload) { request in
            if request.batch.count > 1 {
                BatchDownloadView(sources: request.batch, referenceURL: request.referenceURL) { source, destination, priority in
                    pendingDownloadURLs.append(PendingDownload(source: source, torrent: true, destination: destination, priority: priority, referenceURL: request.referenceURL))
                }
            } else if request.torrent {
                TorrentAddView(source: request.source, initialDestination: request.destination, initialPriority: request.priority, referenceURL: request.referenceURL) { showingAddDownload = false }
                    .id(request.id)
            } else {
                AddDownloadView(
                    initialURL: request.source,
                    initialReferenceURL: request.referenceURL,
                    replacingJob: engine.jobs.first(where: { $0.jobID == request.refreshJobID }),
                    isSubmitting: engine.isSubmitting,
                    probeURL: { url in try await engine.probe(url: url) },
                    onTorrentSource: { source in
                        incomingDownloadURL = source
                        incomingIsTorrent = true
                    },
                    submit: { url, name, destination, priority, checksum, selectedFiles, infoHash, referenceURL, queueID in
                        if let jobID = request.refreshJobID {
                            let replaced = await engine.replaceSource(jobID: jobID, url: url)
                            if replaced { showingAddDownload = false }
                            return replaced
                        }
                        let added = await engine.addJob(url: url, name: name, destination: destination, priority: priority, expectedSHA256: checksum, selectedTorrentFiles: selectedFiles, torrentInfoHash: infoHash, referenceURL: referenceURL, queueID: queueID)
                        if added { showingAddDownload = false }
                        return added
                    }
                )
            }
        }
        .task {
            DispatchQueue.main.async { addButtonFocused = true }
            reconcileSelection(with: filteredJobs)
            for token in BrowserHandoff.pendingTokens() { receiveBrowserHandoff(token, recovering: true) }
        }
        .onChange(of: engine.jobs) { _, _ in reconcileSelection(with: filteredJobs) }
        .onChange(of: selection) { _, _ in reconcileSelection(with: filteredJobs) }
        .onChange(of: searchText) { _, _ in reconcileSelection(with: filteredJobs) }
        .onChange(of: alwaysShowSidebar) { _, enabled in if enabled { columnVisibility = .all } }
        .onChange(of: columnVisibility) { _, value in
            UserDefaults.standard.set(value != .detailOnly, forKey: "dashboardSidebarVisible")
        }
        .onChange(of: showingTaskInspector) { _, value in
            UserDefaults.standard.set(value, forKey: "dashboardInspectorVisible")
        }
        .onChange(of: isConnected) { _, connected in
            if connected { DispatchQueue.main.async { addButtonFocused = true } }
        }
        .onChange(of: focusedQueueID) { old, new in
            if old != nil, new == nil, editingQueueID == old { saveQueueNames() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .speedDownloadNewTransfer)) { _ in newDownload() }
        .onReceive(NotificationCenter.default.publisher(for: .speedDownloadClipboardTransfer)) { notification in
            guard let value = notification.object as? String, value.utf8.count <= 8192 else { return }
            offerDownloadURL(value)
        }
        .onReceive(ClientOpenRequests.shared.$urls) { urls in
            guard !urls.isEmpty else { return }
            DispatchQueue.main.async {
                for incoming in ClientOpenRequests.shared.take() { receiveOpenURL(incoming) }
            }
        }
        .onOpenURL { incoming in receiveOpenURL(incoming) }
        .alert("Could Not Open Browser Download", isPresented: Binding(
            get: { handoffError != nil }, set: { if !$0 { handoffError = nil } }
        )) {
            Button("OK") { handoffError = nil }
        } message: { Text(handoffError ?? "") }
    }

    private func receiveOpenURL(_ incoming: URL) {
            if incoming.scheme?.lowercased() == "speeddownload", incoming.host?.lowercased() == "browser" {
                guard let token = URLComponents(url: incoming, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "request" })?.value else { return }
                receiveBrowserHandoff(token)
                return
            }
            if incoming.scheme?.lowercased() == "speeddownload" {
                guard ["add", "torrent"].contains(incoming.host?.lowercased() ?? ""),
                      let components = URLComponents(url: incoming, resolvingAgainstBaseURL: false),
                      let source = components.queryItems?.first(where: { $0.name == "url" })?.value else { return }
                if let request = components.queryItems?.first(where: { $0.name == "request" })?.value {
                    guard UUID(uuidString: request) != nil, !handledRequests.contains(request) else { return }
                    handledRequests.append(request)
                    if handledRequests.count > 128 { handledRequests.removeFirst() }
                }
                offerDownloadURL(source, forceTorrent: incoming.host?.lowercased() == "torrent")
            } else {
                offerDownloadURL(incoming.absoluteString)
            }
    }

    private func newDownload() {
        incomingDownloadURL = ""
        incomingDestination = nil
        incomingPriority = 0
        incomingReferenceURL = nil
        incomingRefreshJobID = nil
        incomingBatch = []
        incomingIsTorrent = false
        showingAddDownload = true
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

    private func receiveBrowserHandoff(_ token: String, recovering: Bool = false) {
        guard !handledRequests.contains(token), pendingDownloadURLs.count < 100 else { return }
        do {
            let request = try BrowserHandoff.consume(token)
            handledRequests.append(token)
            if handledRequests.count > 128 { handledRequests.removeFirst() }
            if request.action == "batch", request.sources.count > 1 { offerBatch(request.sources, referenceURL: request.referenceURL) }
            else if let source = request.sources.first {
                let refreshing = engine.jobs.first(where: { $0.jobID == engine.refreshingJobID && $0.referenceURL == request.referenceURL })
                offerDownloadURL(source, forceTorrent: request.action == "torrent", referenceURL: request.referenceURL,
                    refreshJobID: request.action == "add" ? refreshing?.jobID : nil)
            }
        } catch {
            // Another window may already have consumed a recovered request.
            if !recovering { handoffError = error.localizedDescription }
        }
    }

    private func offerDownloadURL(_ raw: String, forceTorrent: Bool = false, destination: String? = nil, priority: Int = 0, referenceURL: String? = nil, refreshJobID: String? = nil) {
        guard let value = TorrentSource.normalized(raw) else { return }
        if showingAddDownload {
            if pendingDownloadURLs.count < 100 {
                let stored = PendingDownload(source: value, torrent: forceTorrent, destination: destination, priority: priority, referenceURL: referenceURL, refreshJobID: refreshJobID)
                if !pendingDownloadURLs.contains(stored) { pendingDownloadURLs.append(stored) }
            }
            return
        }
        incomingDownloadURL = value
        incomingDestination = destination
        incomingPriority = priority
        incomingReferenceURL = referenceURL
        incomingRefreshJobID = refreshJobID
        incomingBatch = []
        incomingIsTorrent = forceTorrent || TorrentSource.isTorrent(value)
        showingAddDownload = true
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showNextPendingDownload() {
        guard !pendingDownloadURLs.isEmpty else { return }
        let next = pendingDownloadURLs.removeFirst()
        DispatchQueue.main.async {
            if next.batch.count > 1 { offerBatch(next.batch, referenceURL: next.referenceURL) }
            else { offerDownloadURL(next.source, forceTorrent: next.torrent, destination: next.destination, priority: next.priority, referenceURL: next.referenceURL, refreshJobID: next.refreshJobID) }
        }
    }

    private func offerBatch(_ sources: [String], referenceURL: String? = nil) {
        let urls = sources.compactMap(TorrentSource.normalized)
        guard !urls.isEmpty else { return }
        if urls.count == 1 { offerDownloadURL(urls[0], referenceURL: referenceURL); return }
        if showingAddDownload {
            if pendingDownloadURLs.count < 100 {
                pendingDownloadURLs.append(PendingDownload(source: "", torrent: false, batch: urls, referenceURL: referenceURL))
            }
            return
        }
        incomingBatch = urls
        incomingRefreshJobID = nil
        incomingReferenceURL = referenceURL
        incomingDownloadURL = ""
        incomingIsTorrent = false
        showingAddDownload = true
        NSApp.activate(ignoringOtherApps: true)
    }

    private var filteredJobs: [DownloadJob] {
        let jobs: [DownloadJob]
        switch selection {
        case "Unfinished": jobs = engine.jobs.filter { !["completed", "failed", "canceled"].contains($0.state) }
        case "Completed": jobs = engine.jobs.filter { $0.state == "completed" }
        case "Failed": jobs = engine.jobs.filter { $0.state == "failed" }
        case let value? where value.hasPrefix("Queue:"):
            jobs = engine.jobs.filter { $0.queueID == String(value.dropFirst("Queue:".count)) }
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
    private var selectedSectionTitle: String {
        guard let selection, selection.hasPrefix("Queue:") else { return selection ?? "All Downloads" }
        let id = String(selection.dropFirst("Queue:".count))
        return engine.cachedSettings?.queues.first(where: { $0.id == id })?.name ?? "Queue"
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
    private func showSection(_ section: String) -> Bool {
        switch section {
        case "All Downloads": showAllDownloads
        case "Unfinished": showUnfinished
        case "Completed": showCompleted
        default: showFailed
        }
    }

    private func hideSection(_ section: String) {
        switch section {
        case "All Downloads": showAllDownloads = false
        case "Unfinished": showUnfinished = false
        case "Completed": showCompleted = false
        case "Failed": showFailed = false
        default: break
        }
        if selection == section { selection = "Queue:main" }
    }

    private func queueSidebarRow(_ queue: DownloadQueue) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "tray.full")
            if editingQueueID == queue.id && queue.id != "main" {
                TextField("Queue name", text: Binding(
                    get: { queueDraftNames[queue.id] ?? queue.name },
                    set: { queueDraftNames[queue.id] = $0 }
                ))
                .textFieldStyle(.plain)
                .focused($focusedQueueID, equals: queue.id)
                .onSubmit { saveQueueNames() }
                .onAppear { DispatchQueue.main.async { focusedQueueID = queue.id } }
            } else {
                Text(queue.name).lineLimit(1)
                    .onTapGesture(count: 2) { beginRenaming(queue) }
            }
            Spacer(minLength: 0)
            if hoveredQueueID == queue.id {
                Button {
                    settingsQueue = queue
                } label: {
                    Image(systemName: "ellipsis").rotationEffect(.degrees(90))
                }
                .buttonStyle(.borderless)
                .help("Queue settings")
                .accessibilityLabel("Settings for \(queue.name)")
            }
        }
        .overlay(alignment: .leading) {
            if queue.id != "main" && editingQueueID != queue.id {
                QueueDragSource(name: queue.name, select: { selection = "Queue:\(queue.id)" }, remove: { requestQueueRemoval(queue) }, rename: { beginRenaming(queue) })
                    .frame(width: 135, height: 24)
                    .help("Drag outside the window to remove this queue")
            }
        }
        .onHover { hoveredQueueID = $0 ? queue.id : (hoveredQueueID == queue.id ? nil : hoveredQueueID) }
        .contextMenu {
            Button("Queue Settings…") { settingsQueue = queue }
            if queue.id != "main" {
                Button("Remove Queue", role: .destructive) { requestQueueRemoval(queue) }
            }
        }
    }

    private func addQueue() async {
        guard let queue = await engine.createQueue() else { return }
        queueDraftNames[queue.id] = queue.name
        selection = "Queue:\(queue.id)"
        editingQueueID = queue.id
        columnVisibility = .all
    }

    private func saveQueueNames() {
        let drafts = queueDraftNames
        focusedQueueID = nil
        editingQueueID = nil
        Task { await engine.renameQueues(drafts) }
    }

    private func beginRenaming(_ queue: DownloadQueue) {
        guard queue.id != "main" else { return }
        queueDraftNames[queue.id] = queue.name
        selection = "Queue:\(queue.id)"
        editingQueueID = queue.id
    }

    private func requestQueueRemoval(_ queue: DownloadQueue) {
        if engine.jobs.contains(where: { $0.queueID == queue.id && !["completed", "failed", "canceled"].contains($0.state) }) {
            queuePendingRemoval = queue
        } else {
            removeQueue(queue)
        }
    }

    private func removeQueue(_ queue: DownloadQueue) {
        Task {
            if await engine.deleteQueue(queue) {
                NSSound(named: NSSound.Name("Funk"))?.play()
                if selection == "Queue:\(queue.id)" { selection = "Queue:main" }
                queueDraftNames.removeValue(forKey: queue.id)
            }
            queuePendingRemoval = nil
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
        if job.requestedControl == "pause" { return "Pausing…" }
        if job.requestedControl == "cancel" { return "Canceling…" }
        return switch job.state {
        case "downloading": job.torrentActivePeerCount > 0 ? "Downloading" : (job.torrentPeerCount == 0 ? "Finding peers…" : "Connecting")
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
            if hoveredJobID == job.jobID && sortOrderRaw == SortOrder.queue.rawValue {
                VStack(spacing: 0) {
                    queueMoveButton(job, direction: -1, symbol: "chevron.up", title: "Move up in queue")
                    queueMoveButton(job, direction: 1, symbol: "chevron.down", title: "Move down in queue")
                }
                .frame(width: 20)
            } else {
                Color.clear.frame(width: 20, height: 24)
            }
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
        .onHover { hoveredJobID = $0 ? job.jobID : (hoveredJobID == job.jobID ? nil : hoveredJobID) }
    }

    private func queueMoveButton(_ job: DownloadJob, direction: Int, symbol: String, title: String) -> some View {
        Button {
            guard let position = queueMovePosition(for: job, direction: direction) else { return }
            Task { await engine.reorderJob(job, position: position) }
        } label: {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).frame(width: 18, height: 13)
        }
        .buttonStyle(.borderless)
        .disabled(engine.isSubmitting || queueMovePosition(for: job, direction: direction) == nil)
        .help(title)
        .accessibilityLabel("\(title): \(jobTitle(for: job))")
    }

    private func queueMovePosition(for job: DownloadJob, direction: Int) -> Int? {
        let waiting: Set<String> = ["queued", "scheduled", "paused", "retry_wait"]
        guard waiting.contains(job.state),
              let current = engine.jobs.firstIndex(where: { $0.jobID == job.jobID }) else { return nil }
        let indices = engine.jobs.indices.filter { waiting.contains(engine.jobs[$0].state) }
        guard let offset = indices.firstIndex(of: current), indices.indices.contains(offset + direction) else { return nil }
        return indices[offset + direction]
    }

    private func rowControl(for job: DownloadJob) -> (title: String, symbol: String, action: String)? {
        if job.requestedControl != nil { return nil }
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

                if TorrentSource.isTorrent(job.url) || job.torrentPeerCount != nil {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("BitTorrent Swarm").font(.caption.weight(.semibold))
                        inspectorField("Verified", formattedBytes(UInt64(job.completedBytes ?? "0") ?? 0))
                        inspectorField("Discovered", job.torrentPeerCount.map { "\($0) peers" } ?? "Unknown")
                        inspectorField("Seeders", job.torrentSeederCount.map(String.init) ?? "Unknown")
                        inspectorField("Leechers", job.torrentLeecherCount.map(String.init) ?? "Unknown")
                        Text("Swarm counts are reported by trackers, not connected peers.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Divider()
                        Text("Downloading from").font(.caption.weight(.semibold))
                        if job.torrentActivePeerCount > 0, job.state == "downloading" {
                            HStack {
                                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                                Text("\(job.torrentActivePeerCount) connected source\(job.torrentActivePeerCount == 1 ? "" : "s")")
                                Spacer()
                                Text(downloadRate(engine.jobBytesPerSecond[job.jobID] ?? 0)).monospacedDigit()
                            }
                            .font(.caption2)
                            if let peer = job.torrentActivePeer {
                                Text(peer).monospaced().textSelection(.enabled)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        } else {
                            Text(job.state == "downloading" ? "Discovering or connecting to peers…" : "No connected peers")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Divider()
                        Text("Uploading to").font(.caption.weight(.semibold))
                        Text("Verified pieces may be shared with connected peers while downloading. Upload speed is not measured yet.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }

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

                if !TorrentSource.isTorrent(job.url), job.torrentPeerCount == nil, let workers = job.workers, !workers.isEmpty {
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
        if let reference = job.referenceURL, let page = URL(string: reference) {
            Button("Open Reference Page", systemImage: "globe") { NSWorkspace.shared.open(page) }
            if ["paused", "failed", "queued", "scheduled", "retry_wait"].contains(job.state),
               URL(string: job.url)?.scheme?.hasPrefix("http") == true {
                Button("Refresh Download Link…", systemImage: "arrow.clockwise") {
                    Task {
                        if !["paused", "failed"].contains(job.state) {
                            await engine.controlJob(job, action: "pause")
                            guard engine.actionError == nil else { return }
                        }
                        engine.refreshingJobID = job.jobID
                        NSWorkspace.shared.open(page)
                    }
                }
                .help("Click Download on the reference page, then send the fresh link to Speed Download for review.")
            }
        }
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
    @State private var referencePage = ""
    @State private var name = ""
    @State private var destination = "\(NSHomeDirectory())/Downloads"
    @State private var priority = 0
    @AppStorage("lastQueueID") private var queueID = "main"
    @State private var expectedSHA256 = ""
    @State private var validationError: String?
    @State private var probeResult: DownloadProbe?
    @State private var probeError: String?
    @State private var isProbing = false
    @State private var lastSuggestedName: String?
    @State private var selectedTorrentFiles: Set<String> = []
    let initialURL: String
    let replacingJob: DownloadJob?
    let isSubmitting: Bool
    let probeURL: (String) async throws -> DownloadProbe
    let onTorrentSource: (String) -> Void
    let submit: (String, String, String, Int, String?, [String]?, String?, String?, String) async -> Bool

    init(initialURL: String, initialReferenceURL: String? = nil, replacingJob: DownloadJob? = nil, isSubmitting: Bool, probeURL: @escaping (String) async throws -> DownloadProbe,
         onTorrentSource: @escaping (String) -> Void,
         submit: @escaping (String, String, String, Int, String?, [String]?, String?, String?, String) async -> Bool) {
        self.initialURL = initialURL
        self.replacingJob = replacingJob
        if let job = replacingJob {
            _name = State(initialValue: job.name ?? "")
            _destination = State(initialValue: job.destination)
            _priority = State(initialValue: job.priority ?? 0)
            _expectedSHA256 = State(initialValue: job.expectedSHA256 ?? "")
        }
        self.isSubmitting = isSubmitting
        self.probeURL = probeURL
        self.onTorrentSource = onTorrentSource
        self.submit = submit
        _url = State(initialValue: initialURL)
        _referencePage = State(initialValue: initialReferenceURL ?? "")
    }

    private var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(replacingJob == nil ? "Add Download" : "Replace Download Link").font(.title2.weight(.semibold))
                Text(replacingJob == nil ? "Inspect a link, then choose its name, priority, and destination." : "Confirm the fresh link for this download. Restarting removes its old partial data and downloads the file from the beginning.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Form {
                Section("Download source") {
                    TextField("URL", text: $url, prompt: Text("https://example.com/file.zip or magnet:?xt=…"))
                        .textFieldStyle(.roundedBorder)
                    probeSummary
                    TextField("Reference page", text: $referencePage, prompt: Text("Web page containing the download (optional)"))
                        .textFieldStyle(.roundedBorder)
                        .disabled(replacingJob != nil)
                        .help("Saved with the download so you can return to this page to refresh an expired link.")
                }
                Section("File") {
                    TextField("File name", text: $name, prompt: Text("Suggested after URL check"))
                    HStack(spacing: 8) {
                        TextField("Destination folder", text: $destination).textFieldStyle(.roundedBorder)
                        Button("Choose…", action: chooseDestination)
                    }
                }
                .disabled(replacingJob != nil)
                Picker("Queue Priority", selection: $priority) {
                    Text("Low").tag(-1); Text("Normal").tag(0); Text("High").tag(1)
                }
                .disabled(replacingJob != nil)
                Picker("Queue", selection: $queueID) {
                    ForEach(engine.cachedSettings?.queues ?? [.main]) { queue in
                        Text(queue.name).tag(queue.id)
                    }
                }
                .disabled(replacingJob != nil)
                Section("Verification") {
                    TextField("SHA-256 checksum (optional)", text: $expectedSHA256)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                    Text("If provided, the engine checks the completed file against this value.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(replacingJob != nil)
            }
            .disabled(isSubmitting)
            if let validationError { Text(validationError).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button { Task { await save() } } label: {
                    if isSubmitting { ProgressView().controlSize(.small) } else { Text(replacingJob == nil ? "Add to Queue" : "Replace Link & Restart") }
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
            await engine.ensureConnected()
            if let settings = try? await engine.loadSettings() {
                if !settings.queues.contains(where: { $0.id == queueID }) { queueID = "main" }
                if replacingJob == nil, !settings.defaultDownloadFolder.isEmpty,
                   destination == "\(NSHomeDirectory())/Downloads" {
                    destination = settings.defaultDownloadFolder
                }
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
            Text("Enter a link to inspect the download.")
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
        if TorrentSource.isTorrent(value) {
            guard replacingJob == nil else { probeError = "A replacement must be an HTTP or HTTPS link."; return }
            onTorrentSource(value)
            return
        }
        probeResult = nil
        probeError = nil
        selectedTorrentFiles = []
        guard !value.isEmpty else { isProbing = false; return }
        guard let parsed = URL(string: value),
              (["http", "https", "ftp", "ftps"].contains(parsed.scheme?.lowercased() ?? "") && parsed.host != nil || value.lowercased().hasPrefix("magnet:?") || value.lowercased().hasPrefix("torrent-file:///")) else {
            isProbing = false
            probeError = "Enter a valid download link."
            return
        }
        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        guard !Task.isCancelled else { return }
        isProbing = true
        defer { isProbing = false }
        do {
            let result = try await probeURL(value)
            guard !Task.isCancelled, trimmedURL == value else { return }
            if result.contentType?.lowercased().hasPrefix("application/x-bittorrent") == true {
                guard replacingJob == nil else { throw CocoaError(.fileReadUnsupportedScheme) }
                onTorrentSource(value)
                return
            }
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
        if TorrentSource.isTorrent(trimmedURL) || probeResult?.contentType?.lowercased().hasPrefix("application/x-bittorrent") == true {
            onTorrentSource(trimmedURL)
            return
        }
        guard let parsed = URL(string: trimmedURL),
              (["http", "https", "ftp", "ftps"].contains(parsed.scheme?.lowercased() ?? "") && parsed.host != nil || trimmedURL.lowercased().hasPrefix("magnet:?") || trimmedURL.lowercased().hasPrefix("torrent-file:///")) else {
            validationError = "Enter a valid download link."; return
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
        var reference: String? = nil
        let page = referencePage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !page.isEmpty {
            guard page.utf8.count <= 8192, var components = URLComponents(string: page),
                  ["http", "https"].contains(components.scheme?.lowercased() ?? ""), components.host != nil,
                  components.user == nil, components.password == nil,
                  page.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                validationError = "Enter an HTTP or HTTPS reference page without embedded credentials."; return
            }
            components.fragment = nil
            reference = components.url?.absoluteString
        }
        let validQueue = (engine.cachedSettings?.queues ?? [.main]).contains(where: { $0.id == queueID }) ? queueID : "main"
        let added = await submit(trimmedURL, name.trimmingCharacters(in: .whitespacesAndNewlines), path, priority, checksum.isEmpty ? nil : checksum.lowercased(), selectedFiles, probeResult?.torrentInfoHash, reference, validQueue)
        if !added { validationError = engine.actionError ?? "Could not add this download." }
    }
    private func chooseDestination() {
        let panel = NSOpenPanel(); panel.title = "Choose Download Folder"; panel.prompt = "Choose Folder"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: destination, isDirectory: true)
        if panel.runModal() == .OK, let selectedURL = panel.url { destination = selectedURL.path }
    }
}
