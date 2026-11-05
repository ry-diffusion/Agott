import Foundation
import FoundationModels
import NaturalLanguage

/// Face to face versus behind their back.
///
/// It compares two things the messages already contain: how you write *to*
/// someone in your chat with them, and how you write *about* them in other
/// chats. Tone is measured on-device for every line first, so the gap is a
/// number before it is an opinion; then the model reads the actual quotes and
/// says, kindly and plainly, whether the two match. It also looks at what
/// other people say about them in groups you are in, because sometimes the
/// two-faced one is not you.
enum Consistency {
    @Generable
    struct Read {
        @Guide(description: "How different the user's tone is to the person versus about them, 0 (identical) to 100 (two-faced)", .range(0...100))
        var gap: Int
        @Guide(description: "One honest, kind sentence: is the user consistent with this person?")
        var verdict: String
        @Guide(description: "How the user treats them directly, one sentence")
        var toThem: String
        @Guide(description: "How the user talks about them to others, one sentence. Say so if there is too little to tell")
        var aboutThem: String
        @Guide(description: "What other people say about them in shared chats, one sentence, or that there is nothing notable")
        var othersAboutThem: String
        @Guide(description: "Up to four quotes that show the gap or the consistency, copied exactly", .maximumCount(4))
        var quotes: [Quote]
        @Guide(description: "One short, practical and kind suggestion")
        var advice: String

        @Generable
        struct Quote {
            @Guide(description: "The message, copied exactly")
            var text: String
            @Guide(description: "Where it was said, e.g. 'to Ana' or 'about Ana in Faculdade 2026'")
            var context: String
            @Guide(description: "True if it was said directly to the person")
            var direct: Bool
        }
    }

    @concurrent nonisolated static func toneOffMain(_ lines: [String]) async -> Double { tone(lines) }

    nonisolated static func tone(_ lines: [String]) -> Double {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        var scores: [Double] = []
        for text in lines where text.count > 6 {
            tagger.string = text
            if let tag = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore).0,
               let value = Double(tag.rawValue) { scores.append(value) }
        }
        return scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
    }

    static func check(_ chat: ChatSummary) async throws -> Card.Consistency {
        let me = AppSettings.shared.myName
        let store = MemoryStore.shared
        let direct = try await store.lines(source: chat.source, chatID: chat.chatID, limit: 200)
        let mine = direct.filter(\.isFromMe)

        // Their name as people actually write it: full, and the first name.
        let first = chat.name.split(separator: " ").first.map(String.init) ?? chat.name
        let names = Array(Set([chat.name, first])).filter { $0.count >= 3 }
        let mentions = try await store.mentions(of: names, outside: chat.chatID, limit: 120)
        let mineAbout = mentions.filter { $0.line.isFromMe }
        let othersAbout = mentions.filter { !$0.line.isFromMe && $0.line.sender.folded != chat.name.folded }

        let toneTo = await toneOffMain(mine.map(\.text))
        let toneAbout = await toneOffMain(mineAbout.map(\.line.text))

        let prompt = """
        Person: \(chat.name). The user is \(me).
        Measured tone (-1 negative … 1 positive): user to them \(String(format: "%.2f", toneTo)), \
        user about them elsewhere \(String(format: "%.2f", toneAbout)) over \(mineAbout.count) mentions.

        The user's messages TO \(chat.name) (direct chat):
        \(mine.suffix(40).map { "- \($0.text.prefix(220))" }.joined(separator: "\n"))

        The user's messages ABOUT \(chat.name) in other chats:
        \(mineAbout.prefix(40).map { "- [\($0.chatName)] \($0.line.text.prefix(220))" }.joined(separator: "\n"))

        What OTHER people said about \(chat.name) in chats the user is in:
        \(othersAbout.prefix(25).map { "- [\($0.chatName)] \($0.line.sender): \($0.line.text.prefix(200))" }.joined(separator: "\n"))
        """
        let read = try await ModelHub.generate(
            Read.self, prompt: prompt,
            instructions: """
            The user asked you, with consent, to check whether they treat someone the same to their face as \
            behind their back. Be honest and specific, never preachy. Banter and teasing between friends is \
            not two-faced; contempt, mockery or complaints said only behind someone's back are. If there is \
            too little evidence, say so and keep the gap low. Quote messages exactly. Write in \(Persona.languageName).
            """)

        let card = Card.Consistency(
            name: chat.name, gap: read.gap, verdict: read.verdict, toThem: read.toThem,
            aboutThem: read.aboutThem, othersAboutThem: read.othersAboutThem,
            quotes: read.quotes.map { .init(text: $0.text, context: $0.context, direct: $0.direct) },
            advice: read.advice, toneToThem: toneTo, toneAboutThem: toneAbout, mentionCount: mineAbout.count)
        if let data = try? JSONEncoder().encode(card), let json = String(data: data, encoding: .utf8) {
            try? await store.saveInsight(json, key: "consistency:\(chat.id)")
        }
        return card
    }

    static func cached(_ chat: ChatSummary) async -> Card.Consistency? {
        guard let (json, _) = try? await MemoryStore.shared.insight(key: "consistency:\(chat.id)") else { return nil }
        return try? JSONDecoder().decode(Card.Consistency.self, from: Data(json.utf8))
    }
}

nonisolated struct ConsistencyTool: Tool {
    let name = "face_to_face_check"
    let description = """
    Compare how the user talks TO a person with how they talk ABOUT that person in other chats, plus what others \
    say about them, and show the result as a card. Use for "am I two-faced with X?", "do I talk bad about X?", \
    "is X fake with me?".
    """

    @Generable
    struct Arguments {
        var person: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await CardBus.status(String(localized: "Comparing what you say to and about \(arguments.person)…"))
        guard let chat = try await MemoryStore.shared.findChats(named: arguments.person, limit: 1).first else {
            return "No chat found with \(arguments.person)."
        }
        do {
            let card = try await Consistency.check(chat)
            await CardBus.post(.consistency(card))
            return "Shown: gap \(card.gap)/100. \(card.verdict)"
        } catch {
            return "Could not finish the comparison (\(error.localizedDescription.prefix(160))). Try read_chat and search_memory to look at it directly."
        }
    }
}
