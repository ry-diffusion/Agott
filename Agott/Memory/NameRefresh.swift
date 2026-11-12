import Foundation

/// Gives stored messages the names their senders have today.
///
/// Names are decided when a message is first read, and they age: a number
/// becomes a contact, WhatsApp learns who a private id is, and an old
/// mistake (a data field read as a name, which made thousands of strangers
/// in groups into one person called "IAA=") stays written into every
/// message. This walks the stored messages, asks the source who wrote each
/// one, and rewrites what changed: messages, chats, moments, people.
///
/// A name that turns out to be one other name is a rename, and the person
/// keeps everything known about them. A name that turns out to be many
/// people was never a person: what was learned under it is dropped and the
/// moments it was in are read again.
extension MemoryStore {
    /// What stands for a sender nobody can name any more (a message whose
    /// chat was deleted from the source).
    nonisolated static let unknownSender = "?"

    nonisolated struct StoredSender: Sendable {
        var id: Int64
        var externalID: String
        var chatID: String
        var sender: String
        var chatName: String
        var isGroup: Bool
    }

    nonisolated struct NameChanges: Sendable {
        /// Old sender name, to the new names its messages got and how many each.
        var moved: [String: [String: Int]] = [:]
        var chats = Set<String>()
        /// Chats whose own name changed, to what.
        var chatNames: [String: String] = [:]
        var messages = 0

        var isEmpty: Bool { messages == 0 }
    }

    nonisolated struct NameOutcome: Sendable {
        var renamed: [String: String] = [:]
        /// Names that were several people.
        var split: [String] = []
        /// Moments to write again, and the ones among them to read again.
        var chunks: [Int64] = []
        var relearn = Set<Int64>()
    }

    /// Incoming messages of a source, a page at a time, by id.
    func senders(source: MemorySource, after id: Int64, limit: Int) throws -> [StoredSender] {
        var result: [StoredSender] = []
        try open().rows(
            "SELECT id, ext_id, chat_id, sender, chat_name, is_group FROM messages WHERE source = ? AND is_me = 0 AND id > ? ORDER BY id LIMIT ?",
            [.text(source.rawValue), .int(id), .of(limit)]
        ) { row in
            result.append(StoredSender(id: Int64(row.int(0)), externalID: row.text(1) ?? "", chatID: row.text(2) ?? "",
                                       sender: row.text(3) ?? "", chatName: row.text(4) ?? "", isGroup: row.int(5) != 0))
        }
        return result
    }

    /// Writes the names messages have now.
    func write(names changes: [(id: Int64, sender: String, chatName: String)]) throws {
        guard !changes.isEmpty else { return }
        let db = try open()
        try db.transaction {
            let update = try db.prepare("UPDATE messages SET sender = ?, chat_name = ? WHERE id = ?")
            for change in changes {
                try update.bind([.text(change.sender), .text(change.chatName), .int(change.id)])
                try update.step()
            }
        }
    }

    /// After messages were renamed: decides what each old name was, fixes
    /// people, facts, chats and the graph, and says which moments to write
    /// again.
    func settle(_ changes: NameChanges, source: MemorySource) throws -> NameOutcome {
        var outcome = NameOutcome()
        guard !changes.isEmpty else { return outcome }
        let db = try open()
        var chunks = Set<Int64>()
        for (old, news) in changes.moved {
            let remaining = try db.scalarInt("SELECT COUNT(*) FROM messages WHERE source = ? AND sender = ? AND is_me = 0",
                                             [.text(source.rawValue), .text(old)])
            let garbage = PersonName.isPlaceholder(old) && PersonName.looksEncoded(old)
            if news.count == 1, remaining == 0, let new = news.keys.first {
                outcome.renamed[old] = new
            } else if garbage || (news.count > 1 && remaining == 0) {
                outcome.split.append(old)
            }
            var found: [Int64] = []
            try db.rows("SELECT id FROM chunks WHERE source = ? AND participants LIKE ?", [.text(source.rawValue), .text("%\(old)%")]) {
                found.append(Int64($0.int(0)))
            }
            chunks.formUnion(found)
            if outcome.split.last == old { outcome.relearn.formUnion(found) }
        }
        for (chatID, name) in changes.chatNames {
            try db.rows("SELECT id FROM chunks WHERE source = ? AND chat_id = ?", [.text(source.rawValue), .text(chatID)]) {
                chunks.insert(Int64($0.int(0)))
            }
            // The user's own lines in that chat carry its name too.
            try db.run("UPDATE messages SET chat_name = ? WHERE source = ? AND chat_id = ? AND chat_name != ?",
                       [.text(name), .text(source.rawValue), .text(chatID), .text(name)])
        }
        try db.transaction {
            for old in outcome.split {
                // Whoever is left under a name that was never one person
                // cannot be named any more.
                try db.run("UPDATE messages SET sender = ? WHERE source = ? AND sender = ? AND is_me = 0",
                           [.text(Self.unknownSender), .text(source.rawValue), .text(old)])
                try dropPerson(db, named: old)
            }
            for (old, new) in outcome.renamed {
                var from: Int64?, to: Int64?
                try db.rows("SELECT id FROM people WHERE key = ?", [.text(Self.personKey(old))]) { from = Int64($0.int(0)) }
                try db.rows("SELECT id FROM people WHERE key = ?", [.text(Self.personKey(new))]) { to = Int64($0.int(0)) }
                if let from, let to, from != to {
                    try movePerson(db, from: from, to: to, oldName: old, newName: new)
                } else if let from, to == nil {
                    try db.run("UPDATE people SET name = ?, key = ? WHERE id = ?", [.text(new), .text(Self.personKey(new)), .int(from)])
                    try db.run("INSERT OR IGNORE INTO person_aliases(person_id, alias, folded, kind) VALUES (?, ?, ?, 'name')",
                               [.int(from), .text(new), .text(new.folded)])
                    // A number or an id is no way to find someone by name.
                    if PersonName.isPlaceholder(old) {
                        try db.run("DELETE FROM person_aliases WHERE person_id = ? AND folded = ?", [.int(from), .text(old.folded)])
                    }
                    try db.run("UPDATE OR IGNORE facts SET subject = ? WHERE subject = ?", [.text(new), .text(old)])
                    try db.run("DELETE FROM facts WHERE subject = ?", [.text(old)])
                }
                try db.run("UPDATE OR IGNORE facts SET object = ? WHERE object = ?", [.text(new), .text(old)])
                try db.run("UPDATE reflections SET chat = ? WHERE chat = ?", [.text(new), .text(old)])
                if old.count >= 4 {
                    try db.run("UPDATE reflections SET people = replace(people, ?, ?), summary = replace(summary, ?, ?) WHERE people LIKE ?",
                               [.text(old), .text(new), .text(old), .text(new), .text("%\(old)%")])
                }
                try dropEntity(db, person: old)
            }
        }
        let keys = changes.chats.map { (source, $0) }
        try refreshChats(db: db, keys: keys)
        aliasCache = nil
        salienceCache = nil
        nameCache.removeAll()
        outcome.chunks = Array(chunks)
        return outcome
    }

    /// Removes a person who was never one person, with what was filed
    /// under them.
    func dropPerson(_ db: SQLiteDB, named name: String) throws {
        var id: Int64?
        try db.rows("SELECT id FROM people WHERE key = ?", [.text(Self.personKey(name))]) { id = Int64($0.int(0)) }
        if let id {
            for table in ["person_aliases", "chat_people"] {
                try db.run("DELETE FROM \(table) WHERE person_id = ?", [.int(id)])
            }
            try db.run("DELETE FROM person_links WHERE a = ? OR b = ?", [.int(id), .int(id)])
            try db.run("DELETE FROM person_pairs WHERE a = ? OR b = ?", [.int(id), .int(id)])
            try db.run("DELETE FROM facts WHERE subject_id = ?", [.int(id)])
            try db.run("DELETE FROM people WHERE id = ?", [.int(id)])
        }
        try db.run("DELETE FROM facts WHERE subject = ? OR object = ?", [.text(name), .text(name)])
        try dropEntity(db, person: name)
    }

    func dropEntity(_ db: SQLiteDB, person name: String) throws {
        var entity: Int64?
        try db.rows("SELECT id FROM entities WHERE key = ?", [.text(Self.entityKey(kind: .person, name: name))]) {
            entity = Int64($0.int(0))
        }
        guard let entity else { return }
        try db.run("DELETE FROM edges WHERE src = ? OR dst = ?", [.int(entity), .int(entity)])
        try db.run("DELETE FROM entities WHERE id = ?", [.int(entity)])
    }
}

#if os(macOS)
extension WhatsAppSource {
    /// What WhatsApp calls the sender and the chat of each stored message
    /// today, keyed by chat and message id.
    static func names(of messages: [MemoryStore.StoredSender], contacts: ContactBook,
                      directory: WhatsAppDirectory = .current) -> [Int64: (sender: String, chatName: String)] {
        guard let db = try? SQLiteDB(path: path, readOnly: true) else { return [:] }
        // Voice notes and photos are stored under "media-" plus the id.
        func stanza(_ externalID: String) -> String {
            externalID.hasPrefix("media-") ? String(externalID.dropFirst(6)) : externalID
        }
        var byKey: [String: [Int64]] = [:]
        var ids: [String] = []
        for message in messages {
            let id = stanza(message.externalID)
            // Ids go into the query as text: only plain ones.
            guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else { continue }
            byKey["\(message.chatID)|\(id)", default: []].append(message.id)
            ids.append(id)
        }
        var result: [Int64: (sender: String, chatName: String)] = [:]
        for start in stride(from: 0, to: ids.count, by: 500) {
            let list = ids[start..<min(start + 500, ids.count)].map { "'\($0)'" }.joined(separator: ",")
            try? db.rows("SELECT \(messageColumnsSQL) \(messageJoinsSQL) WHERE m.ZSTANZAID IN (\(list)) AND m.ZISFROMME = 0") { row in
                let message = message(from: row, text: "", contacts: contacts, directory: directory)
                for id in byKey["\(message.chatID)|\(message.externalID)"] ?? [] {
                    result[id] = (message.sender, message.chatName)
                }
            }
        }
        return result
    }
}
#endif
