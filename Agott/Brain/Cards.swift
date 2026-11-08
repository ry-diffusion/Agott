import Foundation
import Observation

/// UI the model can put on screen.
///
/// Prose is the wrong shape for most of what a copilot is asked. "What does
/// this mean?" wants a definition and examples you can scan; "how should I
/// answer her?" wants three replies you can send with one click. The model
/// calls a tool, the tool posts a card, and the chat renders it natively.
nonisolated enum Card: Identifiable, Hashable, Sendable, Codable {
    case explanation(Explanation)
    case replies(Replies)
    case checklist(Checklist)
    case person(PersonRead)
    case events(EventList)
    case note(Note)
    case approval(Approval)
    case consistency(Consistency)
    case artifact(Artifact)
    case chart(ChartData)

    var id: UUID {
        switch self {
        case .explanation(let c): c.id
        case .replies(let c): c.id
        case .checklist(let c): c.id
        case .person(let c): c.id
        case .events(let c): c.id
        case .note(let c): c.id
        case .approval(let c): c.id
        case .consistency(let c): c.id
        case .artifact(let c): c.id
        case .chart(let c): c.id
        }
    }

    /// A chart in the conversation: one or more series over shared labels.
    struct ChartData: Hashable, Sendable, Codable {
        enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
            case bar, horizontalBar, stackedBar, line, area, pie, donut, scatter
        }

        struct Series: Hashable, Sendable, Codable {
            var name: String
            var values: [Double]
        }

        var id = UUID()
        var title: String
        var subtitle: String?
        var kind: Kind
        /// What each value is about: a day, a person, a category, or a number for scatter.
        var labels: [String]
        var series: [Series]
        var unit: String?
    }

    /// Something made to keep: a document, a message draft, code, a page, a
    /// table. It opens beside the chat, and each revision is a new version.
    struct Artifact: Hashable, Sendable, Codable {
        enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
            case document, code, html, table

            var symbol: String {
                switch self {
                case .document: "doc.richtext"
                case .code: "chevron.left.forwardslash.chevron.right"
                case .html: "safari"
                case .table: "tablecells"
                }
            }

            var fileExtension: String {
                switch self {
                case .document, .table: "md"
                case .code: "txt"
                case .html: "html"
                }
            }
        }

        var id = UUID()
        /// Stable across versions: the same piece of work, revised.
        var key: String
        var title: String
        var kind: Kind
        var language: String?
        var content: String
        var version = 1
    }

    struct Explanation: Hashable, Sendable, Codable {
        var id = UUID()
        var term: String
        var meaning: String
        var examples: [Example]
        var tip: String?

        struct Example: Hashable, Sendable, Codable {
            var text: String
            var note: String
        }
    }

    struct Replies: Hashable, Sendable, Codable {
        var id = UUID()
        var context: String
        var options: [Option]

        struct Option: Hashable, Sendable, Codable {
            var text: String
            var tone: String
            var why: String
        }
    }

    struct Checklist: Hashable, Sendable, Codable {
        var id = UUID()
        var title: String
        var items: [String]
    }

    struct PersonRead: Hashable, Sendable, Codable {
        var id = UUID()
        var name: String
        var closeness: Int
        var vibe: String
        var summary: String
        var openLoops: [String]
        var suggestions: [String]
    }

    struct EventList: Hashable, Sendable, Codable {
        var id = UUID()
        var title: String
        var items: [Item]

        struct Item: Hashable, Sendable, Codable {
            var title: String
            var start: Date
            var end: Date?
            var detail: String
        }
    }

    struct Note: Hashable, Sendable, Codable {
        var id = UUID()
        var title: String
        var body: String
        var symbol: String
    }

    /// Face to face versus behind their back.
    struct Consistency: Hashable, Sendable, Codable {
        var id = UUID()
        var name: String
        /// 0 = you talk about them exactly as you talk to them; 100 = two faces.
        var gap: Int
        var verdict: String
        var toThem: String
        var aboutThem: String
        var othersAboutThem: String
        var quotes: [Quote]
        var advice: String
        var toneToThem: Double
        var toneAboutThem: Double
        var mentionCount: Int

        struct Quote: Hashable, Sendable, Codable {
            var text: String
            var context: String
            var direct: Bool
        }
    }

    struct Approval: Hashable, Sendable, Codable {
        var id = UUID()
        var title: String
        var detail: String
        var state: State = .pending

        enum State: String, Hashable, Sendable, Codable { case pending, approved, denied }
    }
}

/// Where tools drop cards for whichever turn is running.
@Observable
final class CardBus {
    static let shared = CardBus()

    /// Set by the turn that is currently running.
    @ObservationIgnored var sink: ((Card) -> Void)?
    @ObservationIgnored var update: ((Card) -> Void)?

    func post(_ card: Card) { sink?(card) }

    nonisolated static func post(_ card: Card) async {
        await MainActor.run { CardBus.shared.post(card) }
    }
}

/// Asks before Agott does something with consequences: clicking in another
/// app, typing into it, creating an event, drafting mail.
///
/// The request shows as a card with Allow and Don't; the tool waits on it. In
/// Autopilot the answer is yes without asking, which is a setting you turn on
/// knowing what it means.
@Observable
final class Approvals {
    static let shared = Approvals()

    private var waiting: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private(set) var pending: [Card.Approval] = []

    func ask(_ title: String, detail: String) async -> Bool {
        if AppSettings.shared.autopilot { return true }
        let approval = Card.Approval(title: title, detail: detail)
        pending.append(approval)
        CardBus.shared.post(.approval(approval))
        return await withCheckedContinuation { continuation in
            waiting[approval.id] = continuation
        }
    }

    func answer(_ id: UUID, allow: Bool) {
        pending.removeAll { $0.id == id }
        // Only the state travels; whoever holds the card keeps its text.
        CardBus.shared.update?(.approval(Card.Approval(
            id: id, title: "", detail: "", state: allow ? .approved : .denied)))
        waiting.removeValue(forKey: id)?.resume(returning: allow)
    }

    /// Declines everything outstanding, e.g. when a turn is cancelled.
    func denyAll() {
        for id in Array(waiting.keys) { answer(id, allow: false) }
    }

    nonisolated static func ask(_ title: String, detail: String) async -> Bool {
        await Approvals.shared.ask(title, detail: detail)
    }
}
