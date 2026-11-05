//
//  AgottTests.swift
//  AgottTests
//

import Foundation
import FoundationModels
import Testing
@testable import Agott

@MainActor
struct MemoryStoreTests {
    private func tempStore() -> MemoryStore {
        let url = FileManager.default.temporaryDirectory.appending(path: "agott-test-\(UUID().uuidString).sqlite")
        return MemoryStore(url: url)
    }

    private func message(_ id: Int, chat: String = "ana", sender: String, me: Bool, minutes: Double, _ text: String) -> RawMessage {
        RawMessage(
            source: .whatsapp, externalID: "m\(id)", chatID: chat, chatName: chat == "ana" ? "Ana Souza" : chat,
            isGroup: false, sender: sender, isFromMe: me,
            date: Date(timeIntervalSince1970: 1_800_000_000 + minutes * 60), text: text)
    }

    @Test func ingestChunksAndSearches() async throws {
        let store = tempStore()
        let first = [
            message(1, sender: "Ana Souza", me: false, minutes: 0, "Bora pra Floripa no feriado?"),
            message(2, sender: "Eu", me: true, minutes: 2, "Bora! Vou ver as passagens"),
            // A long gap starts a new moment.
            message(3, sender: "Ana Souza", me: false, minutes: 300, "Achei um aniversário surpresa pro João"),
        ]
        #expect(try await store.ingest(first) == 3)
        // Re-ingesting is a no-op.
        #expect(try await store.ingest(first) == 0)

        let totals = try await store.totals()
        #expect(totals.messages == 3)
        #expect(totals.chunks == 2)

        // Accent-insensitive prefix match.
        let ids = try await store.keywordSearch("aniversario")
        let chunks = try await store.chunks(ids: ids)
        #expect(chunks.count == 1)
        #expect(chunks.first?.text.contains("João") == true)

        // A continuation lands in the same moment rather than a new one.
        try await store.ingest([message(4, sender: "Eu", me: true, minutes: 305, "Que demais, conta comigo")])
        #expect(try await store.totals().chunks == 2)

        let chats = try await store.chats()
        #expect(chats.first?.messageCount == 4)
        #expect(chats.first?.myCount == 2)
        #expect(chats.first?.lastFromMe == true)
    }

    /// Reading newest-first inserts history before existing moments. The
    /// moments must come out the same as reading in order.
    @Test func newestFirstChunksLikeInOrder() async throws {
        var all: [RawMessage] = []
        for i in 0..<60 {
            // Bursts of 6 messages, an hour apart.
            let minutes = Double(i / 6) * 60 + Double(i % 6)
            all.append(message(i, sender: i % 2 == 0 ? "Ana Souza" : "Eu", me: i % 2 == 1, minutes: minutes, "msg \(i)"))
        }
        let inOrder = tempStore()
        try await inOrder.ingest(all)

        let backwards = tempStore()
        for page in stride(from: all.count, to: 0, by: -13) {
            try await backwards.ingest(Array(all[max(0, page - 13)..<page]))
        }

        func texts(_ store: MemoryStore) async throws -> [String] {
            let ids = try await store.recentChunkIDs(filter: .none, limit: 100)
            return try await store.chunks(ids: ids).map(\.text).sorted()
        }
        let a = try await texts(inOrder)
        let b = try await texts(backwards)
        #expect(a.count == 10)
        #expect(a == b)
    }

    @Test func graphLinksPeopleAndFacts() async throws {
        let store = tempStore()
        try await store.ingest([
            message(1, sender: "Ana Souza", me: false, minutes: 0, "Encontrei a Mariana na Apple ontem em Cupertino"),
            message(2, sender: AppSettings.myNameSnapshot, me: true, minutes: 1, "Sério? Que legal"),
        ])
        _ = try await KnowledgeGraph.link(store: store)
        let people = try await store.entities(limit: 20)
        #expect(people.contains { $0.kind == .me })
        #expect(people.contains { $0.kind == .person && $0.name == "Ana Souza" })

        try await store.addFact(subject: "Ana Souza", predicate: "likes", object: "Floripa", confidence: 0.8,
                                source: .note, chunkID: nil, at: .now)
        let facts = try await store.facts(matching: "Ana")
        #expect(facts.first?.object == "Floripa")
    }

    @Test func vectorIndexFindsNearest() {
        let index = VectorIndex(ids: [1, 2, 3], matrix: [1, 0, 0, 1, 0.7071, 0.7071], dimension: 2)
        let result = index.nearest(to: [1, 0], limit: 2)
        #expect(result.map(\.0) == [1, 3])
    }
}

@MainActor
struct RelationshipTests {
    @Test func statsSeeWhoIsWaiting() {
        let now = Date()
        func line(_ id: Int64, me: Bool, hoursAgo: Double, _ text: String) -> ChatLine {
            ChatLine(id: id, sender: me ? "Eu" : "Ana", isFromMe: me, date: now.addingTimeInterval(-hoursAgo * 3600), text: text)
        }
        let stats = RelationshipAnalyzer.compute([
            line(1, me: true, hoursAgo: 72, "Oi!"),
            line(2, me: false, hoursAgo: 71.5, "Oi, tudo bem?"),
            line(3, me: true, hoursAgo: 71, "Tudo ótimo"),
            line(4, me: false, hoursAgo: 5, "Vamos jantar sexta?"),
        ], now: now)
        #expect(stats.total == 4)
        #expect(stats.mine == 2)
        #expect(stats.awaitingMyReply)
        #expect(stats.lastQuestionFromThem == "Vamos jantar sexta?")
        #expect(stats.myInitiations == 1)
        #expect(stats.theirInitiations == 1)
        #expect(stats.attention > 0)
    }

    @Test func ramblerRejectsDrift() {
        #expect(Rambler.isPlausible("Manda pro João amanhã às 10.", from: "manda pro pedro não pro joão amanhã às 10"))
        #expect(!Rambler.isPlausible("Send it to João tomorrow at 11.", from: "manda pro pedro não pro joão amanhã às 10"))
    }
}

@MainActor
struct OpenCodeWireTests {
    @Generable
    struct Args {
        @Guide(description: "What to look for")
        var query: String
        var days: Int?
    }

    /// The tool schema DeepSeek receives must be a JSON Schema object.
    @Test func toolSchemaIsJSONSchema() throws {
        let definition = Transcript.ToolDefinition(name: "search_memory", description: "Search", parameters: Args.generationSchema)
        let tool = OpenCodeExecutor.tool(definition)
        let function = try #require(tool["function"] as? [String: Any])
        let parameters = try #require(function["parameters"] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys])
        print("schema:", String(decoding: data, as: UTF8.self))
        #expect(parameters["type"] as? String == "object")
        let properties = try #require(parameters["properties"] as? [String: Any])
        #expect(properties["query"] != nil)
    }

    @Test func transcriptBecomesChatMessages() throws {
        let call = Transcript.ToolCall(id: "call_1", toolName: "search_memory", arguments: try GeneratedContent(json: #"{"query":"Floripa"}"#))
        let transcript = Transcript(entries: [
            .instructions(.init(segments: [.text(.init(content: "You are Agott."))], toolDefinitions: [])),
            .prompt(.init(segments: [.text(.init(content: "Quando é a viagem?"))])),
            .toolCalls(.init([call])),
            .toolOutput(.init(id: "call_1", toolName: "search_memory", segments: [.text(.init(content: "Feriado de novembro"))])),
        ])
        let request = LanguageModelExecutorGenerationRequest(
            id: UUID(), transcript: transcript, enabledTools: [], generationOptions: .init(),
            contextOptions: .init(), metadata: [:])
        let messages = OpenCodeExecutor.messages(from: request, vision: false)
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
        let calls = try #require(messages[2]["tool_calls"] as? [[String: Any]])
        #expect(calls.first?["id"] as? String == "call_1")
        #expect(messages[3]["tool_call_id"] as? String == "call_1")
    }
}

@MainActor
struct CirclesAndVoiceTests {
    @Test func circlesFormFromSharedGroups() async throws {
        let store = MemoryStore(url: FileManager.default.temporaryDirectory.appending(path: "agott-circles-\(UUID().uuidString).sqlite"))
        var messages: [RawMessage] = []
        var n = 0
        func group(_ chat: String, _ people: [String]) {
            for round in 0..<4 {
                for person in people {
                    n += 1
                    messages.append(RawMessage(
                        source: .whatsapp, externalID: "c\(n)", chatID: chat, chatName: chat, isGroup: true,
                        sender: person, isFromMe: false, date: Date().addingTimeInterval(-Double(n * 60 + round)), text: "oi \(n)"))
                }
            }
        }
        group("Família", ["Mãe", "Pai", "Tia"])
        group("Família 2", ["Mãe", "Pai"])
        group("Futebol", ["Lucas", "Rafa", "João"])
        try await store.ingest(messages)
        let drafts = try await Circles.detect(store: store)
        let sets = drafts.map { Set($0.members) }
        #expect(sets.contains(["Mãe", "Pai", "Tia"]))
        #expect(sets.contains(["Lucas", "Rafa", "João"]))
    }

    @Test func repliesSplitIntoBubbles() {
        let parts = AssistantTurnView.bubbles("oi\n\nhere is how:\n\n1. first\n\n2. second\n\nmakes sense?")
        #expect(parts == ["oi", "here is how:\n1. first\n2. second", "makes sense?"])
    }
}

/// Answers 429 "overloaded" a set number of times, then 200 with a stream.
final class FlakyServer: URLProtocol {
    nonisolated(unsafe) static var failuresLeft = 0
    nonisolated(unsafe) static var requests = 0

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "flaky.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests += 1
        let failing = Self.failuresLeft > 0
        if failing { Self.failuresLeft -= 1 }
        let status = failing ? 429 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: failing ? ["Retry-After": "0.1"] : ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = failing
            ? #"{"error":{"type":"server_error","message":"[overloaded] retry shortly"}}"#
            : "data: {\"choices\":[{\"delta\":{\"content\":\"oi\"}}]}\n\ndata: [DONE]\n\n"
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
@Suite(.serialized)
struct RetryTests {
    @Test func overloadedIsRetried() async throws {
        URLProtocol.registerClass(FlakyServer.self)
        defer { URLProtocol.unregisterClass(FlakyServer.self) }
        FlakyServer.failuresLeft = 2
        FlakyServer.requests = 0
        let bytes = try await OpenCodeExecutor.open(URLRequest(url: URL(string: "https://flaky.test/chat/completions")!))
        var lines: [String] = []
        for try await line in bytes.lines { lines.append(line) }
        #expect(FlakyServer.requests == 3)
        #expect(lines.contains { $0.contains("oi") })
    }

    @Test func giveUpAfterMaxAttempts() async throws {
        URLProtocol.registerClass(FlakyServer.self)
        defer { URLProtocol.unregisterClass(FlakyServer.self) }
        FlakyServer.failuresLeft = 99
        FlakyServer.requests = 0
        await #expect(throws: OpenCodeExecutor.ExecutorError.self) {
            _ = try await OpenCodeExecutor.open(URLRequest(url: URL(string: "https://flaky.test/chat/completions")!))
        }
        #expect(FlakyServer.requests == OpenCodeExecutor.maxAttempts)
    }
}

@MainActor
struct ClaudeReaderTests {
    @Test func readsEachFileOnceThenOnlyNewLines() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "claude-\(UUID().uuidString)/proj")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "session.jsonl")
        func line(_ type: String, _ text: String, _ id: String) -> String {
            #"{"type":"\#(type)","uuid":"\#(id)","timestamp":"2026-11-05T10:00:00.000Z","message":{"role":"\#(type)","content":"\#(text)"}}"# + "\n"
        }
        let toolResult = #"{"type":"user","uuid":"t","message":{"content":[{"type":"tool_result","tool_use_id":"x","content":"huge"}]}}"# + "\n"
        try (line("user", "build me an app", "a") + toolResult + line("assistant", "sure", "b")).write(to: file, atomically: true, encoding: .utf8)
        defer {
            var progress = UserDefaults.standard.dictionary(forKey: ClaudeHistorySource.progressKey) ?? [:]
            progress.removeValue(forKey: file.path)
            UserDefaults.standard.set(progress, forKey: ClaudeHistorySource.progressKey)
        }

        var source = ClaudeHistorySource()
        source.root = root
        let first = try source.read(after: 0, limit: 10, contacts: ContactBook())
        #expect(first.map(\.externalID) == ["a", "b"])  // tool result skipped
        #expect(try source.read(after: 0, limit: 10, contacts: ContactBook()).isEmpty)  // nothing new

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line("user", "and a graph", "c").utf8))
        try handle.close()
        #expect(try source.read(after: 0, limit: 10, contacts: ContactBook()).map(\.externalID) == ["c"])
    }
}

/// Reads a little from the real sources on this Mac. Prints counts only.
@MainActor
struct LiveSourceSmokeTests {
    @Test(.disabled(if: ProcessInfo.processInfo.environment["AGOTT_LIVE"] == nil, "Set AGOTT_LIVE=1 to read real sources"))
    func readSources() throws {
        let contacts = ContactBook()
        let sources: [any MessageSource] = [WhatsAppSource(), IMessageSource(), ClaudeHistorySource()]
        for source in sources where source.isPresent {
            do {
                let messages = try source.read(after: Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970, limit: 200, contacts: contacts)
                let chats = Set(messages.map(\.chatID)).count
                print("\(source.kind.rawValue): \(messages.count) messages in \(chats) chats, \(messages.filter(\.isFromMe).count) from me")
            } catch {
                print("\(source.kind.rawValue): \(error.localizedDescription)")
            }
        }
    }
}
