import Foundation
import Observation

/// Routines, the days they were done, and the API keys, the same on the Mac,
/// the iPhone and the Watch, through the sync Worker.
///
/// Each device keeps its own copy and works without the others: changes go
/// to an outbox and leave when the Worker can be reached; what other devices
/// wrote comes in by asking for everything after the last change seen. Two
/// devices changing one routine: the later change wins. Days done only grow,
/// so they never conflict, and the streak is counted from them.
@MainActor @Observable
final class RoutineSync {
    static let shared = RoutineSync()

    private(set) var account: SyncAccount?
    private(set) var routines: [UUID: RoutineRecord] = [:]
    private(set) var done: [String: DoneRecord] = [:]
    private(set) var lastSync: Date?
    private(set) var problem: String?
    private(set) var isSyncing = false

    var isConnected: Bool { account != nil }

    /// What this device is called in a day's proof.
    @ObservationIgnored var deviceName = "Mac"
    /// Something another device wrote, after it is merged here.
    @ObservationIgnored var onReceive: ((SyncPayload) -> Void)?
    /// The keys this device has, and where to put keys from the others.
    @ObservationIgnored var localKeys: (() -> [String: String])?
    @ObservationIgnored var applyKeys: (([String: String]) -> Void)?

    private struct Cache: Codable {
        var routines: [RoutineRecord] = []
        var done: [DoneRecord] = []
        var versions: [String: Int] = [:]
        var cursor = 0
        var outbox: [String] = []
        var keysUpdatedAt: Date?
        var lastSync: Date?
    }

    @ObservationIgnored private var versions: [String: Int] = [:]
    @ObservationIgnored private var cursor = 0
    @ObservationIgnored private var outbox: [String] = []
    @ObservationIgnored private var keysUpdatedAt: Date?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Void, Never>?
    private let url: URL
    /// Off in tests: the account stays in memory, never in the Keychain.
    private let keepsAccount: Bool

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Agott"), account: SyncAccount?? = nil,
         keepsAccount: Bool = true) {
        url = directory.appending(path: "sync.json")
        self.keepsAccount = keepsAccount
        self.account = account ?? (keepsAccount ? SyncAccount.load() : nil)
        if let data = try? Data(contentsOf: url), let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            routines = Dictionary(cache.routines.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            done = Dictionary(cache.done.map { (DoneRecord.name($0.routineID, day: $0.day), $0) }, uniquingKeysWith: { $1 })
            versions = cache.versions
            cursor = cache.cursor
            outbox = cache.outbox
            keysUpdatedAt = cache.keysUpdatedAt
            lastSync = cache.lastSync
        }
    }

    // MARK: Reading

    /// Routines that are on, by time of day.
    var active: [RoutineRecord] {
        routines.values.filter { !$0.stopped }.sorted { ($0.hour, $0.minute, $0.title) < ($1.hour, $1.minute, $1.title) }
    }

    func days(_ routineID: UUID) -> Set<String> {
        Set(done.values.filter { $0.routineID == routineID }.map(\.day))
    }

    func streak(_ routineID: UUID, today: Date = Date()) -> Int {
        RoutineDays.streak(days(routineID), today: today)
    }

    func doneToday(_ routineID: UUID, now: Date = Date()) -> DoneRecord? {
        done[DoneRecord.name(routineID, day: RoutineDays.day(now))]
    }

    // MARK: Writing

    func save(_ routine: RoutineRecord) { store(.routine(routine)) }

    /// Today counted for a routine, with what proves it if there is proof.
    @discardableResult
    func markDone(_ routineID: UUID, at date: Date = Date(), proof: WorkoutProof? = nil) -> DoneRecord {
        let record = DoneRecord(routineID: routineID, day: RoutineDays.day(date), at: date, device: deviceName, proof: proof)
        store(.done(record))
        return done[DoneRecord.name(routineID, day: record.day)] ?? record
    }

    /// This device's keys changed (or sync just started): they travel.
    func keysChanged() {
        guard isConnected, let values = localKeys?(), !values.isEmpty else { return }
        keysUpdatedAt = Date()
        store(.keys(KeysRecord(values: values, updatedAt: keysUpdatedAt!)))
    }

    private func store(_ payload: SyncPayload) {
        let merged = local(payload.name).map { SyncPayload.newer(payload, $0) } ?? payload
        apply(merged)
        if !outbox.contains(payload.name) { outbox.append(payload.name) }
        persist()
        soon()
    }

    // MARK: Connecting

    func connect(url: URL, token: String, passphrase: String) async throws {
        let account = try await SyncSetup.connect(url: url, token: token, passphrase: passphrase)
        use(account)
    }

    /// An account handed over by another device (the iPhone to its Watch).
    func use(_ account: SyncAccount) {
        let changed = account != self.account
        if keepsAccount { SyncAccount.save(account) }
        self.account = account
        if changed {
            // A different vault: what came from the old one is not in it.
            versions = [:]
            cursor = 0
            outbox = Array(Set(outbox + routines.values.map { RoutineRecord.name($0.id) }
                + done.values.map { DoneRecord.name($0.routineID, day: $0.day) }))
        }
        problem = nil
        persist()
        if keepsAccount { Task { await sync() } }
    }

    func disconnect() {
        if keepsAccount { SyncAccount.save(nil) }
        account = nil
        versions = [:]
        cursor = 0
        outbox = []
        problem = nil
        persist()
    }

    // MARK: Syncing

    /// Soon, once: several changes in a row leave together.
    private func soon() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    /// Sends what is waiting, then takes what the others wrote.
    func sync() async {
        if let running { return await running.value }
        let task = Task { await self.run() }
        running = task
        await task.value
        running = nil
    }

    private func run() async {
        guard let account, let keys = account.keys else { return }
        let client = SyncClient(url: account.url, token: account.token)
        isSyncing = true
        defer { isSyncing = false; persist() }
        do {
            problem = nil
            try await pull(client, keys)
            for name in outbox { try await push(name, client, keys) }
            lastSync = Date()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func pull(_ client: SyncClient, _ keys: SyncKeys) async throws {
        while true {
            let page = try await client.changes(since: cursor)
            for record in page.records {
                versions[record.id] = record.version
                guard let data = record.data else { continue }
                guard let payload = try? open(data, id: record.id, keys) else {
                    problem = SyncCryptoError.wrongKey.localizedDescription
                    continue
                }
                receive(payload)
            }
            cursor = page.cursor
            if !page.more { break }
        }
    }

    private func push(_ name: String, _ client: SyncClient, _ keys: SyncKeys) async throws {
        let id = keys.recordID(name)
        for _ in 0..<3 {
            guard let payload = local(name) else { outbox.removeAll { $0 == name }; return }
            let sealed = try keys.seal(try JSONEncoder.sync.encode(payload), id: id)
            switch try await client.put(id: id, data: sealed, base: versions[id] ?? 0) {
            case .stored(let record):
                versions[id] = record.version
                outbox.removeAll { $0 == name }
                return
            case .conflict(let current):
                versions[id] = current?.version ?? 0
                if let data = current?.data, let theirs = try? open(data, id: id, keys) {
                    let winner = SyncPayload.newer(payload, theirs)
                    if winner == theirs {
                        // Theirs is newer (or as good): keep it, nothing to send.
                        receive(theirs)
                        outbox.removeAll { $0 == name }
                        return
                    }
                }
                // Ours is newer: write again on top of theirs.
            }
        }
    }

    private func open(_ data: String, id: String, _ keys: SyncKeys) throws -> SyncPayload {
        try JSONDecoder.sync.decode(SyncPayload.self, from: keys.open(data, id: id))
    }

    /// Something from another device, merged in.
    private func receive(_ incoming: SyncPayload) {
        let mine = local(incoming.name)
        let winner = mine.map { SyncPayload.newer($0, incoming) } ?? incoming
        guard winner != mine else { return }
        // Theirs stands: nothing of ours left to send for it.
        outbox.removeAll { $0 == incoming.name }
        apply(winner)
        if case .keys(let keys) = winner {
            keysUpdatedAt = keys.updatedAt
            applyKeys?(keys.values)
        }
        onReceive?(winner)
    }

    private func apply(_ payload: SyncPayload) {
        switch payload {
        case .routine(let routine): routines[routine.id] = routine
        case .done(let record): done[DoneRecord.name(record.routineID, day: record.day)] = record
        case .keys(let keys): keysUpdatedAt = keys.updatedAt
        }
    }

    private func local(_ name: String) -> SyncPayload? {
        if name == KeysRecord.name {
            guard let keysUpdatedAt, let values = localKeys?(), !values.isEmpty else { return nil }
            return .keys(KeysRecord(values: values, updatedAt: keysUpdatedAt))
        }
        if name.hasPrefix("routine/"), let id = UUID(uuidString: String(name.dropFirst("routine/".count))) {
            return routines[id].map { .routine($0) }
        }
        return done[name].map { .done($0) }
    }

    private func persist() {
        // Keys are never written here: they live in the Keychain.
        let cache = Cache(routines: Array(routines.values), done: Array(done.values), versions: versions, cursor: cursor,
                          outbox: outbox, keysUpdatedAt: keysUpdatedAt, lastSync: lastSync)
        guard let data = try? JSONEncoder.sync.encode(cache) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}

nonisolated extension JSONEncoder {
    static var sync: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

nonisolated extension JSONDecoder {
    static var sync: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
