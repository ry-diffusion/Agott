import Foundation

/// A point in 3-D: a gravity direction, an acceleration, a displacement.
nonisolated struct Vec3: Codable, Hashable, Sendable {
    var x: Double, y: Double, z: Double

    init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }

    static let zero = Vec3(0, 0, 0)
    static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: Vec3, k: Double) -> Vec3 { Vec3(a.x * k, a.y * k, a.z * k) }
    func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
    var length: Double { dot(self).squareRoot() }
    var normalized: Vec3 { let l = length; return l > 1e-12 ? self * (1 / l) : self }
}

/// What a rep is counted from.
nonisolated enum MotionChannel: String, Codable, Sendable {
    /// Which way gravity points in the device: the wrist or head tilting as
    /// the body goes down and up (push-ups).
    case tilt
    /// The device's own acceleration (gravity removed), integrated into a
    /// displacement: the head or wrist moving up and down (squats, pull-ups).
    case acceleration
}

/// Counts reps from a stream of motion samples.
///
/// It does not need to know how the device is worn: the samples are smoothed,
/// the direction they move most in is found as it goes (the main axis of their
/// recent spread), and the motion along it is followed. A rep is one trip away
/// from rest and back: the signal turns at the far end (the bottom of a push-up,
/// the top of a pull-up) and turns again on the way back. Turns are only taken
/// when the signal has come back by a good part of the last swing, so a shaky
/// hand is not a rep; every second turn after a rest is counted, at the far end.
nonisolated struct RepCounter: Sendable {
    nonisolated struct Settings: Sendable, Equatable {
        var channel: MotionChannel
        /// Smoothing: motion faster than this is noise.
        var cutoffHz = 2.5
        /// How far back the main direction of motion is taken from.
        var windowSeconds = 4.0
        /// Smallest swing that is a rep, in the channel's units (gravity
        /// direction for tilt, g·s² for acceleration).
        var minSwing: Double
        /// A turn must come back by this much of the last swing.
        var swingFraction = 0.4
        /// Two reps closer than this are one.
        var minRepSeconds = 0.6
        /// Still for this long: a rest; the next turn starts a new rep.
        var restSeconds = 4.0
        /// Forgetting time of the acceleration integration.
        var leakSeconds = 2.0

        static func `for`(_ exercise: Exercise, sensor: MotionSensor) -> Settings {
            switch (exercise, sensor) {
            case (.pushUp, _), (.pullUp, .watch):
                // The forearm (or head) tilts ~15–40° each rep; ~4° is noise.
                Settings(channel: .tilt, minSwing: 0.07, minRepSeconds: 0.7)
            case (.squat, _), (.pullUp, _):
                // ~0.3–0.6 m up and down; under ~0.1 m is not a rep.
                Settings(channel: .acceleration, minSwing: 0.010, minRepSeconds: 0.8)
            }
        }
    }

    let settings: Settings
    private(set) var count = 0
    /// The largest swing of the last reps, for showing how deep they were.
    private(set) var lastSwing = 0.0

    // Filter state.
    private var lastTime: TimeInterval?
    private var smooth = Vec3.zero
    private var velocity = Vec3.zero
    private var position = Vec3.zero
    private var mean = Vec3.zero
    private var cov = [Double](repeating: 0, count: 6) // xx yy zz xy xz yz
    private var axis = Vec3(1, 0, 0).normalized
    private var started = false

    // Turn finding.
    private enum Direction { case unknown, rising, falling }
    private var direction = Direction.unknown
    private var extreme = 0.0
    private var low = 0.0, high = 0.0
    private var lastTurnValue: Double?
    private var lastTurnTime: TimeInterval = 0
    private var lastCountTime: TimeInterval = -.infinity
    private var turns = 0
    private var typicalSwing = 0.0

    init(_ settings: Settings) { self.settings = settings }
    init(exercise: Exercise, sensor: MotionSensor) { self.init(.for(exercise, sensor: sensor)) }

    /// Feeds one sample (gravity for tilt, user acceleration for
    /// acceleration, in g) taken at `time` seconds. True when it completed a rep.
    @discardableResult
    mutating func add(_ sample: Vec3, at time: TimeInterval) -> Bool {
        guard let previous = lastTime else {
            lastTime = time
            smooth = sample
            mean = settings.channel == .tilt ? sample : .zero
            lastTurnTime = time
            return false
        }
        let dt = min(max(time - previous, 0), 0.5)
        lastTime = time
        guard dt > 0 else { return false }

        let rc = 1 / (2 * Double.pi * settings.cutoffHz)
        smooth = smooth + (sample - smooth) * (dt / (rc + dt))

        // What moves: the tilt itself, or the acceleration integrated twice,
        // leaking back to zero so drift does not pile up.
        let point: Vec3
        switch settings.channel {
        case .tilt:
            point = smooth
        case .acceleration:
            let leak = exp(-dt / settings.leakSeconds)
            velocity = (velocity + smooth * dt) * leak
            position = (position + velocity * dt) * leak
            point = position
        }

        // Running mean and spread; the main axis by one power step a sample.
        let beta = dt / (settings.windowSeconds + dt)
        mean = mean + (point - mean) * beta
        let d = point - mean
        let products = [d.x * d.x, d.y * d.y, d.z * d.z, d.x * d.y, d.x * d.z, d.y * d.z]
        for i in 0..<6 { cov[i] += (products[i] - cov[i]) * beta }
        let pushed = Vec3(
            cov[0] * axis.x + cov[3] * axis.y + cov[4] * axis.z,
            cov[3] * axis.x + cov[1] * axis.y + cov[5] * axis.z,
            cov[4] * axis.x + cov[5] * axis.y + cov[2] * axis.z)
        if pushed.length > 1e-12 {
            var next = pushed.normalized
            if next.dot(axis) < 0 { next = next * -1 } // keep the sign steady
            axis = next
        }
        let value = d.dot(axis)
        return follow(value, at: time)
    }

    /// Zigzag: a turn is taken once the signal has come back from its
    /// extreme by the threshold.
    private mutating func follow(_ value: Double, at time: TimeInterval) -> Bool {
        if time - lastTurnTime > settings.restSeconds, direction != .unknown || turns > 0 {
            // A rest: whatever comes next starts from the top again.
            direction = .unknown
            turns = 0
            low = value
            high = value
        }
        let threshold = max(settings.minSwing, settings.swingFraction * typicalSwing)
        switch direction {
        case .unknown:
            if !started { started = true; low = value; high = value }
            low = min(low, value)
            high = max(high, value)
            if value <= high - threshold {
                direction = .falling; extreme = value; lastTurnValue = high; lastTurnTime = time
            } else if value >= low + threshold {
                direction = .rising; extreme = value; lastTurnValue = low; lastTurnTime = time
            }
            return false
        case .falling:
            if value < extreme { extreme = value }
            if value >= extreme + threshold { return turn(at: extreme, time: time, now: .rising, value: value) }
        case .rising:
            if value > extreme { extreme = value }
            if value <= extreme - threshold { return turn(at: extreme, time: time, now: .falling, value: value) }
        }
        return false
    }

    private mutating func turn(at point: Double, time: TimeInterval, now: Direction, value: Double) -> Bool {
        if let lastTurnValue {
            let swing = abs(point - lastTurnValue)
            typicalSwing = typicalSwing == 0 ? swing : typicalSwing * 0.6 + swing * 0.4
            lastSwing = swing
        }
        lastTurnValue = point
        lastTurnTime = time
        direction = now
        extreme = value
        turns += 1
        // Odd turns are the far end of a rep (the first one after a rest is
        // the bottom); even ones are the way back.
        guard turns % 2 == 1, time - lastCountTime >= settings.minRepSeconds else { return false }
        lastCountTime = time
        count += 1
        return true
    }
}
