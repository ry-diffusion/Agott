import CoreMotion
import Foundation
import HealthKit
import Observation

/// The wrist as the counter. A workout session (functional strength
/// training) keeps Agott running and reading motion with the wrist down, and
/// collects heart rate and energy; at the end the workout goes into Health
/// with every set as one of its activities. The barometer records how far
/// the wrist went up and down, as more proof for squats.
@MainActor @Observable
final class WristWorkout: NSObject, HKLiveWorkoutBuilderDelegate {
    private(set) var isRunning = false
    private(set) var problem: String?
    /// The latest heart rate (bpm).
    private(set) var heartRate: Double?

    @ObservationIgnored private(set) var heartRates: [(at: Date, bpm: Double)] = []
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private let altimeter = CMAltimeter()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var lowest: Double?
    @ObservationIgnored private var highest: Double?

    func start(_ workout: WorkoutSession) async {
        await start(onSample: { gravity, acceleration, time in
            workout.add(gravity: gravity, acceleration: acceleration, at: time)
        }, onHeightSwing: { workout.heightSwing = $0 })
    }

    /// Motion samples (gravity, user acceleration, time) to any handler, in a
    /// workout session so they keep coming with the wrist down.
    func start(onSample: @escaping (Vec3, Vec3, TimeInterval) -> Void, onHeightSwing: ((Double) -> Void)? = nil) async {
        guard !isRunning else { return }
        isRunning = true
        problem = nil
        heartRates = []
        await startHealthSession()

        motion.deviceMotionUpdateInterval = 1.0 / 50
        motion.startDeviceMotionUpdates(to: .main) { data, _ in
            guard let data else { return }
            let g = data.gravity, a = data.userAcceleration
            MainActor.assumeIsolated {
                onSample(Vec3(g.x, g.y, g.z), Vec3(a.x, a.y, a.z), data.timestamp)
            }
        }
        if onHeightSwing != nil, CMAltimeter.isRelativeAltitudeAvailable() {
            lowest = nil
            highest = nil
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                let metres = data.relativeAltitude.doubleValue
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.lowest = min(self.lowest ?? metres, metres)
                    self.highest = max(self.highest ?? metres, metres)
                    if let low = self.lowest, let high = self.highest { onHeightSwing?(high - low) }
                }
            }
        }
    }

    /// Stops counting. With a proof, the workout is saved to Health with its
    /// sets, and the proof comes back with heart rate and energy; without
    /// one, the workout is thrown away.
    @discardableResult
    func end(saving proof: WorkoutProof? = nil, routine: RoutineRecord? = nil) async -> WorkoutProof? {
        guard isRunning else { return proof }
        isRunning = false
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        guard let session, let builder else { return proof }
        self.session = nil
        self.builder = nil
        session.end()
        guard var proof, let routine else {
            builder.discardWorkout()
            return proof
        }
        do {
            try await builder.endCollection(at: Date())
            let bpm = HKUnit.count().unitDivided(by: .minute())
            let rate = builder.statistics(for: HKQuantityType(.heartRate))
            proof.heartRateAverage = rate?.averageQuantity()?.doubleValue(for: bpm) ?? proof.heartRateAverage
            proof.heartRateMax = rate?.maximumQuantity()?.doubleValue(for: bpm) ?? proof.heartRateMax
            proof.energy = builder.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
            try await builder.addMetadata(HealthWorkouts.metadata(proof, routine: routine))
            for activity in HealthWorkouts.activities(proof) { try? await builder.addWorkoutActivity(activity) }
            _ = try await builder.finishWorkout()
        } catch {
            problem = error.localizedDescription
        }
        return proof
    }

    /// Without Health, counting still works; it only stops when the screen sleeps.
    private func startHealthSession() async {
        guard await HealthWorkouts.authorize() else { return }
        do {
            let configuration = HealthWorkouts.configuration
            let session = try HKWorkoutSession(healthStore: HealthWorkouts.store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: HealthWorkouts.store, workoutConfiguration: configuration)
            builder.delegate = self
            session.startActivity(with: Date())
            try await builder.beginCollection(at: Date())
            self.session = session
            self.builder = builder
        } catch {
            problem = error.localizedDescription
        }
    }

    // Heart rate as it comes, to tell how hard each set was.
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let type = HKQuantityType(.heartRate)
        guard collectedTypes.contains(type), let statistics = workoutBuilder.statistics(for: type),
              let quantity = statistics.mostRecentQuantity() else { return }
        let bpm = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        let at = statistics.mostRecentQuantityDateInterval()?.end ?? Date()
        Task { @MainActor in
            self.heartRate = bpm
            self.heartRates.append((at, bpm))
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
