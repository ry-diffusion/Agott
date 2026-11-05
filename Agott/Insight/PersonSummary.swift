import Foundation
import FoundationModels

/// A portrait of someone in your life, from everything Agott has of them:
/// your direct chat, what they say in groups you share, and known facts.
nonisolated struct PersonPortrait: Codable, Hashable, Sendable {
    var summary: String
    var toYou: String
    var vibe: String
    var topics: [String]
    var written: Date
}

enum PersonSummary {
    @Generable
    struct Draft {
        @Guide(description: "Who this person is, in two or three sentences, from the messages. Concrete, no guessing beyond them.")
        var summary: String
        @Guide(description: "What they are to the user (friend from X, colleague at Y, family…) in one short sentence")
        var toYou: String
        @Guide(description: "The feel between them and the user, two to four words")
        var vibe: String
        @Guide(description: "What they talk about, short phrases", .maximumCount(5))
        var topics: [String]
    }

    static func key(_ name: String) -> String { "portrait:\(name.folded)" }

    static func cached(_ name: String) async -> PersonPortrait? {
        guard let (json, _) = try? await MemoryStore.shared.insight(key: key(name)) else { return nil }
        return try? JSONDecoder().decode(PersonPortrait.self, from: Data(json.utf8))
    }

    static func write(_ name: String) async throws -> PersonPortrait {
        let store = MemoryStore.shared
        let me = AppSettings.shared.myName
        var sections: [String] = []

        if let chat = try await store.findChats(named: name, limit: 3).first(where: { !$0.isGroup }) {
            let lines = try await store.lines(source: chat.source, chatID: chat.chatID, limit: 80)
            sections.append("Direct chat with the user (\(chat.messageCount) messages):\n" + RelationshipAnalyzer.transcript(lines, me: me))
        }
        let theirs = try await store.messages(by: name, limit: 80)
        if !theirs.isEmpty {
            sections.append("What they said in group chats the user is in:\n" + theirs
                .map { "[\($0.chat)] \($0.line.text.prefix(200))" }.joined(separator: "\n"))
        }
        let mentions = try await store.mentions(of: [name], outside: "", limit: 30).filter { $0.line.isFromMe }
        if !mentions.isEmpty {
            sections.append("What the user said about or to them:\n" + mentions
                .map { "[\($0.chatName)] \($0.line.text.prefix(200))" }.joined(separator: "\n"))
        }
        let facts = try await store.facts(matching: name, limit: 12)
        if !facts.isEmpty { sections.append("Known facts:\n" + facts.map { "- \($0.sentence)" }.joined(separator: "\n")) }

        let draft = try await ModelHub.generate(
            Draft.self,
            prompt: "Person: \(name). The user is \(me).\n\n" + sections.joined(separator: "\n\n"),
            instructions: """
            You describe someone in the user's life from messages the user shared with you, with consent. \
            Be specific and kind, and only say what the messages support; if they say little, keep it short. \
            Never include phone numbers, addresses or anything sensitive. Write in \(Persona.languageName).
            """)
        let portrait = PersonPortrait(summary: draft.summary, toYou: draft.toYou, vibe: draft.vibe,
                                      topics: draft.topics, written: .now)
        if let data = try? JSONEncoder().encode(portrait), let json = String(data: data, encoding: .utf8) {
            try? await store.saveInsight(json, key: key(name))
        }
        return portrait
    }
}
