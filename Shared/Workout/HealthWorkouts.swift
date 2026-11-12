#if os(iOS) || os(watchOS)
import Foundation
import HealthKit

/// Workouts in Apple Health: each routine done with counted reps is saved as
/// a functional strength training workout, every set as one of its
/// activities (exercise and reps in its metadata), and all the sets as JSON
/// in the workout's metadata, so they can be read back to see how the sets
/// improve. On the Watch the workout also carries heart rate and energy.
nonisolated enum HealthWorkouts {
    /// Custom metadata (keys must not start with "HK").
    static let setsKey = "AgottSets"
    static let routineKey = "AgottRoutine"
    static let titleKey = "AgottRoutineTitle"
    static let exerciseKey = "AgottExercise"
    static let repsKey = "AgottReps"

    static let store = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    static var shareTypes: Set<HKSampleType> { [HKObjectType.workoutType()] }
    static var readTypes: Set<HKObjectType> {
        [HKObjectType.workoutType(), HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned)]
    }

    static var configuration: HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .functionalStrengthTraining
        configuration.locationType = .indoor
        return configuration
    }

    /// Asks once; later calls return at once.
    @discardableResult
    static func authorize() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
            return true
        } catch {
            return false
        }
    }

    static func metadata(_ proof: WorkoutProof, routine: RoutineRecord) -> [String: Any] {
        var metadata: [String: Any] = [routineKey: routine.id.uuidString, titleKey: routine.title, HKMetadataKeyIndoorWorkout: true]
        if let sets = proof.sets, let data = try? JSONEncoder.sync.encode(sets) {
            metadata[setsKey] = String(decoding: data, as: UTF8.self)
        }
        return metadata
    }

    /// One activity per set, inside the workout's time.
    static func activities(_ proof: WorkoutProof) -> [HKWorkoutActivity] {
        (proof.sets ?? []).map { set in
            // A set of one rep still gets a moment of its own.
            let end = max(set.end, set.start.addingTimeInterval(1))
            return HKWorkoutActivity(workoutConfiguration: configuration, start: set.start, end: end,
                                     metadata: [exerciseKey: set.exercise.rawValue, repsKey: set.reps])
        }
    }

    /// Saves a workout counted without a workout session (AirPods on the iPhone).
    static func save(_ proof: WorkoutProof, routine: RoutineRecord) async {
        guard proof.sets?.isEmpty == false, await authorize() else { return }
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        do {
            try await builder.beginCollection(at: proof.started)
            try await builder.addMetadata(metadata(proof, routine: routine))
            for activity in activities(proof) { try? await builder.addWorkoutActivity(activity) }
            try await builder.endCollection(at: max(proof.ended, proof.started.addingTimeInterval(1)))
            _ = try await builder.finishWorkout()
        } catch {
            builder.discardWorkout()
        }
    }

    /// A workout Agott saved, as read back.
    struct Saved: Sendable, Hashable {
        var routineID: UUID?
        var start: Date
        var end: Date
        var sets: [WorkoutSet]
        var heartRate: Double?
        var energy: Double?
    }

    /// Agott's workouts in Health, newest first.
    static func load(days: Int = 120, routineID: UUID? = nil) async -> [Saved] {
        guard isAvailable else { return [] }
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForWorkouts(with: .functionalStrengthTraining),
            HKQuery.predicateForSamples(withStart: since, end: nil),
            routineID.map { HKQuery.predicateForObjects(withMetadataKey: routineKey, allowedValues: [$0.uuidString]) }
                ?? HKQuery.predicateForObjects(withMetadataKey: setsKey),
        ])
        let descriptor = HKSampleQueryDescriptor(predicates: [.workout(predicate)],
                                                 sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: 200)
        guard let workouts = try? await descriptor.result(for: store) else { return [] }
        return workouts.compactMap { workout in
            guard let json = workout.metadata?[setsKey] as? String,
                  let sets = try? JSONDecoder.sync.decode([WorkoutSet].self, from: Data(json.utf8)) else { return nil }
            let bpm = HKUnit.count().unitDivided(by: .minute())
            return Saved(
                routineID: (workout.metadata?[routineKey] as? String).flatMap(UUID.init(uuidString:)),
                start: workout.startDate, end: workout.endDate, sets: sets,
                heartRate: workout.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: bpm),
                energy: workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()))
        }
    }
}

/// A routine's history for one exercise: from Health where it is there,
/// and from synced proofs (from any device) for the rest.
@MainActor
enum EfficiencyHistory {
    static func load(_ routineID: UUID) async -> [Exercise: [ExerciseEfficiency]] {
        var byExercise = RoutineSync.shared.efficiency(routineID)
        for saved in await HealthWorkouts.load(routineID: routineID) {
            for exercise in Exercise.allCases {
                guard let efficiency = ExerciseEfficiency(exercise: exercise, sets: saved.sets) else { continue }
                var list = byExercise[exercise] ?? []
                // The same workout, synced and in Health: keep one.
                if !list.contains(where: { abs($0.date.timeIntervalSince(efficiency.date)) < 60 }) { list.append(efficiency) }
                byExercise[exercise] = list.sorted { $0.date < $1.date }
            }
        }
        return byExercise
    }
}
#endif
