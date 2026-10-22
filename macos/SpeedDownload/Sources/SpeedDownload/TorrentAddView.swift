import AppKit
import SwiftUI

/// Classifies OS-opened files, browser handoffs, and pasted torrent sources.
enum TorrentSource {
    static func normalized(_ value: String) -> String? {
        let source = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.utf8.count <= 8192, let url = URL(string: source) else { return nil }
        if url.isFileURL {
            guard url.pathExtension.lowercased() == "torrent",
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            components.scheme = "torrent-file"
            return components.url?.absoluteString
        }
        guard ["http", "https", "ftp", "ftps", "magnet", "torrent-file"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        if ["http", "https", "ftp", "ftps"].contains(url.scheme?.lowercased() ?? ""), url.host == nil { return nil }
        return source
    }

    static func isTorrent(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return ["magnet", "torrent-file"].contains(url.scheme?.lowercased() ?? "") || url.pathExtension.lowercased() == "torrent"
    }
}

struct TorrentAddView: View {
    @EnvironmentObject private var engine: EngineModel
    @Environment(\.dismiss) private var dismiss
    let source: String
    let added: () -> Void
    @State private var preview: DownloadProbe?
    @State private var files: [DownloadProbe.TorrentFile] = []
    @State private var selected: Set<String> = []
    @State private var name = ""
    @State private var destination = "\(NSHomeDirectory())/Downloads"
    @State private var priority = 0
    @State private var trackers = ""
    @State private var originalTrackers: [String] = []
    @State private var trackerEdits = false
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var error: String?
    @State private var metadataAttempt = 0
    @State private var tab = "files"

    private var trackerURLs: [String] {
        var seen = Set<String>()
        return trackers.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.title).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add Torrent").font(.title2.weight(.semibold))
                    Text(preview?.suggestedName ?? "Retrieving torrent metadata…")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if preview?.torrentPrivate == true { Text("Private").font(.caption).foregroundStyle(.secondary) }
            }
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(files.isEmpty ? "Loading file list from the engine…" : "Loading files (\(files.count))…")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            TabView(selection: $tab) {
                fileList.tabItem { Text("Files") }.tag("files")
                VStack(alignment: .leading, spacing: 8) {
                    Text("One tracker URL per line (HTTP, HTTPS, or UDP).")
                        .font(.callout).foregroundStyle(.secondary)
                    TextEditor(text: $trackers)
                        .font(.system(size: 12))
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
                        .onChange(of: trackers) { _, _ in trackerEdits = true }
                    if preview == nil && !isLoading {
                        Button("Retry Metadata with These Trackers") { metadataAttempt += 1 }
                    }
                }
                .padding(12)
                .tabItem { Text("Trackers") }.tag("trackers")
            }
            .frame(height: 260)
            Form {
                TextField("Name", text: $name)
                HStack {
                    TextField("Save to", text: $destination).textFieldStyle(.roundedBorder)
                    Button("Choose…", action: chooseDestination)
                }
                Picker("Queue Priority", selection: $priority) {
                    Text("Low").tag(-1); Text("Normal").tag(0); Text("High").tag(1)
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .lineLimit(4)
            }
            HStack {
                if preview == nil && !isLoading {
                    Button("Retry") { metadataAttempt += 1 }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to Queue") { Task { await save() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(isLoading || isSaving || preview == nil || selected.isEmpty)
            }
        }
        .padding(20).frame(width: 640)
        .disabled(isSaving)
        .task(id: metadataAttempt) { await loadMetadata() }
    }

    private var fileList: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(selected.count) of \(files.count) files selected").foregroundStyle(.secondary)
                Spacer()
                Button("All") { selected = Set(files.map(\.path)) }
                Button("None") { selected.removeAll() }
            }
            .font(.caption).disabled(isLoading)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(files, id: \.path) { file in
                        HStack(spacing: 8) {
                            Toggle(file.path, isOn: Binding(
                                get: { selected.contains(file.path) },
                                set: { enabled in
                                    if enabled { selected.insert(file.path) } else { selected.remove(file.path) }
                                }
                            )).toggleStyle(.checkbox).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 6)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(file.length) ?? 0, countStyle: .file))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.system(size: 12))
                        .padding(.vertical, 2)
                    }
                }
            }
            if !files.isEmpty {
                let bytes = files.filter { selected.contains($0.path) }.reduce(Int64(0)) { $0 + (Int64($1.length) ?? 0) }
                Text("Selected: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(12)
    }

    private func loadMetadata() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        await engine.ensureConnected()
        if let settings = try? await engine.loadSettings(), !settings.defaultDownloadFolder.isEmpty,
           destination == "\(NSHomeDirectory())/Downloads" { destination = settings.defaultDownloadFolder }
        do {
            let result = try await engine.prepareTorrent(url: source, trackers: trackerEdits ? trackerURLs : nil)
            guard !Task.isCancelled else { return }
            preview = result
            files = result.torrentFiles ?? []
            name = result.suggestedName
            originalTrackers = result.torrentTrackers ?? []
            trackers = originalTrackers.joined(separator: "\n")
            trackerEdits = false
            var next = result.torrentNextOffset
            var previous = 0
            while let raw = next {
                guard let offset = Int(raw), offset > previous, offset <= 10_000 else { throw CocoaError(.fileReadCorruptFile) }
                let page = try await engine.prepareTorrent(url: result.finalURL, offset: offset)
                guard !Task.isCancelled, page.torrentInfoHash == result.torrentInfoHash else { return }
                files.append(contentsOf: page.torrentFiles ?? [])
                previous = offset
                next = page.torrentNextOffset
            }
            guard files.count == result.torrentFileCount else { throw CocoaError(.fileReadCorruptFile) }
            selected = Set(files.map(\.path))
        } catch {
            guard !Task.isCancelled else { return }
            preview = nil
            self.error = error.localizedDescription
            tab = "trackers"
            if trackers.isEmpty, let components = URLComponents(string: source) {
                trackers = (components.queryItems ?? []).filter { $0.name == "tr" }.compactMap(\.value).joined(separator: "\n")
            }
        }
    }

    private func save() async {
        guard !isSaving else { return }
        guard let preview else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination, isDirectory: &isDirectory), isDirectory.boolValue else {
            error = "Choose an existing download folder."; return
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "Enter a torrent name."; return }
        guard trackerURLs.count <= 32 else { error = "Use at most 32 trackers."; return }
        isSaving = true
        defer { isSaving = false }
        do {
            let prepared = trackerURLs == originalTrackers ? preview : try await engine.prepareTorrent(url: preview.finalURL, trackers: trackerURLs)
            let chosen = files.map(\.path).filter { selected.contains($0) }
            let success = await engine.addJob(url: prepared.finalURL, name: name.trimmingCharacters(in: .whitespacesAndNewlines), destination: destination, priority: priority,
                selectedTorrentFiles: chosen.count == files.count ? nil : chosen, torrentInfoHash: prepared.torrentInfoHash)
            if success { added() } else { error = engine.actionError ?? "Could not add the torrent." }
        } catch { self.error = error.localizedDescription }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "Choose Folder"
        panel.directoryURL = URL(fileURLWithPath: destination)
        if panel.runModal() == .OK, let url = panel.url { destination = url.path }
    }
}
