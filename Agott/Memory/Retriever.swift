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

        var isEmpty: Bool { hits.isEmpty && facts.isEmpty && connections.isEmpty && reflections.isEmpty }

        /// Rendered for a model to read. Dated and attributed, so it can say
        /// where something came from instead of asserting it.
        func rendered(characterBudget: Int = 9000) -> String {
            var parts: [String] = []
            if !reflections.isEmpty {
                parts.append("Conversations that mattered, as you remember them:\n" + reflections.map {
                    "- [\($0.chat) · \(MemoryStore.stamp($0.date.timeIntervalSince1970))] \($0.title): \($0.summary) (\($0.feeling))"
                }.joined(separator: "\n"))
            }
            if !facts.isEmpty {
                parts.append("Known facts:\n" + facts.map { "- \($0.sentence) (confidence \(Int($0.confidence * 100))%)" }.joined(separator: "\n"))
            }
            if !connections.isEmpty {
                parts.append("Graph connections:\n" + connections.map { "- \($0)" }.joined(separator: "\n"))
            }
            var budget = characterBudget - parts.joined().count
            var moments: [String] = []
            for hit in hits {
                let header = "### \(hit.chunk.source.displayName) · \(hit.chunk.chatName) · \(MemoryStore.stamp(hit.chunk.start.timeIntervalSince1970))"
                let body = String(hit.chunk.text.prefix(max(200, min(1600, budget))))
                budget -= header.count + body.count
                moments.append(header + "\n" + body)
                if budget < 200 { break }
            }
            if !moments.isEmpty { parts.append("Relevant moments from memory:\n" + moments.joined(separator: "\n\n")) }
            return parts.joined(separator: "\n\n")
        }
    }

    @concurrent func recall(_ query: String, filter: MemoryStore.Filter = .none, limit: Int = 8) async -> Recall {
        let keyword = (try? await store.keywordSearch(query, filter: filter, limit: 40)) ?? []

        var meaning: [Int64] = []
        if await embedder.isReady, let vector = try? await embedder.embed(query),
           let index = try? await store.vectorIndex()
        {
            meaning = index.nearest(to: vector, limit: 60).filter { $0.1 > 0.35 }.map(\.0)
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

        return Recall(hits: hits, anchors: anchors, connections: Array(connections.prefix(16)), facts: Array(facts.prefix(16)),
                      reflections: Array(reflections.prefix(5)))
    }
}
