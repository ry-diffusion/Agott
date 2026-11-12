import Foundation
import Testing
@testable import Agott

/// The sync Worker in memory, behind URLSession: same routes, versions and
/// conflicts as sync-worker/src/index.ts. Only answers for its own host.
final class FakeWorker: URLProtocol, @unchecked Sendable {
    struct Record { var version: Int; var seq: Int; var data: String? }
    nonisolated(unsafe) static var records: [String: [String: Record]] = [:]
    nonisolated(unsafe) static var meta: [String: Data] = [:]
    nonisolated(unsafe) static var seq = 0
    /// Every sealed body the Worker was given, to check it never saw plain text.
    nonisolated(unsafe) static var seen: [String] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "sync.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        let (status, body) = handle()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }

    private func handle() -> (Int, Data) {
        let url = request.url!
        let path = url.path()
        if path == "/v1/health" { return (200, json(["ok": true, "service": "agott-sync", "version": 1])) }
        guard let auth = request.value(forHTTPHeaderField: "Authorization"), auth.hasPrefix("Bearer ") else { return (401, json(["error": "unauthorized"])) }
        let vault = String(auth.dropFirst(7))
        let body = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            return data
        } ?? Data()
        if path == "/v1/meta" {
            if request.httpMethod == "GET" { return Self.meta[vault].map { (200, $0) } ?? (404, json(["error": "none"])) }
            if let current = Self.meta[vault] { return (current == body ? 200 : 409, current) }
            Self.meta[vault] = body
            return (201, body)
        }
        var records = Self.records[vault] ?? [:]
        if path == "/v1/records" {
            let since = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "since" }?.value ?? "0") ?? 0
            let changed = records.filter { $0.value.seq > since }.sorted { $0.value.seq < $1.value.seq }
            let list: [[String: Any]] = changed.map { ["id": $0.key, "version": $0.value.version, "seq": $0.value.seq, "data": $0.value.data as Any] }
            return (200, json(["records": list, "cursor": changed.last?.value.seq ?? since, "more": false]))
        }
        let id = String(path.dropFirst("/v1/records/".count))
        let put = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        let base = put["base"] as! Int
        let current = records[id]
        if (current?.version ?? 0) != base {
            let value: Any = current.map { ["id": id, "version": $0.version, "seq": $0.seq, "data": $0.data as Any] } ?? NSNull()
            return (409, json(["error": "changed elsewhere", "current": value]))
        }
        Self.seq += 1
        let record = Record(version: base + 1, seq: Self.seq, data: put["data"] as? String)
        Self.seen.append(record.data ?? "")
        records[id] = record
        Self.records[vault] = records
        return (200, json(["id": id, "version": record.version, "seq": record.seq, "data": record.data as Any]))
    }
}

@MainActor
@Suite(.serialized)
struct RoutineSyncTests {
    init() { URLProtocol.registerClass(FakeWorker.self) }

    private func device(_ name: String, _ account: SyncAccount) -> RoutineSync {
        let directory = FileManager.default.temporaryDirectory.appending(path: "agott-sync-\(UUID().uuidString)")
        let sync = RoutineSync(directory: directory, keepsAccount: false)
        sync.deviceName = name
        sync.use(account)
        return sync
    }

    private func account() async throws -> SyncAccount {
        let token = "fake-token-\(UUID().uuidString)"
        return try await SyncSetup.connect(url: URL(string: "https://sync.test")!, token: token, passphrase: "uma frase bem longa")
    }

    @Test func aRoutineGoesToTheWatchAndADayDoneComesBack() async throws {
        let account = try await account()
        let mac = device("Mac", account)
        let watch = device("Watch", account)
        var heard: [SyncPayload] = []
        mac.onReceive = { heard.append($0) }

        let routine = RoutineRecord(id: UUID(), title: "Calistenia", hour: 7, minute: 30,
                                    steps: "- 3x10 flexões\n- 3x15 agachamentos", updatedAt: Date())
        mac.save(routine)
        await mac.sync()
        await watch.sync()
        #expect(watch.active.map(\.title) == ["Calistenia"])
        #expect(watch.active.first?.plan.targets == [.pushUp: 30, .squat: 45])

        let proof = WorkoutProof(counts: [ExerciseCount(exercise: .pushUp, target: 30, counted: 30, sensor: .watch),
                                          ExerciseCount(exercise: .squat, target: 45, counted: 44, sensor: .watch)],
                                 started: Date(), ended: Date())
        watch.markDone(routine.id, proof: proof)
        await watch.sync()
        await mac.sync()
        #expect(mac.doneToday(routine.id)?.device == "Watch")
        #expect(mac.doneToday(routine.id)?.proof?.counts == proof.counts)
        #expect(mac.streak(routine.id) == 1)
        #expect(heard.contains { if case .done = $0 { true } else { false } })

        // The Worker only ever saw sealed bytes.
        #expect(!FakeWorker.seen.isEmpty)
        #expect(FakeWorker.seen.allSatisfy { $0.hasPrefix("v1.") && !$0.contains("Calistenia") })
    }

    @Test func theLaterEditWinsEverywhere() async throws {
        let account = try await account()
        let mac = device("Mac", account)
        let phone = device("iPhone", account)
        let id = UUID()
        mac.save(RoutineRecord(id: id, title: "Treino", hour: 7, minute: 0, updatedAt: Date(timeIntervalSinceNow: -60)))
        await mac.sync()
        await phone.sync()

        // Both change it offline; the phone's change is later.
        mac.save(RoutineRecord(id: id, title: "Treino (Mac)", hour: 8, minute: 0, updatedAt: Date(timeIntervalSinceNow: -30)))
        phone.save(RoutineRecord(id: id, title: "Treino (iPhone)", hour: 9, minute: 0, updatedAt: Date()))
        await phone.sync()
        await mac.sync() // conflict: the Mac's is older, so it takes the phone's
        await phone.sync()
        #expect(mac.routines[id]?.title == "Treino (iPhone)")
        #expect(phone.routines[id]?.title == "Treino (iPhone)")
    }

    @Test func theSameDayDoneOnTwoDevicesIsOneDay() async throws {
        let account = try await account()
        let mac = device("Mac", account)
        let watch = device("Watch", account)
        let id = UUID()
        mac.markDone(id)
        let proof = WorkoutProof(counts: [ExerciseCount(exercise: .pushUp, target: 10, counted: 10, sensor: .airpods)],
                                 started: Date(), ended: Date())
        watch.markDone(id, proof: proof)
        await mac.sync()
        await watch.sync()
        await mac.sync()
        #expect(mac.days(id).count == 1)
        // The copy with proof is kept on both.
        #expect(mac.doneToday(id)?.proof?.counts == proof.counts)
        #expect(watch.doneToday(id)?.proof?.counts == proof.counts)
    }

    @Test func aWrongPassphraseIsRefused() async throws {
        let account = try await account()
        await #expect(throws: SyncCryptoError.self) {
            _ = try await SyncSetup.connect(url: account.url, token: account.token, passphrase: "outra frase qualquer")
        }
        let again = try await SyncSetup.connect(url: account.url, token: account.token, passphrase: "uma frase bem longa")
        #expect(again.master == account.master)
    }
}
