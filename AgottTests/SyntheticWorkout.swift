@testable import Agott
import Foundation

/// Made-up motion for testing the rep counter: reps of a given depth and
/// pace, rests between them, noise, the device worn at any angle.
nonisolated struct SyntheticWorkout {
    struct Rng {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Double {
            let u = max(next(), 1e-12), v = next()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }

    var reps: Int
    var repSeconds = 2.0
    var jitter = 0.3
    var restBetween = 0.4
    var restLongEvery = 0
    var restLong = 8.0
    var leadIn = 3.0
    var tail = 3.0
    var rate = 50.0
    var seed: UInt64 = 1

    /// Depth of the trip, 0 at rest and 1 at the far end, over time.
    func excursion() -> [(t: Double, e: Double)] {
        var rng = Rng(state: seed)
        var out: [(Double, Double)] = []
        var t = 0.0
        let dt = 1 / rate
        func hold(_ seconds: Double) { let end = t + seconds; while t < end { out.append((t, 0)); t += dt } }
        hold(leadIn)
        for rep in 0..<reps {
            let length = repSeconds * (1 + jitter * (rng.next() - 0.5))
            let depth = 1 + 0.3 * (rng.next() - 0.5)
            let start = t
            while t < start + length {
                let phase = (t - start) / length
                out.append((t, depth * (1 - cos(2 * .pi * phase)) / 2))
                t += dt
            }
            if restLongEvery > 0, (rep + 1) % restLongEvery == 0, rep + 1 < reps { hold(restLong) }
            else { hold(restBetween * rng.next()) }
        }
        hold(tail)
        return out
    }

    /// Gravity in the device as it tilts by up to `degrees`, worn at a random angle.
    func tilt(degrees: Double, noise: Double = 0.01) -> [(t: Double, v: Vec3)] {
        var rng = Rng(state: seed &+ 99)
        let rest = Vec3(rng.gaussian(), rng.gaussian(), rng.gaussian()).normalized
        var other = Vec3(rng.gaussian(), rng.gaussian(), rng.gaussian())
        other = (other - rest * other.dot(rest)).normalized
        return excursion().map { sample in
            let angle = sample.e * degrees * .pi / 180
            let g = rest * cos(angle) + other * sin(angle)
            return (sample.t, g + Vec3(rng.gaussian(), rng.gaussian(), rng.gaussian()) * noise)
        }
    }

    /// Acceleration (g) of a device moving `meters` along a random direction.
    func acceleration(meters: Double, noise: Double = 0.02) -> [(t: Double, v: Vec3)] {
        var rng = Rng(state: seed &+ 7)
        let direction = Vec3(rng.gaussian(), rng.gaussian(), rng.gaussian()).normalized
        let path = excursion()
        let dt = 1 / rate
        var out: [(Double, Vec3)] = []
        for i in path.indices {
            let before = path[max(i - 1, 0)].e, now = path[i].e, after = path[min(i + 1, path.count - 1)].e
            let a = (after - 2 * now + before) / (dt * dt) * meters / 9.81
            out.append((path[i].t, direction * a + Vec3(rng.gaussian(), rng.gaussian(), rng.gaussian()) * noise))
        }
        return out
    }

    /// Nothing but a hand or head that is not quite still.
    static func still(seconds: Double, noise: Double, seed: UInt64 = 3) -> [(t: Double, v: Vec3)] {
        var rng = Rng(state: seed)
        return stride(from: 0.0, to: seconds, by: 0.02).map { t in
            (t, Vec3(0, 0, -1) + Vec3(rng.gaussian(), rng.gaussian(), rng.gaussian()) * noise)
        }
    }

    static func count(_ samples: [(t: Double, v: Vec3)], _ settings: RepCounter.Settings) -> Int {
        var counter = RepCounter(settings)
        for sample in samples { counter.add(sample.v, at: sample.t) }
        return counter.count
    }
}
