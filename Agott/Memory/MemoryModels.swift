import Foundation

/// Where a memory came from. The raw value is what the database stores.
nonisolated enum MemorySource: String, Codable, Sendable, CaseIterable, Identifiable {
    case imessage
    case whatsapp
    case claude
    case screen
    case note

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .imessage: "message.fill"
        case .whatsapp: "phone.bubble.fill"
        case .claude: "sparkle"
        case .screen: "macwindow"
        case .note: "brain.head.profile"
        }
    }

    var displayName: String {
        switch self {
        case .imessage: String(localized: "iMessage")
        case .whatsapp: String(localized: "WhatsApp")
        case .claude: String(localized: "Claude history")
        case .screen: String(localized: "Screen")
        case .note: String(localized: "Things you told Agott")
        }
    }
}

/// One message as read from a source, before it is chunked.
nonisolated struct RawMessage: Sendable {
    var source: MemorySource
    /// Stable within the source, so re-indexing never duplicates.
    var externalID: String
    var chatID: String
    var chatName: String
    var isGroup: Bool
    var sender: String
    var isFromMe: Bool
    var date: Date
    var text: String
}

/// A window of conversation: the unit that gets searched and embedded.
///
/// Single messages are too small to mean anything ("kkkk", "sim") and whole
/// chats are too large to retrieve. A run of messages close in time reads like
/// a moment, which is what someone is actually asking about.
nonisolated struct MemoryChunk: Sendable, Identifiable, Hashable {
    var id: Int64
    var source: MemorySource
    var chatID: String
    var chatName: String
    var start: Date
    var end: Date
    var text: String
    var participants: [String]
    /// Whether the chat is a group. A group named after someone ("bio a
    /// ligia") is not that person, and the model has to be told which is which.
    var isGroup: Bool? = nil
}

/// A search hit, carrying why it ranked where it did.
nonisolated struct MemoryHit: Sendable, Identifiable, Hashable {
    var chunk: MemoryChunk
    var score: Double
    var matchedBy: Set<Signal>

    var id: Int64 { chunk.id }

    nonisolated enum Signal: String, Sendable, Hashable {
        case keyword, meaning, graph
    }
}

/// A chat as a whole, with the counts the relationship view needs.
nonisolated struct ChatSummary: Sendable, Identifiable, Hashable {
    var source: MemorySource
    var chatID: String
    var name: String
    var isGroup: Bool
    var messageCount: Int
    var myCount: Int
    var firstDate: Date
    var lastDate: Date
    var lastFromMe: Bool
    var lastText: String

    var id: String { "\(source.rawValue):\(chatID)" }
    var theirCount: Int { messageCount - myCount }
}

nonisolated enum EntityKind: String, Codable, Sendable, CaseIterable {
    case me, person, group, place, organization, topic, project, thing

    var symbol: String {
        switch self {
        case .me: "person.crop.circle.fill"
        case .person: "person.fill"
        case .group: "person.3.fill"
        case .place: "mappin.circle.fill"
        case .organization: "building.2.fill"
        case .topic: "number"
        case .project: "hammer.fill"
        case .thing: "cube.fill"
        }
    }
}

nonisolated struct GraphEntity: Sendable, Identifiable, Hashable {
    var id: Int64
    var kind: EntityKind
    var name: String
    var mentions: Int
    var lastSeen: Date?
}

nonisolated struct GraphEdge: Sendable, Hashable {
    var source: Int64
    var target: Int64
    var relation: String
    var weight: Double
    var lastSeen: Date?
}

/// Something Agott believes, with where it learned it.
nonisolated struct MemoryFact: Sendable, Identifiable, Hashable {
    var id: Int64
    var subject: String
    var predicate: String
    var object: String
    var confidence: Double
    var source: MemorySource
    var date: Date
    /// The proof: words copied from the moment the fact came from.
    var evidence: String? = nil
    /// The subject said it about themselves (not someone else, not a guess).
    var selfStated = false
    /// Sexuality, gender, health, religion, politics and the like.
    var sensitive = false
    /// The chat it was said in, and whether that chat is a group.
    var chatName: String? = nil
    var inGroup = false
    /// The person the fact is about, in the people directory.
    var subjectID: Int64? = nil
    /// What the fact is about, whatever its wording or language.
    var kind: FactKind? = nil
    /// When it stopped being true (a newer fact replaced it), if it did.
    var ended: Date? = nil

    /// How well the fact holds today: its odds, worn down by time for the
    /// kinds of thing that change (a mood in weeks, a plan in months, a
    /// city in years; a birthday never).
    func strength(at now: Date = .now) -> Double {
        var value = confidence * (selfStated ? 1.08 : 1)
        // Replaced by a newer answer: kept, well below what holds.
        if ended != nil { value *= 0.25 }
        if let days = (kind ?? .other).halfLifeDays {
            let age = max(0, now.timeIntervalSince(date) / 86400)
            value *= max(0.15, pow(0.5, age / days))
        }
        return value
    }

    /// Whether enough time has passed that it may no longer be true.
    func isStale(at now: Date = .now) -> Bool {
        guard let days = (kind ?? .other).halfLifeDays else { return false }
        return now.timeIntervalSince(date) / 86400 > days
    }

    /// Best supported today first.
    static func ranked(_ facts: [MemoryFact], at now: Date = .now) -> [MemoryFact] {
        facts.sorted { a, b in
            let x = a.strength(at: now), y = b.strength(at: now)
            return x == y ? a.date > b.date : x > y
        }
    }

    /// The verb to show: the kind in the reader's language, or the fact's
    /// own words when it is of no listed kind.
    var displayPredicate: String {
        guard let kind, kind != .other else { return predicate }
        return kind.label
    }

    /// Where it was said, for a model to read.
    var place: String? {
        chatName.map { inGroup ? "the group \"\($0)\"" : "the direct chat with \($0)" }
    }

    var sentence: String { "\(subject) \(predicate) \(object)" }

    /// The fact with its odds and its proof, for a model to read.
    var withProof: String {
        var line = "\(sentence) (\(Int((confidence * 100).rounded()))%"
        line += selfStated ? ", said by \(subject) themselves" : ", inferred"
        if let place { line += ", in \(place)" }
        line += ", \(MemoryStore.stamp(date.timeIntervalSince1970))"
        if let ended {
            line += ", a newer answer replaced it on \(MemoryStore.stamp(ended.timeIntervalSince1970).prefix(10))"
        } else if isStale() {
            line += ", old: may have changed since"
        }
        line += ")"
        if let evidence, !evidence.isEmpty { line += " — proof: “\(evidence)”" }
        return line
    }
}

nonisolated struct ChatLine: Sendable, Hashable, Identifiable {
    var id: Int64
    var sender: String
    var isFromMe: Bool
    var date: Date
    var text: String
}

// MARK: - Kinds of links and facts

/// The links the graph builds by itself, between people, groups and things.
/// The raw values are what is stored, unchanged from before they were an
/// enum; the label is what people read, in their language.
nonisolated enum GraphRelation: String, CaseIterable, Sendable {
    case talksWith = "talks with"
    case memberOf = "member of"
    case knows
    case mentions
    case involves

    var label: String {
        switch self {
        case .talksWith: String(localized: "talks with")
        case .memberOf: String(localized: "member of")
        case .knows: String(localized: "knows")
        case .mentions: String(localized: "mentions")
        case .involves: String(localized: "involves")
        }
    }
}

/// What a fact is about, independent of how it was worded or in which
/// language: "gosta de" and "likes" are both `.likes`. Stored beside the
/// fact's own words, it groups facts, finds the same fact said twice, and
/// gives every reader the same wording in their language.
nonisolated enum FactKind: String, CaseIterable, Codable, Sendable {
    case likes, dislikes, works, studies, livesIn, isFrom, plays, watches, listensTo, reads
    case owns, uses, wants, plans, learning, goodAt, birthday, age, feels, believes, said, relationship, other

    var label: String {
        switch self {
        case .likes: String(localized: "likes")
        case .dislikes: String(localized: "dislikes")
        case .works: String(localized: "works on")
        case .studies: String(localized: "studies")
        case .livesIn: String(localized: "lives in")
        case .isFrom: String(localized: "is from")
        case .plays: String(localized: "plays")
        case .watches: String(localized: "watches")
        case .listensTo: String(localized: "listens to")
        case .reads: String(localized: "reads")
        case .owns: String(localized: "has")
        case .uses: String(localized: "uses")
        case .wants: String(localized: "wants")
        case .plans: String(localized: "plans")
        case .learning: String(localized: "is learning")
        case .goodAt: String(localized: "is good at")
        case .birthday: String(localized: "birthday")
        case .age: String(localized: "age")
        case .feels: String(localized: "feels")
        case .believes: String(localized: "thinks")
        case .said: String(localized: "said")
        case .relationship: String(localized: "relationship")
        case .other: String(localized: "other")
        }
    }

    /// After how many days a fact of this kind is as likely to have changed
    /// as not; nil for what does not change (where someone is from, a
    /// birthday) or changes too slowly to matter.
    var halfLifeDays: Double? {
        switch self {
        case .feels: 30
        case .plans: 150
        case .wants: 300
        case .relationship: 365
        case .age: 365
        case .said: 540
        case .learning: 540
        case .uses, .watches, .plays, .reads, .listensTo: 900
        case .works, .studies: 900
        case .livesIn: 1500
        case .believes: 1500
        case .likes, .dislikes, .owns: 2500
        case .isFrom, .birthday, .goodAt, .other: nil
        }
    }

    /// Kinds where a person has one value at a time: a new one replaces
    /// the old one instead of standing beside it. Where someone lives is
    /// not one of them: chats say it in too many ways ("with my parents",
    /// "near the church", a city on a trip) for a newer line to mean the
    /// older one is over. It only wears thin with time.
    var singleValued: Bool {
        switch self {
        case .age, .relationship: true
        default: false
        }
    }

    /// The kind a worded predicate most likely is, in Portuguese or English.
    /// Specific phrases first ("não gosta" before "gosta").
    static func guess(_ predicate: String) -> FactKind {
        let p = " " + predicate.folded + " "
        let rules: [(FactKind, [String])] = [
            (.dislikes, ["nao gosta", "odeia", "dislike", "hate", "detesta"]),
            (.relationship, ["namora", "solteir", "casad", "noiv", "ficando com", "dating", "single", "married", "engaged",
                             "estado civil", "relationship status", "terminou com", "broke up"]),
            (.birthday, ["aniversario", "birthday", "nasceu", "born"]),
            (.age, [" idade ", " tem anos", " anos de idade", " age ", "years old", " tem idade"]),
            (.likes, ["gosta", "ama ", "adora", "curte", "like", "love", "fa de", "fan of", "prefere", "prefer"]),
            (.works, ["trabalha", "work", "emprego", "job", "empresa", "constroi", "build", "desenvolve", "develop"]),
            (.studies, ["estuda", "study", "faculdade", "curso", "escola", "school", "college", "intercambio"]),
            (.livesIn, [" mora ", " moro ", " mora em", " morando em", " vive em", " lives ", " live in", " living in", " reside"]),
            (.isFrom, ["e de ", "veio de", "is from", "from "]),
            (.plays, [" joga", "play", "toca "]),
            (.watches, ["assiste", "watch", "viu ", "maratona"]),
            (.listensTo, ["ouve", "escuta", "listen"]),
            (.reads, [" le ", "lendo", "read"]),
            (.learning, ["aprend", "learning"]),
            (.goodAt, ["bom em", "boa em", "good at", "manja"]),
            (.wants, ["quer", "want", "deseja", "sonha"]),
            (.plans, ["planeja", "vai ", "plan", "pretende"]),
            (.owns, [" tem ", "possui", " has ", " own", "comprou", "bought"]),
            (.uses, [" usa", " use"]),
            (.feels, ["sente", "feel", "esta triste", "esta feliz"]),
            (.believes, ["acha", "pensa", "think", "acredita", "believe"]),
            (.said, ["disse", "diz", "said", "says", "falou", "conta"]),
        ]
        for (kind, needles) in rules where needles.contains(where: { p.contains($0) }) { return kind }
        return .other
    }
}
