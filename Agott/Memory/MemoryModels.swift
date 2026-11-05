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

    var sentence: String { "\(subject) \(predicate) \(object)" }
}

nonisolated struct ChatLine: Sendable, Hashable, Identifiable {
    var id: Int64
    var sender: String
    var isFromMe: Bool
    var date: Date
    var text: String
}
