import Foundation
import Observation

/// One-time fixes for memory that earlier versions wrote less well.
///
/// Version 3 names the WhatsApp people that version 2 could not: group
/// members whose contact name WhatsApp stores as an empty string, and
/// everyone a reset re-read after version 2 had already run. Besides
/// messages and moments it fixes chats, facts, people (merging "+2240…"
/// into the person of the same name) and reflections, then redraws the graph.
///
/// Version 2 repairs three things, without re-reading any source:
/// - WhatsApp people known only by a private id (`+141377874698479`) get the
///   display name WhatsApp itself shows, in messages and moments alike.
/// - The graph is rebuilt from the moments with the stricter name rules and
///   clean project names. It is derived data, so nothing is lost.
/// - Facts that read like secrets or say nothing are dropped, and facts that
///   say the same thing twice are merged.
@Observable
final class MemoryRepair {
    static let shared = MemoryRepair()
    static let version = 3

    private(set) var isRunning = false
    private(set) var note: String?

    private init() {}

    var isNeeded: Bool { UserDefaults.standard.integer(forKey: "memoryRepairVersion") < Self.version }

    func runIfNeeded() async {
        guard isNeeded, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let store = MemoryStore.shared

        #if os(macOS)
        note = String(localized: "Fixing the names of your WhatsApp contacts…")
        let names = await Task.detached(priority: .utility) { WhatsAppSource.profileNames() }.value
        if !names.isEmpty {
            try? await store.renameMessageSenders(names, source: .whatsapp)
            let ids = (try? await store.chunkIDsWithNumberSenders(source: .whatsapp)) ?? []
            for start in stride(from: 0, to: ids.count, by: 300) {
                let batch = ContinuousClock.now
                try? await store.renameSenders(names, inChunks: Array(ids[start..<min(start + 300, ids.count)]))
                await Pace.rest(after: batch)
            }
            try? await store.renameChats(names, source: .whatsapp)
            try? await store.renameInFacts(names)
            try? await store.renamePeople(names)
            try? await store.renameInReflections(names)
            await PeopleDirectory.shared.refresh()
        }
        #endif

        note = String(localized: "Tidying up what I learned about you…")
        try? await store.fixPercentOdds()
        try? await store.cleanFacts(me: AppSettings.myNameSnapshot)

        note = String(localized: "Redrawing your graph…")
        try? await store.resetGraph()
        for fact in (try? await store.facts(limit: 5000)) ?? [] {
            await KnowledgeGraph.link(subject: fact.subject, predicate: fact.predicate, object: fact.object,
                                      kind: .topic, at: fact.date)
        }
        while true {
            let batch = ContinuousClock.now
            guard (try? await KnowledgeGraph.link()) ?? 0 > 0 else { break }
            await Pace.rest(after: batch)
        }

        UserDefaults.standard.set(Self.version, forKey: "memoryRepairVersion")
        note = nil
        await Indexer.shared.refreshTotals()
    }
}

extension MemoryStore {
    /// Chats known only by an id get their name, in chats, messages and moments.
    func renameChats(_ names: [String: String], source: MemorySource) throws {
        let db = try openForRepair()
        var olds: [String] = []
        try db.rows("SELECT name FROM chats WHERE source = ? AND name LIKE '+%'", [.text(source.rawValue)]) { row in
            if let name = row.text(0) { olds.append(name) }
        }
        try db.transaction {
            for old in olds {
                guard let new = names[old] else { continue }
                try db.run("UPDATE chats SET name = ? WHERE source = ? AND name = ?", [.text(new), .text(source.rawValue), .text(old)])
                try db.run("UPDATE messages SET chat_name = ? WHERE source = ? AND chat_name = ?", [.text(new), .text(source.rawValue), .text(old)])
                var chunks: [(Int64, String)] = []
                try db.rows("SELECT id, text FROM chunks WHERE source = ? AND chat_name = ?", [.text(source.rawValue), .text(old)]) { row in
                    chunks.append((Int64(row.int(0)), row.text(1) ?? ""))
                }
                for (id, text) in chunks {
                    try db.run("INSERT INTO chunks_fts(chunks_fts, rowid, text, chat_name) VALUES ('delete', ?, ?, ?)",
                               [.int(id), .text(text), .text(old)])
                    try db.run("UPDATE chunks SET chat_name = ? WHERE id = ?", [.text(new), .int(id)])
                    try db.run("INSERT INTO chunks_fts(rowid, text, chat_name) VALUES (?, ?, ?)", [.int(id), .text(text), .text(new)])
                }
            }
        }
    }

    /// Facts about (or naming) someone known only by an id. Two that become
    /// the same fact keep the first.
    func renameInFacts(_ names: [String: String]) throws {
        let db = try openForRepair()
        var olds = Set<String>()
        try db.rows("SELECT subject FROM facts WHERE subject LIKE '+%' UNION SELECT object FROM facts WHERE object LIKE '+%'") { row in
            if let name = row.text(0) { olds.insert(name) }
        }
        try db.transaction {
            for old in olds {
                guard let new = names[old] else { continue }
                try db.run("UPDATE OR IGNORE facts SET subject = ? WHERE subject = ?", [.text(new), .text(old)])
                try db.run("DELETE FROM facts WHERE subject = ?", [.text(old)])
                try db.run("UPDATE OR IGNORE facts SET object = ? WHERE object = ?", [.text(new), .text(old)])
                try db.run("DELETE FROM facts WHERE object = ?", [.text(old)])
            }
        }
    }

    /// People known only by an id get their name, or, when someone of that
    /// name is already there (from their own chat), become that person:
    /// aliases, chats, links and facts move over.
    func renamePeople(_ names: [String: String]) throws {
        let db = try openForRepair()
        var people: [(Int64, String)] = []
        try db.rows("SELECT id, name FROM people WHERE kind = 'person' AND name LIKE '+%'") { row in
            people.append((Int64(row.int(0)), row.text(1) ?? ""))
        }
        try db.transaction {
            for (id, old) in people {
                guard let new = names[old] else { continue }
                var target: Int64?
                try db.rows("SELECT id FROM people WHERE key = ?", [.text(Self.personKey(new))]) { target = Int64($0.int(0)) }
                if let target, target != id {
                    for table in ["person_aliases", "chat_people"] {
                        try db.run("UPDATE OR IGNORE \(table) SET person_id = ? WHERE person_id = ?", [.int(target), .int(id)])
                        try db.run("DELETE FROM \(table) WHERE person_id = ?", [.int(id)])
                    }
                    for side in ["a", "b"] {
                        try db.run("UPDATE OR IGNORE person_links SET \(side) = ? WHERE \(side) = ?", [.int(target), .int(id)])
                        try db.run("DELETE FROM person_links WHERE \(side) = ?", [.int(id)])
                    }
                    try db.run("DELETE FROM person_links WHERE a = b")
                    try db.run("UPDATE facts SET subject_id = ? WHERE subject_id = ?", [.int(target), .int(id)])
                    try db.run("DELETE FROM people WHERE id = ?", [.int(id)])
                } else {
                    try db.run("UPDATE people SET name = ?, key = ? WHERE id = ?", [.text(new), .text(Self.personKey(new)), .int(id)])
                }
                let owner = target ?? id
                try db.run("DELETE FROM person_aliases WHERE folded = ?", [.text(old.folded)])
                try db.run("INSERT OR IGNORE INTO person_aliases(person_id, alias, folded, kind) VALUES (?, ?, ?, 'name')",
                           [.int(owner), .text(new), .text(new.folded)])
            }
        }
        aliasCache = nil
    }

    /// Reflections that wrote someone down as an id.
    func renameInReflections(_ names: [String: String]) throws {
        let db = try openForRepair()
        var rows: [(Int64, String, String, String)] = []
        try db.rows("SELECT id, title, summary, people FROM reflections WHERE people LIKE '%+%' OR summary LIKE '%+%' OR title LIKE '%+%'") { row in
            rows.append((Int64(row.int(0)), row.text(1) ?? "", row.text(2) ?? "", row.text(3) ?? ""))
        }
        try db.transaction {
            for (id, title, summary, people) in rows {
                var parts = [title, summary, people]
                // Whole ids only, back to front so the ranges stay valid.
                for index in parts.indices {
                    for match in parts[index].matches(of: /\+\d{7,}/).reversed() {
                        if let new = names[String(parts[index][match.range])] { parts[index].replaceSubrange(match.range, with: new) }
                    }
                }
                guard parts != [title, summary, people] else { continue }
                try db.run("UPDATE reflections SET title = ?, summary = ?, people = ? WHERE id = ?",
                           [.text(parts[0]), .text(parts[1]), .text(parts[2]), .int(id)])
            }
        }
    }

    /// Odds written in percent (90 for 0.9) back on a 0–1 scale.
    func fixPercentOdds() throws {
        let db = try openForRepair()
        try db.execute("""
            UPDATE facts SET confidence = MIN(1.0, confidence / 100.0) WHERE confidence > 1;
            UPDATE person_links SET confidence = MIN(1.0, confidence / 100.0) WHERE confidence > 1;
            """)
    }

    /// Replaces sender names in messages. Indexed first, so each rename is a
    /// lookup rather than a scan of every message.
    func renameMessageSenders(_ names: [String: String], source: MemorySource) throws {
        let db = try openForRepair()
        try db.execute("CREATE INDEX IF NOT EXISTS messages_sender ON messages(source, sender)")
        try db.transaction {
            let update = try db.prepare("UPDATE messages SET sender = ? WHERE source = ? AND sender = ?")
            for (old, new) in names {
                try update.bind([.text(new), .text(source.rawValue), .text(old)])
                try update.step()
            }
        }
    }

    /// Moment ids that may mention renamed senders, for batching.
    func chunkIDsWithNumberSenders(source: MemorySource) throws -> [Int64] {
        var ids: [Int64] = []
        try openForRepair().rows(
            "SELECT id FROM chunks WHERE source = ? AND participants LIKE '%+%'", [.text(source.rawValue)]
        ) { ids.append(Int64($0.int(0))) }
        return ids
    }

    /// Rewrites one batch of moments with the new names, keeping the word
    /// index in step and re-embedding what changed. Small batches let chat
    /// and search run in between.
    func renameSenders(_ names: [String: String], inChunks ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        let db = try openForRepair()
        let list = ids.map(String.init).joined(separator: ",")
        try db.transaction {
            var changed: [(Int64, String, String, String, String)] = []
            try db.rows("SELECT id, text, chat_name, participants FROM chunks WHERE id IN (\(list))") { row in
                let id = Int64(row.int(0))
                let text = row.text(1) ?? ""
                let participants = row.text(3) ?? ""
                var newText = text
                var newParticipants = participants
                for old in participants.split(separator: "\u{1F}").map(String.init) {
                    guard let new = names[old] else { continue }
                    newText = newText.replacingOccurrences(of: "] \(old): ", with: "] \(new): ")
                    newParticipants = newParticipants.replacingOccurrences(of: old, with: new)
                }
                if newText != text { changed.append((id, text, newText, row.text(2) ?? "", newParticipants)) }
            }
            for (id, oldText, newText, chatName, newParticipants) in changed {
                try db.run("INSERT INTO chunks_fts(chunks_fts, rowid, text, chat_name) VALUES ('delete', ?, ?, ?)",
                           [.int(id), .text(oldText), .text(chatName)])
                try db.run("UPDATE chunks SET text = ?, participants = ?, graphed = 0 WHERE id = ?",
                           [.text(newText), .text(newParticipants), .int(id)])
                try db.run("INSERT INTO chunks_fts(rowid, text, chat_name) VALUES (?, ?, ?)",
                           [.int(id), .text(newText), .text(chatName)])
                try db.run("DELETE FROM vectors WHERE chunk_id = ?", [.int(id)])
            }
        }
        dropVectorCache()
    }

    /// Both steps, for tests and small stores.
    func renameSenders(_ names: [String: String], source: MemorySource) throws {
        try renameMessageSenders(names, source: source)
        try renameSenders(names, inChunks: chunkIDsWithNumberSenders(source: source))
    }

    /// Clears the graph so it can be rebuilt from moments and facts.
    func resetGraph() throws {
        let db = try openForRepair()
        try db.transaction {
            try db.execute("DELETE FROM edges; DELETE FROM entities; UPDATE chunks SET graphed = 0;")
        }
    }

    /// Drops secret-like and empty facts and merges ones that say the same
    /// thing, keeping the most confident wording.
    func cleanFacts(me: String) throws {
        let all = try facts(limit: 100_000)
        var drop = Set<Int64>()
        for fact in all {
            if KnowledgeGraph.isSensitive(fact.sentence) || fact.object.folded == fact.subject.folded
                || fact.predicate.folded == "is named" {
                drop.insert(fact.id)
            }
        }
        let grouped = Dictionary(grouping: all.filter { !drop.contains($0.id) }) { "\($0.subject.folded)|\($0.predicate.folded)" }
        for (_, group) in grouped where group.count > 1 {
            let ordered = group.sorted { $0.confidence > $1.confidence }
            var kept: [MemoryFact] = []
            for fact in ordered {
                if kept.contains(where: { KnowledgeGraph.sameMeaning($0.object, fact.object) }) {
                    drop.insert(fact.id)
                } else {
                    kept.append(fact)
                }
            }
        }
        for id in drop { try deleteFact(id: id) }
    }
}
