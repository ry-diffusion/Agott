import Foundation
import Observation

/// Raw motion from one set, with the real number of reps typed by the
/// person who did them: what the rep counter is tuned and tested on.
///
/// Recorded on the Watch (wrist) or the iPhone (AirPods), saved as JSON in
/// Documents/Recordings, sent from the Watch to the iPhone, and from there
/// (Files, AirDrop) into `AgottTests/Recordings`, where a test replays every
/// one and checks the count.
nonisolated struct MotionRecording: Codable, Sendable, Identifiable, Hashable {
    var id = UUID()
    var exercise: Exercise
    var sensor: MotionSensor
    /// "Apple Watch Series 11", "AirPods Pro"…
    var device: String
    var recordedAt: Date
    /// What the person counted themselves.
    var actualReps: Int?
    /// What the counter said while recording.
    var countedReps: Int
    var note: String?
    /// Each sample: seconds since the start, gravity x y z, user acceleration x y z (g).
    var samples: [[Double]]

    var duration: TimeInterval { samples.last?.first ?? 0 }

    /// The counter run again over the samples.
    func replay(_ settings: RepCounter.Settings? = nil) -> Int {
        var counter = RepCounter(settings ?? .for(exercise, sensor: sensor))
        for sample in samples where sample.count == 7 {
            let gravity = Vec3(sample[1], sample[2], sample[3])
            let acceleration = Vec3(sample[4], sample[5], sample[6])
            counter.add(counter.settings.channel == .tilt ? gravity : acceleration, at: sample[0])
        }
        return counter.count
    }

    var fileName: String {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: recordedAt)
        let stamp = String(format: "%04d%02d%02d-%02d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                           parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        return "\(exercise.rawValue)-\(sensor.rawValue)-\(stamp)-\(id.uuidString.prefix(4)).json"
    }

    static var folder: URL { URL.documentsDirectory.appending(path: "Recordings") }

    @discardableResult
    func save(in folder: URL = MotionRecording.folder) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: fileName)
        try JSONEncoder.sync.encode(self).write(to: url, options: .atomic)
        return url
    }

    static func load(_ url: URL) -> MotionRecording? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.sync.decode(MotionRecording.self, from: $0) }
    }

    /// Every recording in a folder, newest first.
    static func all(in folder: URL = MotionRecording.folder) -> [(url: URL, recording: MotionRecording)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { url in load(url).map { (url, $0) } }
            .sorted { $0.recording.recordedAt > $1.recording.recordedAt }
    }
}

/// Records while counting, so the person sees the count they will correct.
@MainActor @Observable
final class MotionRecorder {
    let exercise: Exercise
    let sensor: MotionSensor
    private(set) var count = 0
    private(set) var isRecording = false
    private(set) var seconds = 0.0

    @ObservationIgnored private var counter: RepCounter
    @ObservationIgnored private var samples: [[Double]] = []
    @ObservationIgnored private var start: TimeInterval?
    @ObservationIgnored private var startedAt = Date()
    /// An hour at 50 Hz, at most.
    private static let limit = 50 * 3600

    init(exercise: Exercise, sensor: MotionSensor) {
        self.exercise = exercise
        self.sensor = sensor
        counter = RepCounter(exercise: exercise, sensor: sensor)
    }

    func begin() {
        samples = []
        start = nil
        count = 0
        seconds = 0
        counter = RepCounter(exercise: exercise, sensor: sensor)
        startedAt = Date()
        isRecording = true
    }

    func add(gravity: Vec3, acceleration: Vec3, at time: TimeInterval) {
        guard isRecording, samples.count < Self.limit else { return }
        let t0 = start ?? time
        start = t0
        let t = time - t0
        func round(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }
        samples.append([round(t), round(gravity.x), round(gravity.y), round(gravity.z),
                        round(acceleration.x), round(acceleration.y), round(acceleration.z)])
        if counter.add(counter.settings.channel == .tilt ? gravity : acceleration, at: t) { count = counter.count }
        if samples.count % 25 == 0 { seconds = t }
    }

    /// Stops; the recording waits for the real count before it is saved.
    func finish(device: String) -> MotionRecording {
        isRecording = false
        return MotionRecording(exercise: exercise, sensor: sensor, device: device, recordedAt: startedAt,
                               actualReps: nil, countedReps: count, samples: samples)
    }
}
