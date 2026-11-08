import Foundation
import FoundationModels

extension CardBus {
    /// One line of "what Agott is doing", shown under the face while it works.
    nonisolated(unsafe) static var statusSink: (@MainActor (String) -> Void)?

    nonisolated static func status(_ text: String) async {
        await MainActor.run { statusSink?(text) }
    }
}

nonisolated enum ToolDates {
    static func parse(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withFullDate, .withFullTime, .withTimeZone]] {
            iso.formatOptions = options
            if let date = iso.date(from: text) { return date }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Memory

nonisolated struct SearchMemoryTool: Tool {
    let name = "search_memory"
    let description = """
    Search everything Agott remembers: WhatsApp and iMessage conversations, Claude chat history, \
    and facts about the user and people they know. Use it whenever the question touches the user's life, \
    people, plans, past conversations or preferences.
    """

    @Generable
    struct Arguments {
        @Guide(description: "What to look for, in natural language. Include names and key words in the language they were likely written in.")
        var query: String
        @Guide(description: "Only conversations with or about this person or group, if the question is about someone")
        var person: String?
        @Guide(description: "Only the last N days, if the question is about a recent period")
        var days: Int?
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await CardBus.status(String(localized: "Remembering “\(arguments.query)”…"))
        var filter = MemoryStore.Filter()
        filter.chatName = arguments.person
        if let days = arguments.days, days > 0 { filter.since = Date().addingTimeInterval(-Double(days) * 86400) }
        let recall = await Retriever().recall(arguments.query, filter: filter, limit: 8)
        if recall.isEmpty { return "Nothing in memory matches that." }
        return recall.rendered()
    }
}

nonisolated struct ReadChatTool: Tool {
    let name = "read_chat"
    let description = "Read the latest messages of a WhatsApp or iMessage conversation with a person or group, verbatim."

    @Generable
    struct Arguments {
        @Guide(description: "Name of the person or group")
        var person: String
        @Guide(description: "How many recent messages to read, 10 to 150", .range(10...150))
        var count: Int
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await CardBus.status(String(localized: "Reading your chat with \(arguments.person)…"))
        guard let chat = try await MemoryStore.shared.findChats(named: arguments.person, limit: 1).first else {
            return "No chat found with \(arguments.person). The messages may not be indexed yet."
        }
        return try await Self.read(chat, count: arguments.count)
    }

    /// The end of one known chat as a transcript.
    static func read(_ chat: ChatSummary, count: Int) async throws -> String {
        let lines = try await MemoryStore.shared.lines(source: chat.source, chatID: chat.chatID, limit: count)
        let me = AppSettings.myNameSnapshot
        return "\(chat.source.displayName) chat \"\(chat.name)\" (\(chat.messageCount) messages total):\n"
            + RelationshipAnalyzer.transcript(lines, me: me)
    }
}

nonisolated struct PersonInsightTool: Tool {
    let name = "person_insight"
    let description = """
    Measured facts about the user's relationship with someone: how much each writes, reply speeds, who starts \
    conversations, whether it is warming or cooling, whether they are waiting for a reply, plus known facts.
    """

    @Generable
    struct Arguments {
        @Guide(description: "Name of the person")
        var person: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await CardBus.status(String(localized: "Looking at you and \(arguments.person)…"))
        guard let chat = try await MemoryStore.shared.findChats(named: arguments.person, limit: 1).first else {
            return "No chat found with \(arguments.person)."
        }
        return await Self.insight(chat)
    }

    /// How things stand in one known chat.
    static func insight(_ chat: ChatSummary) async -> String {
        let stats = await RelationshipAnalyzer.stats(for: chat)
        let facts = (try? await MemoryStore.shared.facts(matching: chat.name, limit: 12)) ?? []
        var text = "\(chat.name) (\(chat.source.displayName)): " + RelationshipAnalyzer.statsLine(stats)
        if let question = stats.lastQuestionFromThem { text += "\nTheir unanswered question: \(question)" }
        if !facts.isEmpty { text += "\nKnown facts:\n" + facts.map { "- \($0.sentence)" }.joined(separator: "\n") }
        return text
    }
}

nonisolated struct PeopleOverviewTool: Tool {
    let name = "people_overview"
    let description = "List the people the user talks to most recently, with who is waiting for a reply and which relationships are cooling."

    @Generable
    struct Arguments {
        @Guide(description: "How many people to list", .range(3...30))
        var count: Int
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await CardBus.status(String(localized: "Checking on everyone…"))
        let chats = try await MemoryStore.shared.chats(limit: 60, includeGroups: false, since: Date().addingTimeInterval(-90 * 86400))
        var rows: [(ChatSummary, RelationshipStats)] = []
        for chat in chats { rows.append((chat, await RelationshipAnalyzer.stats(for: chat))) }
        rows.sort { $0.1.attention > $1.1.attention }
        return rows.prefix(arguments.count).map { chat, stats in
            var line = "- \(chat.name) [\(chat.source.displayName)]: \(stats.trend.rawValue), \(stats.last30) msgs/30d"
            if stats.awaitingMyReply, let since = stats.waitingSince {
                line += ", waiting for reply since \(ToolDates.format(since))"
            }
            return line
        }.joined(separator: "\n")
    }
}

nonisolated struct RememberTool: Tool {
    let name = "remember"
    let description = "Save a lasting fact about the user or someone they know, when they tell you something worth remembering."

    @Generable
    struct Arguments {
        @Guide(description: "Who the fact is about. Use \"me\" for the user.")
        var subject: String
        @Guide(description: "The relation, short, in the user's language, e.g. trabalha em, gosta de, faz aniversário em, namora")
        var predicate: String
        @Guide(description: "The value")
        var object: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        let subject = arguments.subject.lowercased() == "me" ? AppSettings.myNameSnapshot : arguments.subject
        try await MemoryStore.shared.addFact(
            subject: subject, predicate: arguments.predicate, object: arguments.object,
            confidence: 0.95, source: .note, chunkID: nil, at: .now)
        await KnowledgeGraph.link(subject: subject, predicate: arguments.predicate, object: arguments.object, kind: .thing, at: .now)
        return "Saved: \(subject) \(arguments.predicate) \(arguments.object)"
    }
}

extension RelationshipAnalyzer {
    nonisolated static func transcript(_ lines: [ChatLine], me: String) -> String {
        lines.map { line in
            "[\(MemoryStore.stamp(line.date.timeIntervalSince1970))] \(line.isFromMe ? "\(me) (user)" : line.sender): \(line.text.prefix(500))"
        }.joined(separator: "\n")
    }

    nonisolated static func statsLine(_ stats: RelationshipStats) -> String {
        var parts = [
            "\(stats.total) messages; user wrote \(Int(stats.balance * 100))%",
            "last 30 days: \(stats.last30), previous 30: \(stats.prior30) (\(stats.trend.rawValue))",
            "started by user: \(stats.myInitiations), by them: \(stats.theirInitiations)",
        ]
        if let mine = stats.myReplyMinutes { parts.append("user's median reply \(Int(mine)) min") }
        if let theirs = stats.theirReplyMinutes { parts.append("their median reply \(Int(theirs)) min") }
        if stats.awaitingMyReply { parts.append("waiting for the user's reply") }
        parts.append(String(format: "tone: user %.2f, them %.2f (-1..1)", stats.mySentiment, stats.theirSentiment))
        return parts.joined(separator: "; ")
    }
}
