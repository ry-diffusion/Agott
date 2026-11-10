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
            @Guide(description: "The reply exactly as it would be sent, in plain words: names written out, never a <e id=…/> tag")
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
        do {
            let card = try await RelationshipAnalyzer.read(chat, stats: stats)
            await CardBus.post(.person(card))
            return "Shown: closeness \(card.closeness)/100, \(card.vibe). \(card.summary)"
        } catch {
            // Answer from the numbers instead of failing the whole reply.
            return "Could not write the full read (\(error.localizedDescription.prefix(160))). Measured facts instead: "
                + RelationshipAnalyzer.statsLine(stats) + ". Read recent messages with read_chat if needed."
        }
    }
}

nonisolated struct ArtifactTool: Tool {
    let name = "artifact"
    let description = """
    Make or revise something the user asked to keep as a document: a file, a long draft, a study guide, \
    code, a small interactive web page. It opens in a panel beside the chat. To revise one, call again with \
    the same title and the full new content; it becomes the next version. Prefer answering in the chat: \
    only use this when the user asks for a document or the content is longer than a page and meant to be saved. \
    Write people and groups as their tags (<e id=12/>) here too, never their names: Agott shows the names, \
    or hides them. \(ArtifactStyle.guidance)
    """

    @Generable
    struct Arguments {
        @Guide(description: "A short title; reuse the exact title to revise an existing artifact")
        var title: String
        @Guide(description: "document (Markdown), code, html (one self-contained page with inline CSS and JS), or table (a Markdown table)")
        var kind: Kind
        @Guide(description: "For code: the language, e.g. swift, python")
        var language: String?
        @Guide(description: "The complete content")
        var content: String

        @Generable
        enum Kind { case document, code, html, table }
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        let kind = Card.Artifact.Kind(rawValue: "\(arguments.kind)") ?? .document
        // Who it names, kept with it: the names then travel with the artifact.
        let content = arguments.content
        let people = await MainActor.run {
            ArtifactNames.mentions(in: content) { PeopleDirectory.shared.name($0) }
        }
        await CardBus.post(.artifact(.init(
            key: arguments.title.folded, title: arguments.title, kind: kind,
            language: arguments.language, content: arguments.content, people: people.isEmpty ? nil : people)))
        return "The artifact \"\(arguments.title)\" is open beside the chat. Say in one sentence what it is; do not repeat its content."
    }
}

nonisolated struct ChartTool: Tool {
    let name = "show_chart"
    let description = """
    Show a chart in the conversation when numbers are easier to see than to read: trends over time (line or \
    area), comparisons (bar, horizontal bar, stacked bar), shares of a whole (pie or donut), or how two \
    measures relate (scatter, with numeric labels). Use real numbers from memory, tools or the user.
    """

    @Generable
    struct Arguments {
        var title: String
        @Guide(description: "Optional short note under the title, e.g. the period or source")
        var subtitle: String?
        var kind: Kind
        @Guide(description: "The x-axis labels or categories, in order. For scatter, numbers as text.", .maximumCount(60))
        var labels: [String]
        @Guide(description: "One or more series; each has one value per label", .maximumCount(6))
        var series: [Series]
        @Guide(description: "Unit of the values, e.g. msgs, R$, h, %")
        var unit: String?

        @Generable
        struct Series {
            var name: String
            var values: [Double]
        }

        @Generable
        enum Kind { case bar, horizontalBar, stackedBar, line, area, pie, donut, scatter }
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        let kind = Card.ChartData.Kind(rawValue: "\(arguments.kind)") ?? .bar
        let count = arguments.labels.count
        // Every series must line up with the labels.
        let series = arguments.series.map { item in
            Card.ChartData.Series(name: item.name, values: Array((item.values + Array(repeating: 0, count: max(0, count - item.values.count))).prefix(count)))
        }
        guard count > 0, !series.isEmpty else { return "A chart needs labels and at least one series of values." }
        await CardBus.post(.chart(.init(title: arguments.title, subtitle: arguments.subtitle, kind: kind,
                                        labels: arguments.labels, series: series, unit: arguments.unit)))
        return "The chart is on screen. Say in a sentence or two what stands out; do not list the numbers again."
    }
}
