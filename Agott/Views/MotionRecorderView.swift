#if os(iOS)
import SwiftUI

/// Records a set of one exercise from AirPods, with the real count typed
/// after, and lists every recording (the Watch's too) to send to the Mac,
/// where they go into AgottTests/Recordings to tune the rep counter.
struct MotionRecorderView: View {
    @State private var exercise: Exercise = .pushUp
    @State private var recorder: MotionRecorder?
    @State private var motion = HeadphoneMotion.shared
    @State private var pending: MotionRecording?
    @State private var actual = 0
    @State private var files: [(url: URL, recording: MotionRecording)] = []

    var body: some View {
        List {
            Section {
                if let pending {
                    Stepper(value: $actual, in: 0...500) {
                        Text("You did \(actual)").monospacedDigit()
                    }
                    Text("Agott counted \(pending.countedReps) in \(Duration.seconds(pending.duration).formatted(.time(pattern: .minuteSecond))).")
                        .font(.caption).foregroundStyle(Ink.muted)
                    HStack {
                        Button("Discard", role: .destructive) { self.pending = nil }
                        Spacer()
                        Button("Save") { save(pending) }.fontWeight(.semibold)
                    }
                    .buttonStyle(.borderless)
                } else if let recorder, recorder.isRecording {
                    HStack {
                        Text("\(recorder.count)")
                            .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                        Spacer()
                        Text(Duration.seconds(recorder.seconds).formatted(.time(pattern: .minuteSecond)))
                            .monospacedDigit().foregroundStyle(Ink.muted)
                    }
                    Button("Stop", systemImage: "stop.fill", role: .destructive) { stop(recorder) }
                } else {
                    Picker("Exercise", selection: $exercise) {
                        ForEach(Exercise.allCases) { Text($0.name).tag($0) }
                    }
                    Button("Record a set with AirPods", systemImage: "record.circle") { start() }
                        .disabled(!motion.isAvailable)
                }
            } footer: {
                Text("Do one set counting the reps yourself, stop, and type how many you did. Recordings from the Watch (Record motion, on the Watch) arrive here too.")
            }

            if !files.isEmpty {
                Section {
                    ForEach(files, id: \.url) { file in
                        ShareLink(item: file.url) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(file.recording.exercise.name), \(file.recording.sensor == .watch ? "Watch" : "AirPods")")
                                    .foregroundStyle(Ink.text)
                                Text("Counted \(file.recording.countedReps), real \(file.recording.actualReps ?? 0) · \(file.recording.recordedAt.formatted(.dateTime.day().month().hour().minute()))")
                                    .font(.caption).foregroundStyle(Ink.muted)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { try? FileManager.default.removeItem(at: files[index].url) }
                        reload()
                    }
                } header: {
                    HStack {
                        Text("Recordings")
                        Spacer()
                        ShareLink(items: files.map(\.url)) { Text("Share all") }.font(.caption)
                    }
                } footer: {
                    Text("AirDrop them to your Mac, into AgottTests/Recordings in the project.")
                }
            }
        }
        .navigationTitle("Record motion")
        .onAppear(perform: reload)
        .refreshable { reload() }
        .onDisappear { if let recorder, recorder.isRecording { stop(recorder) } }
    }

    private func start() {
        let recorder = MotionRecorder(exercise: exercise, sensor: .airpods)
        recorder.begin()
        self.recorder = recorder
        motion.start { gravity, acceleration, time in
            recorder.add(gravity: gravity, acceleration: acceleration, at: time)
        }
    }

    private func stop(_ recorder: MotionRecorder) {
        motion.stop()
        let recording = recorder.finish(device: "AirPods")
        actual = recording.countedReps
        pending = recording
    }

    private func save(_ recording: MotionRecording) {
        var recording = recording
        recording.actualReps = actual
        try? recording.save()
        pending = nil
        reload()
    }

    private func reload() { files = MotionRecording.all() }
}
#endif
