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
            // A structured request answered the way models often do: fenced, with chatter.
            events = [#"{"choices":[{"delta":{"content":"Claro! Aqui está:\n```json\n{\"closeness\": 80, "}}]}"#,
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
