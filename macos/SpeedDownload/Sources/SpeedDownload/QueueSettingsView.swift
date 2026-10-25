import SwiftUI

struct QueueSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var queue: DownloadQueue
    @State private var selectedDays: Set<Int>
    @State private var startHour: Int
    @State private var stopHour: Int
    let save: (DownloadQueue) -> Void

    private static let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    init(queue: DownloadQueue, save: @escaping (DownloadQueue) -> Void) {
        var queue = queue
        if queue.finishAction == "custom_app", let path = queue.customApp {
            queue.finishAction = "user_command"
            queue.userCommand = "open " + Self.shellQuoted(path)
            queue.customApp = nil
        }
        _queue = State(initialValue: queue)
        let activeDays = Set((0..<7).filter { day in
            queue.scheduleSlots.dropFirst(day * 24).prefix(24).contains(true)
        })
        _selectedDays = State(initialValue: activeDays)
        let firstDay = activeDays.sorted().first ?? 0
        let hours = Array(queue.scheduleSlots.dropFirst(firstDay * 24).prefix(24))
        _startHour = State(initialValue: hours.firstIndex(of: true) ?? 0)
        _stopHour = State(initialValue: (hours.lastIndex(of: true) ?? 23) + 1)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(queue.name) Settings").font(.title2.weight(.semibold))
            GroupBox("Downloads") {
                Stepper(value: $queue.maxActive, in: 1...32) {
                    LabeledContent("Active downloads", value: "\(queue.maxActive)")
                }
                .padding(6)
            }
            GroupBox("Schedule") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Start and stop this queue on a schedule", isOn: $queue.scheduleEnabled)
                    HStack(spacing: 6) {
                        ForEach(0..<7, id: \.self) { day in
                            Toggle(isOn: Binding(
                                get: { selectedDays.contains(day) },
                                set: { enabled in
                                    if enabled { selectedDays.insert(day) }
                                    else { selectedDays.remove(day) }
                                }
                            )) {
                                Text(Self.names[day]).frame(width: 32)
                            }
                            .toggleStyle(.button)
                            .tint(.accentColor)
                            .accessibilityLabel(Self.names[day])
                        }
                    }
                    .disabled(!queue.scheduleEnabled)
                    HStack(spacing: 20) {
                        Picker("Start", selection: $startHour) {
                            ForEach(0..<24, id: \.self) { hour in Text(Self.hourLabel(hour)).tag(hour) }
                        }
                        Picker("Stop", selection: $stopHour) {
                            ForEach((startHour + 1)...24, id: \.self) { hour in Text(Self.hourLabel(hour)).tag(hour) }
                        }
                    }
                    .disabled(!queue.scheduleEnabled || selectedDays.isEmpty)
                    Text("The queue runs between these hours on the selected days, using local time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
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
                        Text("Runs with /bin/sh as your user account when the queue finishes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    queue.scheduleSlots = (0..<7).flatMap { day in
                        (0..<24).map { hour in selectedDays.contains(day) && hour >= startHour && hour < stopHour }
                    }
                    save(queue)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(queue.scheduleEnabled && selectedDays.isEmpty || queue.finishAction == "user_command" && (queue.userCommand ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 570)
        .onChange(of: startHour) { _, newValue in
            if stopHour <= newValue { stopHour = min(24, newValue + 1) }
        }
    }

    private static func hourLabel(_ hour: Int) -> String { String(format: "%02d:00", hour) }
    private static func shellQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
