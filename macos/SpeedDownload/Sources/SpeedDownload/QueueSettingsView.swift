import SwiftUI

struct QueueSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var queue: DownloadQueue
    @State private var days: [QueueDay]
    let save: (DownloadQueue) -> Void

    private static let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    init(queue: DownloadQueue, save: @escaping (DownloadQueue) -> Void) {
        var queue = queue
        if queue.finishAction == "custom_app", let path = queue.customApp {
            queue.finishAction = "user_command"
            queue.userCommand = "open " + Self.shellQuoted(path)
            queue.customApp = nil
        }
        _queue = State(initialValue: queue)
        _days = State(initialValue: (0..<7).map { day in
            let slots = Array(queue.scheduleSlots.dropFirst(day * 24).prefix(24))
            let first = slots.firstIndex(of: true)
            let last = slots.lastIndex(of: true)
            return QueueDay(enabled: first != nil, start: first ?? 0, stop: (last ?? 23) + 1)
        })
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
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Start and stop this queue on a schedule", isOn: $queue.scheduleEnabled)
                    ForEach(days.indices, id: \.self) { index in
                        HStack {
                            Toggle(Self.names[index], isOn: $days[index].enabled)
                                .frame(width: 125, alignment: .leading)
                                .disabled(!queue.scheduleEnabled)
                            Picker("Start", selection: $days[index].start) {
                                ForEach(0..<24, id: \.self) { hour in Text(Self.hourLabel(hour)).tag(hour) }
                            }
                            .frame(width: 165)
                            .disabled(!queue.scheduleEnabled || !days[index].enabled)
                            Picker("Stop", selection: $days[index].stop) {
                                ForEach(1...24, id: \.self) { hour in Text(Self.hourLabel(hour)).tag(hour) }
                            }
                            .frame(width: 165)
                            .disabled(!queue.scheduleEnabled || !days[index].enabled)
                        }
                    }
                    Text("Hours use your Mac’s local time. To span midnight, set both days.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
            }
            GroupBox("When all downloads finish") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Action", selection: $queue.finishAction) {
                        Text("Do nothing").tag("none")
                        Text("Quit Speed Download").tag("quit_app")
                        Text("Shut down this Mac").tag("power_off")
                        Text("User command").tag("user_command")
                    }
                    if queue.finishAction == "user_command" {
                        TextField("Shell command", text: Binding(
                            get: { queue.userCommand ?? "" },
                            set: { queue.userCommand = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Text("Runs with /bin/sh when this queue finishes. Commands run as your user account.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    queue.scheduleSlots = days.flatMap { day in
                        (0..<24).map { day.enabled && $0 >= day.start && $0 < day.stop }
                    }
                    save(queue)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(queue.finishAction == "user_command" && (queue.userCommand ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 660)
    }

    private static func hourLabel(_ hour: Int) -> String { String(format: "%02d:00", hour) }
    private static func shellQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private struct QueueDay {
    var enabled: Bool
    var start: Int
    var stop: Int
}
