import Foundation

/// One set: reps of one exercise in a row, until a rest or another exercise.
nonisolated struct WorkoutSet: Codable, Hashable, Sendable {
    var exercise: Exercise
    var reps: Int
    /// The first and last rep.
    var start: Date
    var end: Date
    /// Rest since the set before (any exercise), if there was one.
    var restBefore: TimeInterval?
    /// Average heart rate during the set (bpm), from the Watch.
    var heartRate: Double?

    var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Seconds from one rep to the next.
    var secondsPerRep: Double? { reps > 1 ? duration / Double(reps - 1) : nil }

    /// A pause longer than this between two reps ends the set.
    static let restGap: TimeInterval = 15

    /// Rep times (in order) as sets: a new set after a rest or when the
    /// exercise changes.
    static func split(_ reps: [(exercise: Exercise, at: Date)], restGap: TimeInterval = restGap) -> [WorkoutSet] {
        var sets: [WorkoutSet] = []
        for rep in reps.sorted(by: { $0.at < $1.at }) {
            if var last = sets.last, last.exercise == rep.exercise, rep.at.timeIntervalSince(last.end) <= restGap {
                last.reps += 1
                last.end = rep.at
                sets[sets.count - 1] = last
            } else {
                let rest = sets.last.map { rep.at.timeIntervalSince($0.end) }
                sets.append(WorkoutSet(exercise: rep.exercise, reps: 1, start: rep.at, end: rep.at, restBefore: rest))
            }
        }
        return sets
    }

    /// Each set's average heart rate from samples (time, bpm) taken during it.
    static func withHeartRates(_ sets: [WorkoutSet], samples: [(at: Date, bpm: Double)]) -> [WorkoutSet] {
        sets.map { set in
            var set = set
            let during = samples.filter { $0.at >= set.start.addingTimeInterval(-3) && $0.at <= set.end.addingTimeInterval(3) }
            set.heartRate = during.isEmpty ? nil : during.map(\.bpm).reduce(0, +) / Double(during.count)
            return set
        }
    }
}

/// How one exercise went in one workout.
nonisolated struct ExerciseEfficiency: Hashable, Sendable, Identifiable {
    var exercise: Exercise
    var date: Date
    /// Reps in each set, in order.
    var sets: [Int]
    var secondsPerRep: Double?
    /// Average rest between this exercise's sets.
    var rest: TimeInterval?
    /// Reps per minute from the first rep to the last, rests included:
    /// how much work fits in the time.
    var repsPerMinute: Double?
    var heartRate: Double?

    var id: String { "\(exercise.rawValue)-\(date.timeIntervalSince1970)" }
    var reps: Int { sets.reduce(0, +) }

    init?(exercise: Exercise, sets all: [WorkoutSet]) {
        let sets = all.filter { $0.exercise == exercise }
        guard let first = sets.first, let last = sets.last else { return nil }
        self.exercise = exercise
        date = first.start
        self.sets = sets.map(\.reps)
        let reps = self.sets.reduce(0, +)
        let gaps = sets.compactMap { set -> (TimeInterval, Int)? in set.reps > 1 ? (set.duration, set.reps - 1) : nil }
        let gapTime = gaps.map(\.0).reduce(0, +), gapCount = gaps.map(\.1).reduce(0, +)
        secondsPerRep = gapCount > 0 ? gapTime / Double(gapCount) : nil
        let rests = zip(sets, sets.dropFirst()).map { $1.start.timeIntervalSince($0.end) }
        rest = rests.isEmpty ? nil : rests.reduce(0, +) / Double(rests.count)
        let span = last.end.timeIntervalSince(first.start)
        repsPerMinute = span > 0 && reps > 1 ? Double(reps - 1) / span * 60 : nil
        let rates = sets.compactMap { set in set.heartRate.map { ($0, Double(set.reps)) } }
        let weight = rates.map(\.1).reduce(0, +)
        heartRate = weight > 0 ? rates.map { $0.0 * $0.1 }.reduce(0, +) / weight : nil
    }

    /// "12 · 10 · 8"
    var setsText: String { sets.map(String.init).joined(separator: " · ") }
}

/// The latest workout against the ones before it.
nonisolated struct EfficiencyTrend: Hashable, Sendable {
    var latest: ExerciseEfficiency
    /// Change in reps against the average of up to five before (0.1 = 10 % more).
    var reps: Double?
    /// Change in reps per minute (more is better).
    var pace: Double?
    /// Change in heart rate for the same work (less is better).
    var heartRate: Double?

    /// From one exercise's history, oldest first.
    static func of(_ history: [ExerciseEfficiency], window: Int = 5) -> EfficiencyTrend? {
        let sorted = history.sorted { $0.date < $1.date }
        guard let latest = sorted.last else { return nil }
        let before = sorted.dropLast().suffix(window)
        func change(_ value: (ExerciseEfficiency) -> Double?) -> Double? {
            let past = before.compactMap(value)
            guard let now = value(latest), !past.isEmpty else { return nil }
            let mean = past.reduce(0, +) / Double(past.count)
            return mean > 0 ? now / mean - 1 : nil
        }
        return EfficiencyTrend(latest: latest, reps: change { Double($0.reps) }, pace: change(\.repsPerMinute),
                               heartRate: change(\.heartRate))
    }
}

nonisolated extension ExerciseEfficiency {
    /// "12 · 10 · 8 · 2.1 s a rep · 75 s rest · 128 bpm"
    var summary: String {
        var parts = [setsText]
        if let secondsPerRep { parts.append(String(localized: "\(secondsPerRep.formatted(.number.precision(.fractionLength(1)))) s a rep")) }
        if let rest { parts.append(String(localized: "\(Int(rest.rounded())) s rest")) }
        if let heartRate { parts.append(String(localized: "\(Int(heartRate.rounded())) bpm")) }
        return parts.joined(separator: " · ")
    }
}

nonisolated extension EfficiencyTrend {
    /// "+12% reps · +8% pace · −5% heart rate", only what moved.
    var summary: String? {
        func percent(_ value: Double?) -> String? {
            guard let value, abs(value) >= 0.02 else { return nil }
            return value.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always()))
        }
        let parts = [
            percent(reps).map { String(localized: "\($0) reps") },
            percent(pace).map { String(localized: "\($0) pace") },
            percent(heartRate).map { String(localized: "\($0) heart rate") },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
