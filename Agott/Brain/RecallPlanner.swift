import Foundation

/// Decides, before the chat model starts, everything a message needs from
/// memory, and gathers it all at once.
///
/// Without a plan the model finds out what it needs one tool call at a time:
/// it searches, reads the result, searches again, reads a chat, checks the
/// calendar. Each round trip is a few seconds of "Remembering". Jev answers
/// all the routing questions in one quick request (who is this about, which
/// period, does it need the chat itself, the relationship, the calendar),
/// code runs every lookup in parallel, and the model gets it in one piece.
///
/// Jev chooses; code fetches. Without a TypeSafe key, or when Jev is slow,
/// the plan is empty and the reply goes on as before.
nonisolated enum RecallPlanner {
    struct Plan: Sendable, Equatable {
        /// The chat (person or group) the message is about, as it is named in memory.
        var person: String?
        /// That exact chat, so the lookups read the one Jev picked and not
        /// another chat with a similar name.
        var chat: ChatSummary?
        var since: Date?
        var readChat = false
        var relationship = false
        var overview = false
        var calendarDays: Int?

        var isEmpty: Bool { person == nil && since == nil && !overview && calendarDays == nil }
    }

    enum Period: String, CaseIterable {
        case today, yesterday, week, month, any

        var since: Date? {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: .now)
            switch self {
            case .today: return today
            case .yesterday: return calendar.date(byAdding: .day, value: -1, to: today)
            case .week: return calendar.date(byAdding: .day, value: -7, to: today)
            case .month: return calendar.date(byAdding: .day, value: -31, to: today)
            case .any: return nil
            }
        }
    }

    /// The questions, all about the same state, asked together.
    static func questions(candidates: [String: String]) -> [String: Jev.Question] {
        [
            "person": .choice("""
            Which person or group is `message` about, reading `earlier` to resolve words like "she", \
            "him", "them" or "that group"? Pick none when it is about no one in particular or about \
            several people at once.
            """, candidates),
            "period": .choice("Which stretch of time does `message` ask about, given `now`?", [
                Period.today.rawValue: "Today.",
                Period.yesterday.rawValue: "Yesterday, or last night.",
                Period.week.rawValue: "The last few days or this week.",
                Period.month.rawValue: "The last weeks or this month.",
                Period.any.rawValue: "No particular time, or long ago.",
            ]),
            "read_chat": .noul("""
            To answer `message`, does the assistant need to read the latest messages of the chosen \
            person's conversation word for word: what they just said, how to reply to them, what is \
            going on between them right now?
            """),
            "relationship": .noul("""
            Is `message` about how the user's relationship with someone is going: closeness, who \
            writes more, whether they are drifting apart, whether someone is waiting for a reply?
            """),
            "overview": .noul("""
            Is `message` about the user's people in general rather than one person: who they talk to \
            most, who is waiting for them, who they have neglected?
            """),
            "calendar": .choice("Does answering `message` need the user's calendar, and for how long?", [
                "none": "No calendar needed.",
                "day": "Today or tomorrow: what is on, when they are free, a single plan.",
                "week": "The coming week or a specific day this week.",
                "month": "The coming weeks or a date further away.",
            ]),
        ]
    }

    /// Asks Jev for a plan. Nil when it is not configured, fails, or takes
    /// longer than `limit`.
    static func plan(for message: String, earlier: [String], within limit: Duration = .seconds(4)) async -> Plan? {
        guard Jev.isConfigured, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let chats = (try? await MemoryStore.shared.chats(limit: 60, includeGroups: true,
                                                         since: Date().addingTimeInterval(-120 * 86400))) ?? []
        var candidates: [String: String] = ["none": "Nobody in particular, or several people at once."]
        var names: [String: String] = [:]
        var picked: [String: ChatSummary] = [:]
        for (index, chat) in chats.prefix(50).enumerated() where !chat.name.isEmpty {
            let key = "c\(index)"
            candidates[key] = chat.isGroup ? "The group chat \"\(chat.name)\"." : "\(chat.name)."
            names[key] = chat.name
            picked[key] = chat
        }
        let state: [String: Any] = [
            "user": AppSettings.myNameSnapshot,
            "message": message,
            "earlier": earlier,
            "now": Date().formatted(.dateTime.weekday(.wide).day().month().year().hour().minute()),
        ]
        let questions = questions(candidates: candidates)
        let answers: [String: Jev.Answer]? = await withTaskGroup(of: [String: Jev.Answer]?.self) { group in
            group.addTask { try? await Jev.ask(state: state, questions: questions) }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let answers, !answers.isEmpty else { return nil }
        return plan(from: answers, names: names, chats: picked)
    }

    /// Turns Jev's answers into lookups. Thresholds lean towards fetching:
    /// an extra lookup costs milliseconds, a missing one costs a round trip.
    static func plan(from answers: [String: Jev.Answer], names: [String: String],
                     chats: [String: ChatSummary] = [:]) -> Plan {
        var plan = Plan()
        if let key = answers["person"]?.choice, let name = names[key] {
            plan.person = name
            plan.chat = chats[key]
        }
        if let period = answers["period"]?.choice.flatMap(Period.init(rawValue:)) { plan.since = period.since }
        plan.readChat = plan.person != nil && (answers["read_chat"]?.probability ?? 0) >= 0.4
        plan.relationship = plan.person != nil && (answers["relationship"]?.probability ?? 0) >= 0.5
        plan.overview = plan.person == nil && (answers["overview"]?.probability ?? 0) >= 0.5
        switch answers["calendar"]?.choice {
        case "day": plan.calendarDays = 2
        case "week": plan.calendarDays = 8
        case "month": plan.calendarDays = 31
        default: break
        }
        return plan
    }

    /// One thing gathered for the reply, and how to show it as a step.
    struct Gathered: Sendable {
        var title: String
        var symbol: String
        var text: String
    }

    /// Runs every lookup in the plan at once.
    static func gather(_ plan: Plan, query: String) async -> [Gathered] {
        await withTaskGroup(of: (Int, Gathered?).self) { group in
            if plan.person != nil || plan.since != nil {
                group.addTask {
                    var filter = MemoryStore.Filter()
                    filter.chatName = plan.person
                    filter.since = plan.since
                    let recall = await Retriever().recall(query, filter: filter, limit: 8)
                    guard !recall.isEmpty else { return (0, nil) }
                    let title = plan.person.map { String(localized: "Remembered things with \($0)") }
                        ?? String(localized: "Remembered that stretch of time")
                    return (0, Gathered(title: title, symbol: "brain.head.profile",
                                        text: recall.rendered(characterBudget: 5000)))
                }
            }
            if plan.readChat, let person = plan.person {
                group.addTask {
                    let text = if let chat = plan.chat {
                        try? await ReadChatTool.read(chat, count: 60)
                    } else {
                        try? await ReadChatTool().call(arguments: .init(person: person, count: 60))
                    }
                    return (1, text.map { Gathered(title: String(localized: "Read your chat with \(person)"),
                                                   symbol: "text.bubble", text: String($0.suffix(6000))) })
                }
            }
            if plan.relationship, let person = plan.person {
                group.addTask {
                    let text = if let chat = plan.chat {
                        await PersonInsightTool.insight(chat)
                    } else {
                        try? await PersonInsightTool().call(arguments: .init(person: person))
                    }
                    return (2, text.map { Gathered(title: String(localized: "Looked at you and \(person)"),
                                                   symbol: "heart.text.square", text: $0) })
                }
            }
            if plan.overview {
                group.addTask {
                    let text = try? await PeopleOverviewTool().call(arguments: .init(count: 15))
                    return (3, text.map { Gathered(title: String(localized: "Checked on everyone"),
                                                   symbol: "person.2", text: $0) })
                }
            }
            if let days = plan.calendarDays {
                group.addTask {
                    let text = try? await CalendarTool().call(arguments: .init(from: nil, days: days, show: false))
                    return (4, text.map { Gathered(title: String(localized: "Looked at your calendar"),
                                                   symbol: "calendar", text: $0) })
                }
            }
            var results: [(Int, Gathered)] = []
            for await (order, gathered) in group {
                if let gathered { results.append((order, gathered)) }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
