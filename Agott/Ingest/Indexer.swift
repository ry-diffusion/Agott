import Foundation
import Observation
import OSLog

/// Keeps memory current: reads new messages, links them into the graph, and
/// embeds them, in that order, in the background.
@Observable
final class Indexer {
    static let shared = Indexer()

    enum Phase: Equatable {
        case idle
        case reading(MemorySource)
        case linking
        case embedding(done: Int, total: Int)
        case learning(done: Int, total: Int)
    }

    enum SourceState: Equatable {
        case unknown, ready, missing, needsPermission, failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var states: [MemorySource: SourceState] = [:]
    private(set) var counts: [MemorySource: Int] = [:]
    private(set) var totals = (messages: 0, chunks: 0, vectors: 0, entities: 0, facts: 0)
    private(set) var lastRun: Date?
    private(set) var lastError: String?
    /// Messages read from the current source in this run.
    private(set) var readSoFar = 0

    var isRunning: Bool { phase != .idle }

    /// One line for anywhere in the app: what memory is doing right now.
    var statusText: String {
        switch phase {
        case .idle:
            if let lastRun {
                return String(localized: "Up to date, \(lastRun.formatted(.relative(presentation: .named)))")
            }
            return totals.messages == 0 ? String(localized: "Nothing indexed yet") : String(localized: "All caught up")
        case .reading(let source):
            return readSoFar > 0
                ? String(localized: "Reading \(source.displayName)… \(readSoFar.formatted()) messages")
                : String(localized: "Reading \(source.displayName)…")
        case .linking: return String(localized: "Connecting the dots…")
        case .embedding(let done, let total): return String(localized: "Understanding moments \(done.formatted()) of \(total.formatted())…")
        case .learning(let done, let total): return String(localized: "Learning about you \(done) of \(total)…")
        }
    }

    /// 0…1 when the current step can be measured, nil when it cannot.
    var progress: Double? {
        switch phase {
        case .embedding(let done, let total), .learning(let done, let total):
            total > 0 ? min(1, Double(done) / Double(total)) : nil
        default: nil
        }
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private let contacts = ContactBook()
    @ObservationIgnored private let log = Logger(subsystem: "br.com.zesmoi.Agott", category: "indexer")

    private init() {}

    /// Indexes now, then every ten minutes while the app runs.
    func startAutomatic() {
        guard timer == nil else { return }
        timer = Task {
            await refreshTotals()
            while !Task.isCancelled {
                if AppSettings.shared.hasOnboarded { run() }
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    func run() {
        guard task == nil else { return }
        task = Task {
            await index()
            task = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    private func index() async {
        lastError = nil
        #if os(macOS)
        if !contacts.isLoaded {
            let contacts = self.contacts
            await Task.detached(priority: .utility) { contacts.load() }.value
        }
        let sources: [any MessageSource] = [WhatsAppSource(), IMessageSource(), ClaudeHistorySource()]
        for source in sources where AppSettings.shared.enabledSources.contains(source.kind) {
            guard !Task.isCancelled else { break }
            phase = .reading(source.kind)
            await read(source)
        }
        #endif

        guard !Task.isCancelled else { phase = .idle; return }
        phase = .linking
        do {
            while try await KnowledgeGraph.link() > 0, !Task.isCancelled {}
        } catch {
            lastError = error.localizedDescription
        }

        await embed()
        await refreshTotals()
        lastRun = .now
        phase = .idle
    }

    private func read(_ source: any MessageSource) async {
        readSoFar = 0
        guard source.isPresent else {
            states[source.kind] = .missing
            return
        }
        let contacts = self.contacts
        do {
            var cursor = try await MemoryStore.shared.cursor(for: source.kind)
            while !Task.isCancelled {
                let after = cursor
                let batch = try await Task.detached(priority: .utility) {
                    try source.read(after: after, limit: 5000, contacts: contacts)
                }.value
                guard !batch.isEmpty else { break }
                try await MemoryStore.shared.ingest(batch)
                cursor = batch.map(\.date.timeIntervalSince1970).max() ?? cursor
                try await MemoryStore.shared.setCursor(cursor, for: source.kind)
                readSoFar += batch.count
                counts = (try? await MemoryStore.shared.counts()) ?? counts
                if batch.count < 5000 { break }
            }
            states[source.kind] = .ready
        } catch let error as SourceError {
            if case .needsFullDiskAccess = error { states[source.kind] = .needsPermission }
            else { states[source.kind] = .missing }
        } catch {
            states[source.kind] = .failed(error.localizedDescription)
            log.error("Reading \(source.kind.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func embed() async {
        do {
            try await Embedder.shared.prepare()
        } catch {
            lastError = error.localizedDescription
            return
        }
        let total = (try? await MemoryStore.shared.totals()) ?? totals
        var done = total.vectors
        let goal = total.chunks
        while !Task.isCancelled {
            guard let batch = try? await MemoryStore.shared.chunksNeedingVectors(limit: 128), !batch.isEmpty else { break }
            phase = .embedding(done: done, total: goal)
            let vectors = await Task.detached(priority: .utility) { () -> [(Int64, [Float])] in
                var out: [(Int64, [Float])] = []
                for (id, text) in batch {
                    if let vector = try? await Embedder.shared.embed(text) { out.append((id, vector)) }
                    else { out.append((id, [])) }
                }
                return out
            }.value
            // Empty vectors are stored too, so a chunk that yields nothing is
            // not retried forever; the index skips them by dimension.
            try? await MemoryStore.shared.storeVectors(vectors.map { ($0.0, $0.1.isEmpty ? [0] : $0.1) })
            done += batch.count
        }
    }

    func refreshTotals() async {
        if let totals = try? await MemoryStore.shared.totals() { self.totals = totals }
        if let counts = try? await MemoryStore.shared.counts() { self.counts = counts }
    }

    // MARK: Deep learning pass

    @ObservationIgnored private var learnTask: Task<Void, Never>?
    private(set) var isLearning = false

    /// Reads your own words with the on-device model and extracts facts,
    /// then rewrites the portrait.
    func learn(moments: Int = 400) {
        guard learnTask == nil else { return }
        isLearning = true
        learnTask = Task {
            defer {
                isLearning = false
                learnTask = nil
                phase = .idle
            }
            phase = .learning(done: 0, total: moments)
            do {
                _ = try await KnowledgeGraph.learn(maxMoments: moments) { [weak self] count in
                    self?.phase = .learning(done: count, total: moments)
                }
                let portrait = try await KnowledgeGraph.writePortrait()
                if !portrait.isEmpty { AppSettings.shared.aboutMe = portrait }
            } catch {
                lastError = error.localizedDescription
            }
            await refreshTotals()
        }
    }

    func stopLearning() {
        learnTask?.cancel()
    }

    #if os(macOS)
    func importClaudeExport(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let messages = try await Task.detached { try ClaudeExportImporter.read(url) }.value
            try await MemoryStore.shared.ingest(messages)
            run()
        } catch {
            lastError = error.localizedDescription
        }
    }
    #endif

    func forget(_ source: MemorySource) async {
        try? await MemoryStore.shared.forget(source: source)
        await refreshTotals()
    }
}
