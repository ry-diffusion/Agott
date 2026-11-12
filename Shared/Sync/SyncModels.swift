import Foundation

/// A daily routine as every device sees it.
nonisolated struct RoutineRecord: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var hour: Int
    var minute: Int
    /// What to do, in Markdown.
    var steps: String?
    /// What Agott says when it is put off, sharper each time.
    var nagLines: [String] = []
    /// Stopped routines stay as a record so every device stops them too.
    var stopped = false
    /// The last change wins.
    var updatedAt: Date

    var plan: WorkoutPlan { WorkoutPlan.parse(steps) }
    var time: String { String(format: "%02d:%02d", hour, minute) }

    static func name(_ id: UUID) -> String { "routine/\(id.uuidString)" }
}

/// Reps counted for one exercise of a workout.
nonisolated struct ExerciseCount: Codable, Hashable, Sendable {
    var exercise: Exercise
    var target: Int
    var counted: Int
    var sensor: MotionSensor
}

/// What shows a routine was really done: the reps counted against its
/// steps, the steps ticked by hand, and when.
nonisolated struct WorkoutProof: Codable, Hashable, Sendable {
    var counts: [ExerciseCount]
    /// Steps (by index) ticked by hand.
    var ticked: [Int] = []
    var started: Date
    var ended: Date
    /// How far the watch went up and down (metres), from the barometer.
    var heightSwing: Double?

    /// "30/30 push-ups, 45/48 squats".
    var summary: String {
        counts.map { "\($0.counted)/\($0.target) \($0.exercise.name.lowercased())" }.joined(separator: ", ")
    }
}

/// A day a routine was done. Grow-only, so devices never disagree: the same
/// day marked done twice is the same record.
nonisolated struct DoneRecord: Codable, Hashable, Sendable {
    var routineID: UUID
    /// The day, in the time zone of the device that marked it (yyyy-MM-dd).
    var day: String
    var at: Date
    /// "Watch", "iPhone", "Mac".
    var device: String
    var proof: WorkoutProof?

    static func name(_ routineID: UUID, day: String) -> String { "done/\(routineID.uuidString)/\(day)" }
}

/// API keys, so the iPhone and Watch work without the Mac. Keyed by the
/// Keychain account they live under.
nonisolated struct KeysRecord: Codable, Hashable, Sendable {
    var values: [String: String]
    var updatedAt: Date

    static let name = "keys"
    /// The keys that travel.
    static let accounts = ["opencode-api-key", "typesafe-api-key"]
}

/// What is inside a sealed record.
nonisolated enum SyncPayload: Codable, Hashable, Sendable {
    case routine(RoutineRecord)
    case done(DoneRecord)
    case keys(KeysRecord)

    var name: String {
        switch self {
        case .routine(let routine): RoutineRecord.name(routine.id)
        case .done(let done): DoneRecord.name(done.routineID, day: done.day)
        case .keys: KeysRecord.name
        }
    }

    /// Two copies of one record: the one to keep.
    static func newer(_ a: SyncPayload, _ b: SyncPayload) -> SyncPayload {
        switch (a, b) {
        case (.routine(let x), .routine(let y)): x.updatedAt >= y.updatedAt ? a : b
        case (.keys(let x), .keys(let y)): x.updatedAt >= y.updatedAt ? a : b
        // A day done stays done; the copy with proof is the better one.
        case (.done(let x), .done(let y)): x.proof != nil || y.proof == nil ? a : b
        default: a
        }
    }
}

nonisolated enum RoutineDays {
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Days in a row ending today, or yesterday if today is not done yet.
    static func streak(_ days: Set<String>, today: Date = Date(), calendar: Calendar = .current) -> Int {
        var date = today
        if !days.contains(day(date, calendar: calendar)) {
            date = calendar.date(byAdding: .day, value: -1, to: date)!
        }
        var count = 0
        while days.contains(day(date, calendar: calendar)) {
            count += 1
            date = calendar.date(byAdding: .day, value: -1, to: date)!
        }
        return count
    }

    /// The last `count` days ending at `last`, for routines whose streak was
    /// kept before days were.
    static func days(ending last: Date, count: Int, calendar: Calendar = .current) -> [String] {
        (0..<max(count, 0)).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: last).map { day($0, calendar: calendar) }
        }
    }
}
