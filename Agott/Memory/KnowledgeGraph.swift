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
                let others = chunk.participants.filter { $0 != me && $0 != "Claude" && $0 != MemoryStore.unknownSender }
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
                        try store.addEdge(projectID, id, relation: GraphRelation.involves.rawValue, weight: 1, at: chunk.end)
                    }
                    continue
                }

                for person in others {
                    let id = try store.upsertEntity(kind: .person, name: person, at: chunk.end)
                    participantIDs[person] = id
                }

                if isGroup {
                    let groupID = try store.upsertEntity(kind: .group, name: chunk.chatName, at: chunk.end)
                    try store.addEdge(meID, groupID, relation: GraphRelation.memberOf.rawValue, weight: lineCount / 10, at: chunk.end)
                    for (_, id) in participantIDs {
                        try store.addEdge(id, groupID, relation: GraphRelation.memberOf.rawValue, weight: 0.5, at: chunk.end)
                    }
                    // Co-presence: people who talk in the same moment know each other.
                    let ids = Array(participantIDs.values).sorted()
                    for i in ids.indices {
                        for j in ids.indices where j > i {
                            try store.addEdge(ids[i], ids[j], relation: GraphRelation.knows.rawValue, weight: 0.2, at: chunk.end)
                        }
                    }
                } else if let (_, id) = participantIDs.first {
                    try store.addEdge(meID, id, relation: GraphRelation.talksWith.rawValue, weight: lineCount, at: chunk.end)
                }

                for (kind, name) in mentions[chunk.id] ?? [] {
                    // A mention of someone already in the chat is just a vocative.
                    guard participantIDs[name] == nil, name.folded != me.folded else { continue }
                    let id = try store.upsertEntity(kind: kind, name: name, at: chunk.end)
                    let anchor = isGroup
                        ? try store.upsertEntity(kind: .group, name: chunk.chatName, at: chunk.end)
                        : (participantIDs.values.first ?? meID)
                    try store.addEdge(anchor, id, relation: GraphRelation.mentions.rawValue, weight: 1, at: chunk.end)
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

    /// How a model refers to the user.
    nonisolated static func isUser(_ name: String, me: String, alsoCalled: Set<String> = []) -> Bool {
        let folded = name.folded
        return ["me", "eu", "user", "o usuario", "usuario", "the user"].contains(folded) || folded == me.folded
            || alsoCalled.contains(folded)
    }

    /// Nicknames and links between people, each checked against its moment.
    /// `spoken` is for what the user told Agott directly: theirs to say, so
    /// a nickname needs no second sighting.
    static func learnPeople(_ extraction: Extraction, pack: [MemoryChunk], me: String, spoken: Bool = false) async {
        let store = MemoryStore.shared
        let mine = Set(((try? await store.myNicknames()) ?? []).map(\.folded))
        func person(_ name: String, in chunk: MemoryChunk) -> String {
            isUser(name, me: me, alsoCalled: mine) ? me : canonicalName(name, in: chunk)
        }
        for nickname in extraction.nicknames {
            let chunk = pack.indices.contains(nickname.moment - 1) ? pack[nickname.moment - 1] : pack[0]
            let who = person(nickname.person, in: chunk)
            if spoken {
                let proof = chunk.text.folded.contains(nickname.evidence.folded) ? String(nickname.evidence.prefix(120)) : nil
                if who == me {
                    _ = try? await store.learnNickname(nickname.nickname, forID: MemoryStore.me, name: me, evidence: proof, trusted: true)
                } else if let id = try? await store.ensurePerson(who), let ref = try? await store.person(id: id) {
                    _ = try? await store.learnNickname(nickname.nickname, forID: id, name: ref.name, evidence: proof, trusted: true)
                }
            } else {
                _ = try? await store.learnNickname(nickname.nickname, claimed: who, evidence: nickname.evidence, in: chunk, me: me)
            }
        }
        for relation in extraction.relations {
            let chunk = pack.indices.contains(relation.moment - 1) ? pack[relation.moment - 1] : pack[0]
            let a = person(relation.person, in: chunk), b = person(relation.other, in: chunk)
            guard a.folded != b.folded,
                  let kept = vetted(confidence: relation.confidence, evidence: relation.evidence, in: chunk.text,
                                    selfStated: false, sensitive: false),
                  let kind = MemoryStore.LinkKind(rawValue: "\(relation.kind)") else { continue }
            // The user is a side of their own ties: their mother, their ex.
            let first = a == me ? MemoryStore.me : try? await store.ensurePerson(a)
            let second = b == me ? MemoryStore.me : try? await store.ensurePerson(b)
            guard let first, let second else { continue }
            try? await store.link(first, second, kind: kind, detail: relation.detail.isEmpty ? nil : relation.detail,
                                  confidence: kept.confidence, evidence: kept.evidence, chunkID: chunk.id > 0 ? chunk.id : nil,
                                  at: chunk.end, ended: relation.ended)
            // And in the graph you can see.
            if !relation.ended {
                await link(subject: a, predicate: kind.phrase.replacingOccurrences(of: "is ", with: ""), object: b,
                           kind: .person, at: chunk.end)
            }
        }
    }

    /// Files what a model read in some moments: facts with their proof,
    /// then nicknames and ties. Shared by reading old conversations and by
    /// listening to what the user says to Agott.
    static func absorb(_ extraction: Extraction, pack: [MemoryChunk], me: String, spoken: Bool = false) async throws {
        let store = MemoryStore.shared
        let mine = Set(((try? await store.myNicknames()) ?? []).map(\.folded))
        for fact in extraction.facts where !fact.object.isEmpty {
            let chunk = pack.indices.contains(fact.moment - 1) ? pack[fact.moment - 1] : pack[0]
            let isMe = isUser(fact.subject, me: me, alsoCalled: mine)
            let subject = isMe ? me : canonicalName(fact.subject, in: chunk)
            let sentence = "\(subject) \(fact.predicate) \(fact.object)"
            guard !isSensitive(sentence), fact.object.folded != subject.folded,
                  isMe || !PersonName.isDescriptor(subject) else { continue }
            // The fact belongs to a person by id when the name is unambiguous.
            let candidates = isMe ? [] : ((try? await store.resolvePeople(subject)) ?? []).filter { $0.kind == .person }
            let subjectID = candidates.count == 1 ? candidates[0].id : candidates.first { $0.name.folded == subject.folded }?.id
            guard let kept = Self.vetted(confidence: fact.confidence, evidence: fact.evidence, in: chunk.text,
                                         selfStated: fact.selfStated, sensitive: fact.sensitive) else { continue }
            let factKind = FactKind(rawValue: fact.about) ?? FactKind.guess(fact.predicate)
            let chunkID: Int64? = chunk.id > 0 ? chunk.id : nil
            // Already known in other words: only strengthen it. Only this
            // person's facts count ("Ana" is not "Mariana"), and the same
            // kind with the same meaning is the same fact.
            let known = ((try? await store.facts(about: subject, limit: 200)) ?? []).filter { other in
                other.subject.folded == subject.folded || (subjectID != nil && other.subjectID == subjectID)
            }
            if let twin = known.first(where: { other in
                let sameKind = factKind != .other && other.kind == factKind
                return (sameKind || other.predicate.folded == fact.predicate.folded) && sameMeaning(other.object, fact.object)
            }) {
                try await store.addFact(subject: twin.subject, predicate: twin.predicate, object: twin.object,
                                        confidence: kept.confidence, source: chunk.source, chunkID: chunkID, at: chunk.end,
                                        evidence: kept.evidence, selfStated: fact.selfStated, sensitive: fact.sensitive,
                                        subjectID: subjectID, kind: twin.kind ?? factKind)
                continue
            }
            try await store.addFact(
                subject: subject, predicate: fact.predicate, object: fact.object,
                confidence: kept.confidence, source: chunk.source, chunkID: chunkID, at: chunk.end,
                evidence: kept.evidence, selfStated: fact.selfStated, sensitive: fact.sensitive,
                subjectID: subjectID, kind: factKind)
            // Where someone lives, how old they are, whether they are
            // single: the newer answer replaces the older one.
            if factKind.singleValued, kept.confidence >= 0.6 {
                try? await store.supersede(subject: subject, subjectID: subjectID, kind: factKind, object: fact.object, at: chunk.end)
            }
            await link(subject: subject, predicate: fact.predicate, object: fact.object,
                       kind: entityKind(fact.kind), at: chunk.end)
        }
        await learnPeople(extraction, pack: pack, me: me, spoken: spoken)
    }

    /// Checks a fact against its proof. The quote has to really be in the
    /// moment; without it a fact is kept at lower odds, and a sensitive one
    /// is dropped. A sensitive fact nobody stated about themselves is a
    /// guess, and its odds are capped so it reads as one.
    nonisolated static func vetted(confidence: Double, evidence: String, in text: String,
                                   selfStated: Bool, sensitive: Bool) -> (confidence: Double, evidence: String?)? {
        let quote = evidence.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”'")))
        let found = quote.count >= 4 && text.folded.contains(quote.folded)
        var odds = MemoryStore.odds(confidence)
        if !found {
            if sensitive { return nil }
            odds *= 0.7
        }
        if sensitive && !selfStated { odds = min(odds, 0.5) }
        guard odds >= 0.35 else { return nil }
        return (odds, found ? String(quote.prefix(160)) : nil)
    }

    /// The subject as the moment writes the person: "Ale" in a chat where
    /// "Alexsander Lima" speaks is Alexsander Lima.
    nonisolated static func canonicalName(_ name: String, in chunk: MemoryChunk) -> String {
        let words = name.wordList
        guard let first = words.first else { return name }
        var people = chunk.participants + (chunk.isGroup == false ? [chunk.chatName] : [])
        // The user is "me", never a match for someone else's first name.
        let me = AppSettings.myNameSnapshot.folded
        if name.folded != me { people.removeAll { $0.folded == me } }
        // Written out in full: that person.
        if let same = people.first(where: { $0.folded == name.folded }) { return same }
        // Only when exactly one person fits; two Anas stay "Ana" rather than
        // landing on whichever wrote first.
        let containing = Set(people.filter { Set(words).isSubset(of: Set($0.wordList)) })
        if containing.count == 1, let only = containing.first { return only }
        if containing.count > 1 { return name }
        let prefixed = Set(people.filter { ($0.wordList.first ?? "").hasPrefix(first) && first.count >= 3 })
        if prefixed.count == 1, let only = prefixed.first { return only }
        return name
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
        @Guide(description: "Lasting facts about the user and the people in the moments. Empty if there are none.", .maximumCount(400))
        var facts: [Fact]

        @Guide(description: "Nicknames people are called by in the moments. Empty if there are none.", .maximumCount(60))
        var nicknames: [Nickname]

        @Guide(description: "Relationships between two people, the user's own included (the user is \"me\"), seen in the moments. Empty if there are none.", .maximumCount(80))
        var relations: [Relation]

        @Generable
        struct Nickname {
            @Guide(description: "The number of the moment it comes from")
            var moment: Int
            @Guide(description: "The person who is called by it: the one spoken to or about, never the one writing the line (unless they say it is their own nickname). Their name exactly as it appears as a sender in the moment, or \"me\" for the user")
            var person: String
            @Guide(description: "The nickname used for them, as written (\"Ale\", \"Lili\"). Not generic words like mano, amor, bb, amiga, galera, and not their own first name")
            var nickname: String
            @Guide(description: "The exact words from the moment where the nickname is used for them, at most 120 characters")
            var evidence: String
        }

        @Generable
        struct Relation {
            @Guide(description: "The number of the moment it comes from")
            var moment: Int
            @Guide(description: "One person, by name as written, or \"me\" for the user")
            var person: String
            @Guide(description: "How the first person relates to the second")
            var kind: LinkKindChoice
            @Guide(description: "The other person, by name as written, or \"me\" for the user")
            var other: String
            @Guide(description: "How the moment says it, short, in its own language (\"namorado\", \"prima\", \"ex dela\")")
            var detail: String
            @Guide(description: "The exact words from the moment that show it, at most 160 characters")
            var evidence: String
            @Guide(description: "How sure, from 0.0 to 1.0. A joke or a rumour is low", .range(0.0...1.0))
            var confidence: Double
            @Guide(description: "true only when the moment says the link is over: they broke up, stopped being friends, moved out, left the job. false while it holds")
            var ended: Bool
        }

        @Generable
        enum LinkKindChoice { case partner, ex, crush, family, sibling, parent, friend, bestFriend, classmate, coworker, roommate, conflict }

        @Generable
        struct Fact {
            @Guide(description: "The number of the moment the fact comes from, as given in its header")
            var moment: Int
            @Guide(description: "\"me\" for the user, otherwise the person's name exactly as it appears as a sender in the moment")
            var subject: String
            @Guide(description: "Short relation, as a verb phrase in the language the instructions name, e.g. trabalha em, usa, gosta de, mora em, está aprendendo, quer, é amigo de")
            var predicate: String
            @Guide(description: "The value, short, in its original language")
            var object: String
            @Guide(description: "What kind of thing the value is")
            var kind: Kind
            @Guide(description: "What the fact is about, one of: likes, dislikes, works, studies, livesIn, isFrom, plays, watches, listensTo, reads, owns, uses, wants, plans, learning, goodAt, birthday, age, feels, believes, said, relationship (single, dating, married, with no partner named), other")
            var about: String
            @Guide(description: "How sure, from 0.0 to 1.0", .range(0.0...1.0))
            var confidence: Double
            @Guide(description: "The proof: the exact words from the moment that show it, copied verbatim, at most 160 characters")
            var evidence: String
            @Guide(description: "true only when the subject said it about themselves in those words")
            var selfStated: Bool
            @Guide(description: "true for sexuality, gender identity, health, mental health, religion, politics, ethnicity, or legal trouble")
            var sensitive: Bool
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
        var skippedInARow = 0
        var queue = candidates[...]
        while !queue.isEmpty {
            try Task.checkCancellation()
            var pack: [MemoryChunk] = []
            var used = 0
            // Most of the room for the moments, some for who is who.
            let room = Int(Double(budget.characters) * 0.85)
            while let next = queue.first {
                let text = String(next.text.prefix(4000))
                if !pack.isEmpty && used + text.count > room { break }
                pack.append(next)
                used += text.count + 120
                queue = queue.dropFirst()
            }

            let moments = pack.enumerated().map { index, chunk in
                "### Moment \(index + 1) · \(chunk.source.displayName) · \(Retriever.Recall.place(chunk)) · \(MemoryStore.stamp(chunk.start.timeIntervalSince1970))\n\(chunk.text.prefix(4000))"
            }.joined(separator: "\n\n")

            // Cross-reference: what is already known about these people.
            let known = (try? await store.whoIsWho(for: pack, budget: budget.characters - used)) ?? ""
            let context = known.isEmpty ? "" : """
                Who is who in these moments, from what you already know. Use these names for the same people, \
                connect what you read to them, and do not repeat what is already known unless the moments add \
                proof or change it:
                \(known)


                """

            let nicknames = ((try? await store.myNicknames()) ?? []).prefix(5).map(\.alias)
            let called = nicknames.isEmpty ? "" : ", also called " + nicknames.joined(separator: ", ")
            let extraction: Extraction
            do {
                extraction = try await ModelHub.generate(
                    Extraction.self,
                    prompt: "The user is \(me)\(called). Lines from \(me) are the user speaking.\n\n\(context)\(moments)",
                    instructions: """
                    You build a private memory of one person, the user, from their own messages, which they \
                    shared with you on purpose. You get several numbered moments. Extract only lasting facts: \
                    what they work on, tools and skills, preferences, plans and goals, places, and the people \
                    important to them and how (family, friends, partners, colleagues, and what they share). \
                    Also learn about the other people in the moments, each under their own name as it appears \
                    as a sender: where they study or work, who they are close to, what they like, what happened \
                    in their life, and how they describe themselves. Keep people apart: a group named after \
                    someone is not that person, and what one person says about another is not self-stated. \
                    Also list the nicknames people are called by (each with the words where it is used). A \
                    nickname belongs to whoever is being called, not to whoever wrote the line: when Yasmin \
                    writes "Zé, me liga" in her chat with the user, Zé is the user. \
                    And the relationships between people, the user's own included (the user is "me"): who \
                    dates whom, exes, crushes, family (say which: mother, cousin), best friends, classmates, \
                    coworkers, who is fighting with whom. A relationship needs two named people; "Gustavo's \
                    boyfriend" with no name for him is not one, but "Gustavo is dating" is a fact about \
                    Gustavo (about: relationship). Relationships change: when a moment shows one is over \
                    (they broke up, fell out, moved out), report it with ended true rather than leaving it out. \
                    Every fact needs proof: copy the exact words from the moment that show it. Rate confidence \
                    honestly: a joke, sarcasm or a rumour is low; something someone says plainly about \
                    themselves is high. Mark sensitive facts (sexuality, gender, health, religion, politics) \
                    and never guess them from stereotypes. \
                    Ignore small talk, one-off logistics, and anything that will not matter in a month. \
                    Never record secrets: passwords, tokens, API keys, where credentials are stored, account \
                    logins, card or ID numbers. Skip operating instructions the user gives to AI coding tools \
                    (timeouts, disk space, which commands to run); keep what they say about the person. \
                    Do not state the obvious (their own name). Cite the moment number of each fact. Merge \
                    duplicates across moments. Write each predicate in \(Persona.languageName), as a short verb \
                    phrase; keep the proof in its original words.
                    """,
                    provider: provider,
                    modelName: provider == .openCode ? ModelHub.learningModel : nil)
            } catch {
                // Offline, blocked or out of credit: stop and keep these
                // moments unread, so they are learned once the model is back.
                if ModelHub.isConnectionProblem(error) { throw error }
                // A wrong model, no credit, a bad endpoint: every pack would
                // fail the same way. Stop with all of them still unread.
                if ModelHub.isConfigurationProblem(error) { throw error }
                // Several packs in a row failing is the setup, not the packs.
                skippedInARow += 1
                if skippedInARow >= 3 { throw error }
                // A refusal or a malformed pack: skip it rather than stall forever.
                try await store.markLearned(pack.map(\.id))
                done += pack.count
                onProgress(done)
                continue
            }

            skippedInARow = 0
            try await absorb(extraction, pack: pack, me: me)
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
