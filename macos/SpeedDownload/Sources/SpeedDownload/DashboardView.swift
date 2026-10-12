import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var engine: EngineModel
    @State private var selection: String? = "Downloads"

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
                        emptyDownloads
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
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
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
            Button {} label: {
                Label("Add Download", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(true)
            .help("Download jobs will be available when engine job methods are implemented.")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(.regularMaterial)
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
                Text("Secure local connection established. The engine is ready for job control once job RPCs are available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .disconnected(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Engine unavailable").font(.title3.weight(.semibold))
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Start `speed-download engine`, then reconnect.")
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
            Text("No downloads yet")
                .font(.title3.weight(.semibold))
            Text("The download list will appear here when job storage and IPC controls are available.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
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
