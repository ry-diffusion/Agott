import Foundation
import Observation

/// A person or a group, by id. Names are what people are called; the id is
/// who they are. "Lígia" the person and "bio a ligia" the class group are
/// two entries that never mix, and "Ale", "alex" and "Alexsander Lima" are
/// aliases of one.
///
/// In the chat, people travel as tags, `<e id=12/>`: the model reads a table
/// of who each tag is and writes tags back, and the app shows the name (or,
/// with names hidden, "Person 12").
nonisolated struct PersonRef: Sendable, Hashable, Identifiable {
    enum Kind: String, Sendable { case person, group }
    var id: Int64
    var kind: Kind
    var name: String

    var tag: String { "<e id=\(id)/>" }
}

extension MemoryStore {
    static let peopleSchema = """
    CREATE TABLE IF NOT EXISTS people(
        id INTEGER PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, key TEXT NOT NULL UNIQUE);
    CREATE TABLE IF NOT EXISTS person_aliases(
        person_id INTEGER NOT NULL, alias TEXT NOT NULL, folded TEXT NOT NULL, kind TEXT NOT NULL,
        PRIMARY KEY(person_id, folded));
    CREATE INDEX IF NOT EXISTS person_aliases_folded ON person_aliases(folded);
    CREATE TABLE IF NOT EXISTS chat_people(
        source TEXT NOT NULL, chat_id TEXT NOT NULL, person_id INTEGER NOT NULL, role TEXT NOT NULL,
        PRIMARY KEY(source, chat_id, person_id));
    CREATE INDEX IF NOT EXISTS chat_people_person ON chat_people(person_id);
    CREATE TABLE IF NOT EXISTS person_links(
        a INTEGER NOT NULL, b INTEGER NOT NULL, kind TEXT NOT NULL, detail TEXT,
        confidence REAL NOT NULL, evidence TEXT, chunk_id INTEGER, ts REAL NOT NULL,
        PRIMARY KEY(a, b, kind));
    CREATE INDEX IF NOT EXISTS person_links_b ON person_links(b);
    """

    /// The key that makes two mentions the same entry: a person by their
    /// folded full name (so WhatsApp and iMessage merge), a group by its chat.
    nonisolated static func personKey(_ name: String) -> String { "person:" + name.folded }
    nonisolated static func groupKey(source: MemorySource, chatID: String) -> String { "group:\(source.rawValue):\(chatID)" }

    private func upsertPerson(kind: PersonRef.Kind, name: String, key: String) throws -> Int64 {
        let db = try open()
        try db.run("INSERT INTO people(kind, name, key) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET name = excluded.name",
                   [.text(kind.rawValue), .text(name), .text(key)])
        var id: Int64 = 0
        try db.rows("SELECT id FROM people WHERE key = ?", [.text(key)]) { id = Int64($0.int(0)) }
        return id
    }

    private func addAlias(_ id: Int64, _ alias: String, kind: String, evidence: String? = nil) throws {
        let folded = alias.folded
        guard folded.count >= 2 else { return }
        let db = try open()
        try db.run("INSERT OR IGNORE INTO person_aliases(person_id, alias, folded, kind, evidence) VALUES (?, ?, ?, ?, ?)",
                   [.int(id), .text(alias), .text(folded), .text(kind), evidence.map { .text($0) } ?? .null])
    }

    // MARK: Learned names and links

    /// Words that are what people call everyone, not one person's name.
    nonisolated static let genericNicknames: Set<String> = [
        "mano", "mana", "mn", "amor", "mozao", "mozinho", "bb", "bebe", "baby", "gata", "gato", "linda", "lindo",
        "bro", "brother", "cara", "vei", "vey", "veio", "amg", "amiga", "amigo", "miga", "migo", "irmao", "irma",
        "mae", "pai", "mamae", "papai", "vc", "voce", "tu", "parca", "parceiro", "chefe", "fofa", "fofo", "neném",
        "nenem", "princesa", "querida", "querido", "lindona", "guria", "guri", "moço", "moca", "moco", "senhor",
    ]

    /// A nickname the moment proves: it is really written there, it is not
    /// what everyone gets called, and the person really is in that chat.
    nonisolated static func nicknameIsProven(_ nickname: String, person: String, in chunk: MemoryChunk) -> Bool {
        let alias = nickname.folded
        guard alias.count >= 2, alias.count <= 30, !genericNicknames.contains(alias), alias != person.folded else { return false }
        let words = chunk.text.wordList.joined(separator: " ")
        guard (" " + words + " ").contains(" " + alias.wordList.joined(separator: " ") + " ") else { return false }
        let present = chunk.participants + (chunk.isGroup == false ? [chunk.chatName] : [])
        return present.contains { $0.folded == person.folded }
    }

    /// Saves a nickname for a person who is in the moment.
    func learnNickname(_ nickname: String, for person: String, evidence: String?) throws {
        let people = try resolvePeople(person).filter { $0.kind == .person }
        guard let ref = people.first(where: { $0.name.folded == person.folded }) ?? (people.count == 1 ? people[0] : nil)
        else { return }
        try addAlias(ref.id, nickname, kind: "nickname", evidence: evidence)
        aliasCache = nil
    }

    /// The person a learned name stands for: one we know without doubt, or
    /// a new entry for someone only mentioned ("Gustavo", nobody's contact).
    func ensurePerson(_ name: String) throws -> Int64? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.folded != AppSettings.myNameSnapshot.folded else { return nil }
        let people = try resolvePeople(trimmed).filter { $0.kind == .person }
        if people.count == 1 { return people[0].id }
        if people.count > 1 { return people.first { $0.name.folded == trimmed.folded }?.id }
        let id = try upsertPerson(kind: .person, name: trimmed, key: Self.personKey(trimmed))
        try addAlias(id, trimmed, kind: "mentioned")
        aliasCache = nil
        return id
    }

    /// Kinds of links between two people. Symmetric ones are stored once.
    nonisolated enum LinkKind: String, CaseIterable, Sendable {
        case partner, ex, crush, family, sibling, parent, friend, bestFriend, classmate, coworker, roommate, conflict

        var symmetric: Bool { self != .parent && self != .crush }

        var phrase: String {
            switch self {
            case .partner: "is dating"
            case .ex: "is the ex of"
            case .crush: "has a crush on"
            case .family: "is family of"
            case .sibling: "is a sibling of"
            case .parent: "is a parent of"
            case .friend: "is friends with"
            case .bestFriend: "is best friends with"
            case .classmate: "studies with"
            case .coworker: "works with"
            case .roommate: "lives with"
            case .conflict: "has a conflict with"
            }
        }
    }

    /// Links two people with proof. A stronger or newer sighting raises it.
    func link(_ a: Int64, _ b: Int64, kind: LinkKind, detail: String?, confidence: Double,
              evidence: String?, chunkID: Int64?, at date: Date) throws {
        guard a != b else { return }
        let (first, second) = kind.symmetric && b < a ? (b, a) : (a, b)
        try open().run(
            """
            INSERT INTO person_links(a, b, kind, detail, confidence, evidence, chunk_id, ts) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(a, b, kind) DO UPDATE SET
                confidence = MIN(1.0, MAX(confidence, excluded.confidence) + 0.05),
                evidence = COALESCE(evidence, excluded.evidence), detail = COALESCE(detail, excluded.detail),
                ts = MAX(ts, excluded.ts)
            """,
            [.int(first), .int(second), .text(kind.rawValue), detail.map { .text($0) } ?? .null, .double(Self.odds(confidence)),
             evidence.map { .text($0) } ?? .null, chunkID.map { .int($0) } ?? .null, .double(date.timeIntervalSince1970)])
    }

    nonisolated struct PersonLink: Sendable, Hashable {
        var other: PersonRef
        var kind: LinkKind
        /// True when the person is the first side ("parent of", "has a crush on").
        var outgoing: Bool
        var detail: String?
        var confidence: Double
        var evidence: String?
        var date: Date

        var phrase: String { outgoing || kind.symmetric ? kind.phrase : (kind == .parent ? "is a child of" : "is the crush of") }

        /// "is dating <e id=9/> Gustavo (85%, proof: “…”)"
        var line: String {
            var text = "\(phrase) \(other.tag) \(other.name)"
            if let detail, !detail.isEmpty { text += " (“\(detail)”)" }
            text += " (\(Int((confidence * 100).rounded()))%, \(MemoryStore.stamp(date.timeIntervalSince1970))"
            if let evidence, !evidence.isEmpty { text += ", proof: “\(evidence)”" }
            return text + ")"
        }
    }

    /// The names someone goes by besides their own: nicknames and first name.
    func otherNames(of id: Int64) throws -> [String] {
        var result: [String] = []
        try open().rows("SELECT alias FROM person_aliases WHERE person_id = ? AND kind IN ('nickname', 'first_name') ORDER BY kind = 'nickname' DESC, alias LIMIT 8",
                        [.int(id)]) { if let alias = $0.text(0) { result.append(alias) } }
        return result
    }

    /// What is already known about the people in some moments, for the model
    /// that reads them: who each one is, what they are called, who they are
    /// linked to, and a few facts. It reads with that in mind, so "o gustavo"
    /// is Gustavo Fernandes and what is known is built on, not repeated.
    func whoIsWho(for chunks: [MemoryChunk], budget: Int) throws -> String {
        guard budget > 200 else { return "" }
        let me = AppSettings.myNameSnapshot.folded
        var counts: [Int64: Int] = [:]
        var refs: [Int64: PersonRef] = [:]
        func note(_ ref: PersonRef, weight: Int = 1) {
            refs[ref.id] = ref
            counts[ref.id, default: 0] += weight
        }
        // Who speaks, and where.
        for chunk in chunks {
            let kind: PersonRef.Kind = chunk.isGroup == true ? .group : .person
            if let chat = try resolvePeople(chunk.chatName).first(where: { $0.kind == kind && $0.name.folded == chunk.chatName.folded }) {
                note(chat, weight: 2)
            }
            for participant in chunk.participants where participant.folded != me {
                if let ref = try resolvePeople(participant).first(where: { $0.name.folded == participant.folded }) { note(ref, weight: 2) }
            }
        }
        // Who is mentioned by a name only one person has.
        let names = try unambiguousNames()
        let longest = names.keys.map { $0.split(separator: " ").count }.max() ?? 1
        for chunk in chunks {
            let words = chunk.text.wordList
            var index = 0
            while index < words.count {
                var step = 1
                for length in stride(from: min(longest, words.count - index), through: 1, by: -1) {
                    let key = words[index..<(index + length)].joined(separator: " ")
                    if key.count >= 3, let id = names[key], key != me {
                        if refs[id] == nil, let ref = try person(id: id) { refs[id] = ref }
                        counts[id, default: 0] += 1
                        step = length
                        break
                    }
                }
                index += step
            }
        }
        var lines: [String] = []
        var used = 0
        for id in counts.sorted(by: { $0.value > $1.value }).map(\.key) {
            guard let ref = refs[id] else { continue }
            var line: String
            if ref.kind == .group {
                line = "\"\(ref.name)\" is a group chat, not a person"
            } else {
                line = ref.name
                let others = try otherNames(of: id).filter { $0.folded != ref.name.folded }
                if !others.isEmpty { line += " (also called " + others.joined(separator: ", ") + ")" }
                let ties = try links(of: id, limit: 4).map { "\($0.phrase) \($0.other.name) (\(Int(($0.confidence * 100).rounded()))%)" }
                let known = try profile(of: ref, limit: 4).map { "\($0.predicate) \($0.object) (\(Int(($0.confidence * 100).rounded()))%)" }
                let about = ties + known
                if !about.isEmpty { line += ": " + about.joined(separator: "; ") }
            }
            guard used + line.count < budget else { break }
            used += line.count + 3
            lines.append("- " + line)
        }
        return lines.joined(separator: "\n")
    }

    /// Everyone a person is linked to, best supported first.
    func links(of id: Int64, limit: Int = 8) throws -> [PersonLink] {
        var result: [PersonLink] = []
        try open().rows(
            """
            SELECT l.a, l.b, l.kind, l.detail, l.confidence, l.evidence, l.ts, p.id, p.kind, p.name
            FROM person_links l JOIN people p ON p.id = CASE WHEN l.a = ? THEN l.b ELSE l.a END
            WHERE l.a = ? OR l.b = ? ORDER BY l.confidence DESC, l.ts DESC LIMIT ?
            """,
            [.int(id), .int(id), .int(id), .of(limit)]
        ) { row in
            guard let kind = LinkKind(rawValue: row.text(2) ?? "") else { return }
            let other = PersonRef(id: Int64(row.int(7)), kind: PersonRef.Kind(rawValue: row.text(8) ?? "") ?? .person,
                                  name: row.text(9) ?? "")
            result.append(PersonLink(other: other, kind: kind, outgoing: Int64(row.int(0)) == id, detail: row.text(3),
                                     confidence: row.double(4), evidence: row.text(5),
                                     date: Date(timeIntervalSince1970: row.double(6))))
        }
        return result
    }

    /// Builds the directory from the chats: each direct chat is a person,
    /// each group chat is a group, and everyone who wrote in a group is a
    /// member. Incremental: only chats with news since the last run.
    @discardableResult
    func syncPeople() throws -> Int {
        let db = try open()
        try db.execute(Self.peopleSchema)
        var since = 0.0
        try db.rows("SELECT value FROM cursors WHERE source = 'people-rowid'") { since = $0.double(0) }
        // Chats are rewritten (INSERT OR REPLACE) whenever they get messages,
        // which gives them a new rowid: "rowid above the last one seen" means
        // new or changed, whatever the dates of their messages.
        var chats: [(MemorySource, String, String, Bool, Double)] = []
        try db.rows("SELECT source, chat_id, name, is_group, rowid FROM chats WHERE source != 'claude' AND rowid > ?",
                    [.double(since)]) { row in
            chats.append((MemorySource(rawValue: row.text(0) ?? "") ?? .note, row.text(1) ?? "", row.text(2) ?? "",
                          row.int(3) != 0, row.double(4)))
        }
        guard !chats.isEmpty else { return 0 }
        let me = AppSettings.myNameSnapshot.folded
        try db.transaction {
            for (source, chatID, name, isGroup, _) in chats where !name.isEmpty {
                if isGroup {
                    let group = try upsertPerson(kind: .group, name: name, key: Self.groupKey(source: source, chatID: chatID))
                    try addAlias(group, name, kind: "name")
                    try db.run("INSERT OR IGNORE INTO chat_people(source, chat_id, person_id, role) VALUES (?, ?, ?, 'is')",
                               [.text(source.rawValue), .text(chatID), .int(group)])
                    var senders: [String] = []
                    try db.rows("SELECT DISTINCT sender FROM messages WHERE source = ? AND chat_id = ? AND is_me = 0",
                                [.text(source.rawValue), .text(chatID)]) { if let s = $0.text(0) { senders.append(s) } }
                    for sender in senders where !sender.isEmpty && sender.folded != me {
                        let person = try upsertPerson(kind: .person, name: sender, key: Self.personKey(sender))
                        try addPersonAliases(person, sender)
                        try db.run("INSERT OR IGNORE INTO chat_people(source, chat_id, person_id, role) VALUES (?, ?, ?, 'member')",
                                   [.text(source.rawValue), .text(chatID), .int(person)])
                    }
                } else {
                    let person = try upsertPerson(kind: .person, name: name, key: Self.personKey(name))
                    try addPersonAliases(person, name)
                    try db.run("INSERT OR IGNORE INTO chat_people(source, chat_id, person_id, role) VALUES (?, ?, ?, 'direct')",
                               [.text(source.rawValue), .text(chatID), .int(person)])
                }
            }
            let latest = chats.map(\.4).max() ?? since
            try db.run("INSERT OR REPLACE INTO cursors(source, value) VALUES ('people-rowid', ?)", [.double(latest)])
        }
        aliasCache = nil
        try linkFactsToPeople()
        return chats.count
    }

    /// A person's full name, and their first name when it is a real word.
    private func addPersonAliases(_ id: Int64, _ name: String) throws {
        try addAlias(id, name, kind: "name")
        let words = name.split(separator: " ").map(String.init)
        if words.count > 1, let first = words.first, first.count >= 3, first.rangeOfCharacter(from: .decimalDigits) == nil {
            try addAlias(id, first, kind: "first_name")
        }
    }

    // MARK: Lookup

    /// Every alias, folded, with who it may mean. Small; kept in memory.
    private func aliases() throws -> [String: [PersonRef]] {
        if let aliasCache { return aliasCache }
        let db = try open()
        try db.execute(Self.peopleSchema)
        var result: [String: [PersonRef]] = [:]
        try db.rows("SELECT a.folded, p.id, p.kind, p.name FROM person_aliases a JOIN people p ON p.id = a.person_id") { row in
            let ref = PersonRef(id: Int64(row.int(1)), kind: PersonRef.Kind(rawValue: row.text(2) ?? "") ?? .person,
                                name: row.text(3) ?? "")
            result[row.text(0) ?? "", default: []].append(ref)
        }
        aliasCache = result
        return result
    }

    /// Who a name means, people before groups: "Ligia" is the person Lígia;
    /// "bio a ligia" is the group. Several when the name is ambiguous.
    func resolvePeople(_ name: String) throws -> [PersonRef] {
        let all = try aliases()
        let folded = name.folded
        if let exact = all[folded], !exact.isEmpty { return Self.peopleFirst(exact, name: folded) }
        // Whole words: "Alexsander" finds "Alexsander Lima".
        let words = Set(name.wordList)
        guard !words.isEmpty else { return [] }
        var found: [PersonRef] = []
        for (alias, refs) in all where words.isSubset(of: Set(alias.split(separator: " ").map(String.init))) {
            found += refs
        }
        return Self.peopleFirst(Array(Set(found)), name: folded)
    }

    nonisolated static func peopleFirst(_ refs: [PersonRef], name: String) -> [PersonRef] {
        let people = refs.filter { $0.kind == .person }
        // A group only when no person has the name, or it is the group's own name.
        let groups = refs.filter { $0.kind == .group && (people.isEmpty || $0.name.folded == name) }
        return (people.sorted { $0.name < $1.name } + groups.sorted { $0.name < $1.name })
    }

    /// Groups with the word in their name ("ligia" → "bio a ligia").
    func groupsNamed(containing word: String) throws -> [PersonRef] {
        let folded = word.folded
        guard folded.count >= 3 else { return [] }
        return try aliases().filter { alias, _ in alias.split(separator: " ").contains { $0 == folded } }
            .flatMap(\.value).filter { $0.kind == .group }
    }

    func person(id: Int64) throws -> PersonRef? {
        var result: PersonRef?
        try open().rows("SELECT id, kind, name FROM people WHERE id = ?", [.int(id)]) { row in
            result = PersonRef(id: Int64(row.int(0)), kind: PersonRef.Kind(rawValue: row.text(1) ?? "") ?? .person,
                               name: row.text(2) ?? "")
        }
        return result
    }

    /// Every name by id, for the chat to turn tags into names.
    /// Folded names and first names that point at exactly one entry, for
    /// hiding names written in plain text.
    func unambiguousNames() throws -> [String: Int64] {
        var result: [String: Int64] = [:]
        var clash = Set<String>()
        for (alias, refs) in try aliases() where alias.count >= 3 {
            let ids = Set(refs.map(\.id))
            if ids.count == 1, !clash.contains(alias) { result[alias] = ids.first } else { clash.insert(alias); result[alias] = nil }
        }
        return result
    }

    func peopleNames() throws -> [Int64: PersonRef] {
        let db = try open()
        try db.execute(Self.peopleSchema)
        var result: [Int64: PersonRef] = [:]
        try db.rows("SELECT id, kind, name FROM people") { row in
            let ref = PersonRef(id: Int64(row.int(0)), kind: PersonRef.Kind(rawValue: row.text(1) ?? "") ?? .person,
                                name: row.text(2) ?? "")
            result[ref.id] = ref
        }
        return result
    }

    /// Where someone is: their direct chats, and the groups they write in
    /// (or, for a group, its members).
    func connections(of ref: PersonRef, limit: Int = 8) throws -> (direct: [ChatSummary], others: [PersonRef]) {
        let db = try open()
        var keys: [(String, String, String)] = []
        try db.rows("SELECT source, chat_id, role FROM chat_people WHERE person_id = ?", [.int(ref.id)]) {
            keys.append(($0.text(0) ?? "", $0.text(1) ?? "", $0.text(2) ?? ""))
        }
        var direct: [ChatSummary] = []
        var others: [PersonRef] = []
        for (source, chatID, role) in keys {
            if role == "direct" || role == "is" {
                try db.rows("SELECT name, is_group, msg_count, my_count, first_ts, last_ts FROM chats WHERE source = ? AND chat_id = ?",
                            [.text(source), .text(chatID)]) { row in
                    direct.append(ChatSummary(
                        source: MemorySource(rawValue: source) ?? .note, chatID: chatID, name: row.text(0) ?? "",
                        isGroup: row.int(1) != 0, messageCount: row.int(2), myCount: row.int(3),
                        firstDate: Date(timeIntervalSince1970: row.double(4)), lastDate: Date(timeIntervalSince1970: row.double(5)),
                        lastFromMe: false, lastText: ""))
                }
            }
            if ref.kind == .person, role == "member" {
                try db.rows("SELECT p.id, p.name FROM chat_people c JOIN people p ON p.id = c.person_id WHERE c.source = ? AND c.chat_id = ? AND c.role = 'is'",
                            [.text(source), .text(chatID)]) { row in
                    others.append(PersonRef(id: Int64(row.int(0)), kind: .group, name: row.text(1) ?? ""))
                }
            }
            if ref.kind == .group, role == "is" {
                try db.rows("SELECT p.id, p.name FROM chat_people c JOIN people p ON p.id = c.person_id WHERE c.source = ? AND c.chat_id = ? AND c.role = 'member' LIMIT 40",
                            [.text(source), .text(chatID)]) { row in
                    others.append(PersonRef(id: Int64(row.int(0)), kind: .person, name: row.text(1) ?? ""))
                }
            }
        }
        return (direct, Array(others.prefix(limit)))
    }

    // MARK: Facts by id

    /// Ties facts to the person they are about, so "Ale" and "Alexsander"
    /// facts land on one profile and never on the group named after someone.
    func linkFactsToPeople() throws {
        let db = try open()
        var pending: [(Int64, String)] = []
        try db.rows("SELECT id, subject FROM facts WHERE subject_id IS NULL LIMIT 5000") {
            pending.append((Int64($0.int(0)), $0.text(1) ?? ""))
        }
        guard !pending.isEmpty else { return }
        let me = AppSettings.myNameSnapshot.folded
        try db.transaction {
            for (id, subject) in pending {
                // Only an unambiguous person; otherwise leave it for later.
                let refs = subject.folded == me ? [] : try resolvePeople(subject).filter { $0.kind == .person }
                try db.run("UPDATE facts SET subject_id = ? WHERE id = ?", [refs.count == 1 ? .int(refs[0].id) : .int(0), .int(id)])
            }
        }
    }

    /// Everything known about one person by id, plus facts still filed
    /// under a name that matches them.
    func profile(of ref: PersonRef, limit: Int = 30) throws -> [MemoryFact] {
        var result: [MemoryFact] = []
        try open().rows(Self.factColumnsSQL + " WHERE f.subject_id = ? ORDER BY f.confidence DESC, f.ts DESC LIMIT ?",
                        [.int(ref.id), .of(limit)]) { result.append(Self.factRow($0)) }
        if result.count < limit, ref.kind == .person {
            let ids = Set(result.map(\.id))
            result += try profile(of: ref.name, limit: limit).filter { !ids.contains($0.id) && ($0.subjectID ?? 0) == 0 }
        }
        return Array(result.prefix(limit))
    }
}

/// Names for tags, on the main thread, for the chat to draw.
@MainActor
@Observable
final class PeopleDirectory {
    static let shared = PeopleDirectory()
    private(set) var byID: [Int64: PersonRef] = [:]
    /// Folded name → id, for names written without a tag.
    @ObservationIgnored private var nameIndex: [String: Int64] = [:]
    @ObservationIgnored private var longestName = 1

    func refresh() async {
        if let names = try? await MemoryStore.shared.peopleNames() { byID = names }
        if let index = try? await MemoryStore.shared.unambiguousNames() {
            nameIndex = index
            longestName = index.keys.map { $0.split(separator: " ").count }.max() ?? 1
        }
    }

    /// How a tag reads: the name, or "Person 12" while names are hidden.
    func label(_ id: Int64, hidden: Bool) -> String {
        let ref = byID[id]
        if hidden || ref == nil {
            return ref?.kind == .group ? String(localized: "Group \(id)") : String(localized: "Person \(id)")
        }
        return ref!.name
    }

    /// Plain text with every known name turned into its tag, longest
    /// match first: used to hide names the user typed.
    func tagPlainNames(_ text: String) -> String {
        guard !nameIndex.isEmpty else { return text }
        var words: [(range: Range<String.Index>, folded: String)] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { word, range, _, _ in
            if let word { words.append((range, word.folded)) }
        }
        var result = ""
        var cursor = text.startIndex
        var index = 0
        while index < words.count {
            var matched: (Int, Int64)?
            for length in stride(from: min(longestName, words.count - index), through: 1, by: -1) {
                let key = words[index..<(index + length)].map(\.folded).joined(separator: " ")
                if let id = nameIndex[key] { matched = (length, id); break }
            }
            if let (length, id) = matched {
                result += text[cursor..<words[index].range.lowerBound]
                result += "<e id=\(id)/>"
                cursor = words[index + length - 1].range.upperBound
                index += length
            } else {
                index += 1
            }
        }
        result += text[cursor...]
        return result
    }

    func name(_ id: Int64) -> PersonRef? { byID[id] }

    /// The tags in a text, in order.
    nonisolated static func tags(in text: String) -> [Int64] {
        text.matches(of: /<e id="?(\d+)"?\s*\/?>/).compactMap { Int64($0.1) }
    }

    /// Writes tags in place of the names of `people`, for replies where the
    /// model wrote a name instead of its tag. Longest names first, whole
    /// words only.
    nonisolated static func tagNames(_ text: String, people: [PersonRef]) -> String {
        // Full names, and a person's first name when nobody else here has it.
        var names: [(String, PersonRef)] = people.map { ($0.name, $0) }
        let firsts = Dictionary(grouping: people.filter { $0.kind == .person }) { $0.name.split(separator: " ").first.map(String.init)?.folded ?? "" }
        for (first, refs) in firsts where refs.count == 1 && first.count >= 3 && refs[0].name.contains(" ") {
            if let word = refs[0].name.split(separator: " ").first { names.append((String(word), refs[0])) }
        }
        let regexes: [(NSRegularExpression, String)] = names.sorted(by: { $0.0.count > $1.0.count }).compactMap { name, ref in
            guard name.count >= 3 else { return nil }
            let escaped = NSRegularExpression.escapedPattern(for: name)
            guard let regex = try? NSRegularExpression(
                pattern: "(?<![\\p{L}\\d<=/])\(escaped)(?![\\p{L}\\d])", options: [.caseInsensitive]) else { return nil }
            return (regex, NSRegularExpression.escapedTemplate(for: ref.tag))
        }
        func tagged(_ piece: Substring) -> String {
            var piece = String(piece)
            for (regex, template) in regexes {
                piece = regex.stringByReplacingMatches(in: piece, range: NSRange(piece.startIndex..., in: piece), withTemplate: template)
            }
            return piece
        }
        // Media tags are left whole: a person tag inside by="…" or title="…"
        // broke the tag and showed its insides in the reply.
        var result = ""
        var cursor = text.startIndex
        for match in text.matches(of: MediaTag.pattern) {
            result += tagged(text[cursor..<match.range.lowerBound])
            result += text[match.range]
            cursor = match.range.upperBound
        }
        return result + tagged(text[cursor...])
    }
}

// MARK: - Facts in the user's language

extension MemoryStore {
    /// Relations the graph builds itself (not facts), matched by name elsewhere.
    nonisolated static let structuralRelations: Set<String> = Set(GraphRelation.allCases.map(\.rawValue))

    /// The last fact and edge written before facts were learned in the user's language.
    struct PredicateMark: Sendable { var facts: Int64; var edges: Int64 }

    func predicateMark() throws -> PredicateMark {
        let db = try open()
        return PredicateMark(facts: Int64(try db.scalarInt("SELECT COALESCE(MAX(id), 0) FROM facts")),
                             edges: Int64(try db.scalarInt("SELECT COALESCE(MAX(rowid), 0) FROM edges")))
    }

    /// Every verb used up to the mark, facts and graph edges alike.
    func predicates(through mark: PredicateMark) throws -> [String] {
        let db = try open()
        var found = Set<String>()
        try db.rows("SELECT DISTINCT predicate FROM facts WHERE id <= ?", [.int(mark.facts)]) { row in
            if let text = row.text(0), !text.isEmpty { found.insert(text) }
        }
        try db.rows("SELECT DISTINCT rel FROM edges WHERE rowid <= ?", [.int(mark.edges)]) { row in
            // The graph's own relations stay as they are: KnowledgeGraph keeps
            // writing them in English and screens look them up by name.
            if let text = row.text(0), !text.isEmpty, !Self.structuralRelations.contains(text) { found.insert(text) }
        }
        return found.sorted()
    }

    /// Rewrites verbs up to the mark. Two facts that become the same one
    /// ("owns" and "has" are both "tem") keep the first.
    func renamePredicates(_ map: [String: String], through mark: PredicateMark) throws {
        guard !map.isEmpty else { return }
        let db = try open()
        try db.run("BEGIN")
        do {
            for (old, new) in map where old != new {
                try db.run("UPDATE OR IGNORE facts SET predicate = ? WHERE predicate = ? AND id <= ?",
                           [.text(new), .text(old), .int(mark.facts)])
                try db.run("DELETE FROM facts WHERE predicate = ? AND id <= ?", [.text(old), .int(mark.facts)])
                guard !Self.structuralRelations.contains(old) else { continue }
                try db.run("UPDATE OR IGNORE edges SET rel = ? WHERE rel = ? AND rowid <= ?",
                           [.text(new), .text(old), .int(mark.edges)])
                try db.run("DELETE FROM edges WHERE rel = ? AND rowid <= ?", [.text(old), .int(mark.edges)])
            }
            try db.run("COMMIT")
        } catch {
            try? db.run("ROLLBACK")
            throw error
        }
    }
}

