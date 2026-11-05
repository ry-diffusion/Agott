import Foundation
import FoundationModels
import NaturalLanguage

/// Builds the graph of your life from what you have said.
///
/// Three passes, cheapest first, so the graph is useful long before it is
/// complete:
///
/// 1. **Structure** (free, instant): every chat gives edges. You ↔ each person
///    you talk to (weighted by how much), people → the groups they are in,
///    people in the same group → each other. This alone answers "who matters"
///    and "who knows whom".
/// 2. **Names** (on-device NLP, fast): `NLTagger` finds people, places and
///    organisations mentioned in each moment, and links whoever mentioned them.
///    That is how "Floripa" ends up connected to the three friends planning the
///    trip.
/// 3. **Facts** (on-device model, slow, opt-in): Foundation Models reads your
///    Claude history and your own messages and extracts statements about you:
///    what you build, what you like, who matters, what you are aiming at. Each
///    becomes a fact with a confidence, and a typed edge from you.
enum KnowledgeGraph {
    // MARK: Pass 1 + 2

    /// Structural and name edges for moments not yet in the graph.
    @concurrent nonisolated static func link(batch: Int = 400, store: MemoryStore = .shared) async throws -> Int {
        let chunks = try await store.chunksNeedingGraph(limit: batch)
        guard !chunks.isEmpty else { return 0 }
        let me = AppSettings.myNameSnapshot
        let tagger = NLTagger(tagSchemes: [.nameType])

        // Tagging is pure computation; do it before taking the store.
        let mentions: [Int64: [(EntityKind, String)]] = Dictionary(uniqueKeysWithValues: chunks.map { chunk in
            (chunk.id, names(in: chunk, tagger: tagger))
        })

        try await store.graphBatch { store in
            let meID = try store.upsertEntity(kind: .me, name: me, at: .now, mentions: 0)
            for chunk in chunks {
                let others = chunk.participants.filter { $0 != me && $0 != "Claude" }
                let isGroup = chunk.participants.count > 2 || (others.count > 1)
                let lineCount = Double(chunk.text.split(separator: "\n").count)
                var participantIDs: [String: Int64] = [:]

                if chunk.source == .claude {
                    // A Claude session is a project you were working on.
                    let project = projectName(chunk.chatName.components(separatedBy: " — ").first ?? chunk.chatName)
                    let projectID = try store.upsertEntity(kind: .project, name: project, at: chunk.end)
                    try store.addEdge(meID, projectID, relation: "works on", weight: 1, at: chunk.end)
                    for (kind, name) in mentions[chunk.id] ?? [] {
                        let id = try store.upsertEntity(kind: kind, name: name, at: chunk.end)
                        try store.addEdge(projectID, id, relation: "involves", weight: 1, at: chunk.end)
                    }
                    continue
                }

                for person in others {
                    let id = try store.upsertEntity(kind: .person, name: person, at: chunk.end)
                    participantIDs[person] = id
                }

                if isGroup {
                    let groupID = try store.upsertEntity(kind: .group, name: chunk.chatName, at: chunk.end)
                    try store.addEdge(meID, groupID, relation: "member of", weight: lineCount / 10, at: chunk.end)
                    for (_, id) in participantIDs {
                        try store.addEdge(id, groupID, relation: "member of", weight: 0.5, at: chunk.end)
                    }
                    // Co-presence: people who talk in the same moment know each other.
                    let ids = Array(participantIDs.values).sorted()
                    for i in ids.indices {
                        for j in ids.indices where j > i {
                            try store.addEdge(ids[i], ids[j], relation: "knows", weight: 0.2, at: chunk.end)
                        }
                    }
                } else if let (_, id) = participantIDs.first {
                    try store.addEdge(meID, id, relation: "talks with", weight: lineCount, at: chunk.end)
                }

                for (kind, name) in mentions[chunk.id] ?? [] {
                    // A mention of someone already in the chat is just a vocative.
                    guard participantIDs[name] == nil, name.folded != me.folded else { continue }
                    let id = try store.upsertEntity(kind: kind, name: name, at: chunk.end)
                    let anchor = isGroup
                        ? try store.upsertEntity(kind: .group, name: chunk.chatName, at: chunk.end)
                        : (participantIDs.values.first ?? meID)
                    try store.addEdge(anchor, id, relation: "mentions", weight: 1, at: chunk.end)
                }
            }
            try store.markGraphed(chunks.map(\.id))
        }
        return chunks.count
    }

    nonisolated private static func names(in chunk: MemoryChunk, tagger: NLTagger) -> [(EntityKind, String)] {
        // Strip "[date] Sender:" so senders are not counted as mentions.
        let body = chunk.text.split(separator: "\n").map { line -> Substring in
            guard let colon = line.range(of: ": ") else { return line }
            return line[colon.upperBound...]
        }.joined(separator: "\n")
        tagger.string = body
        var found: [String: EntityKind] = [:]
        tagger.enumerateTags(
            in: body.startIndex..<body.endIndex, unit: .word, scheme: .nameType,
            options: [.omitPunctuation, .omitWhitespace, .joinNames]
        ) { tag, range in
            let name = String(body[range]).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            guard isPlausibleName(name) else { return true }
            switch tag {
            case .personalName: found[name] = .person
            case .placeName: found[name] = .place
            case .organizationName: found[name] = .organization
            default: break
            }
            return true
        }
        return found.map { ($0.value, $0.key) }
    }

    /// Words the name tagger mistakes for names in chat Portuguese and
    /// English: interjections, pronouns, sentence starters, acronyms.
    nonisolated static let notNames: Set<String> = [
        "mano", "isso", "aham", "pra", "pro", "nada", "nao", "sim", "tipo", "cara", "oi", "ola", "bom", "boa",
        "entao", "mas", "porque", "quando", "onde", "aqui", "ali", "hoje", "amanha", "ontem", "gente", "galera",
        "mds", "kkk", "kkkk", "vlw", "obg", "blz", "beleza", "serio", "nossa", "caraca", "poxa", "vixe", "eita",
        "opa", "uai", "to", "ta", "vou", "vai", "que", "qual", "quem", "como", "essa", "esse", "aquele", "aquilo",
        "meu", "minha", "seu", "sua", "nosso", "top", "show", "legal", "massa", "claro", "verdade", "certo",
        "exato", "haha", "rs", "bora", "partiu", "fala", "salve", "eae", "tudo", "obrigado", "obrigada", "valeu",
        "amor", "vida", "deus", "pai", "mae", "filho", "filha", "irmao", "irma", "senhor", "senhora", "dona",
        "the", "this", "that", "yes", "okay", "hey", "hello", "thanks", "sorry", "well", "what", "why", "how",
        "when", "where", "who", "lol", "omg", "wow", "yeah", "nope", "claude", "agott", "user", "assistant",
        "api", "usb", "gpu", "cpu", "url", "json", "http", "https", "html", "css", "sql", "pdf", "app",
    ]

    nonisolated static func isPlausibleName(_ name: String) -> Bool {
        guard name.count >= 3, name.count <= 40, name.first?.isUppercase == true else { return false }
        let folded = name.folded
        if notNames.contains(folded) { return false }
        // Short all-caps words are shouting or acronyms, not names.
        if name.count <= 4, name == name.uppercased() { return false }
        if name.contains(where: { $0.isNumber }) { return false }
        let words = folded.split(separator: " ")
        if words.allSatisfy({ notNames.contains(String($0)) }) { return false }
        return true
    }

    /// "git/personal/Licor/wt/slot/cl/h3" → "Licor"; worktrees and generic
    /// folders fold into the project they belong to.
    nonisolated static func projectName(_ path: String) -> String {
        var trimmed = path
        for marker in ["/wt/", "/.claude/", "//claude/", "/claude/worktrees", "/worktrees/"] {
            if let range = trimmed.range(of: marker) { trimmed = String(trimmed[..<range.lowerBound]) }
        }
        let generic: Set<String> = ["git", "app", "apps", "src", "ios", "macos", "android", "web", "server", "client",
                                    "k8s", "personal", "xcode", "midas", "projects", "code", "dev", "repos", "users"]
        let parts = trimmed.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        if let meaningful = parts.reversed().first(where: { !generic.contains($0.lowercased()) }) {
            return meaningful
        }
        return parts.last ?? path
    }

    /// Facts that must never be kept: anything that reads like a credential.
    nonisolated static func isSensitive(_ fact: String) -> Bool {
        let folded = fact.folded
        let markers = ["token", "password", "senha", "secret", "api key", "apikey", "chave de api", "credential",
                       "private key", "ssh key", "2fa", "otp", "pin code", "cvv", "cartao", "credit card", ".env",
                       "keychain", "login:", "account:"]
        return markers.contains { folded.contains($0) }
    }

    /// Two statements say the same thing when their words mostly overlap.
    nonisolated static func sameMeaning(_ a: String, _ b: String) -> Bool {
        let filler: Set<String> = ["for", "to", "the", "and", "with", "of", "in", "on", "a", "an", "his", "her",
                                   "de", "da", "do", "para", "com", "em", "e", "o", "os", "as", "um", "uma"]
        func words(_ text: String) -> Set<String> {
            Set(text.folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                .filter { $0.count >= 2 && !filler.contains($0) })
        }
        let wa = words(a), wb = words(b)
        guard !wa.isEmpty, !wb.isEmpty else { return a.folded == b.folded }
        let shared = Double(wa.intersection(wb).count)
        // Same words mostly, or one statement is the other plus a little.
        return shared / Double(wa.union(wb).count) >= 0.6 || shared / Double(min(wa.count, wb.count)) >= 0.75
    }

    // MARK: Pass 3

    @Generable
    struct Extraction {
        @Guide(description: "Lasting facts about the user found in the moments. Empty if there are none.", .maximumCount(400))
        var facts: [Fact]

        @Generable
        struct Fact {
            @Guide(description: "The number of the moment the fact comes from, as given in its header")
            var moment: Int
            @Guide(description: "\"me\" for the user, otherwise the person's name")
            var subject: String
            @Guide(description: "Short relation in English, e.g. works on, uses, likes, lives in, is learning, wants to, is friends with")
            var predicate: String
            @Guide(description: "The value, short, in its original language")
            var object: String
            @Guide(description: "What kind of thing the value is")
            var kind: Kind
            @Guide(description: "How sure, from 0.0 to 1.0", .range(0.0...1.0))
            var confidence: Double
        }

        @Generable
        enum Kind { case person, place, organization, project, topic, preference, skill, goal, thing }
    }

    /// How much of a model's context one learning request may fill.
    ///
    /// Batching is the difference between learning being practical or not.
    /// One moment per request spends most of every call on instructions and
    /// schema, and pays latency per moment; DeepSeek has room for hundreds of
    /// moments at once. So moments are packed until they fill a share of the
    /// window (half, by default), leaving the rest for instructions and for
    /// the facts coming back. The on-device model has a small window, so its
    /// packs stay small.
    struct Budget {
        var contextTokens: Int
        var fill: Double

        /// Characters per token, roughly, for Portuguese and English chat.
        static let charactersPerToken = 3.3

        var characters: Int { Int(Double(contextTokens) * fill * Self.charactersPerToken) }

        static func current(for provider: ModelProvider) -> Budget {
            let settings = AppSettings.shared
            switch provider {
            case .openCode:
                // The analysis model's own window, when the catalogue knows it.
                let id = ModelHub.learningModel ?? settings.modelName
                let window = ModelCatalog.shared.model(id)?.context ?? settings.contextTokens
                return Budget(contextTokens: min(window, settings.contextTokens), fill: settings.batchFill)
            case .privateCloud: return Budget(contextTokens: 32_000, fill: 0.5)
            case .onDevice: return Budget(contextTokens: 4_096, fill: 0.45)
            }
        }
    }

    /// Reads moments written by you and extracts facts, as many per request as
    /// the budget allows. Returns how many moments it read; call repeatedly to
    /// go further back.
    static func learn(maxMoments: Int = 400, onProgress: (Int) -> Void = { _ in }) async throws -> Int {
        let store = MemoryStore.shared
        let me = AppSettings.shared.myName
        let provider = ModelHub.learningProvider
        let budget = Budget.current(for: provider)
        // Fetch generously; packing decides how many actually go in.
        let candidates = try await store.chunksForLearning(limit: maxMoments)
        guard !candidates.isEmpty else { return 0 }

        var done = 0
        var queue = candidates[...]
        while !queue.isEmpty {
            try Task.checkCancellation()
            var pack: [MemoryChunk] = []
            var used = 0
            while let next = queue.first {
                let text = String(next.text.prefix(4000))
                if !pack.isEmpty && used + text.count > budget.characters { break }
                pack.append(next)
                used += text.count + 120
                queue = queue.dropFirst()
            }

            let moments = pack.enumerated().map { index, chunk in
                "### Moment \(index + 1) · \(chunk.source.displayName) · \"\(chunk.chatName)\" · \(MemoryStore.stamp(chunk.start.timeIntervalSince1970))\n\(chunk.text.prefix(4000))"
            }.joined(separator: "\n\n")

            let extraction: Extraction
            do {
                extraction = try await ModelHub.generate(
                    Extraction.self,
                    prompt: "The user is \(me). Lines from \(me) are the user speaking.\n\n\(moments)",
                    instructions: """
                    You build a private memory of one person, the user, from their own messages, which they \
                    shared with you on purpose. You get several numbered moments. Extract only lasting facts: \
                    what they work on, tools and skills, preferences, plans and goals, places, and the people \
                    important to them and how (family, friends, partners, colleagues, and what they share). \
                    Ignore small talk, one-off logistics, and anything that will not matter in a month. \
                    Never record secrets: passwords, tokens, API keys, where credentials are stored, account \
                    logins, card or ID numbers. Skip operating instructions the user gives to AI coding tools \
                    (timeouts, disk space, which commands to run); keep what they say about the person. \
                    Do not state the obvious (their own name). Cite the moment number of each fact. Merge \
                    duplicates across moments.
                    """,
                    provider: provider,
                    modelName: provider == .openCode ? ModelHub.learningModel : nil)
            } catch {
                // A refusal or a malformed pack: skip it rather than stall forever.
                try await store.markLearned(pack.map(\.id))
                done += pack.count
                onProgress(done)
                continue
            }

            for fact in extraction.facts where fact.confidence >= 0.5 && !fact.object.isEmpty {
                let chunk = pack.indices.contains(fact.moment - 1) ? pack[fact.moment - 1] : pack[0]
                let subject = ["me", "eu", "user", "o usuário"].contains(fact.subject.lowercased()) ? me : fact.subject
                let sentence = "\(subject) \(fact.predicate) \(fact.object)"
                guard !isSensitive(sentence), fact.object.folded != subject.folded else { continue }
                // Already known in other words: only strengthen it.
                let known = (try? await store.facts(about: subject, limit: 200)) ?? []
                if let twin = known.first(where: { $0.predicate.folded == fact.predicate.folded && sameMeaning($0.object, fact.object) }) {
                    try await store.addFact(subject: twin.subject, predicate: twin.predicate, object: twin.object,
                                            confidence: fact.confidence, source: chunk.source, chunkID: chunk.id, at: chunk.end)
                    continue
                }
                try await store.addFact(
                    subject: subject, predicate: fact.predicate, object: fact.object,
                    confidence: fact.confidence, source: chunk.source, chunkID: chunk.id, at: chunk.end)
                await link(subject: subject, predicate: fact.predicate, object: fact.object,
                           kind: entityKind(fact.kind), at: chunk.end)
            }
            try await store.markLearned(pack.map(\.id))
            done += pack.count
            onProgress(done)
        }
        return done
    }

    nonisolated static func link(subject: String, predicate: String, object: String, kind: EntityKind, at date: Date) async {
        let store = MemoryStore.shared
        let me = AppSettings.myNameSnapshot
        do {
            try await store.graphBatch { store in
                let subjectID = subject == me
                    ? try store.upsertEntity(kind: .me, name: me, at: date, mentions: 0)
                    : try store.upsertEntity(kind: .person, name: subject, at: date)
                let objectID = try store.upsertEntity(kind: kind, name: object, at: date)
                try store.addEdge(subjectID, objectID, relation: predicate, weight: 2, at: date)
            }
        } catch {}
    }

    private static func entityKind(_ kind: Extraction.Kind) -> EntityKind {
        switch kind {
        case .person: .person
        case .place: .place
        case .organization: .organization
        case .project: .project
        case .topic, .skill, .goal, .preference: .topic
        case .thing: .thing
        }
    }

    // MARK: About me

    @Generable
    struct Portrait {
        @Guide(description: "A portrait of the user in 6 to 10 short sentences, second person (\"You…\")")
        var portrait: String
    }

    /// Writes the "about you" paragraph every conversation starts from.
    static func writePortrait() async throws -> String {
        let me = AppSettings.shared.myName
        let facts = try await MemoryStore.shared.facts(about: me, limit: 80)
        let people = try await MemoryStore.shared.neighbors(of: meID(), limit: 20)
        let prompt = """
        Facts about \(me):
        \(facts.map { "- \($0.predicate) \($0.object)" }.joined(separator: "\n"))

        Strongest connections:
        \(people.map { "- \($0.1.relation) \($0.0.name) (\($0.0.kind.rawValue))" }.joined(separator: "\n"))
        """
        let portrait = try await ModelHub.generate(
            Portrait.self, prompt: prompt,
            instructions: """
            Write a grounded portrait of the user for their personal assistant to keep in mind: work, \
            interests, important people, current goals, how they like to communicate. Only what the facts \
            support. Write in \(Persona.languageName).
            """)
        return portrait.portrait
    }

    nonisolated static func meID() async throws -> Int64 {
        try await MemoryStore.shared.upsertEntity(kind: .me, name: AppSettings.myNameSnapshot, at: .now, mentions: 0)
    }
}

extension MemoryStore {
    /// Moments worth learning from: Claude sessions first (they are about
    /// you), then direct chats where you wrote a fair share.
    func chunksForLearning(limit: Int) throws -> [MemoryChunk] {
        let me = AppSettings.myNameSnapshot
        let ids = try learningCandidateIDs(me: me, limit: limit)
        return try chunks(ids: ids)
    }
}
