import SwiftUI
import WatchKit

/// Records a set of one exercise from the wrist, with the real count typed
/// after, and sends it to the iPhone: real motion to tune the rep counter on.
struct RecorderView: View {
    @State private var exercise: Exercise = .pushUp
    @State private var recorder: MotionRecorder?
    @State private var wrist = WristWorkout()
    @State private var pending: MotionRecording?
    @State private var actual = 0
    @State private var sent = 0

    var body: some View {
        Group {
            if let pending {
                confirm(pending)
            } else if let recorder, recorder.isRecording {
                recording(recorder)
            } else {
                setup
            }
        }
        .navigationTitle("Record motion")
    }

    private var setup: some View {
        List {
            Picker("Exercise", selection: $exercise) {
                ForEach(Exercise.allCases) { Label($0.name, systemImage: $0.symbol).tag($0) }
            }
            Button {
                let recorder = MotionRecorder(exercise: exercise, sensor: .watch)
                recorder.begin()
                self.recorder = recorder
                Task {
                    await wrist.start(onSample: { gravity, acceleration, time in
                        recorder.add(gravity: gravity, acceleration: acceleration, at: time)
                    })
                }
            } label: {
                Label("Record a set", systemImage: "record.circle")
            }
            .tint(.red)
            Text("Do one set, counting the reps yourself, then stop and type how many you did.")
                .font(.footnote).foregroundStyle(.secondary)
            if sent > 0 {
                Text("Sent to your iPhone: \(sent)").font(.footnote).foregroundStyle(.green)
            }
        }
    }

    private func recording(_ recorder: MotionRecorder) -> some View {
        VStack(spacing: 6) {
            Label(exercise.name, systemImage: exercise.symbol).font(.footnote).foregroundStyle(.secondary)
            Text("\(recorder.count)")
                .font(.system(size: 56, weight: .semibold, design: .rounded).monospacedDigit())
            Text(Duration.seconds(recorder.seconds).formatted(.time(pattern: .minuteSecond)))
                .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            Button("Stop", systemImage: "stop.fill") {
                let recording = recorder.finish(device: WKInterfaceDevice.current().model)
                actual = recording.countedReps
                pending = recording
                Task { await wrist.end() }
            }
            .tint(.red)
        }
    }

    private func confirm(_ recording: MotionRecording) -> some View {
        VStack(spacing: 6) {
            Text("How many did you do?").font(.footnote)
            Text("\(actual)")
                .font(.system(size: 48, weight: .semibold, design: .rounded).monospacedDigit())
                .focusable()
                .digitalCrownRotation(detent: $actual, from: 0, through: 300, by: 1, sensitivity: .medium)
            Text("Agott counted \(recording.countedReps)").font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("Discard", role: .destructive) { pending = nil }
                Button("Save") {
                    var recording = recording
                    recording.actualReps = actual
                    if let url = try? recording.save() {
                        WatchLink.shared.sendRecording(url)
                        sent += 1
                    }
                    pending = nil
                }
                .tint(.green)
            }
        }
    }
}
