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
        let store = MemoryStore.shared
        let me = AppSettings.myNameSnapshot
        let mine = Set(((try? await store.myNicknames()) ?? []).map(\.folded))
        var subject = arguments.subject
        var subjectID: Int64?
        if KnowledgeGraph.isUser(subject, me: me, alsoCalled: mine) {
            subject = me
        } else if let ref = try? await store.resolvePeople(subject).first(where: { $0.kind == .person }) {
            // Filed under the person, whatever name the user used for them.
            subject = ref.name
            subjectID = ref.id
        }
        let kind = FactKind.guess(arguments.predicate)
        try await store.addFact(
            subject: subject, predicate: arguments.predicate, object: arguments.object,
            confidence: 0.95, source: .note, chunkID: nil, at: .now, selfStated: subject == me,
            subjectID: subjectID, kind: kind)
        if kind.singleValued {
            try? await store.supersede(subject: subject, subjectID: subjectID, kind: kind, object: arguments.object, at: .now)
        }
        await KnowledgeGraph.link(subject: subject, predicate: arguments.predicate, object: arguments.object, kind: .thing, at: .now)
        return "Saved: \(subject) \(arguments.predicate) \(arguments.object)"
    }
}

nonisolated struct PersonNoteTool: Tool {
    let name = "note_person"
    let description = """
    Record who someone is, when the user says so or corrects you: a nickname they go by, that two names (or a \
    name and a number) are the same person, or how two people are related and whether that is over. The user \
    can be a side ("me"): their mother, partner, ex, best friend, boss.
    """

    @Generable
    struct Arguments {
        @Guide(description: "The person, by name, or \"me\" for the user")
        var person: String
        @Guide(description: "A nickname this person goes by, if that is what was said")
        var nickname: String?
        @Guide(description: "Another name, contact name or number that is this same person, if that is what was said")
        var sameAs: String?
        @Guide(description: "How the person relates to `other`, one of: partner, ex, crush, family, sibling, parent, friend, bestFriend, classmate, coworker, roommate, conflict. parent means the person is the parent of `other`; crush means the person likes `other`")
        var relation: String?
        @Guide(description: "The other person in the relation, by name, or \"me\" for the user")
        var other: String?
        @Guide(description: "The relation in the user's words: mãe, namorada, primo, chefe")
        var detail: String?
        @Guide(description: "true when the relation is over (they broke up, fell out)")
        var ended: Bool?
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        let store = MemoryStore.shared
        let me = AppSettings.myNameSnapshot
        let mine = Set(((try? await store.myNicknames()) ?? []).map(\.folded))
        func id(_ name: String) async -> (id: Int64, name: String)? {
            if KnowledgeGraph.isUser(name, me: me, alsoCalled: mine) { return (MemoryStore.me, me) }
            if let ref = try? await store.resolvePeople(name).first(where: { $0.kind == .person }) { return (ref.id, ref.name) }
            guard let new = try? await store.ensurePerson(name) else { return nil }
            return (new, name)
        }
        guard let person = await id(arguments.person) else { return "I could not tell who \(arguments.person) is." }
        var done: [String] = []

        if let nickname = arguments.nickname?.trimmingCharacters(in: .whitespaces), !nickname.isEmpty {
            let kept = (try? await store.learnNickname(nickname, forID: person.id, name: person.name, evidence: nil, trusted: true)) ?? false
            done.append(kept ? "\(person.name) is also called \(nickname)" : "\(nickname) is too common a word to keep as a nickname")
        }
        if let same = arguments.sameAs?.trimmingCharacters(in: .whitespaces), !same.isEmpty, person.id != MemoryStore.me {
            let others = ((try? await store.resolvePeople(same)) ?? []).filter { $0.kind == .person && $0.id != person.id }
            if let other = others.first(where: { $0.name.folded == same.folded }) ?? (others.count == 1 ? others[0] : nil) {
                // Into the entry with a real name; between two names, the one the user called them by.
                let keepOther = PersonName.isPlaceholder(person.name) && !PersonName.isPlaceholder(other.name)
                try? await store.mergePerson(keepOther ? person.id : other.id, into: keepOther ? other.id : person.id)
                done.append("\(other.name) and \(person.name) are now one person")
            } else if others.isEmpty {
                _ = try? await store.learnNickname(same, forID: person.id, name: person.name, evidence: nil, trusted: true)
                done.append("\(person.name) is also \(same)")
            } else {
                done.append("\(same) could be " + others.prefix(4).map(\.name).joined(separator: " or ") + "; ask which one")
            }
        }
        if let relation = arguments.relation, let kind = MemoryStore.LinkKind(rawValue: relation),
           let otherName = arguments.other, let other = await id(otherName), other.id != person.id {
            let ended = arguments.ended ?? false
            try? await store.link(person.id, other.id, kind: kind, detail: arguments.detail, confidence: 0.95,
                                  evidence: nil, chunkID: nil, at: .now, ended: ended)
            done.append("\(person.name) \(ended ? kind.pastPhrase : kind.phrase) \(other.name)" + (ended ? " (over)" : ""))
        } else if arguments.ended == true, let otherName = arguments.other, let other = await id(otherName) {
            try? await store.endLinks(between: person.id, and: other.id, kinds: [.partner, .crush, .friend, .bestFriend, .roommate],
                                      at: .now)
            done.append("what there was between \(person.name) and \(other.name) is marked as over")
        }
        guard !done.isEmpty else { return "Nothing to record: give a nickname, a same-as name, or a relation with the other person." }
        await PeopleDirectory.shared.refresh()
        await PeopleBrief.refresh()
        return "Saved: " + done.joined(separator: "; ")
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
