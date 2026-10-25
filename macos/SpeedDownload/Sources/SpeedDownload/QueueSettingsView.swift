import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct QueueSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var queue: DownloadQueue
    let save: (DownloadQueue) -> Void

    init(queue: DownloadQueue, save: @escaping (DownloadQueue) -> Void) {
        _queue = State(initialValue: queue)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(queue.name) Settings").font(.title2.weight(.semibold))
            GroupBox("Downloads") {
                Stepper(value: $queue.maxActive, in: 1...32) {
                    LabeledContent("Active downloads", value: "\(queue.maxActive)")
                }
                .padding(6)
            }
            GroupBox("Schedule") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Start and stop this queue on a schedule", isOn: $queue.scheduleEnabled)
                    Text("Blue hours allow downloads in this queue. Other queues keep their own schedules.")
                        .font(.caption).foregroundStyle(.secondary)
                    QueueScheduleGrid(slots: $queue.scheduleSlots)
                        .disabled(!queue.scheduleEnabled)
                }
                .padding(6)
            }
            GroupBox("When all downloads finish") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Action", selection: $queue.finishAction) {
                        Text("Do nothing").tag("none")
                        Text("Quit Speed Download").tag("quit_app")
                        Text("Shut down this Mac").tag("power_off")
                        Text("Open an application").tag("custom_app")
                    }
                    if queue.finishAction == "custom_app" {
                        HStack {
                            Text(queue.customApp ?? "Choose an application").lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Choose…") { chooseApplication() }
                        }
                    }
                }
                .padding(6)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save(queue); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(queue.finishAction == "custom_app" && queue.customApp == nil)
            }
        }
        .padding(20)
        .frame(width: 610)
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { queue.customApp = panel.url?.path }
    }
}
