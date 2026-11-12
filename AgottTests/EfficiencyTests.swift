import Foundation
import Testing
@testable import Agott

struct EfficiencyTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Reps every `pace` seconds, sets separated by `rest`.
    private func reps(_ exercise: Exercise, sets: [Int], pace: Double = 2, rest: Double = 60, from start: Double = 0) -> [(exercise: Exercise, at: Date)] {
        var out: [(Exercise, Date)] = []
        var time = start
        for (index, count) in sets.enumerated() {
            if index > 0 { time += rest }
            for rep in 0..<count {
                if rep > 0 { time += pace }
                out.append((exercise, t0.addingTimeInterval(time)))
            }
        }
        return out
    }

    @Test func repsSplitIntoSetsAtRestsAndExerciseChanges() {
        let pushUps = reps(.pushUp, sets: [12, 10, 8], pace: 2, rest: 60)
        let squats = reps(.squat, sets: [15], pace: 3, from: 200)
        let sets = WorkoutSet.split(pushUps + squats)
        #expect(sets.map(\.reps) == [12, 10, 8, 15])
        #expect(sets.map(\.exercise) == [.pushUp, .pushUp, .pushUp, .squat])
        #expect(sets[0].restBefore == nil)
        #expect(sets[1].restBefore == 60)
        #expect(sets[0].secondsPerRep == 2)
        // A short pause inside a set does not split it.
        #expect(WorkoutSet.split(reps(.pushUp, sets: [5, 5], rest: 10)).map(\.reps) == [10])
    }

    @Test func efficiencyOfOneExercise() throws {
        var sets = WorkoutSet.split(reps(.pushUp, sets: [12, 10, 8], pace: 2, rest: 60))
        sets = WorkoutSet.withHeartRates(sets, samples: [
            (t0.addingTimeInterval(10), 120), (t0.addingTimeInterval(100), 130), (t0.addingTimeInterval(170), 140),
        ])
        let efficiency = try #require(ExerciseEfficiency(exercise: .pushUp, sets: sets))
        #expect(efficiency.reps == 30)
        #expect(efficiency.setsText == "12 · 10 · 8")
        #expect(efficiency.secondsPerRep == 2)
        #expect(efficiency.rest == 60)
        // 27 gaps of 2 s and two rests of 60 s: 174 s from the first rep to the last.
        #expect(abs((efficiency.repsPerMinute ?? 0) - 29.0 / 174 * 60) < 0.001)
        // Weighted by reps: (120·12 + 130·10 + 140·8) / 30.
        #expect(abs((efficiency.heartRate ?? 0) - (120.0 * 12 + 130 * 10 + 140 * 8) / 30) < 0.001)
        #expect(ExerciseEfficiency(exercise: .squat, sets: sets) == nil)
    }

    @Test func trendComparesWithTheWorkoutsBefore() throws {
        func day(_ n: Double, _ sets: [Int], pace: Double) -> ExerciseEfficiency {
            ExerciseEfficiency(exercise: .pushUp, sets: WorkoutSet.split(reps(.pushUp, sets: sets, pace: pace, from: n * 86_400)))!
        }
        let history = [day(0, [10, 10, 10], pace: 2.5), day(1, [10, 10, 10], pace: 2.5), day(2, [12, 12, 12], pace: 2)]
        let trend = try #require(EfficiencyTrend.of(history))
        #expect(trend.latest.reps == 36)
        #expect(abs((trend.reps ?? 0) - 0.2) < 0.001)
        #expect((trend.pace ?? 0) > 0)
        #expect(EfficiencyTrend.of([history[0]])?.reps == nil)
    }

    @Test func proofsKeepTheirSetsAndOldOnesStillOpen() throws {
        let sets = WorkoutSet.split(reps(.squat, sets: [15, 15]))
        let proof = WorkoutProof(counts: [], started: t0, ended: t0, sets: sets, heartRateAverage: 128)
        let decoded = try JSONDecoder.sync.decode(WorkoutProof.self, from: JSONEncoder.sync.encode(proof))
        #expect(decoded.efficiency.first?.sets == [15, 15])
        // A proof saved before sets were kept.
        let old = #"{"counts":[],"ticked":[],"started":0,"ended":0}"#
        let legacy = try JSONDecoder.sync.decode(WorkoutProof.self, from: Data(old.utf8))
        #expect(legacy.sets == nil && legacy.efficiency.isEmpty)
    }
}
