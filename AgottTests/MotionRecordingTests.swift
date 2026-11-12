import Foundation
import Testing
@testable import Agott

struct MotionRecordingTests {
    /// Made-up motion through the recorder, saved, read back and replayed.
    @Test @MainActor func recordingsRoundTripAndReplay() throws {
        let workout = SyntheticWorkout(reps: 10, seed: 4)
        let recorder = MotionRecorder(exercise: .pushUp, sensor: .watch)
        recorder.begin()
        for sample in workout.tilt(degrees: 25) {
            recorder.add(gravity: sample.v, acceleration: .zero, at: 1_000 + sample.t)
        }
        var recording = recorder.finish(device: "Test")
        recording.actualReps = 10
        #expect(recording.countedReps == 10)
        #expect(recording.samples.first?.first == 0)

        let folder = FileManager.default.temporaryDirectory.appending(path: "agott-recordings-\(UUID().uuidString)")
        let url = try recording.save(in: folder)
        #expect(url.lastPathComponent.hasPrefix("pushUp-watch-"))
        let loaded = try #require(MotionRecording.all(in: folder).first?.recording)
        #expect(loaded.actualReps == 10)
        #expect(loaded.replay() == 10)
    }

    /// Every real set in AgottTests/Recordings, counted again.
    @Test func recordedSetsCountRight() {
        let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Recordings")
        let recordings = MotionRecording.all(in: folder).filter { $0.recording.actualReps != nil }
        for (url, recording) in recordings {
            let actual = recording.actualReps ?? 0
            let counted = recording.replay()
            let allowed = max(1, actual / 10)
            print("\(url.lastPathComponent): counted \(counted), real \(actual)")
            #expect(abs(counted - actual) <= allowed,
                    "\(url.lastPathComponent): counted \(counted) of \(actual) \(recording.exercise.rawValue) (\(recording.sensor.rawValue))")
        }
    }
}
