import Foundation
import FoundationModels
import Observation

/// What new messages ask of you, judged by Jev the moment they arrive.
///
/// For each chat with something new, one request asks four things about the
/// last stretch of the conversation: does their latest message want an
/// answer, is a question of theirs still open, did you ask something they
/// never answered (worth asking again), and how soon it matters. The answers
/// are kept per chat and ranked, so "who needs me?" is a list, not a guess.
nonisolated struct FollowUp: Codable, Hashable, Sendable, Identifiable {
    var id: String { chatKey }
    var chatKey: String
    var name: String
    var source: MemorySource
    var lastText: String
    var date: Date
    /// Probabilities, 0…1.
    var needsReply: Double
    var openQuestion: Double
    var askAgain: Double
    /// 0 (can wait) … 3 (right now).
    var urgency: Double
    var kind: String
    var checked: Date

    var priority: Double { max(needsReply, openQuestion) * (1 + urgency) + askAgain * 0.6 }
    var matters: Bool { needsReply >= 0.6 || openQuestion >= 0.6 || askAgain >= 0.6 }
}

@Observable
final class FollowUpCenter {
    static let shared = FollowUpCenter()
    private static let insightKey = "followups"

    private(set) var items: [FollowUp] = []

    private init() {
        Task {
            if let (json, _) = try? await MemoryStore.shared.insight(key: Self.insightKey),
               let saved = try? JSONDecoder().decode([FollowUp].self, from: Data(json.utf8)) {
                items = saved
            }
        }
    }

    /// The ones worth your attention, most pressing first.
    var pending: [FollowUp] { items.filter(\.matters).sorted { $0.priority > $1.priority } }

    func item(for chatKey: String) -> FollowUp? { items.first { $0.chatKey == chatKey } }

    /// You answered: it is no longer waiting on you.
    func clear(_ chatKey: String) {
        items.removeAll { $0.chatKey == chatKey }
        save()
    }

    func update(_ followUp: FollowUp) {
        items.removeAll { $0.chatKey == followUp.chatKey }
        items.append(followUp)
        // Old judgments go stale; keep two weeks.
        items.removeAll { $0.date < Date().addingTimeInterval(-14 * 86400) }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items), let json = String(data: data, encoding: .utf8) else { return }
        Task { try? await MemoryStore.shared.saveInsight(json, key: Self.insightKey) }
    }
}

enum FollowUps {
    /// What one check found: the follow-up, and a new message worth
    /// remembering if there is one.
    struct Result: Sendable {
        var followUp: FollowUp
        var memorable: RawMessage?
        var memorability: Double
    }

    /// Judges a chat after new messages from `name`. `recent` is the end of
    /// the conversation, oldest first, including `fresh`, the new ones.
    static func check(name: String, source: MemorySource, chatKey: String,
                      recent: [RawMessage], fresh: [RawMessage]) async throws -> Result {
        let me = AppSettings.myNameSnapshot
        let conversation = recent.suffix(20).map { message -> [String: String] in
            [
                "from": message.isFromMe ? "user" : (message.sender.isEmpty ? name : message.sender),
                "at": message.date.formatted(.dateTime.day().month().hour().minute()),
                "text": String(message.text.prefix(500)),
            ]
        }
        // The new messages, by id, so Jev can point at the one worth keeping.
        let incoming = Array(fresh.filter { !$0.isFromMe }.suffix(8))
        var candidates: [String: String] = ["none": "None of them says anything lasting."]
        var newMessages: [[String: String]] = []
        for (index, message) in incoming.enumerated() {
            candidates["m\(index)"] = "The new message `new_messages[\(index)]`."
            newMessages.append(["id": "m\(index)", "text": String(message.text.prefix(500))])
        }
        let state: [String: Any] = [
            "user": "\(me) (the user)",
            "person": name,
            "conversation": conversation,
            "new_messages": newMessages,
            "now": Date().formatted(.dateTime.weekday(.wide).day().month().hour().minute()),
        ]
        let answers = try await Jev.ask(state: state, questions: [
            "needs_reply": .noul("Does the latest message from `person` in `conversation` expect or deserve a reply from the user, considering everything said after it?"),
            "open_question": .noul("Is there a question from `person` in `conversation` that the user has not answered yet?"),
            "ask_again": .noul("Did the user ask `person` something earlier in `conversation` that `person` has still not answered, so it would be worth asking again?"),
            "urgency": .score("How soon should the user answer `person`, given `conversation` and `now`?", [
                "No answer needed, or it can wait for days.",
                "Should be answered today.",
                "Should be answered within the hour.",
                "Needs an answer right now: an emergency, or someone waiting in real time.",
            ]),
            "remember": .noul("""
            Do `new_messages` say something lasting that a close friend would remember about `person` or the user: \
            a plan or date, a preference, a life event, a promise, where they work or study, someone in their life? \
            Small talk, reactions and passing moods are not lasting.
            """),
            "remember_which": .choice("Which of `new_messages` holds the thing most worth remembering?", candidates),
            "kind": .choice("What is the latest message from `person` in `conversation` mainly about?", [
                "question": "Asks the user something.",
                "plan": "An invitation, plan, date or arrangement.",
                "support": "They are upset, sad, stressed or sharing something hard.",
                "news": "Sharing something that happened, a link or a photo.",
                "logistics": "Practical details: addresses, times, payments, tasks.",
                "small_talk": "Greetings, reactions, jokes or chit-chat.",
            ]),
        ])
        let last = recent.last { !$0.isFromMe }
        let which = answers["remember_which"]?.choice ?? "none"
        let memorable = which.hasPrefix("m") ? Int(which.dropFirst()).flatMap { incoming.indices.contains($0) ? incoming[$0] : nil } : nil
        let followUp = FollowUp(
            chatKey: chatKey, name: name, source: source,
            lastText: last?.text ?? "", date: last?.date ?? .now,
            needsReply: answers["needs_reply"]?.probability ?? 0,
            openQuestion: answers["open_question"]?.probability ?? 0,
            askAgain: answers["ask_again"]?.probability ?? 0,
            urgency: answers["urgency"]?.score ?? 0,
            kind: answers["kind"]?.choice ?? "small_talk",
            checked: .now)
        return Result(followUp: followUp, memorable: memorable, memorability: answers["remember"]?.probability ?? 0)
    }
}

/// Writes down what Jev judged worth remembering. Jev decides *whether*;
/// the learning model only phrases the fact, so small talk never costs a call.
enum Remembering {
    @Generable
    struct Draft {
        @Guide(description: "Who the fact is about: the person's name, or \"me\" for the user")
        var subject: String
        @Guide(description: "The relation, short: works at, likes, birthday is, is travelling to, promised to…")
        var predicate: String
        @Guide(description: "The value, short and specific")
        var object: String
    }

    static let threshold = 0.7

    static func save(_ message: RawMessage, from name: String, probability: Double) async {
        guard probability >= threshold, !KnowledgeGraph.isSensitive(message.text) else { return }
        let me = AppSettings.myNameSnapshot
        guard let draft = try? await ModelHub.generate(
            Draft.self,
            prompt: "\(name) wrote to \(me) on \(message.date.formatted(date: .abbreviated, time: .shortened)):\n\(message.text.prefix(800))",
            instructions: "Turn the message into one lasting fact worth remembering. Keep names as written. Write in \(Persona.languageName).",
            provider: ModelHub.learningProvider, modelName: ModelHub.learningModel)
        else { return }
        let subject = draft.subject.lowercased() == "me" ? me : draft.subject
        guard !KnowledgeGraph.isSensitive(draft.object) else { return }
        try? await MemoryStore.shared.addFact(
            subject: subject, predicate: draft.predicate, object: draft.object,
            confidence: min(0.95, probability), source: message.source, chunkID: nil, at: message.date)
        await KnowledgeGraph.link(subject: subject, predicate: draft.predicate, object: draft.object, kind: .thing, at: message.date)
    }
}
