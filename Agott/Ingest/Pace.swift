import Foundation

/// Keeps background work from taking over the Mac.
///
/// After each batch of heavy work, rest for as long as the batch took. That
/// holds a loop to roughly half of one core no matter how big the job is, so
/// indexing and repairs run steadily without fans or a sluggish Mac.
nonisolated enum Pace {
    static func rest(after started: ContinuousClock.Instant, share: Double = 0.5) async {
        let worked = ContinuousClock.now - started
        let seconds = Double(worked.components.seconds) + Double(worked.components.attoseconds) / 1e18
        let pause = min(2.0, seconds * (1 - share) / share)
        guard pause > 0.005 else { return }
        try? await Task.sleep(for: .seconds(pause))
    }
}
