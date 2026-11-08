import Foundation
import FoundationModels
import NaturalLanguage

/// The shape of a relationship, measured from the messages themselves.
///
/// Numbers first, model second. Who writes first, how fast each of you
/// answers, whether it is getting warmer or quieter, whether a question of
/// theirs is sitting unanswered: all of that is counting, and counting does
/// not hallucinate. The model is only asked to read the conversation once
/// those facts are in front of it.
nonisolated struct RelationshipStats: Sendable, Hashable, Codable {
    var total = 0
    var mine = 0
    var theirs = 0
    var last30 = 0
    var prior30 = 0
    var myReplyMinutes: Double?
    var theirReplyMinutes: Double?
    var myInitiations = 0
    var theirInitiations = 0
    var mySentiment = 0.0
    var theirSentiment = 0.0
    var awaitingMyReply = false
    var waitingSince: Date?
    var lastQuestionFromThem: String?
    var lastDate = Date.distantPast
    /// Messages per week, oldest first, for the last twelve weeks.
    var weekly: [Int] = Array(repeating: 0, count: 12)
    /// Messages per day, oldest first, for the last fourteen days.
    var daily: [Int] = Array(repeating: 0, count: 14)

    enum Trend: String, Codable, Sendable { case warming, steady, cooling, quiet }

    var trend: Trend {
        if last30 == 0 && prior30 == 0 { return .quiet }
        if prior30 == 0 { return .warming }
        let ratio = Double(last30) / Double(prior30)
        return ratio > 1.3 ? .warming : ratio < 0.6 ? .cooling : .steady
    }

    /// Higher means this chat wants your attention.
    var attention: Double {
        var score = 0.0
        if awaitingMyReply, let since = waitingSince {
            let hours = Date().timeIntervalSince(since) / 3600
            score += min(10, 2 + hours / 12)
            if lastQuestionFromThem != nil { score += 3 }
        }
        if trend == .cooling { score += 1.5 }
        score += min(3, Double(last30) / 80)
        return score
    }

    var balance: Double { total == 0 ? 0.5 : Double(mine) / Double(total) }
}

enum RelationshipAnalyzer {
    /// A new conversation starts after this much silence.
    nonisolated static let conversationGap: TimeInterval = 8 * 3600

    /// Runs off the main actor: sentiment over thousands of lines is real work.
    @concurrent nonisolated static func stats(for chat: ChatSummary, store: MemoryStore = .shared) async -> RelationshipStats {
        // A chat whose size and last message have not moved has not changed.
        let stamp = "\(chat.messageCount)|\(chat.lastDate.timeIntervalSince1970)"
        if let cached = await StatsCache.shared.get(chat.id, stamp: stamp) { return cached }
        let lines = (try? await store.lines(source: chat.source, chatID: chat.chatID, limit: 8000)) ?? []
        let stats = compute(lines)
        await StatsCache.shared.set(chat.id, stamp: stamp, stats: stats)
        return stats
    }

    nonisolated static func compute(_ lines: [ChatLine], now: Date = .now) -> RelationshipStats {
        var stats = RelationshipStats()
        guard !lines.isEmpty else { return stats }
        stats.total = lines.count
        stats.mine = lines.filter(\.isFromMe).count
        stats.theirs = stats.total - stats.mine
        stats.lastDate = lines.last!.date

        let day: TimeInterval = 86400
        var myReplies: [Double] = []
        var theirReplies: [Double] = []
        var previous: ChatLine?
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        var mySentiments: [Double] = []
        var theirSentiments: [Double] = []

        for line in lines {
            let age = now.timeIntervalSince(line.date)
            if age < 30 * day { stats.last30 += 1 } else if age < 60 * day { stats.prior30 += 1 }
            // A clock that was wrong can date a message in the future; count it as this week.
            let week = max(0, Int(age / (7 * day)))
            if week < 12 { stats.weekly[11 - week] += 1 }
            let calendar = Calendar.current
            let days = max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: line.date),
                                                      to: calendar.startOfDay(for: now)).day ?? 0)
            if days < 14 { stats.daily[13 - days] += 1 }

            if let previous {
                let gap = line.date.timeIntervalSince(previous.date)
                if gap > conversationGap {
                    if line.isFromMe { stats.myInitiations += 1 } else { stats.theirInitiations += 1 }
                } else if previous.isFromMe != line.isFromMe {
                    if line.isFromMe { myReplies.append(gap / 60) } else { theirReplies.append(gap / 60) }
                }
            } else {
                if line.isFromMe { stats.myInitiations += 1 } else { stats.theirInitiations += 1 }
            }

            if age < 60 * day, line.text.count > 8 {
                tagger.string = line.text
                let tag = tagger.tag(at: line.text.startIndex, unit: .paragraph, scheme: .sentimentScore).0
                if let value = tag.flatMap({ Double($0.rawValue) }) {
                    if line.isFromMe { mySentiments.append(value) } else { theirSentiments.append(value) }
                }
            }
            previous = line
        }

        stats.myReplyMinutes = median(myReplies)
        stats.theirReplyMinutes = median(theirReplies)
        stats.mySentiment = mySentiments.isEmpty ? 0 : mySentiments.reduce(0, +) / Double(mySentiments.count)
        stats.theirSentiment = theirSentiments.isEmpty ? 0 : theirSentiments.reduce(0, +) / Double(theirSentiments.count)

        // Their trailing run of messages, if they spoke last.
        let tail = lines.reversed().prefix { !$0.isFromMe }
        if !tail.isEmpty, let oldest = tail.last {
            stats.awaitingMyReply = now.timeIntervalSince(oldest.date) < 21 * day
            stats.waitingSince = oldest.date
            stats.lastQuestionFromThem = tail.first(where: { $0.text.contains("?") })?.text
        }
        return stats
    }

    nonisolated static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    // MARK: Reading, with a model

    @Generable
    struct Read: Codable {
        @Guide(description: "How close the two people are, from 0 (strangers) to 100 (closest possible)", .range(0...100))
        var closeness: Int
        @Guide(description: "The feel of the relationship right now, in two to four words")
        var vibe: String
        @Guide(description: "Three or four sentences: who this person is to the user, what they talk about, and how things stand now")
        var summary: String
        @Guide(description: "Things left hanging: unanswered questions, promises, plans not confirmed", .maximumCount(4))
        var openLoops: [String]
        @Guide(description: "Concrete, kind suggestions for the user about this relationship", .maximumCount(3))
        var suggestions: [String]
    }

    @Generable
    struct ReplyIdeas {
        @Guide(description: "One sentence on what the other person is asking or feeling right now")
        var context: String
        @Guide(description: "Three different replies the user could send", .count(3))
        var options: [Option]

        @Generable
        struct Option {
            @Guide(description: "The reply exactly as the user would send it, in the language of the chat and in the user's own style")
            var text: String
            @Guide(description: "One or two words naming the tone, such as warm, playful, direct")
            var tone: String
            @Guide(description: "Why this reply works, in one short sentence")
            var why: String
        }
    }

    static func read(_ chat: ChatSummary, stats: RelationshipStats) async throws -> Card.PersonRead {
        let me = AppSettings.shared.myName
        let lines = try await MemoryStore.shared.lines(source: chat.source, chatID: chat.chatID, limit: 120)
        let facts = (try? await MemoryStore.shared.facts(matching: chat.name, limit: 12)) ?? []
        let prompt = """
        Chat with \(chat.name) on \(chat.source.displayName).
        Measured: \(statsLine(stats)).
        \(facts.isEmpty ? "" : "Known facts:\n" + facts.map { "- \($0.sentence)" }.joined(separator: "\n"))

        Most recent messages:
        \(transcript(lines, me: me))
        """
        let read = try await ModelHub.generate(
            Read.self, prompt: prompt,
            instructions: """
            You read a private conversation the user has shared with you, with their consent, to help them \
            understand and care for their relationships. Be warm, honest and specific. Never invent events. \
            Write in \(Persona.languageName).
            """)
        let card = Card.PersonRead(
            name: chat.name, closeness: read.closeness, vibe: read.vibe, summary: read.summary,
            openLoops: read.openLoops, suggestions: read.suggestions)
        if let data = try? JSONEncoder().encode(card), let json = String(data: data, encoding: .utf8) {
            try? await MemoryStore.shared.saveInsight(json, key: "read:\(chat.id)")
        }
        return card
    }

    static func cachedRead(_ chat: ChatSummary) async -> (Card.PersonRead, Date)? {
        guard let (json, date) = try? await MemoryStore.shared.insight(key: "read:\(chat.id)"),
              let card = try? JSONDecoder().decode(Card.PersonRead.self, from: Data(json.utf8))
        else { return nil }
        return (card, date)
    }

    static func replies(for chat: ChatSummary, intent: String? = nil) async throws -> Card.Replies {
        let me = AppSettings.shared.myName
        let lines = try await MemoryStore.shared.lines(source: chat.source, chatID: chat.chatID, limit: 60)
        // How the user actually writes, so suggestions sound like them.
        let style = lines.filter(\.isFromMe).suffix(25).map { "- \($0.text.prefix(160))" }.joined(separator: "\n")
        let ideas = try await ModelHub.generate(
            ReplyIdeas.self,
            prompt: """
            Chat with \(chat.name).
            \(intent.map { "What the user wants to get across: \($0)\n" } ?? "")
            How the user writes (their own recent messages):
            \(style)

            Conversation:
            \(transcript(lines, me: me))
            """,
            instructions: """
            You help the user answer a message. Write replies in the user's voice: match their language, \
            slang, length, punctuation and emoji habits exactly as shown in their own messages. \
            Never sound like an assistant. The context sentence is in \(Persona.languageName).
            """)
        return Card.Replies(
            context: ideas.context,
            options: ideas.options.map { .init(text: $0.text, tone: $0.tone, why: $0.why) })
    }
}

/// Relationship statistics already computed, keyed by chat and its size.
actor StatsCache {
    static let shared = StatsCache()
    private var entries: [String: (stamp: String, stats: RelationshipStats)] = [:]

    func get(_ id: String, stamp: String) -> RelationshipStats? {
        guard let entry = entries[id], entry.stamp == stamp else { return nil }
        return entry.stats
    }

    func set(_ id: String, stamp: String, stats: RelationshipStats) {
        entries[id] = (stamp, stats)
    }
}
