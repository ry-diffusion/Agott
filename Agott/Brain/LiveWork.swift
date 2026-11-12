import Foundation
import Observation

/// Work a tool does that takes a while (fetching and transcribing a video),
/// shown live in the conversation as a card: what it is doing now, how far
/// along when that is known, and for how long. Gone when it ends.
@MainActor @Observable
final class LiveWork {
    static let shared = LiveWork()

    struct Job: Identifiable, Equatable, Sendable {
        let id: UUID
        var title: String
        var symbol: String
        var stage: String
        /// 0…1 when known; nil for "working on it".
        var fraction: Double?
        var started: Date
        /// Bumped by each update, so a late one never undoes a newer one.
        var revision = 0
    }

    private(set) var jobs: [Job] = []

    private init() {}

    func begin(id: UUID, title: String, symbol: String, stage: String) {
        jobs.append(Job(id: id, title: title, symbol: symbol, stage: stage, started: Date()))
    }

    func update(_ id: UUID, revision: Int, title: String?, stage: String?, fraction: Double??) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), revision > jobs[index].revision else { return }
        jobs[index].revision = revision
        if let title { jobs[index].title = title }
        if let stage { jobs[index].stage = stage }
        if let fraction { jobs[index].fraction = fraction.map { min(1, max(0, $0)) } }
    }

    func end(_ id: UUID) {
        jobs.removeAll { $0.id == id }
    }

    /// Runs `work` with a card in the chat, and takes the card away when it
    /// ends, however it ends.
    nonisolated static func track<T: Sendable>(
        _ title: String, symbol: String, stage: String,
        _ work: @Sendable (Reporter) async throws -> T
    ) async rethrows -> T {
        let reporter = Reporter(id: UUID())
        await LiveWork.shared.begin(id: reporter.id, title: title, symbol: symbol, stage: stage)
        defer { Task { @MainActor in LiveWork.shared.end(reporter.id) } }
        return try await work(reporter)
    }

    /// What a tool holds to say how it is going, from any thread.
    nonisolated final class Reporter: Sendable {
        let id: UUID
        private let counter = Counter()

        init(id: UUID) { self.id = id }

        /// A new step: what it is doing now, and how far along if known.
        func stage(_ stage: String, fraction: Double? = nil) {
            send(title: nil, stage: stage, fraction: .some(fraction))
        }

        /// How far along the current step is.
        func progress(_ fraction: Double) {
            send(title: nil, stage: nil, fraction: .some(fraction))
        }

        /// A better name, once it is known ("Watching “Full body…”").
        func title(_ title: String) {
            send(title: title, stage: nil, fraction: nil)
        }

        private func send(title: String?, stage: String?, fraction: Double??) {
            let revision = counter.next()
            let id = self.id
            Task { @MainActor in
                LiveWork.shared.update(id, revision: revision, title: title, stage: stage, fraction: fraction)
            }
        }
    }

    private nonisolated final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
    }
}
