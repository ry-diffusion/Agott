import Foundation
import FoundationModels

/// A deep conversation, condensed: what happened, how it felt, what was
/// decided, what it says about the people in it.
nonisolated struct Reflection: Sendable, Hashable, Identifiable {
    var id: Int64
    var source: MemorySource
    var chat: String
    var title: String
    var summary: String
    var people: [String]
    var feeling: String
    var depth: Double
    var date: Date
}

/// Turns the conversations that mattered into memories with substance.
///
/// Facts ("Ana likes surf") are thin; what you remember about a friend is the
/// night you talked about your father, the fight and the making up. So a
/// second pass looks at long, two-sided moments: Jev scores how deep each is
/// (one request for a dozen), and only the deep ones go to the learning model,
/// which condenses each into a few sentences. Small talk never costs a call.
enum Reflections {
    /// Moments per Jev request.
    static let jevBatch = 12
    /// From "a real conversation" up (0…3 scale).
    static let deepEnough = 1.7

    @Generable
    struct Condensed {
        @Guide(description: "One memory per deep moment given", .maximumCount(20))
        var memories: [Memory]

        @Generable
        struct Memory {
            @Guide(description: "The number of the moment, as given in its header")
            var moment: Int
            @Guide(description: "A short title, like a diary entry heading")
            var title: String
            @Guide(description: "Three to six sentences: what happened, what each person felt or needed, anything decided or promised, and what it shows about them and their relationship. Concrete, in the past tense.")
            var summary: String
            @Guide(description: "The people involved, by name", .maximumCount(6))
            var people: [String]
            @Guide(description: "The emotional tone in two to four words")
            var feeling: String
        }
    }

    /// Reflects on up to `limit` unread moments, newest first. Returns how
    /// many moments it looked at.
    static func run(limit: Int = 120, onProgress: (Int) -> Void = { _ in }) async throws -> Int {
        let store = MemoryStore.shared
        let candidates = try await store.chunksForReflection(limit: limit)
        guard !candidates.isEmpty else { return 0 }
        var done = 0
        for start in stride(from: 0, to: candidates.count, by: jevBatch) {
            try Task.checkCancellation()
            let batch = Array(candidates[start..<min(start + jevBatch, candidates.count)])
            let depths = await depth(of: batch)
            let deep = zip(batch, depths).filter { $0.1 >= deepEnough }
            if !deep.isEmpty {
                try await condense(deep.map(\.0), depths: deep.map(\.1))
            }
            try await store.markReflected(zip(batch.map(\.id), depths).map { ($0, $1) })
            done += batch.count
            onProgress(done)
        }
        return done
    }

    /// How deep each moment goes, 0…3. Jev when there is a key; otherwise a
    /// rough guess from length and back-and-forth.
    static func depth(of chunks: [MemoryChunk]) async -> [Double] {
        if Jev.isConfigured {
            let me = AppSettings.myNameSnapshot
            let moments = chunks.map { ["chat": $0.chatName, "text": String($0.text.prefix(2500))] }
            var questions: [String: Jev.Question] = [:]
            for index in chunks.indices {
                questions["depth_\(index)"] = .score(
                    "How deep and meaningful is the conversation in `moments[\(index)]` for the user (\(me)) and the people in it?",
                    [
                        "Small talk, logistics, links or jokes.",
                        "Some personal sharing, but light.",
                        "A real conversation: feelings, plans, opinions, advice or support.",
                        "A defining conversation: vulnerability, conflict, a big decision or a turning point in a relationship.",
                    ])
            }
            if let answers = try? await Jev.ask(state: ["user": me, "moments": moments], questions: questions) {
                return chunks.indices.map { answers["depth_\($0)"]?.score ?? 0 }
            }
        }
        return chunks.map(heuristicDepth)
    }

    nonisolated static func heuristicDepth(_ chunk: MemoryChunk) -> Double {
        let lines = chunk.text.split(separator: "\n")
        let speakers = Set(lines.compactMap { $0.split(separator: ":", maxSplits: 1).first.map(String.init) })
        guard speakers.count >= 2 else { return 0 }
        let long = lines.filter { $0.count > 80 }.count
        return min(3, Double(chunk.text.count) / 2500 + Double(long) / 8)
    }

    private static func condense(_ chunks: [MemoryChunk], depths: [Double]) async throws {
        let me = AppSettings.myNameSnapshot
        let moments = chunks.enumerated().map { index, chunk in
            "### Moment \(index + 1) · \(chunk.source.displayName) · \"\(chunk.chatName)\" · \(MemoryStore.stamp(chunk.start.timeIntervalSince1970))\n\(chunk.text.prefix(5000))"
        }.joined(separator: "\n\n")
        let provider = ModelHub.learningProvider
        guard let condensed = try? await ModelHub.generate(
            Condensed.self,
            prompt: "The user is \(me). Lines from \(me) are the user speaking.\n\n\(moments)",
            instructions: """
            You keep the user's private diary of conversations that mattered, from messages they shared with \
            you on purpose. For each numbered moment, write one memory the way a close friend would remember \
            it: what happened, what each person felt or needed, what was decided or promised, and what it says \
            about them. Be specific and kind; only say what the messages support. Never include passwords, \
            numbers or addresses. Write in \(Persona.languageName).
            """,
            provider: provider,
            modelName: provider == .openCode ? ModelHub.learningModel : nil)
        else { return }
        for memory in condensed.memories where !memory.summary.isEmpty {
            let index = memory.moment - 1
            guard chunks.indices.contains(index), !KnowledgeGraph.isSensitive(memory.summary) else { continue }
            let chunk = chunks[index]
            try await MemoryStore.shared.addReflection(
                chunkID: chunk.id, source: chunk.source, chat: chunk.chatName, title: memory.title,
                summary: memory.summary, people: memory.people, feeling: memory.feeling,
                depth: depths[index], date: chunk.end)
        }
    }
}

extension MemoryStore {
    /// Long, two-sided message moments not yet reflected on, newest first.
    func chunksForReflection(limit: Int) throws -> [MemoryChunk] {
        var ids: [Int64] = []
        try openForRepair().rows(
            """
            SELECT c.id FROM chunks c LEFT JOIN reflected r ON r.chunk_id = c.id
            WHERE r.chunk_id IS NULL AND c.source IN ('whatsapp', 'imessage') AND length(c.text) >= 1200
            ORDER BY c.end_ts DESC LIMIT ?
            """, [.of(limit)]
        ) { ids.append(Int64($0.int(0))) }
        return try chunks(ids: ids)
    }

    func markReflected(_ items: [(Int64, Double)]) throws {
        let db = try openForRepair()
        for (id, depth) in items {
            try db.run("INSERT OR REPLACE INTO reflected(chunk_id, depth) VALUES (?, ?)", [.of(Int(id)), .double(depth)])
        }
    }

    func addReflection(chunkID: Int64, source: MemorySource, chat: String, title: String, summary: String,
                       people: [String], feeling: String, depth: Double, date: Date) throws {
        try openForRepair().run(
            """
            INSERT OR IGNORE INTO reflections(chunk_id, source, chat, title, summary, people, feeling, depth, ts)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [.of(Int(chunkID)), .text(source.rawValue), .text(chat), .text(title), .text(summary),
             .text(people.joined(separator: ", ")), .text(feeling), .double(depth), .double(date.timeIntervalSince1970)])
    }

    /// The newest reflections.
    func reflections(limit: Int) throws -> [Reflection] {
        var result: [Reflection] = []
        try openForRepair().rows(
            "SELECT id, source, chat, title, summary, people, feeling, depth, ts FROM reflections ORDER BY ts DESC LIMIT ?",
            [.of(limit)]) { result.append(Self.reflection($0)) }
        return result
    }

    /// Reflections matching the words of a question, best first.
    func searchReflections(_ query: String, limit: Int) throws -> [Reflection] {
        let terms = query
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !Self.stopwords.contains($0) }
        guard !terms.isEmpty else { return [] }
        let match = terms.prefix(12).map { "\"\($0)\"*" }.joined(separator: " OR ")
        var result: [Reflection] = []
        try openForRepair().rows(
            """
            SELECT r.id, r.source, r.chat, r.title, r.summary, r.people, r.feeling, r.depth, r.ts
            FROM reflections_fts f JOIN reflections r ON r.id = f.rowid
            WHERE reflections_fts MATCH ? ORDER BY bm25(reflections_fts) LIMIT ?
            """, [.text(match), .of(limit)]) { result.append(Self.reflection($0)) }
        return result
    }

    private static func reflection(_ row: SQLiteDB.Statement) -> Reflection {
        Reflection(
            id: Int64(row.int(0)), source: MemorySource(rawValue: row.text(1) ?? "") ?? .note,
            chat: row.text(2) ?? "", title: row.text(3) ?? "", summary: row.text(4) ?? "",
            people: (row.text(5) ?? "").components(separatedBy: ", ").filter { !$0.isEmpty },
            feeling: row.text(6) ?? "", depth: row.double(7), date: Date(timeIntervalSince1970: row.double(8)))
    }
}
