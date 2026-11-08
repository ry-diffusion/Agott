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
        /// Voice notes and photos becoming words.
        case media(done: Int)
        case linking
        case embedding(done: Int, total: Int)
        case learning(done: Int, total: Int)
        case reflecting(done: Int, total: Int)
    }

    enum SourceState: Equatable {
        case unknown, ready, missing, needsPermission, failed(String)
    }

    private(set) var phase: Phase = .idle
    /// What the model is learning, which runs alongside reading.
    private(set) var learnPhase: Phase = .idle
    private(set) var states: [MemorySource: SourceState] = [:]
    private(set) var counts: [MemorySource: Int] = [:]
    private(set) var totals = (messages: 0, chunks: 0, vectors: 0, entities: 0, facts: 0)
    private(set) var lastRun: Date?
    private(set) var lastError: String?
    /// Messages read from the current source in this run.
    private(set) var readSoFar = 0
    /// How many the current source has to read, when it can say.
    private(set) var readTotal: Int?
    /// Paused by you. Survives relaunches; nothing indexes until you resume.
    private(set) var isPaused = UserDefaults.standard.bool(forKey: "indexingPaused")

    var isRunning: Bool { phase != .idle }

    /// One line for anywhere in the app: what memory is doing right now.
    var statusText: String {
        switch (phase, learnPhase) {
        case (.idle, .idle): return describe(.idle)
        case (.idle, let learning): return describe(learning)
        case (let reading, .idle): return describe(reading)
        case (let reading, let learning): return describe(reading) + " · " + describe(learning)
        }
    }

    private func describe(_ phase: Phase) -> String {
        switch phase {
        case .idle:
            if isPaused { return String(localized: "Indexing paused") }
            if let lastRun {
                return String(localized: "Up to date, \(lastRun.formatted(.relative(presentation: .named)))")
            }
            return totals.messages == 0 ? String(localized: "Nothing indexed yet") : String(localized: "All caught up")
        case .reading(let source):
            if let readTotal, readTotal > 0 {
                return String(localized: "Reading \(source.displayName)… \(min(readSoFar, readTotal).formatted()) of \(readTotal.formatted())")
            }
            return readSoFar > 0
                ? String(localized: "Reading \(source.displayName)… \(readSoFar.formatted()) messages")
                : String(localized: "Reading \(source.displayName)…")
        case .media(let done):
            return done > 0 ? String(localized: "Listening to voice notes and looking at photos… \(done.formatted())")
                            : String(localized: "Listening to voice notes and looking at photos…")
        case .linking: return String(localized: "Connecting the dots…")
        case .embedding(let done, let total): return String(localized: "Understanding moments \(done.formatted()) of \(total.formatted())…")
        case .learning(let done, let total): return String(localized: "Learning about you \(done) of \(total)…")
        case .reflecting(let done, let total): return String(localized: "Remembering conversations that mattered \(done) of \(total)…")
        }
    }

    /// 0…1 when the current step can be measured, nil when it cannot.
    var progress: Double? {
        switch phase == .idle ? learnPhase : phase {
        case .embedding(let done, let total), .learning(let done, let total), .reflecting(let done, let total):
            total > 0 ? min(1, Double(done) / Double(total)) : nil
        case .reading:
            readTotal.flatMap { $0 > 0 ? min(1, Double(readSoFar) / Double($0)) : nil }
        default: nil
        }
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastTotals = Date.distantPast
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
        guard task == nil, !isPaused, !MemoryRepair.shared.isRunning else { return }
        // Utility priority: indexing yields to everything you are doing.
        task = Task(priority: .utility) {
            await index()
            task = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    /// Every step saves its place (cursors per source, graphed and embedded
    /// flags per moment), so pausing is just stopping, and resuming picks up
    /// exactly where it left off.
    func pause() {
        isPaused = true
        UserDefaults.standard.set(true, forKey: "indexingPaused")
        stop()
        stopLearning()
    }

    func resume() {
        isPaused = false
        UserDefaults.standard.set(false, forKey: "indexingPaused")
        run()
    }

    private func index() async {
        lastError = nil
        // Understanding starts while reading: the newest moments land first,
        // and the model reads them as they arrive instead of after every
        // message of every source has been indexed.
        if AppSettings.shared.autoLearn, ModelHub.isAvailable(AppSettings.shared.learningProvider) {
            learn(untilDone: true)
        }
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
        // WhatsApp voice notes and photos, as words, in their conversations.
        // A few batches per run: the first time there are thousands, and the
        // graph and people should not wait half an hour behind them. The
        // rest come in over the next runs.
        if AppSettings.shared.enabledSources.contains(.whatsapp),
           AppSettings.shared.transcribeVoiceNotes || AppSettings.shared.describePhotos {
            var done = 0
            var batches = 0
            phase = .media(done: 0)
            while !Task.isCancelled, batches < MediaIngestor.batchesPerRun,
                  let added = await MediaIngestor.run(contacts: contacts) {
                done += added
                batches += 1
                phase = .media(done: done)
                await Task.yield()
            }
        }
        #endif

        guard !Task.isCancelled else { phase = .idle; return }
        phase = .linking
        do {
            while !Task.isCancelled {
                let batch = ContinuousClock.now
                guard try await KnowledgeGraph.link(batch: 150) > 0 else { break }
                await Pace.rest(after: batch)
            }
            // Who is who, by id: people, groups and their members.
            if (try? await MemoryStore.shared.syncPeople()) ?? 0 > 0 { await PeopleDirectory.shared.refresh() }
            await ContactPhotos.shared.refresh()
        } catch {
            lastError = error.localizedDescription
        }

        await embed()
        await refreshTotals()
        lastRun = .now
        phase = .idle

        // Then the model reads what is new, if you want it to.
        if !Task.isCancelled, AppSettings.shared.autoLearn, ModelHub.isAvailable(AppSettings.shared.learningProvider) {
            learn()
        }
    }

    /// Smaller pages newest-first: the first page is what you talked about
    /// today, and it should land in seconds.
    private static let page = 2000
    /// "No upper bound yet": the newest-first pass starts from now.
    private static let fromNow = 9e15

    /// Reads one source.
    ///
    /// The first time (or when a big backlog is waiting), message databases
    /// are read **newest first**, down to whatever is already indexed, so
    /// the last few days are searchable within a minute and older years fill
    /// in behind them. After that, each run only reads what is new. Every
    /// page saves where it reached, so pausing or quitting loses nothing.
    private func read(_ source: any MessageSource) async {
        readSoFar = 0
        readTotal = nil
        guard source.isPresent else {
            states[source.kind] = .missing
            return
        }
        let contacts = self.contacts
        let store = MemoryStore.shared
        let beforeKey = "\(source.kind.rawValue).backfill.before"
        let floorKey = "\(source.kind.rawValue).backfill.floor"
        do {
            var forward = try await store.cursor(for: source.kind)
            var before = try await store.cursor(named: beforeKey)
            var floor = try await store.cursor(named: floorKey)

            if source.supportsNewestFirst, before == 0 {
                let after = forward
                let backlog = await Task.detached(priority: .utility) {
                    source.estimatedCount(after: after, before: nil)
                }.value ?? 0
                if forward == 0 || backlog > 5000 {
                    floor = forward
                    before = Self.fromNow
                    try await store.setCursor(floor, named: floorKey)
                    try await store.setCursor(before, named: beforeKey)
                }
            }

            // Progress: everything this run will read.
            let (f, b, fw) = (floor, before, forward)
            readTotal = await Task.detached(priority: .utility) { () -> Int? in
                if b > 0 { return source.estimatedCount(after: f, before: b >= Self.fromNow ? nil : b) }
                return source.estimatedCount(after: fw, before: nil)
            }.value

            // Newest first, down to the floor.
            if before > 0 {
                var finished = false
                while !Task.isCancelled {
                    let (lower, upper) = (floor, before >= Self.fromNow ? nil : before)
                    let batch = try await Task.detached(priority: .utility) {
                        try source.read(after: lower, before: upper, newestFirst: true, limit: Self.page, contacts: contacts)
                    }.value
                    guard !batch.isEmpty else { finished = true; break }
                    let dates = batch.map(\.date.timeIntervalSince1970)
                    if let newest = dates.max(), newest > forward {
                        // New messages from here on are the forward pass's job.
                        forward = newest
                        try await store.setCursor(forward, for: source.kind)
                    }
                    try await ingestLive(batch)
                    before = dates.min() ?? before
                    try await store.setCursor(before, named: beforeKey)
                    if batch.count < Self.page { finished = true; break }
                }
                if finished {
                    try await store.setCursor(0, named: beforeKey)
                    try await store.setCursor(0, named: floorKey)
                }
            }

            // Then whatever arrived since, oldest first.
            while !Task.isCancelled {
                let after = forward
                let batch = try await Task.detached(priority: .utility) {
                    try source.read(after: after, before: nil, newestFirst: false, limit: 5000, contacts: contacts)
                }.value
                guard !batch.isEmpty else { break }
                try await ingestLive(batch)
                forward = batch.map(\.date.timeIntervalSince1970).max() ?? forward
                try await store.setCursor(forward, for: source.kind)
                #if os(macOS)
                if source.kind == .claude, !Task.isCancelled { ClaudeHistorySource.commitProgress() }
                #endif
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

    /// Saves a batch in slices and links each one into the graph right away,
    /// so People and Graph fill in while reading.
    private func ingestLive(_ batch: [RawMessage]) async throws {
        // Small slices keep each hold on the store short, so a question
        // asked mid-read still gets its memories quickly.
        let sliceSize = 1000
        for slice in stride(from: 0, to: batch.count, by: sliceSize) {
            guard !Task.isCancelled else { return }
            let part = Array(batch[slice..<min(slice + sliceSize, batch.count)])
            let started = ContinuousClock.now
            try await MemoryStore.shared.ingest(part)
            readSoFar += part.count
            await Pace.rest(after: started)
            while !Task.isCancelled {
                let batch = ContinuousClock.now
                guard try await KnowledgeGraph.link(batch: 150) > 0 else { break }
                await Pace.rest(after: batch)
            }
            // Who is who, by id: people, groups and their members.
            if (try? await MemoryStore.shared.syncPeople()) ?? 0 > 0 { await PeopleDirectory.shared.refresh() }
            // Totals drive several screens; once a second is plenty.
            if Date().timeIntervalSince(lastTotals) > 1 {
                lastTotals = .now
                await refreshTotals()
            }
            try? await Task.sleep(for: .milliseconds(30))
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
            let started = ContinuousClock.now
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
            // Leave room for everything else on the Mac.
            await Pace.rest(after: started)
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
    /// Learns from the next moments. `untilDone` keeps going until every
    /// moment has been read (a re-read), instead of one batch per run.
    func learn(moments: Int = 400, untilDone: Bool = false) {
        guard learnTask == nil, !isPaused else { return }
        isLearning = true
        learnTask = Task(priority: .utility) {
            defer {
                isLearning = false
                learnTask = nil
                learnPhase = .idle
            }
            learnPhase = .learning(done: 0, total: moments)
            do {
                var read = 0
                var last = 0
                repeat {
                    let before = read
                    last = try await KnowledgeGraph.learn(maxMoments: moments) { [weak self] count in
                        self?.learnPhase = .learning(done: before + count, total: before + moments)
                    }
                    read += last
                    if untilDone { await refreshTotals() }
                    // A short batch means nothing is left to read.
                } while untilDone && last >= moments && !Task.isCancelled
                let portrait = try await KnowledgeGraph.writePortrait()
                if !portrait.isEmpty { AppSettings.shared.aboutMe = portrait }
                // Then the conversations that went deep, condensed.
                let reflectTotal = 120
                learnPhase = .reflecting(done: 0, total: reflectTotal)
                var reflected = 0
                repeat {
                    let before = reflected
                    let count = try await Reflections.run(limit: reflectTotal) { [weak self] count in
                        self?.learnPhase = .reflecting(done: before + count, total: reflectTotal)
                    }
                    reflected += count
                    if count == 0 { break }
                } while untilDone && !Task.isCancelled
            } catch {
                lastError = error.localizedDescription
            }
            await refreshTotals()
        }
    }

    /// Reads every message again: learning and deep memories start over,
    /// keeping what is already known.
    func reread() {
        stopLearning()
        Task {
            try? await MemoryStore.shared.resetLearning()
            await refreshTotals()
            learn()
        }
    }

    /// Reads your conversations with people again, until done: facts with
    /// proof, nicknames, who is linked to whom, and the deep conversations.
    func rereadPeople() {
        stopLearning()
        Task {
            try? await MemoryStore.shared.resetPeopleLearning()
            await refreshTotals()
            learn(untilDone: true)
        }
    }

    /// What a people re-read costs, roughly: moments, tokens and, when the
    /// catalogue knows the price, dollars.
    func peopleRelearnEstimate() async -> (moments: Int, tokens: Int, dollars: Double?) {
        let size = (try? await MemoryStore.shared.peopleRelearnSize()) ?? (moments: 0, characters: 0)
        // Instructions and schema per batch, the deep conversations again,
        // and what comes back.
        let input = Double(size.characters) * 1.25 / KnowledgeGraph.Budget.charactersPerToken
        let output = input * 0.12
        let model = ModelCatalog.shared.model(ModelHub.learningModel ?? AppSettings.shared.modelName)
        var dollars: Double?
        if let priceIn = model?.priceIn, let priceOut = model?.priceOut {
            dollars = (input * priceIn + output * priceOut) / 1_000_000
        }
        return (size.moments, Int(input + output), dollars)
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
        #if os(macOS)
        if source == .claude { ClaudeHistorySource.resetProgress() }
        #endif
        try? await MemoryStore.shared.forget(source: source)
        // Rebuild who is who from what is left, and drop forgotten names from
        // tags and photos.
        _ = try? await MemoryStore.shared.syncPeople()
        await PeopleDirectory.shared.refresh()
        #if os(macOS)
        await ContactPhotos.shared.refresh()
        #endif
        await refreshTotals()
    }
}
