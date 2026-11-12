import Foundation
import Observation

/// Doing a routine with something that counts: the exercises in its steps,
/// reps counted from motion against each target, the other steps ticked by
/// hand, and at the end the proof that goes with the day.
@MainActor @Observable
final class WorkoutSession {
    let routine: RoutineRecord
    let plan: WorkoutPlan
    let sensor: MotionSensor

    private(set) var counts: [Exercise: Int] = [:]
    private(set) var ticked: Set<Int> = []
    /// The exercise being counted now.
    private(set) var current: Exercise?
    private(set) var started = Date()
    /// How far the watch went up and down, from the barometer (metres).
    var heightSwing: Double?

    /// A rep was counted (for a tap on the wrist, a sound).
    @ObservationIgnored var onRep: ((Exercise, Int) -> Void)?
    /// An exercise reached its target.
    @ObservationIgnored var onExerciseDone: ((Exercise) -> Void)?

    @ObservationIgnored private var counter: RepCounter?

    init(routine: RoutineRecord, sensor: MotionSensor) {
        self.routine = routine
        self.plan = routine.plan
        self.sensor = sensor
        current = exercises.first
        counter = current.map { RepCounter(exercise: $0, sensor: sensor) }
    }

    /// In the order the steps name them.
    var exercises: [Exercise] {
        var seen: [Exercise] = []
        for step in plan.steps { if let exercise = step.exercise, step.reps != nil, !seen.contains(exercise) { seen.append(exercise) } }
        return seen
    }

    func target(_ exercise: Exercise) -> Int { plan.targets[exercise] ?? 0 }
    func count(_ exercise: Exercise) -> Int { counts[exercise] ?? 0 }
    func isMet(_ exercise: Exercise) -> Bool { count(exercise) >= WorkoutPlan.required(target(exercise)) }

    /// Steps to tick by hand: timed ones, and what motion can't count.
    var manualSteps: [WorkoutStep] { plan.steps.filter { !$0.isCountable } }

    var isProven: Bool { plan.isProven(counts: counts, ticked: ticked) }

    func select(_ exercise: Exercise) {
        current = exercise
        counter = RepCounter(exercise: exercise, sensor: sensor)
    }

    func toggle(_ step: WorkoutStep) {
        if ticked.contains(step.id) { ticked.remove(step.id) } else { ticked.insert(step.id) }
    }

    /// One motion sample: gravity and user acceleration in g, at a time in seconds.
    func add(gravity: Vec3, acceleration: Vec3, at time: TimeInterval) {
        guard let exercise = current, var counter else { return }
        let sample = counter.settings.channel == .tilt ? gravity : acceleration
        let rep = counter.add(sample, at: time)
        self.counter = counter
        guard rep else { return }
        let wasMet = isMet(exercise)
        counts[exercise, default: 0] += 1
        onRep?(exercise, count(exercise))
        if !wasMet, count(exercise) >= target(exercise) {
            onExerciseDone?(exercise)
            // On to the next one still short of its target.
            if let next = exercises.first(where: { !isMet($0) }) { select(next) }
        }
    }

    func proof(now: Date = Date()) -> WorkoutProof {
        WorkoutProof(
            counts: exercises.map { ExerciseCount(exercise: $0, target: target($0), counted: count($0), sensor: sensor) },
            ticked: ticked.sorted(), started: started, ended: now, heightSwing: heightSwing)
    }
}

#if os(iOS)
import CoreMotion

/// AirPods (Pro, Max, 3rd generation and later) as the counter: head motion
/// during push-ups, squats and pull-ups.
@MainActor @Observable
final class HeadphoneMotion: NSObject, CMHeadphoneMotionManagerDelegate {
    static let shared = HeadphoneMotion()

    private(set) var isConnected = false
    private(set) var isRunning = false
    @ObservationIgnored private let manager = CMHeadphoneMotionManager()

    override private init() {
        super.init()
        manager.delegate = self
    }

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var isDenied: Bool { CMHeadphoneMotionManager.authorizationStatus() == .denied }

    func start(_ handler: @escaping (_ gravity: Vec3, _ acceleration: Vec3, _ time: TimeInterval) -> Void) {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        isRunning = true
        manager.startDeviceMotionUpdates(to: .main) { motion, _ in
            guard let motion else { return }
            let g = motion.gravity, a = motion.userAcceleration
            MainActor.assumeIsolated {
                handler(Vec3(g.x, g.y, g.z), Vec3(a.x, a.y, a.z), motion.timestamp)
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        isRunning = false
    }

    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in self.isConnected = true }
    }

    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        Task { @MainActor in self.isConnected = false }
    }
}
#endif
