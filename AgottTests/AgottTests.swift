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
