import Foundation

/// Hybrid retrieval: words, meaning and the graph each nominate moments, and
/// reciprocal rank fusion decides.
///
/// Each signal fails differently. Keywords miss paraphrase ("the trip" vs
/// "a viagem pra Floripa"); vectors miss exact names and rare words; the graph
/// knows that a question about Ana is a question about the chat with Ana even
/// when nothing in the question matches what was said there. Fusing ranks
/// rather than scores means none of them has to be calibrated against the
/// others.
nonisolated struct Retriever: Sendable {
    var store: MemoryStore = .shared
    var embedder: Embedder = .shared

    /// The context block for one question.
    struct Recall: Sendable {
        var hits: [MemoryHit]
        var anchors: [GraphEntity]
        var connections: [String]
        var facts: [MemoryFact]
        /// Deep conversations remembered as a whole.
        var reflections: [Reflection] = []
        /// Names in the question that point at more than one chat.
        var whoIsWho: [String] = []
        /// What is known about each person in the question, with odds and proof.
        var profiles: [(name: String, facts: [MemoryFact])] = []
        /// Everyone the question and the moments involve, by id, each with
        /// one line saying who they are. The model writes their tags.
        var people: [(ref: PersonRef, line: String)] = []

        /// Tags by folded name, to label where moments happened.
        var tags: [String: PersonRef] {
            Dictionary(people.map { ($0.ref.name.folded, $0.ref) }, uniquingKeysWith: { first, _ in first })
        }

        var isEmpty: Bool { hits.isEmpty && facts.isEmpty && connections.isEmpty && reflections.isEmpty }

        /// Rendered for a model to read. Dated and attributed, so it can say
        /// where something came from instead of asserting it.
        func rendered(characterBudget: Int = 9000) -> String {
            var parts: [String] = []
            if !people.isEmpty {
                parts.append("""
                People and groups, by tag. When you mention one, write its tag exactly (for example \
                \(people[0].ref.tag)) and not the name; the app shows the name. A group is never a person:
                """ + "\n" + people.map { "- \($0.line)" }.joined(separator: "\n"))
            }
            if !whoIsWho.isEmpty {
                parts.append("""
                Who's who. These names point at more than one chat; keep them apart. A group named after \
                someone is not that person, and what was said in a group was said in front of everyone in it:
                """ + "\n" + whoIsWho.map { "- \($0)" }.joined(separator: "\n"))
            }
            for profile in profiles where !profile.facts.isEmpty {
                parts.append("""
                What you know about \(profile.name), with odds and proof. Say how sure you are; an inferred \
                or low-odds fact is a maybe, never a certainty:
                """ + "\n" + profile.facts.map { "- \($0.withProof)" }.joined(separator: "\n"))
            }
            if !reflections.isEmpty {
                parts.append("Conversations that mattered, as you remember them:\n" + reflections.map {
                    "- [\($0.chat) · \(MemoryStore.stamp($0.date.timeIntervalSince1970))] \($0.title): \($0.summary) (\($0.feeling))"
                }.joined(separator: "\n"))
            }
            if !facts.isEmpty {
                parts.append("Known facts:\n" + facts.map { "- \($0.withProof)" }.joined(separator: "\n"))
            }
            if !connections.isEmpty {
                parts.append("Graph connections:\n" + connections.map { "- \($0)" }.joined(separator: "\n"))
            }
            var budget = characterBudget - parts.joined().count
            var moments: [String] = []
            for hit in hits {
                let header = "### \(hit.chunk.source.displayName) · \(Self.place(hit.chunk, tags: tags)) · \(MemoryStore.stamp(hit.chunk.start.timeIntervalSince1970))"
                let body = String(hit.chunk.text.prefix(max(200, min(1600, budget))))
                budget -= header.count + body.count
                moments.append(header + "\n" + body)
                if budget < 200 { break }
            }
            if !moments.isEmpty { parts.append("Relevant moments from memory:\n" + moments.joined(separator: "\n\n")) }
            return parts.joined(separator: "\n\n")
        }

        /// Where a moment happened, said so it cannot be mistaken: a group by
        /// its name and people, a direct chat by the person.
        static func place(_ chunk: MemoryChunk, tags: [String: PersonRef] = [:]) -> String {
            func named(_ name: String) -> String {
                tags[name.folded].map { "\($0.tag) \(name)" } ?? name
            }
            switch chunk.isGroup {
            case true?:
                let people = chunk.participants.prefix(8).map(named).joined(separator: ", ")
                return "group chat \(named("\"\(chunk.chatName)\""))".replacingOccurrences(of: "\"\"", with: "\"")
                    + (people.isEmpty ? "" : " (with \(people))")
            case false?:
                return "direct chat with \(named(chunk.chatName))"
            case nil:
                return chunk.chatName
            }
        }

        /// One line saying who someone is, for the people table.
        static func line(for ref: PersonRef, direct: [ChatSummary], others: [PersonRef]) -> String {
            switch ref.kind {
            case .person:
                var line = "\(ref.tag) \(ref.name): a person"
                if !direct.isEmpty {
                    line += "; direct chat on " + direct.map { "\($0.source.displayName) (\($0.messageCount) messages)" }.joined(separator: " and ")
                }
                if !others.isEmpty { line += "; writes in the groups " + others.map { "\($0.tag) \"\($0.name)\"" }.joined(separator: ", ") }
                return line
            case .group:
                var line = "\(ref.tag) \"\(ref.name)\": a group chat, not a person"
                if !others.isEmpty { line += "; members include " + others.map { "\($0.tag) \($0.name)" }.joined(separator: ", ") }
                return line
            }
        }

        /// One line per name that is ambiguous: each chat it may mean.
        static func whoIsWho(name: String, chats: [ChatSummary]) -> String? {
            guard chats.count > 1 else { return nil }
            let options = chats.prefix(5).map { chat in
                chat.isGroup
                    ? "the group \"\(chat.name)\" on \(chat.source.displayName) (\(chat.messageCount) messages)"
                    : "\(chat.name), a direct chat on \(chat.source.displayName) (\(chat.messageCount) messages)"
            }
            return "\"\(name)\" may mean " + options.joined(separator: "; or ")
        }
    }

    @concurrent func recall(_ query: String, filter: MemoryStore.Filter = .none, limit: Int = 8) async -> Recall {
        let keyword = (try? await store.keywordSearch(query, filter: filter, limit: 40)) ?? []

        var meaning: [Int64] = []
        if await embedder.isReady, let vector = try? await embedder.embed(query),
           let index = try? await store.vectorIndex()
        {
            meaning = index.nearest(to: vector, limit: 60).filter { $0.1 > 0.35 }.map(\.0)
            // Asked about a person or a period: meaning alone may not cross it.
            meaning = (try? await store.chunkIDs(meaning, matching: filter)) ?? meaning
        }

        // Graph: anchor the question on entities it names, then pull the
        // recent moments from the chats those entities live in.
        let anchors = (try? await store.entitiesMentioned(in: query)) ?? []
        var graphIDs: [Int64] = []
        var connections: [String] = []
        for anchor in anchors.prefix(3) {
            var anchorFilter = filter
            anchorFilter.chatName = anchor.name
            graphIDs += (try? await store.recentChunkIDs(filter: anchorFilter, limit: 6)) ?? []
            let neighbors = (try? await store.neighbors(of: anchor.id, limit: 8)) ?? []
            for (other, edge) in neighbors {
                let forward = edge.source == anchor.id
                let line = forward
                    ? "\(anchor.name) —\(edge.relation)→ \(other.name) (×\(Int(edge.weight)))"
                    : "\(other.name) —\(edge.relation)→ \(anchor.name) (×\(Int(edge.weight)))"
                connections.append(line)
            }
        }

        var fused: [Int64: (Double, Set<MemoryHit.Signal>)] = [:]
        func vote(_ ids: [Int64], _ signal: MemoryHit.Signal, weight: Double) {
            for (rank, id) in ids.enumerated() {
                let score = weight / Double(60 + rank)
                var entry = fused[id] ?? (0, [])
                entry.0 += score
                entry.1.insert(signal)
                fused[id] = entry
            }
        }
        vote(keyword, .keyword, weight: 1.0)
        vote(meaning, .meaning, weight: 0.9)
        vote(graphIDs, .graph, weight: 0.7)

        let ranked = fused.sorted { $0.value.0 > $1.value.0 }.prefix(limit)
        let chunks = (try? await store.chunks(ids: ranked.map(\.key))) ?? []
        let byID = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, $0) })
        let hits = ranked.compactMap { id, value in
            byID[id].map { MemoryHit(chunk: $0, score: value.0, matchedBy: value.1) }
        }

        var facts = (try? await store.facts(matching: nil, limit: 0)) ?? []
        for anchor in anchors.prefix(3) {
            facts += (try? await store.facts(matching: anchor.name, limit: 8)) ?? []
        }
        for term in query.split(separator: " ").map(String.init).filter({ $0.count > 4 }).prefix(4) {
            facts += (try? await store.facts(matching: term, limit: 4)) ?? []
        }
        var seen = Set<Int64>()
        facts = facts.filter { seen.insert($0.id).inserted }

        // Deep moments: by the words of the question, and by the people in it.
        var reflections = (try? await store.searchReflections(query, limit: 4)) ?? []
        for anchor in anchors.prefix(2) {
            reflections += (try? await store.searchReflections(anchor.name, limit: 2)) ?? []
        }
        var seenReflections = Set<Int64>()
        reflections = reflections.filter { seenReflections.insert($0.id).inserted }

        // Who everyone is, by id: the people the question names first, then
        // the people and groups of the moments found.
        var refs: [PersonRef] = []
        func add(_ found: [PersonRef]) {
            for ref in found where !refs.contains(ref) { refs.append(ref) }
        }
        var names: [String] = filter.chatName.map { [$0] } ?? []
        names += anchors.filter { $0.kind == .person || $0.kind == .group }.prefix(4).map(\.name)
        var whoIsWho: [String] = []
        var askedAbout = Set<String>()
        for name in names where askedAbout.insert(name.folded).inserted {
            let found = (try? await store.resolvePeople(name)) ?? []
            add(Array(found.prefix(3)))
            // The name as a word in other chats' names: groups named after someone.
            let first = name.wordList.first ?? name.folded
            let lookalikes = ((try? await store.resolvePeople(first)) ?? []) + ((try? await store.groupsNamed(containing: first)) ?? [])
            var options = found
            for ref in lookalikes where !options.contains(ref) { options.append(ref) }
            if options.count > 1 {
                add(Array(options.prefix(4)))
                whoIsWho.append("\"\(name)\" may mean " + options.prefix(4).map {
                    $0.kind == .group ? "\($0.tag) (the group \"\($0.name)\")" : "\($0.tag) (\($0.name), a person)"
                }.joined(separator: " or "))
            }
        }
        for hit in hits {
            if let chat = try? await store.resolvePeople(hit.chunk.chatName).first(where: {
                $0.name.folded == hit.chunk.chatName.folded && $0.kind == (hit.chunk.isGroup == true ? .group : .person)
            }) { add([chat]) }
            for participant in hit.chunk.participants.prefix(8) {
                if let ref = try? await store.resolvePeople(participant).first(where: { $0.name.folded == participant.folded }) {
                    add([ref])
                }
            }
        }
        var people: [(ref: PersonRef, line: String)] = []
        for ref in refs.prefix(18) {
            let links = (try? await store.connections(of: ref, limit: 6)) ?? (direct: [], others: [])
            var line = Recall.line(for: ref, direct: links.direct, others: links.others)
            // Who they are to other people, learned with proof.
            if ref.kind == .person, let ties = try? await store.links(of: ref.id, limit: 5), !ties.isEmpty {
                line += "; " + ties.map(\.line).joined(separator: "; ")
            }
            people.append((ref, line))
        }

        // A profile for each person the question is about, by id.
        var profiles: [(name: String, facts: [MemoryFact])] = []
        for ref in refs.prefix(4) where ref.kind == .person && names.contains(where: { ref.name.folded.contains($0.wordList.first ?? "~") }) {
            let known = (try? await store.profile(of: ref, limit: 25)) ?? []
            if !known.isEmpty { profiles.append(("\(ref.tag) \(ref.name)", known)) }
        }
        let inProfiles = Set(profiles.flatMap { $0.facts.map(\.id) })
        facts = facts.filter { !inProfiles.contains($0.id) }

        return Recall(hits: hits, anchors: anchors, connections: Array(connections.prefix(16)), facts: Array(facts.prefix(16)),
                      reflections: Array(reflections.prefix(5)), whoIsWho: whoIsWho, profiles: profiles, people: people)
    }
}
