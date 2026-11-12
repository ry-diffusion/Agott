import CoreMotion
import Foundation
import HealthKit
import Observation

/// The wrist as the counter. A workout session (functional strength
/// training) keeps Agott running and reading motion with the wrist down,
/// and goes into Health; the barometer records how far the wrist went up
/// and down, as more proof for squats.
@MainActor @Observable
final class WristWorkout {
    private(set) var isRunning = false
    private(set) var problem: String?

    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private let altimeter = CMAltimeter()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var lowest: Double?
    @ObservationIgnored private var highest: Double?

    func start(_ workout: WorkoutSession) async {
        guard !isRunning else { return }
        isRunning = true
        problem = nil
        await startHealthSession()

        motion.deviceMotionUpdateInterval = 1.0 / 50
        motion.startDeviceMotionUpdates(to: .main) { data, _ in
            guard let data else { return }
            let g = data.gravity, a = data.userAcceleration
            MainActor.assumeIsolated {
                workout.add(gravity: Vec3(g.x, g.y, g.z), acceleration: Vec3(a.x, a.y, a.z), at: data.timestamp)
            }
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            lowest = nil
            highest = nil
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                let metres = data.relativeAltitude.doubleValue
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.lowest = min(self.lowest ?? metres, metres)
                    self.highest = max(self.highest ?? metres, metres)
                    if let low = self.lowest, let high = self.highest { workout.heightSwing = high - low }
                }
            }
        }
    }

    /// Stops counting and saves the workout to Health (if allowed).
    func end() async {
        guard isRunning else { return }
        isRunning = false
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        guard let session, let builder else { return }
        session.end()
        do {
            try await builder.endCollection(at: Date())
            _ = try await builder.finishWorkout()
        } catch {
            problem = error.localizedDescription
        }
        self.session = nil
        self.builder = nil
    }

    /// Without Health, counting still works; it only stops when the screen sleeps.
    private func startHealthSession() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        do {
            try await store.requestAuthorization(toShare: [HKObjectType.workoutType()],
                                                 read: [HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned)])
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .functionalStrengthTraining
            configuration.locationType = .indoor
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            session.startActivity(with: Date())
            try await builder.beginCollection(at: Date())
            self.session = session
            self.builder = builder
        } catch {
            problem = error.localizedDescription
        }
    }
}
