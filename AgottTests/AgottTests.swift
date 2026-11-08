//
//  AgottTests.swift
//  AgottTests
//

import Foundation
import FoundationModels
import Testing
import SwiftUI
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

    @Test func tracesOnePerson() async throws {
        let store = tempStore()
        var group = message(1, chat: "g1", sender: "Erika", me: false, minutes: 0, "bora no projeto x")
        group.isGroup = true
        group.chatName = "PROJETO X"
        try await store.ingest([
            group,
            message(2, sender: "Erika", me: false, minutes: 5, "oi sumido"),
            message(3, sender: "Eu", me: true, minutes: 6, "oi!"),
        ])
        let trace = try await store.trace(of: "Erika")
        #expect(trace.total == 2)
        #expect(trace.inGroups == 1)
        #expect(trace.groups.first?.name == "PROJETO X")
        let said = try await store.messages(by: "Erika", limit: 10)
        #expect(said.map(\.line.text) == ["bora no projeto x", "oi sumido"])
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
        // A reply that is only whitespace (the card said it all) is no bubble at all.
        #expect(AssistantTurnView.bubbles("\n").isEmpty)
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
        // Not committed (as if the app stopped before storing): read again.
        #expect(try source.read(after: 0, limit: 10, contacts: ContactBook()).map(\.externalID) == ["a", "b"])
        ClaudeHistorySource.commitProgress()
        #expect(try source.read(after: 0, limit: 10, contacts: ContactBook()).isEmpty)  // nothing new

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line("user", "and a graph", "c").utf8))
        try handle.close()
        #expect(try source.read(after: 0, limit: 10, contacts: ContactBook()).map(\.externalID) == ["c"])
        ClaudeHistorySource.commitProgress()
    }
}

/// A fake OpenCode Go: the first call asks for a tool, the second answers.
final class FakeModelServer: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fake-model.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let sent = String(decoding: body, as: UTF8.self)
        let path = request.url?.path ?? ""
        let events: [String]
        if path.hasSuffix("/responses"), sent.contains("json_schema") {
            // OpenAI's rule: a JSON answer needs "json" in the input messages.
            let inputPart = sent.components(separatedBy: #""input""#).dropFirst().joined()
            events = inputPart.localizedCaseInsensitiveContains("json")
                ? [#"{"type":"response.output_text.delta","delta":"{\"closeness\": 80, \"vibe\": \"carinhosa\"}"}"#]
                : [#"{"type":"error","message":"Response input messages must contain the word 'json'"}"#]
        } else if path.hasSuffix("/responses") {
            // OpenAI Responses, the way GPT-6 Luna streams.
            events = sent.contains("function_call_output")
                ? [#"{"type":"response.output_text.delta","delta":"achei: floripa no feriado"}"#, #"{"type":"response.completed"}"#]
                : [#"{"type":"response.reasoning_summary_text.delta","delta":"preciso lembrar da viagem"}"#,
                   #"{"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_r1","name":"echo_memory","arguments":"{\"query\":\"Floripa\"}"}}"#]
        } else if path.hasSuffix("/messages") {
            // Anthropic Messages, the way Claude Haiku streams.
            events = sent.contains("tool_result")
                ? [#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                   #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"achei: floripa no feriado"}}"#,
                   #"{"type":"message_stop"}"#]
                : [#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
                   #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"preciso lembrar da viagem"}}"#,
                   #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"echo_memory","input":{}}}"#,
                   #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\":"}}"#,
                   #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"Floripa\"}"}}"#,
                   #"{"type":"message_stop"}"#]
        } else if sent.contains("response_format") {
            // A structured request answered the way models often do: fenced, with chatter;
            // a thinking model reasons first.
            let thinking = sent.contains("reasoning_effort")
                ? [#"{"choices":[{"delta":{"reasoning_content":"vou ler a conversa"}}]}"#] : []
            events = thinking + [#"{"choices":[{"delta":{"content":"Claro! Aqui está:\n```json\n{\"closeness\": 80, "}}]}"#,
                      #"{"choices":[{"delta":{"content":"\"vibe\": \"carinhosa\"}\n```"}}]}"#]
        } else {
            let hasToolResult = sent.contains(#""role":"tool""#)
            events = hasToolResult
            ? [#"{"choices":[{"delta":{"content":"achei: floripa no feriado"}}]}"#]
            : [#"{"choices":[{"delta":{"reasoning_content":"preciso lembrar da viagem"}}]}"#,
               #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"echo_memory","arguments":"{\"query\":\"Floripa\"}"}}]}}]}"#]
        }
        let sse = events.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(sse.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

nonisolated struct EchoMemoryTool: Tool {
    let name = "echo_memory"
    let description = "Looks something up."
    @Generable struct Arguments { var query: String }
    @concurrent func call(arguments: Arguments) async throws -> String { "found \(arguments.query) trip in November" }
}

@MainActor
struct StepsTests {
    @Test func toolLoopProducesThinkingAndToolSteps() async throws {
        URLProtocol.registerClass(FakeModelServer.self)
        defer { URLProtocol.unregisterClass(FakeModelServer.self) }
        let model = OpenCodeLanguageModel(configuration: .init(
            baseURL: "https://fake-model.test", model: "fake", apiKey: "test-key"))
        let session = LanguageModelSession(model: model, tools: [EchoMemoryTool()], instructions: "Be brief.")
        let baseline = session.transcript.count
        let answer = try await session.respond(to: "quando é a viagem?").content
        #expect(answer.contains("floripa"))

        let steps = StepTracker.steps(from: session.transcript, after: baseline, busy: false, clock: .init())
        #expect(steps.contains { $0.kind == .thinking && ($0.detail ?? "").contains("viagem") })
        let tool = try #require(steps.first { $0.kind == .tool })
        #expect(tool.state == .done)
        #expect((tool.detail ?? "").contains("found Floripa"))
    }

    /// GPT-6 Luna (Responses) and Claude Haiku (Messages) go through the same
    /// tool loop as DeepSeek.
    @Test(arguments: [OpenCodeExecutor.API.responses, .messages])
    func otherWireFormatsRunTheToolLoop(api: OpenCodeExecutor.API) async throws {
        URLProtocol.registerClass(FakeModelServer.self)
        defer { URLProtocol.unregisterClass(FakeModelServer.self) }
        let model = OpenCodeLanguageModel(configuration: .init(
            baseURL: "https://fake-model.test", model: "fake", apiKey: "test-key", api: api))
        let session = LanguageModelSession(model: model, tools: [EchoMemoryTool()], instructions: "Be brief.")
        let baseline = session.transcript.count
        let answer = try await session.respond(to: "quando é a viagem?").content
        #expect(answer.contains("floripa"))
        let steps = StepTracker.steps(from: session.transcript, after: baseline, busy: false, clock: .init())
        #expect(steps.contains { $0.kind == .thinking && ($0.detail ?? "").contains("viagem") })
        #expect((steps.first { $0.kind == .tool }?.detail ?? "").contains("found Floripa"))
    }

    @Generable struct Mini { var closeness: Int; var vibe: String }

    /// The "Failed to parse generated content" error: fenced JSON must parse.
    @Test func fencedJSONParses() async throws {
        URLProtocol.registerClass(FakeModelServer.self)
        defer { URLProtocol.unregisterClass(FakeModelServer.self) }
        let model = OpenCodeLanguageModel(configuration: .init(baseURL: "https://fake-model.test", model: "fake", apiKey: "k"))
        let session = LanguageModelSession(model: model, instructions: "Read the relationship.")
        let read = try await session.respond(to: "como estou com a Ana?", generating: Mini.self).content
        #expect(read.closeness == 80)
        #expect(read.vibe == "carinhosa")
        #expect(OpenCodeExecutor.cleanJSON("ok: {\"a\": 1} bye") == "{\"a\": 1}")
    }

    /// "Read again" with a thinking model: reasoning arrives before the JSON.
    @Test func structuredAnswerAfterThinking() async throws {
        URLProtocol.registerClass(FakeModelServer.self)
        defer { URLProtocol.unregisterClass(FakeModelServer.self) }
        let model = OpenCodeLanguageModel(configuration: .init(
            baseURL: "https://fake-model.test", model: "fake", apiKey: "k", reasoningEffort: "low", family: "deepseek-flash"))
        let session = LanguageModelSession(model: model, instructions: "Read the relationship.")
        let read = try await session.respond(to: "como estou com a Ana?", generating: Mini.self).content
        #expect(read.closeness == 80)
    }

    /// GPT-6 Luna: JSON answers through the Responses API.
    @Test func responsesJSONAnswer() async throws {
        URLProtocol.registerClass(FakeModelServer.self)
        defer { URLProtocol.unregisterClass(FakeModelServer.self) }
        let model = OpenCodeLanguageModel(configuration: .init(baseURL: "https://fake-model.test", model: "gpt-6-luna", apiKey: "k", api: .responses))
        let session = LanguageModelSession(model: model, instructions: "Read the relationship.")
        let read = try await session.respond(to: "o que a clara pensa sobre mim", generating: Mini.self).content
        #expect(read.closeness == 80)
    }

    @Test func busyModelShowsThinking() {
        let transcript = Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "oi"))]))])
        let steps = StepTracker.steps(from: transcript, after: 0, busy: true, clock: .init())
        #expect(steps.last?.kind == .thinking)
        #expect(steps.last?.state == .running)
    }
}

@MainActor
struct HarnessTests {
    @Test func markdownBecomesBlocks() {
        let blocks = MarkdownBlock.parse("""
        # Plano

        oi, **isso** aqui:

        - um
        - dois
          continua

        1. primeiro
        2. segundo

        > citação

        ```swift
        let x = 1
        ```

        | a | b |
        |---|---|
        | 1 | 2 |
        """)
        #expect(blocks == [
            .heading(1, "Plano"),
            .paragraph("oi, **isso** aqui:"),
            .list(ordered: false, items: [.init(text: "um", depth: 0), .init(text: "dois continua", depth: 0)]),
            .list(ordered: true, items: [.init(text: "primeiro", depth: 0), .init(text: "segundo", depth: 0)]),
            .quote("citação"),
            .code(language: "swift", code: "let x = 1"),
            .table(header: ["a", "b"], rows: [["1", "2"]]),
        ])
    }

    @Test func memoryResultsBecomeItems() {
        let output = """
        Known facts:
        - Ana likes surf

        Relevant moments from memory:
        ### WhatsApp · Ana · 2026-10-02 18:00
        Ana: bora pra Floripa?
        Me: bora
        ### iMessage · Lucas · 2026-09-01 09:00
        Lucas: oi
        """
        let items = StepTracker.items(in: output)
        #expect(items.map(\.title) == ["Ana", "Lucas"])
        #expect(items[0].subtitle == "WhatsApp · 2026-10-02 18:00")
        #expect(items[0].snippet == "Ana: bora pra Floripa?\nMe: bora")
        #expect(StepTracker.items(in: "No memories found.").isEmpty)
    }

    @Test func publishedPagesAreSafe() throws {
        #expect(ArtifactPublisher.slug("Clara — perfil!") == "clara-perfil")
        #expect(ArtifactPublisher.slug("Ação & Reação") == "acao-reacao")
        #expect(ArtifactPublisher.slug("🙂") == "artifact")
        // Content cannot close the script it is embedded in.
        let js = SitePages.jsString("a </script><script>alert(1)</script> \"q\"")
        #expect(!js.contains("</script"))
        #expect(js.hasPrefix("\"") && js.hasSuffix("\""))
        #expect(SitePages.escape("<b>\"x\" & y</b>") == "&lt;b&gt;&quot;x&quot; &amp; y&lt;/b&gt;")

        let entry = ArtifactPublisher.Entry(key: "k", slug: "k", title: "<Plano>", kind: .document,
                                            version: 2, versions: [1, 2], published: .now)
        let index = SitePages.index([entry], domain: "artifacts.example.com")
        #expect(index.contains("&lt;Plano&gt;"))
        #expect(index.contains("/a/k/v2/"))
        let doc = SitePages.artifact(.init(key: "k", title: "T", kind: .document, content: "# Oi"), entry: entry)
        #expect(doc.contains("marked.parse"))

        if let out = ProcessInfo.processInfo.environment["AGOTT_SITE_OUT"] {
            try SitePages.index([], domain: "artifacts.grupomidas.com.br")
                .write(toFile: out, atomically: true, encoding: .utf8)
        }
    }

    @Test func jevAnswersParse() {
        let body = """
        {"model":"jev-latest","answers":{
          "needs_reply":{"type":"noul","noul":0.91},
          "kind":{"type":"choice","choice":"plan","confidence":0.7,"probabilities":{"plan":0.7,"question":0.3}},
          "urgency":{"type":"score","score":1.4,"confidence":0.6,"legend":{"0":"a","1":"b"},"probabilities":{"0":0.1,"1":0.9}}
        },"usage":{"input_tokens":10,"output_tokens":3}}
        """
        let answers = Jev.parse(Data(body.utf8))
        #expect(answers["needs_reply"]?.probability == 0.91)
        #expect(answers["kind"]?.choice == "plan")
        #expect(answers["urgency"]?.score == 1.4)
    }

    @Test func spotifyPKCEChallenge() {
        // Reference computed independently (Python hashlib + urlsafe base64).
        #expect(SpotifyAccount.challenge(for: "dBjftJeZ4CVP-mJ92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "ngF5GsXcbwljx6u133FFr3Xht9xooA_DuaX_3QwODtc")
        let verifier = SpotifyAccount.randomVerifier()
        #expect(verifier.count == 64)
    }

    @Test func smallTalkIsNotDeep() {
        let chunk = { (text: String) in
            MemoryChunk(id: 1, source: .whatsapp, chatID: "c", chatName: "Ana", start: .now, end: .now, text: text, participants: [])
        }
        #expect(Reflections.heuristicDepth(chunk("Ana: oi\nMe: oi")) < Reflections.deepEnough)
        let long = (0..<30).map { i in (i % 2 == 0 ? "Ana: " : "Me: ") + String(repeating: "sinto que a gente precisa conversar sobre isso ", count: 3) }
        #expect(Reflections.heuristicDepth(chunk(long.joined(separator: "\n"))) >= Reflections.deepEnough)
    }

    @Test func chatThinksAndReadingStaysCheap() {
        let model = CatalogModel(id: "m", name: "M", summary: "", family: "deepseek-flash", context: 1, output: 1,
                                 chatBaseURL: "x", api: "chat-completions", vision: false, reasoning: true,
                                 efforts: ["low", "high", "max"], tools: true)
        #expect(ModelHub.effort(for: model, thinking: true) == "high")
        #expect(ModelHub.effort(for: model, thinking: false) == "low")
        var messages = model
        messages.api = "messages"
        #expect(ModelHub.effort(for: messages, thinking: true) == nil)
    }
}

@MainActor
struct MemoryQualityTests {
    @Test func namesProjectsAndSecrets() {
        #expect(!KnowledgeGraph.isPlausibleName("Mano"))
        #expect(!KnowledgeGraph.isPlausibleName("NAO"))
        #expect(!KnowledgeGraph.isPlausibleName("+141377874698479"))
        #expect(KnowledgeGraph.isPlausibleName("Dayvid Albuquerque"))
        #expect(KnowledgeGraph.isPlausibleName("Florianópolis"))
        #expect(KnowledgeGraph.projectName("git/personal/Licor/wt/slot/cl/h3") == "Licor")
        #expect(KnowledgeGraph.projectName("git/iAndroid/ios/beryllium//claude/worktrees/wlan26") == "beryllium")
        #expect(KnowledgeGraph.projectName("git/midas/app/pack") == "pack")
        #expect(KnowledgeGraph.isSensitive("Moizes keeps the TypeSafe token at /Users/x/TYPESAFE.txt"))
        #expect(!KnowledgeGraph.isSensitive("Moizes works on Midas Mail"))
        #expect(KnowledgeGraph.sameMeaning("uv for Python dependencies", "uv to install Python dependencies"))
        #expect(!KnowledgeGraph.sameMeaning("SvelteKit", "Cloudflare Workers"))
    }

    @Test func repairRenamesAndCleans() async throws {
        let store = MemoryStore(url: FileManager.default.temporaryDirectory.appending(path: "agott-repair-\(UUID().uuidString).sqlite"))
        let base = Date().addingTimeInterval(-3600)
        try await store.ingest([
            RawMessage(source: .whatsapp, externalID: "r1", chatID: "g", chatName: "Grupo", isGroup: true,
                       sender: "+141377874698479", isFromMe: false, date: base, text: "bora jogar quinta"),
            RawMessage(source: .whatsapp, externalID: "r2", chatID: "g", chatName: "Grupo", isGroup: true,
                       sender: "Eu", isFromMe: true, date: base.addingTimeInterval(60), text: "bora"),
        ])
        try await store.renameSenders(["+141377874698479": "Lucas"], source: .whatsapp)
        let ids = try await store.keywordSearch("Lucas")
        let chunk = try #require(try await store.chunks(ids: ids).first)
        #expect(chunk.text.contains("] Lucas: bora jogar"))
        #expect(chunk.participants.contains("Lucas"))

        for (p, o) in [("uses", "uv for Python dependencies"), ("uses", "uv to install Python dependencies"),
                       ("keeps", "the API token at ~/secret.txt"), ("is named", "Eu")] {
            try await store.addFact(subject: "Eu", predicate: p, object: o, confidence: 0.8, source: .claude, chunkID: nil, at: .now)
        }
        try await store.cleanFacts(me: "Eu")
        let facts = try await store.facts(limit: 50)
        #expect(facts.count == 1)
        #expect(facts.first?.predicate == "uses")
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

/// Draws chat pieces offscreen when AGOTT_SNAPSHOT_DIR is set, to look at
/// them without opening a window.
@MainActor
struct SnapshotTests {
    @Test func chatPieces() throws {
        guard let dir = ProcessInfo.processInfo.environment["AGOTT_SNAPSHOT_DIR"] else { return }
        let now = Date()
        let view = VStack(alignment: .leading, spacing: 3) {
            HStack { Spacer(); MessageBubble(outgoing: true, joinsBelow: true) {
                TextWithTime(text: "oi, tudo bem?", time: now, outgoing: true) } }
            HStack { Spacer(); MessageBubble(outgoing: true, joinsAbove: true) {
                TextWithTime(text: "me responde em texto sem ter que usar o doc", time: now, outgoing: true) } }
            HStack { MessageBubble(outgoing: false, joinsBelow: true) {
                TextWithTime(text: "tá aqui, com data e hora.", time: now, outgoing: false) }; Spacer() }
            HStack { MessageBubble(outgoing: false, joinsAbove: true) {
                DocumentRow(symbol: "doc.richtext", title: "Como lidar com as crises", detail: "Documento · 3 min de leitura") }; Spacer() }
            HStack(spacing: 10) {
                InitialsAvatar(text: "Crises de bipolaridade", size: 46)
                InitialsAvatar(text: "Como foi meu dia", size: 46)
                InitialsAvatar(text: "qm eu mais odeio", size: 46)
                PeopleAvatar(people: ["Hellen", "Pamela", "Carol"], size: 46)
            }
            .padding(.top, 12)
            TypingDots().padding(.top, 12)
        }
        .padding(24)
        .frame(width: 520)
        .background(Ink.canvas)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { Issue.record("no image"); return }
        let url = URL(fileURLWithPath: dir).appending(path: "chat-pieces.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func rankedChart() throws {
        guard let dir = ProcessInfo.processInfo.environment["AGOTT_SNAPSHOT_DIR"] else { return }
        let chart = Card.ChartData(
            title: "Suas bandas e artistas mais tocados", subtitle: "últimos 14 dias · 209 faixas no total",
            kind: .horizontalBar,
            labels: ["O Grilo", "FOTO EM GRUPO", "Venere Vai Venus", "Lua Dultra", "kenji", "Israel Paixão"],
            series: [.init(name: "Faixas", values: [33, 18, 17, 13, 10, 9])], unit: "faixas")
        let view = ChartCardView(chart: chart)
            .padding(24)
            .frame(width: 700)
            .background(Color(.sRGB, red: 0.2, green: 0.1, blue: 0.2))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { Issue.record("no image"); return }
        let url = URL(fileURLWithPath: dir).appending(path: "ranked-chart.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}


/// Jev's answers become lookups; code owns the thresholds.
struct RecallPlannerTests {
    @Test func picksPersonPeriodAndLookups() {
        let answers: [String: Jev.Answer] = [
            "person": .init(choice: "c3"),
            "period": .init(choice: "yesterday"),
            "read_chat": .init(probability: 0.7),
            "relationship": .init(probability: 0.2),
            "overview": .init(probability: 0.9),
            "calendar": .init(choice: "day"),
        ]
        let plan = RecallPlanner.plan(from: answers, names: ["c3": "Clara"])
        #expect(plan.person == "Clara")
        #expect(plan.since == Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: .now)))
        #expect(plan.readChat)
        #expect(!plan.relationship)
        // About one person, so not about everyone.
        #expect(!plan.overview)
        #expect(plan.calendarDays == 2)
    }

    @Test func nobodyAndNoTimeIsAnEmptyPlan() {
        let answers: [String: Jev.Answer] = [
            "person": .init(choice: "none"),
            "period": .init(choice: "any"),
            "read_chat": .init(probability: 0.9),
            "overview": .init(probability: 0.1),
            "calendar": .init(choice: "none"),
        ]
        let plan = RecallPlanner.plan(from: answers, names: [:])
        #expect(plan.isEmpty)
        // Reading a chat needs someone to read.
        #expect(!plan.readChat)
    }

    @Test func everyQuestionHasItsOptions() {
        let questions = RecallPlanner.questions(candidates: ["none": "Nobody.", "c0": "Clara."])
        #expect(Set(questions.keys) == ["person", "period", "read_chat", "relationship", "overview", "calendar"])
    }
}


/// "Ligia" is the person, not the class group named after a teacher.
struct NameResolutionTests {
    private func chat(_ name: String, group: Bool, count: Int = 10) -> ChatSummary {
        ChatSummary(source: .whatsapp, chatID: name, name: name, isGroup: group, messageCount: count, myCount: 0,
                    firstDate: .now, lastDate: .now, lastFromMe: false, lastText: "")
    }

    @Test func personBeforeGroupNamedAfterThem() {
        let all = [chat("bio a ligia", group: true, count: 1200), chat("Lígia", group: false, count: 19)]
        let target = MemoryStore.target(for: "Ligia", in: all)
        #expect(target.chats.map(\.name) == ["Lígia"])
        #expect(target.spellings.contains("Lígia"))
    }

    @Test func groupByItsOwnName() {
        let all = [chat("bio a ligia", group: true), chat("Lígia", group: false)]
        #expect(MemoryStore.target(for: "bio a ligia", in: all).chats.map(\.name) == ["bio a ligia"])
    }

    @Test func wholeWordsOnly() {
        let all = [chat("Analu", group: false), chat("Ana Souza", group: false)]
        #expect(MemoryStore.target(for: "ana", in: all).chats.map(\.name) == ["Ana Souza"])
    }

    @Test func ambiguousNamesAreSpelledOut() {
        let line = Retriever.Recall.whoIsWho(name: "Ligia", chats: [chat("Lígia", group: false), chat("bio a ligia", group: true)])
        #expect(line?.contains("the group \"bio a ligia\"") == true)
        #expect(Retriever.Recall.whoIsWho(name: "Ligia", chats: [chat("Lígia", group: false)]) == nil)
    }
}


/// Facts carry odds and proof; sensitive ones need both.
struct FactProofTests {
    let moment = "Alexsander: eu sou bi, todo mundo sabe kkk\nYasmin: aff"

    @Test func selfStatedWithProofIsKept() {
        let kept = KnowledgeGraph.vetted(confidence: 0.9, evidence: "eu sou bi", in: moment, selfStated: true, sensitive: true)
        #expect(kept?.confidence == 0.9)
        #expect(kept?.evidence == "eu sou bi")
    }

    @Test func sensitiveWithoutRealProofIsDropped() {
        #expect(KnowledgeGraph.vetted(confidence: 0.9, evidence: "ele é gay", in: moment, selfStated: true, sensitive: true) == nil)
    }

    @Test func sensitiveGuessIsCappedAsAMaybe() {
        let kept = KnowledgeGraph.vetted(confidence: 0.9, evidence: "todo mundo sabe", in: moment, selfStated: false, sensitive: true)
        #expect(kept?.confidence == 0.5)
    }

    @Test func ordinaryFactWithoutProofLosesOdds() {
        let kept = KnowledgeGraph.vetted(confidence: 0.8, evidence: "não está aqui", in: moment, selfStated: false, sensitive: false)
        #expect(kept != nil && kept!.confidence < 0.8 && kept!.evidence == nil)
    }

    @Test func nicknamesBecomeTheSender() {
        let chunk = MemoryChunk(id: 1, source: .whatsapp, chatID: "g", chatName: "bio a ligia", start: .now, end: .now,
                                text: "", participants: ["Alexsander Lima", "Yasmin"], isGroup: true)
        #expect(KnowledgeGraph.canonicalName("Alexsander", in: chunk) == "Alexsander Lima")
        #expect(KnowledgeGraph.canonicalName("alex", in: chunk) == "Alexsander Lima")
        #expect(KnowledgeGraph.canonicalName("Lígia", in: chunk) == "Lígia")
    }

    @Test func proofIsSpelledOutForTheModel() {
        let fact = MemoryFact(id: 1, subject: "Alexsander", predicate: "is", object: "bisexual", confidence: 0.9,
                              source: .whatsapp, date: .now, evidence: "eu sou bi", selfStated: true,
                              sensitive: true, chatName: "bio a ligia", inGroup: true)
        #expect(fact.withProof.contains("90%"))
        #expect(fact.withProof.contains("said by Alexsander themselves"))
        #expect(fact.withProof.contains("the group \"bio a ligia\""))
        #expect(fact.withProof.contains("“eu sou bi”"))
    }
}


/// People and groups by id: a person never merges with the group named
/// after someone, and names travel as tags.
@MainActor
struct PeopleDirectoryTests {
    private func raw(_ id: Int, chat: String, name: String, group: Bool, sender: String, me: Bool = false) -> RawMessage {
        RawMessage(source: .whatsapp, externalID: "p\(id)", chatID: chat, chatName: name, isGroup: group,
                   sender: sender, isFromMe: me, date: Date(timeIntervalSince1970: 1_800_000_000 + Double(id) * 60), text: "oi \(id)")
    }

    @Test func personGroupAndMembersAreSeparate() async throws {
        let store = MemoryStore(url: FileManager.default.temporaryDirectory.appending(path: "agott-people-\(UUID().uuidString).sqlite"))
        try await store.ingest([
            raw(1, chat: "dm-ligia", name: "Lígia", group: false, sender: "Lígia"),
            raw(2, chat: "g-bio", name: "bio a ligia", group: true, sender: "Alexsander Lima"),
            raw(3, chat: "g-bio", name: "bio a ligia", group: true, sender: "Yasmin"),
            raw(4, chat: "dm-ale", name: "Alexsander Lima", group: false, sender: "Alexsander Lima"),
        ])
        #expect(try await store.syncPeople() > 0)

        let ligia = try await store.resolvePeople("Ligia")
        #expect(ligia.map(\.name) == ["Lígia"])
        #expect(ligia.first?.kind == .person)

        let group = try await store.resolvePeople("bio a ligia")
        #expect(group.map(\.kind) == [.group])

        // One Alexsander, from the direct chat and the group alike, found by first name.
        let ale = try await store.resolvePeople("Alexsander")
        #expect(ale.count == 1)
        let links = try await store.connections(of: ale[0])
        #expect(links.direct.map(\.name) == ["Alexsander Lima"])
        #expect(links.others.map(\.name) == ["bio a ligia"])

        let lookalikes = try await store.groupsNamed(containing: "ligia")
        #expect(lookalikes.map(\.name) == ["bio a ligia"])
    }

    @Test func plainNamesBecomeTags() {
        let ana = PersonRef(id: 3, kind: .person, name: "Ana Souza")
        let group = PersonRef(id: 9, kind: .group, name: "bio a ligia")
        let text = PeopleDirectory.tagNames("a Ana falou no bio a ligia, e Ana Souza riu", people: [ana, group])
        #expect(text == "a <e id=3/> falou no <e id=9/>, e <e id=3/> riu")
        #expect(PeopleDirectory.tags(in: text) == [3, 9, 3])
    }
}


/// Nicknames and links between people, only with proof.
@MainActor
struct LearnedPeopleTests {
    private let chunk = MemoryChunk(
        id: 1, source: .whatsapp, chatID: "g", chatName: "bio a ligia", start: .now, end: .now,
        text: "Yasmin: valeu ale\nAlexsander Lima: de nada mano\nYasmin: o gustavo vem buscar, meu namorado é pontual",
        participants: ["Yasmin", "Alexsander Lima"], isGroup: true)

    @Test func realNicknamesOnly() {
        #expect(MemoryStore.nicknameIsProven("Ale", person: "Alexsander Lima", in: chunk))
        // Everyone is "mano".
        #expect(!MemoryStore.nicknameIsProven("mano", person: "Alexsander Lima", in: chunk))
        // Not written in the moment.
        #expect(!MemoryStore.nicknameIsProven("Xande", person: "Alexsander Lima", in: chunk))
        // Not in this chat.
        #expect(!MemoryStore.nicknameIsProven("Ale", person: "Lígia", in: chunk))
    }

    @Test func linksAreStoredOnceAndReadBothWays() async throws {
        let store = MemoryStore(url: FileManager.default.temporaryDirectory.appending(path: "agott-links-\(UUID().uuidString).sqlite"))
        _ = try await store.syncPeople()
        let yasmin = try #require(try await store.ensurePerson("Yasmin"))
        let gustavo = try #require(try await store.ensurePerson("Gustavo"))
        #expect(try await store.ensurePerson("gustavo") == gustavo)
        try await store.link(gustavo, yasmin, kind: .partner, detail: "namorado", confidence: 0.8,
                             evidence: "meu namorado é pontual", chunkID: 1, at: .now)
        try await store.link(yasmin, gustavo, kind: .partner, detail: nil, confidence: 0.9, evidence: nil, chunkID: 2, at: .now)
        let fromYasmin = try await store.links(of: yasmin)
        #expect(fromYasmin.count == 1)
        #expect(fromYasmin.first?.other.name == "Gustavo")
        #expect(fromYasmin.first?.line.contains("is dating <e id=\(gustavo)/> Gustavo") == true)
        #expect(fromYasmin.first?.evidence == "meu namorado é pontual")
        #expect((fromYasmin.first?.confidence ?? 0) > 0.9)
        #expect(try await store.links(of: gustavo).first?.other.name == "Yasmin")
    }
}


/// Rereading people: only WhatsApp and iMessage, groups you only read
/// included, and deep conversations rewritten in place.
@MainActor
struct RereadPeopleTests {
    @Test func rereadsPeopleNotClaude() async throws {
        let store = MemoryStore(url: FileManager.default.temporaryDirectory.appending(path: "agott-reread-\(UUID().uuidString).sqlite"))
        let long = String(repeating: "eu sou bi e todo mundo sabe disso faz tempo. ", count: 10)
        func raw(_ id: Int, source: MemorySource, chat: String, group: Bool, sender: String) -> RawMessage {
            RawMessage(source: source, externalID: "r\(id)", chatID: chat, chatName: chat, isGroup: group, sender: sender,
                       isFromMe: false, date: Date(timeIntervalSince1970: 1_800_000_000 + Double(id) * 60), text: long)
        }
        try await store.ingest([
            // A group where the user never wrote.
            raw(1, source: .whatsapp, chat: "bio a ligia", group: true, sender: "Alexsander Lima"),
            raw(2, source: .claude, chat: "Agott — memory", group: false, sender: "Claude"),
        ])
        let all = try await store.learningCandidateIDs(me: "Moizes", limit: 50)
        try await store.markLearned(all)
        #expect(try await store.learningCandidateIDs(me: "Moizes", limit: 50).isEmpty)

        try await store.resetPeopleLearning()
        let again = try await store.chunks(ids: try await store.learningCandidateIDs(me: "Moizes", limit: 50))
        #expect(again.map(\.source) == [.whatsapp])
        #expect(try await store.peopleRelearnSize().moments == 1)
    }

    @Test func reflectionsAreRewrittenNotDuplicated() async throws {
        let store = MemoryStore(url: FileManager.default.temporaryDirectory.appending(path: "agott-refl-\(UUID().uuidString).sqlite"))
        try await store.addReflection(chunkID: 7, source: .whatsapp, chat: "bio a ligia", title: "Old", summary: "Lígia disse",
                                      people: [], feeling: "calm", depth: 2, date: .now)
        try await store.addReflection(chunkID: 7, source: .whatsapp, chat: "bio a ligia", title: "New", summary: "No grupo, Alexsander disse",
                                      people: [], feeling: "calm", depth: 2.5, date: .now)
        let found = try await store.searchReflections("Alexsander", limit: 5)
        #expect(found.map(\.title) == ["New"])
        #expect(try await store.searchReflections("Old", limit: 5).isEmpty)
    }
}


/// Each learning batch carries who is who, so the model connects what it
/// reads to the people already known.
@MainActor
struct LearningCrossReferenceTests {
    @Test func whoIsWhoForABatch() async throws {
        let store = MemoryStore(url: FileManager.default.temporaryDirectory.appending(path: "agott-xref-\(UUID().uuidString).sqlite"))
        func raw(_ id: Int, chat: String, name: String, group: Bool, sender: String, _ text: String) -> RawMessage {
            RawMessage(source: .whatsapp, externalID: "x\(id)", chatID: chat, chatName: name, isGroup: group, sender: sender,
                       isFromMe: false, date: Date(timeIntervalSince1970: 1_800_000_000 + Double(id) * 60), text: text)
        }
        try await store.ingest([
            raw(1, chat: "dm-g", name: "Gustavo Fernandes", group: false, sender: "Gustavo Fernandes", "e ai"),
            raw(2, chat: "g-bio", name: "bio a ligia", group: true, sender: "Yasmin Costa", "o gustavo vem me buscar hoje"),
        ])
        _ = try await store.syncPeople()
        let yasmin = try #require(try await store.ensurePerson("Yasmin Costa"))
        let gustavo = try #require(try await store.ensurePerson("Gustavo Fernandes"))
        try await store.link(yasmin, gustavo, kind: .partner, detail: "namorado", confidence: 0.85, evidence: nil, chunkID: nil, at: .now)
        try await store.learnNickname("Yas", for: "Yasmin Costa", evidence: nil)

        let chunk = MemoryChunk(id: 1, source: .whatsapp, chatID: "g-bio", chatName: "bio a ligia", start: .now, end: .now,
                                text: "Yasmin Costa: o gustavo vem me buscar hoje", participants: ["Yasmin Costa"], isGroup: true)
        let card = try await store.whoIsWho(for: [chunk], budget: 2000)
        #expect(card.contains("\"bio a ligia\" is a group chat, not a person"))
        #expect(card.contains("Yasmin Costa (also called Yas, Yasmin): is dating Gustavo Fernandes (85%)"), "\(card)")
        // Mentioned only by first name, still recognised.
        #expect(card.contains("- Gustavo Fernandes"))
        #expect(try await store.whoIsWho(for: [chunk], budget: 100).isEmpty)
    }
}

@MainActor
struct WebToolsTests {
    @Test func parsesDuckDuckGoResults() {
        let html = """
        <div class="result"><h2 class="result__title"><a rel="nofollow" class="result__a" href="https://www.imdb.com/title/tt1196946/">The <b>Mentalist</b> (TV Series 2008&#x2013;2015)</a></h2>
        <a class="result__snippet" href="https://www.imdb.com/title/tt1196946/">A famous &quot;psychic&quot; outs himself.</a></div>
        <div class="result"><h2 class="result__title"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fpt.wikipedia.org%2Fwiki%2FThe_Mentalist&amp;rut=x">O Mentalista</a></h2>
        <a class="result__snippet" href="x">Série americana.</a></div>
        """
        let results = WebSearch.parse(html, limit: 5)
        #expect(results.count == 2)
        #expect(results[0].url == "https://www.imdb.com/title/tt1196946/")
        #expect(results[0].title == "The Mentalist (TV Series 2008–2015)")
        #expect(results[0].snippet == "A famous \"psychic\" outs himself.")
        #expect(results[1].url == "https://pt.wikipedia.org/wiki/The_Mentalist")
    }

    @Test func rendersIMDbTitle() {
        let title: [String: Any] = [
            "titleText": ["text": "O Mentalista"], "originalTitleText": ["text": "The Mentalist"],
            "titleType": ["text": "TV Series"], "releaseYear": ["year": 2008, "endYear": 2015],
            "ratingsSummary": ["aggregateRating": 8.2, "voteCount": 261485],
            "genres": ["genres": [["text": "Policial"], ["text": "Drama"]]],
            "plot": ["plotText": ["plainText": "Um famoso psíquico."]],
            "episodes": ["seasons": [["number": 1], ["number": 2]]],
            "principalCredits": [["category": ["text": "Stars"], "credits": [["name": ["nameText": ["text": "Simon Baker"]]]]]],
        ]
        let text = IMDb.render(title, id: "tt1196946")
        #expect(text.hasPrefix("O Mentalista (The Mentalist), TV Series, 2008–2015"))
        #expect(text.contains("IMDb rating 8.2/10"))
        #expect(text.contains("Genres: Policial, Drama"))
        #expect(text.contains("2 seasons"))
        #expect(text.contains("Stars: Simon Baker"))
    }

    @Test func newToolsAreOffered() {
        let names = Persona.tools(for: .openCode).map(\.name)
        for name in ["web_search", "read_web_page", "find_place", "nearby_places", "movie_info"] {
            #expect(names.contains(name))
        }
    }
}

@MainActor
struct FactLanguageTests {
    @Test func rewritesEnglishVerbsUpToTheMark() async throws {
        let store = MemoryStore(url: FileManager.default.temporaryDirectory.appending(path: "agott-words-\(UUID().uuidString).sqlite"))
        let now = Date()
        try await store.addFact(subject: "Clara", predicate: "plays", object: "Roblox", confidence: 0.9, source: .whatsapp, chunkID: nil, at: now)
        try await store.addFact(subject: "Clara", predicate: "owns", object: "um gato", confidence: 0.8, source: .whatsapp, chunkID: nil, at: now)
        try await store.addFact(subject: "Clara", predicate: "has", object: "um gato", confidence: 0.7, source: .whatsapp, chunkID: nil, at: now)
        let mark = try await store.predicateMark()
        // Learned after the switch, already in Portuguese: left alone.
        try await store.addFact(subject: "Clara", predicate: "is", object: "legal", confidence: 0.6, source: .whatsapp, chunkID: nil, at: now)
        let english = try await store.predicates(through: mark)
        #expect(Set(english) == ["plays", "owns", "has"])
        try await store.renamePredicates(english.reduce(into: [:]) { $0[$1] = FactWords.portuguese[$1] }, through: mark)
        let facts = try await store.facts(about: "Clara")
        let predicates = facts.map(\.predicate).sorted()
        // "owns" and "has" both become "tem": one fact stays.
        #expect(predicates == ["is", "joga", "tem"])
    }

    @Test func linksReadInTheUsersLanguage() {
        #expect(!MemoryStore.LinkKind.partner.phrase(outgoing: true).isEmpty)
        #expect(MemoryStore.LinkKind.parent.phrase(outgoing: true) != MemoryStore.LinkKind.parent.phrase(outgoing: false))
    }
}

struct ShortChatStatsTests {
    @Test func countsMessagesPerDay() {
        let now = Date()
        let lines = (0..<30).map { index in
            ChatLine(id: Int64(index), sender: index.isMultiple(of: 2) ? "me" : "Clara", isFromMe: index.isMultiple(of: 2),
                     date: now.addingTimeInterval(Double(index - 30) * 60), text: "oi")
        }
        let stats = RelationshipAnalyzer.compute(lines, now: now)
        #expect(stats.daily.count == 14)
        #expect(stats.daily.reduce(0, +) == 30)
        #expect(stats.daily.last! + stats.daily[12] == 30)
    }
}

@MainActor
struct WhatsAppIDNamesTests {
    @Test func idsBecomeTheirNamesAndMergeWithTheSamePerson() async throws {
        let store = MemoryStore(url: FileManager.default.temporaryDirectory.appending(path: "agott-lid-\(UUID().uuidString).sqlite"))
        let now = Date()
        let real = try #require(try await store.ensurePerson("Dayvid Albuquerque"))
        let id = try #require(try await store.ensurePerson("+224064970952769"))
        let friend = try #require(try await store.ensurePerson("Carol"))
        try await store.link(id, friend, kind: .coworker, detail: nil, confidence: 0.8, evidence: nil, chunkID: nil, at: now)
        try await store.addFact(subject: "+224064970952769", predicate: "precisa de", object: "WORM na AWS",
                                confidence: 90, source: .whatsapp, chunkID: nil, at: now, subjectID: id)
        try await store.addFact(subject: "+135686757822712", predicate: "gosta de", object: "drones FPV",
                                confidence: 0.8, source: .whatsapp, chunkID: nil, at: now)
        let names = ["+224064970952769": "Dayvid Albuquerque", "+135686757822712": "Bruno Reis"]
        try await store.renameInFacts(names)
        try await store.renamePeople(names)

        let facts = try await store.facts(limit: 10)
        #expect(Set(facts.map(\.subject)) == ["Dayvid Albuquerque", "Bruno Reis"])
        // A model's "90" is stored as 0.9.
        #expect(facts.first { $0.subject == "Dayvid Albuquerque" }?.confidence == 0.9)
        // The id merged into the person who already had that name, links and all.
        let gone = try await store.person(id: id)
        #expect(gone == nil)
        let links: [MemoryStore.PersonLink] = try await store.links(of: real)
        let moved = links.contains { link in link.other.id == friend && link.kind == .coworker }
        #expect(moved)
    }

    @Test func numbersAreNotNames() {
        #expect(!WhatsAppSource.isName("+55 11 98888-7777"))
        #expect(!WhatsAppSource.isName(""))
        #expect(WhatsAppSource.isName("Dayvid"))
        #expect(MemoryStore.odds(90) == 0.9)
        #expect(MemoryStore.odds(0.7) == 0.7)
    }
}

struct DictationJoinTests {
    @Test func sentencesKeepTheirSpace() {
        #expect(Dictation.join("tudo bem.", "E você?") == "tudo bem. E você?")
        #expect(Dictation.join("tudo bem. ", "E você?") == "tudo bem. E você?")
        #expect(Dictation.join("ok", ", então") == "ok, então")
        #expect(Dictation.join("", "oi") == "oi")
        #expect(Dictation.join("oi", "") == "oi")
    }
}

/// The orbs and the activity line, drawn offscreen when AGOTT_SNAPSHOT_DIR is set.
@MainActor
struct ThinkingSnapshotTests {
    @Test func orbsAndActivity() throws {
        guard let dir = ProcessInfo.processInfo.environment["AGOTT_SNAPSHOT_DIR"] else { return }
        let start = Date().addingTimeInterval(-7)
        let steps = [
            Step(id: "t", kind: .thinking, title: "Thinking", symbol: "sparkle", state: .done,
                 detail: "Ela perguntou do fim de semana. Vale olhar a agenda e a última conversa com a Ana antes de responder.",
                 started: start, ended: start.addingTimeInterval(4)),
            Step(id: "m", kind: .tool, title: "Remembering “viagem”", symbol: "brain.head.profile", state: .running, started: start),
        ]
        let view = VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                ForEach(Array(ThinkingOrb.Mode.allCases.enumerated()), id: \.offset) { _, mode in
                    ThinkingOrb(mode: mode, size: 64, active: false)
                }
            }
            HStack(spacing: 18) {
                ForEach(Array(ThinkingOrb.Mode.allCases.enumerated()), id: \.offset) { _, mode in
                    ThinkingOrb(mode: mode, size: 18, active: false)
                }
            }
            StepsView(steps: steps, isStreaming: true, started: start)
            StepsView(steps: Array(steps.prefix(1)), isStreaming: false, started: start)
        }
        .padding(24)
        .frame(width: 520, alignment: .leading)
        .background(Ink.canvas)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { Issue.record("no image"); return }
        let url = URL(fileURLWithPath: dir).appending(path: "thinking.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}

struct FactKindTests {
    @Test func wordsInEitherLanguageMeanOneKind() {
        #expect(FactKind.guess("gosta de") == .likes)
        #expect(FactKind.guess("likes") == .likes)
        #expect(FactKind.guess("não gosta de") == .dislikes)
        #expect(FactKind.guess("faz aniversário em") == .birthday)
        #expect(FactKind.guess("joga") == .plays)
        #expect(FactKind.guess("trabalha em") == .works)
        #expect(FactKind.guess("mora em") == .livesIn)
        #expect(FactKind.guess("xyz") == .other)
    }

    @Test func graphRelationsKeepTheirStoredNames() {
        #expect(GraphRelation.talksWith.rawValue == "talks with")
        #expect(GraphRelation.memberOf.rawValue == "member of")
        #expect(MemoryStore.structuralRelations.contains("knows"))
    }

    @Test func factsGetAKindAndShowItsLabel() async throws {
        let store = MemoryStore(url: FileManager.default.temporaryDirectory.appending(path: "agott-kind-\(UUID().uuidString).sqlite"))
        try await store.addFact(subject: "Ana", predicate: "curte muito", object: "Roblox", confidence: 0.8,
                                source: .whatsapp, chunkID: nil, at: .now, kind: .plays)
        try await store.addFact(subject: "Ana", predicate: "mora em", object: "Goiânia", confidence: 0.8,
                                source: .whatsapp, chunkID: nil, at: .now)
        let facts = try await store.facts(about: "Ana", limit: 10)
        #expect(facts.first { $0.object == "Roblox" }?.kind == .plays)
        #expect(facts.first { $0.object == "Goiânia" }?.kind == .livesIn)
        #expect(try await store.backfillFactKinds() == 0)
    }
}

@MainActor
struct ReviewFixTests {
    private func chunk(_ participants: [String], group: Bool = true) -> MemoryChunk {
        MemoryChunk(id: 1, source: .whatsapp, chatID: "g", chatName: "Turma", start: .now, end: .now,
                    text: "", participants: participants, isGroup: group)
    }

    @Test func ambiguousFirstNamesStayAsWritten() {
        let both = chunk(["Ana Souza", "Ana Clara", "Bruno"])
        #expect(KnowledgeGraph.canonicalName("Ana", in: both) == "Ana")
        #expect(KnowledgeGraph.canonicalName("Ana Clara", in: both) == "Ana Clara")
        #expect(KnowledgeGraph.canonicalName("Bru", in: both) == "Bruno")
        let one = chunk(["Ana Souza", "Bruno"])
        #expect(KnowledgeGraph.canonicalName("Ana", in: one) == "Ana Souza")
    }

    @Test func setupErrorsStopInsteadOfSkipping() {
        #expect(ModelHub.isConfigurationProblem(OpenCodeExecutor.ExecutorError.http(404, "no such model")))
        #expect(ModelHub.isConfigurationProblem(OpenCodeExecutor.ExecutorError.http(402, "no credit")))
        #expect(!ModelHub.isConfigurationProblem(OpenCodeExecutor.ExecutorError.streamFailed("filtered")))
        #expect(!ModelHub.isConnectionProblem(OpenCodeExecutor.ExecutorError.streamFailed("filtered")))
        #expect(ModelHub.isConnectionProblem(Jev.JevError.http(429, "busy")))
    }

    @Test func meaningHitsRespectTheFilter() async throws {
        let store = MemoryStore(url: FileManager.default.temporaryDirectory.appending(path: "agott-filter-\(UUID().uuidString).sqlite"))
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await store.ingest([
            RawMessage(source: .whatsapp, externalID: "a", chatID: "ana", chatName: "Ana", isGroup: false,
                       sender: "Ana", isFromMe: false, date: old, text: "vamos pra praia"),
            RawMessage(source: .whatsapp, externalID: "b", chatID: "bia", chatName: "Bia", isGroup: false,
                       sender: "Bia", isFromMe: false, date: .now, text: "vamos pra praia hoje"),
        ])
        let all = try await store.recentChunkIDs(filter: .none, limit: 10)
        var recent = MemoryStore.Filter()
        recent.since = Date().addingTimeInterval(-86400)
        let kept = try await store.chunkIDs(all, matching: recent)
        #expect(kept.count == 1)
        #expect(try await store.chunkIDs(all, matching: .none) == all)
    }
}

@Suite("Run findings")
struct RunFindingsTests {
    @Test @MainActor func summarySkipsZeroAndUsesSingular() {
        var findings = Indexer.Findings()
        #expect(findings.isEmpty)
        findings.messages = 2
        findings.voiceNotes = 1
        findings.facts = 12
        #expect(!findings.isEmpty)
        let summary = findings.summary
        #expect(summary.contains("2"))
        #expect(summary.contains("12"))
        #expect(summary.components(separatedBy: " · ").count == 3)
    }
}

@Suite("Person tags")
struct PersonTagTests {
    @Test func acceptsTagsWithoutSlashOrWithQuotes() {
        #expect(PeopleDirectory.tags(in: #"<e id=13>, <e id="85"/>, <e id=50/> e <e id=7 />"#) == [13, 85, 50, 7])
    }
}

#if os(macOS)
@Suite("Parakeet")
struct ParakeetTests {
    /// Reads one real voice note when the model and WhatsApp are on this Mac;
    /// prints only sizes and time, never the words.
    @Test func readsAVoiceNote() async throws {
        guard Parakeet.isInstalled else { return }
        let root = MediaIngestor.root
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
              let file = enumerator.compactMap({ $0 as? URL }).first(where: { $0.pathExtension == "opus" }) else { return }
        let clock = ContinuousClock.now
        let text = try await Parakeet.shared.transcribe(file: file, language: Parakeet.language(for: "pt-BR"))
        print("PARAKEET words=\(text.split(separator: " ").count) seconds=\(ContinuousClock.now - clock)")
        #expect(!text.isEmpty)
    }
}
#endif

@Suite("Media tags")
struct MediaTagTests {
    @Test func parsesAndBecomesALink() throws {
        let media = try #require(MediaTag(#"<media kind="song" title="Do I Wanna Know?" by="Arctic Monkeys"/>"#))
        #expect(media.kind == "song")
        #expect(media.title == "Do I Wanna Know?")
        #expect(media.by == "Arctic Monkeys")
        #expect(MediaTag(link: media.link) == media)
    }

    @MainActor @Test func plainTextReadsTheTitle() {
        let text = #"meu chute é <media kind="song" title="Do I Wanna Know?" by="Arctic Monkeys"/> — aquele riff"#
        #expect(EntityText.plain(text, hidden: false) == "meu chute é “Do I Wanna Know?” — Arctic Monkeys — aquele riff")
        #expect(EntityText.markdown(text, hidden: false).contains("agott://media/song?title="))
    }
}

@Suite("Collections")
struct CollectionTests {
    @Test func spotsTheSameListTwice() {
        let first = Card.Collection(title: "Your top songs", style: .ranking, kind: "song",
                                    items: ["TEARS", "Bota Em Você Machuca", "Recollect", "Anjos"].map { .init(title: $0) })
        let again = Card.Collection(title: "suas mais tocadas", style: .ranking, kind: "song",
                                    items: ["TEARS", "Bota Em Você Machuca", "Recollect"].map { .init(title: $0) })
        let other = Card.Collection(title: "Filmes", style: .grid, kind: "movie",
                                    items: ["Duna", "Oppenheimer"].map { .init(title: $0) })
        #expect(first.repeats(again))
        #expect(!first.repeats(other))
    }
}
