import Foundation
import FoundationModels

/// Tools whose only job is to put UI on screen.

nonisolated struct ExplainTool: Tool {
    let name = "show_explanation"
    let description = """
    Show an explanation card: what a word, expression, slang, joke, meme or message means, with examples of how \
    people use it. Use it when the user does not understand something.
    """

    @Generable
    struct Arguments {
        @Guide(description: "The thing being explained, as it appeared")
        var term: String
        @Guide(description: "What it means, plainly, in two or three sentences")
        var meaning: String
        @Guide(description: "Realistic examples of it in use", .count(2...4))
        var examples: [Example]
        @Guide(description: "Optional tip on how to use or answer it")
        var tip: String?

        @Generable
        struct Example {
            @Guide(description: "An example message using it")
            var text: String
            @Guide(description: "What it means in that example")
            var note: String
        }
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await CardBus.post(.explanation(.init(
            term: arguments.term, meaning: arguments.meaning,
            examples: arguments.examples.map { .init(text: $0.text, note: $0.note) },
            tip: arguments.tip)))
        return "The explanation card is on screen. Add at most one short sentence; do not repeat the card."
    }
}

nonisolated struct SuggestRepliesTool: Tool {
    let name = "suggest_replies"
    let description = """
    Show reply options the user can insert into the chat with one click. Write them in the user's own voice and \
    language, matching how they write to this person.
    """

    @Generable
    struct Arguments {
        @Guide(description: "One sentence on what the other person wants or feels")
        var context: String
        @Guide(description: "Different replies", .count(2...4))
        var options: [Option]

        @Generable
        struct Option {
            @Guide(description: "The reply exactly as it would be sent")
            var text: String
            @Guide(description: "Tone in one or two words")
            var tone: String
            @Guide(description: "Why it works, briefly")
            var why: String
        }
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await CardBus.post(.replies(.init(
            context: arguments.context,
            options: arguments.options.map { .init(text: $0.text, tone: $0.tone, why: $0.why) })))
        return "The reply options are on screen. Do not repeat them."
    }
}

nonisolated struct ChecklistTool: Tool {
    let name = "show_checklist"
    let description = "Show a checklist card: steps, a plan, things to bring, things to do."

    @Generable
    struct Arguments {
        var title: String
        @Guide(description: "Items, short", .maximumCount(12))
        var items: [String]
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await CardBus.post(.checklist(.init(title: arguments.title, items: arguments.items)))
        return "The checklist is on screen."
    }
}

nonisolated struct RelationshipReadTool: Tool {
    let name = "show_relationship"
    let description = """
    Read the user's whole relationship with a person from their chats and show it as a card: closeness, vibe, \
    summary, open loops, suggestions. Use it for questions like \"how are things with X?\".
    """

    @Generable
    struct Arguments {
        var person: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await CardBus.status(String(localized: "Reading your story with \(arguments.person)…"))
        guard let chat = try await MemoryStore.shared.findChats(named: arguments.person, limit: 1).first else {
            return "No chat found with \(arguments.person)."
        }
        let stats = await RelationshipAnalyzer.stats(for: chat)
        let card = try await RelationshipAnalyzer.read(chat, stats: stats)
        await CardBus.post(.person(card))
        return "Shown: closeness \(card.closeness)/100, \(card.vibe). \(card.summary)"
    }
}
