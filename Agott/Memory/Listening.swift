import Foundation
import FoundationModels

/// Learning from what the user says to Agott, without being asked.
///
/// "Remember that…" should never be needed. When a message tells Agott
/// something lasting (who someone is, a nickname, that two people broke up,
/// what the user likes or plans), it is read once, after the reply, by the
/// learning model, and filed the same way as what is learned from old
/// conversations: with the user's own words as proof.
///
/// Most messages say nothing lasting ("abre o Spotify"). A cheap look at
/// the words, then Jev when there is a key, keeps those from costing a
/// request.
enum Listening {
    /// What it kept from one message, for the chat to show.
    struct Heard: Sendable, Equatable {
        var facts = 0
        var nicknames = 0
        var ties = 0

        var isEmpty: Bool { facts + nicknames + ties == 0 }
    }

    /// Words that make a message likely to say something about the user or
    /// their people. Folded, with spaces around, to match whole words.
    nonisolated static let signals: [String] = [
        " eu ", " meu ", " minha ", " meus ", " minhas ", " sou ", " estou ", " to ", " tava ", " moro ", " trabalho ",
        " estudo ", " gosto ", " odeio ", " amo ", " prefiro ", " namoro ", " terminei ", " comecei ", " quero ", " vou ",
        " mae ", " pai ", " irma ", " irmao ", " namorad", " ex ", " amig", " prim", " chefe ", " esposa ", " marido ",
        " apelido ", " se chama ", " chama de ", " chamo de ", " mesma pessoa ", " terminaram ", " terminou ", " ficando ",
        " i ", " my ", " i'm ", " im ", " mine ", " mom ", " dad ", " girlfriend ", " boyfriend ", " wife ", " husband ",
        " friend", " nickname ", " broke up ", " same person ", " lembra que ", " lembre que ", " remember that ",
        " aniversario ", " birthday ", " e o ", " e a ", " is my ", " e meu ", " e minha ",
    ]

    /// Whether a message could hold something worth keeping. Wide on
    /// purpose: it only decides whether to look closer.
    nonisolated static func mayHoldSomething(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16, trimmed.count <= 6000 else { return false }
        let folded = " " + trimmed.folded.replacingOccurrences(of: "\n", with: " ") + " "
        return signals.contains { folded.contains($0) }
    }

    /// Reads one message of the user's. Returns what it kept.
    @discardableResult
    static func hear(_ text: String, earlier: [String], at date: Date = .now) async -> Heard {
        let settings = AppSettings.shared
        let provider = ModelHub.learningProvider
        guard settings.autoLearn, !LaunchOptions.isDemo, mayHoldSomething(text), ModelHub.isAvailable(provider) else { return Heard() }
        let me = settings.myName
        let store = MemoryStore.shared

        if Jev.isConfigured {
            let answers = try? await Jev.ask(
                state: ["user": me, "message": text, "earlier": earlier],
                questions: ["lasting": .noul("""
                    Does `message`, written by the user to their assistant, state or take for granted something \
                    lasting about the user or about people they know that is worth remembering for later: who \
                    someone is, a nickname, a relationship or its end, a preference, a habit, a plan, a place, \
                    a date? A request, a question with nothing personal in it, or small talk is a no.
                    """)])
            if let odds = answers?["lasting"]?.probability, odds < 0.35 { return Heard() }
        }

        let before = (try? await store.heardMark()) ?? MemoryStore.HeardMark()
        // Only this message is proof; what came before is there to read it right.
        let chunk = MemoryChunk(id: 0, source: .note, chatID: "agott", chatName: "Agott", start: date, end: date,
                                text: "[\(MemoryStore.stamp(date.timeIntervalSince1970))] \(me): \(text)", participants: [me])
        let known = (try? await store.whoIsWho(for: [chunk], budget: 3000)) ?? ""
        let nicknames = ((try? await store.myNicknames()) ?? []).prefix(5).map(\.alias)
        var prompt = "The user is \(me)" + (nicknames.isEmpty ? "" : ", also called " + nicknames.joined(separator: ", ")) + ".\n\n"
        if !known.isEmpty { prompt += "Who is who, from what you already know. Use these names for the same people:\n\(known)\n\n" }
        if !earlier.isEmpty {
            prompt += "Earlier in this conversation, only so you read the message right. Take nothing from it:\n"
                + earlier.joined(separator: "\n") + "\n\n"
        }
        prompt += "### Moment 1 · what the user just told you\n\(chunk.text)"

        guard var extraction = try? await ModelHub.generate(
            KnowledgeGraph.Extraction.self, prompt: prompt,
            instructions: """
            You are the user's personal assistant, keeping a private memory of them and of the people in their \
            life. The user just wrote you the message in Moment 1. Keep only what it tells you that will still \
            matter in a month: facts about the user (work, tastes, plans, places, dates), facts about people \
            they name, nicknames ("o Garicas é o Bruno": Garicas is a nickname of Bruno), and relationships, \
            the user's own included (the user is "me"): "minha mãe, a Maria" makes Maria the parent of me; \
            "minha namorada Ana" makes Ana the partner of me. What a question takes for granted counts ("o que \
            eu dou pra minha namorada Ana?"). When they say something is over ("terminei com a Ana", "o João \
            e a Bia terminaram"), report that relationship with ended true. \
            A request to do something, a question with nothing personal in it, and small talk give nothing: \
            return empty lists. Never record secrets (passwords, keys, card or ID numbers). \
            Every item needs proof: the exact words of the message, copied. The user saying something about \
            themselves is self-stated and high confidence; a guess is low. Mark sensitive facts (sexuality, \
            gender, health, religion, politics) and never guess them. Write each predicate in \
            \(Persona.languageName), as a short verb phrase.
            """,
            provider: provider,
            modelName: provider == .openCode ? ModelHub.learningModel : nil)
        else { return Heard() }

        // A first name several people share means the closest one, or
        // whoever the conversation was about.
        let mentioned = (try? await store.peopleMentioned(in: text)) ?? []
        func named(_ name: String) -> String {
            mentioned.first { $0.alias == name.folded }?.ref.name ?? name
        }
        for index in extraction.facts.indices { extraction.facts[index].subject = named(extraction.facts[index].subject) }
        for index in extraction.nicknames.indices { extraction.nicknames[index].person = named(extraction.nicknames[index].person) }
        for index in extraction.relations.indices {
            extraction.relations[index].person = named(extraction.relations[index].person)
            extraction.relations[index].other = named(extraction.relations[index].other)
        }
        try? await KnowledgeGraph.absorb(extraction, pack: [chunk], me: me, spoken: true)

        let after = (try? await store.heardMark()) ?? before
        let heard = Heard(facts: max(0, after.facts - before.facts), nicknames: max(0, after.nicknames - before.nicknames),
                          ties: max(0, after.ties - before.ties))
        if !heard.isEmpty {
            await PeopleDirectory.shared.refresh()
            await PeopleBrief.refresh()
        }
        return heard
    }
}

extension MemoryStore {
    /// How much is known, to tell what one message added.
    nonisolated struct HeardMark: Sendable {
        var facts = 0
        var nicknames = 0
        var ties = 0
    }

    func heardMark() throws -> HeardMark {
        let db = try open()
        return HeardMark(
            facts: try db.scalarInt("SELECT COUNT(*) FROM facts"),
            nicknames: try db.scalarInt("SELECT COALESCE(SUM(count), 0) FROM person_aliases WHERE kind IN ('nickname', 'heard')"),
            ties: try db.scalarInt("SELECT COALESCE(SUM(count), 0) + COUNT(ended_ts) FROM person_links"))
    }
}
