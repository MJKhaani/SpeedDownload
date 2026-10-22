import AppKit
import SwiftUI

struct BatchDownloadView: View {
    @EnvironmentObject private var engine: EngineModel
    @Environment(\.dismiss) private var dismiss
    let sources: [String]
    let reviewTorrent: (String, String, Int) -> Void
    @State private var selected: Set<String> = []
    @State private var destination = "\(NSHomeDirectory())/Downloads"
    @State private var priority = 0
    @State private var isAdding = false
    @State private var stopRequested = false
    @State private var settingsLoaded = false
    @State private var completed: Set<String> = []
    @State private var failures: [String: String] = [:]
    @State private var error: String?
    @State private var filter = ""

    private var uniqueSources: [String] {
        var seen = Set<String>()
        return sources.filter { seen.insert($0).inserted }
    }
    private var visibleSources: [String] {
        uniqueSources.filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Multiple Downloads").font(.title2.weight(.semibold))
            Text("Choose the links you want to download.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("Filter links", text: $filter).textFieldStyle(.roundedBorder)
                Button("All") { selected.formUnion(visibleSources.filter { !completed.contains($0) }) }
                Button("None") { selected.subtract(visibleSources) }
            }
            .disabled(isAdding)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleSources, id: \.self) { source in
                        HStack(alignment: .center, spacing: 8) {
                            Toggle("Include \(title(source))", isOn: Binding(
                                get: { selected.contains(source) },
                                set: { included in
                                    if included { selected.insert(source) } else { selected.remove(source) }
                                }
                            )).labelsHidden().toggleStyle(.checkbox)
                            Image(systemName: TorrentSource.isTorrent(source) ? "point.3.connected.trianglepath.dotted" : "doc")
                                .foregroundStyle(.secondary).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(source)).lineLimit(1).truncationMode(.middle)
                                Text(URL(string: source)?.host ?? "Magnet link").font(.caption).foregroundStyle(.secondary)
                                if let failure = failures[source] {
                                    Text(failure).font(.caption).foregroundStyle(.red).lineLimit(2)
                                }
                            }
                            Spacer()
                            if completed.contains(source) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        }
                        .font(.system(size: 12)).padding(.vertical, 7).padding(.horizontal, 8)
                        .disabled(completed.contains(source))
                        .disabled(isAdding)
                        .help(source)
                        Divider()
                    }
                }
            }
            .frame(height: 300)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
            Form {
                HStack {
                    TextField("Save to", text: $destination).textFieldStyle(.roundedBorder)
                    Button("Choose…", action: chooseDestination)
                }
                Picker("Queue Priority", selection: $priority) {
                    Text("Low").tag(-1); Text("Normal").tag(0); Text("High").tag(1)
                }
            }
            .disabled(isAdding)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Text("\(selected.count) of \(uniqueSources.count) selected").font(.caption).foregroundStyle(.secondary)
                if isAdding { ProgressView().controlSize(.small) }
                Spacer()
                Button(isAdding ? (stopRequested ? "Stopping…" : "Stop") : (completed.isEmpty ? "Cancel" : "Done")) {
                    if isAdding { stopRequested = true } else { dismiss() }
                }
                .disabled(stopRequested && isAdding).keyboardShortcut(.cancelAction)
                Button("Add Selected") { Task { await addSelected() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(isAdding || selected.isEmpty || !settingsLoaded)
            }
        }
        .padding(20).frame(width: 700)
        .interactiveDismissDisabled(isAdding)
        .task {
            selected = Set(uniqueSources)
            await engine.ensureConnected()
            if let settings = try? await engine.loadSettings(), !settings.defaultDownloadFolder.isEmpty,
               destination == "\(NSHomeDirectory())/Downloads" { destination = settings.defaultDownloadFolder }
            settingsLoaded = true
        }
    }

    private func title(_ source: String) -> String {
        guard let url = URL(string: source) else { return source }
        if url.scheme?.lowercased() == "magnet" {
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "dn" })?.value ?? "Magnet torrent"
        }
        return url.lastPathComponent.isEmpty ? (url.host ?? source) : url.lastPathComponent
    }

    private func addSelected() async {
        guard !isAdding else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination, isDirectory: &isDirectory), isDirectory.boolValue else {
            error = "Choose an existing download folder."; return
        }
        isAdding = true
        stopRequested = false
        error = nil
        defer { isAdding = false }
        for source in uniqueSources where selected.contains(source) {
            if stopRequested { break }
            var torrent = TorrentSource.isTorrent(source)
            if !torrent, let probe = try? await engine.probe(url: source) {
                torrent = probe.contentType?.lowercased().hasPrefix("application/x-bittorrent") == true
            }
            if stopRequested { break }
            if torrent {
                reviewTorrent(source, destination, priority)
                completed.insert(source)
                selected.remove(source)
                continue
            }
            let success = await engine.addJob(url: source, name: "", destination: destination, priority: priority)
            if success {
                completed.insert(source)
                selected.remove(source)
                failures[source] = nil
            } else {
                failures[source] = engine.actionError ?? "Could not add this link."
            }
        }
        if selected.isEmpty { dismiss() }
        else if stopRequested { error = "Stopped. Remaining links are still selected." }
        else { error = "Some links could not be added. You can retry the selected links." }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "Choose Folder"
        panel.directoryURL = URL(fileURLWithPath: destination)
        if panel.runModal() == .OK, let folder = panel.url { destination = folder.path }
    }
}
