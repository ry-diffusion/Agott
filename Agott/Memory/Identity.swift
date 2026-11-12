import Foundation

/// Who is who.
///
/// A person reaches memory under many names: the contact name with its
/// emoji, a first name, a nickname only one friend uses, a typo, a phone
/// number. This file is what makes them one person, and what picks the
/// right one when a name fits several ("Ana" is the Ana you talk to every
/// day before it is one of the other twelve).
///
/// Three ideas, taken from how the better memory systems do it and made to
/// fit chat data:
///
/// - **Cheap first, careful after.** Names that are equal once cleaned are
///   the same person. Names that are only similar become a *maybe*, which a
///   model (or you) settles later with everything known about both. Nothing
///   is merged on likeness alone: two people made one is worse than one
///   person kept as two.
/// - **Proof decides whose name it is.** A model proposes a nickname; code
///   checks who wrote the words that use it. "Zé, você mandou o áudio",
///   written by Yasmin in her chat with you, is your nickname, not hers.
/// - **Closeness breaks ties.** Every name lookup is ordered by how much
///   and how recently you talk to each person.
nonisolated enum PersonName {
    /// A contact name without what decorates it: "Lígia 🌻" is "Lígia",
    /// "~Joca~" is "Joca", "𝓐𝓷𝓪" is "Ana". Empty decoration-only names stay
    /// as they are.
    static func clean(_ name: String) -> String {
        let plain = name.precomposedStringWithCompatibilityMapping
        var kept = String.UnicodeScalarView()
        for scalar in plain.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .nonspacingMark, .decimalNumber:
                kept.append(scalar)
            default:
                kept.append(scalar == "'" || scalar == "-" || scalar == "." ? scalar : " ")
            }
        }
        var words = String(kept).split(separator: " ").map(String.init)
        // Beside Latin letters, letters of other scripts are ornament
        // ("𝜗ৎHanna"); a name written wholly in another script is a name.
        if words.contains(where: { $0.unicodeScalars.filter(isLatin).count >= 2 }) {
            words = words.compactMap { word in
                var scalars = Array(word.unicodeScalars)
                func ornament(_ scalar: Unicode.Scalar) -> Bool {
                    scalar.properties.isAlphabetic && !isLatin(scalar)
                }
                while let first = scalars.first, ornament(first) { scalars.removeFirst() }
                while let last = scalars.last, ornament(last) { scalars.removeLast() }
                let trimmed = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: CharacterSet(charactersIn: "-'."))
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        let cleaned = words.joined(separator: " ")
        return cleaned.isEmpty ? name.trimmingCharacters(in: .whitespaces) : cleaned
    }

    private static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.properties.isAlphabetic else { return false }
        return scalar.value < 0x250 || (0x1E00...0x1EFF).contains(scalar.value)
    }

    /// A name that is really a number or an id: "+5591985574073",
    /// "+55 91 98557-4073", "IAA=".
    static func isPlaceholder(_ name: String) -> Bool {
        !name.contains(where: \.isLetter) || looksEncoded(name)
    }

    /// Base64 where a name should be: "IAA=", "CLSYy9YGGhE5OTMw…". WhatsApp
    /// keeps encoded data in fields that read like names.
    static func looksEncoded(_ text: String) -> Bool {
        var text = text.trimmingCharacters(in: .whitespaces)
        // Stored as if it were a number: "+EAA=", "+GIO5stcGIAE=".
        let plus = text.hasPrefix("+")
        if plus { text.removeFirst() }
        guard text.count >= 4, text.contains(where: \.isLetter), text.unicodeScalars.allSatisfy({
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+/=".unicodeScalars.contains($0))
        }) else { return false }
        if text.hasSuffix("=") { return text.count % 4 == 0 }
        let mixed = text.contains(where: \.isNumber) && text.contains(where: \.isUppercase) && text.contains(where: \.isLowercase)
        return mixed && (text.count >= 24 || (plus && text.count >= 8))
    }

    /// Words that describe someone instead of naming them. "irmão", "her ex"
    /// and "primeiro amor" are not people to keep a page on.
    static let descriptors: Set<String> = [
        "irmao", "irma", "mae", "pai", "primo", "prima", "tio", "tia", "avo", "vo", "filho", "filha", "namorado",
        "namorada", "ex", "crush", "amigo", "amiga", "amg", "amor", "marido", "esposa", "mulher", "chefe", "professor",
        "professora", "vizinho", "vizinha", "colega", "ficante", "primeiro", "primeira", "meu", "minha", "seu", "sua",
        "her", "his", "my", "their", "the", "brother", "sister", "mother", "father", "mom", "dad", "boyfriend",
        "girlfriend", "friend", "husband", "wife", "boss", "teacher", "cousin", "uncle", "aunt", "someone", "alguem",
        "ele", "ela", "eles", "elas", "o", "a", "um", "uma", "essa", "esse", "aquele", "aquela", "menino", "menina",
        "cara", "mina", "garoto", "garota", "pessoa", "galera", "todos", "todo",
    ]

    /// Whether `name` names nobody in particular.
    static func isDescriptor(_ name: String) -> Bool {
        let words = name.wordList
        guard let first = words.first else { return true }
        if descriptors.contains(first) { return true }
        // Several words and none capitalised reads as a phrase, not a name.
        let original = name.split(separator: " ")
        return original.count >= 2 && !original.contains { $0.first?.isUppercase == true }
    }

    /// Jaro–Winkler likeness of two folded names, 0…1.
    static func likeness(_ a: String, _ b: String) -> Double {
        let s = Array(a.folded), t = Array(b.folded)
        guard !s.isEmpty, !t.isEmpty else { return 0 }
        if s == t { return 1 }
        let window = max(0, max(s.count, t.count) / 2 - 1)
        var sMatched = [Bool](repeating: false, count: s.count)
        var tMatched = [Bool](repeating: false, count: t.count)
        var matches = 0.0
        for i in s.indices {
            let low = max(0, i - window), high = min(t.count - 1, i + window)
            guard low <= high else { continue }
            for j in low...high where !tMatched[j] && s[i] == t[j] {
                sMatched[i] = true
                tMatched[j] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0 }
        var transpositions = 0.0
        var k = 0
        for i in s.indices where sMatched[i] {
            while !tMatched[k] { k += 1 }
            if s[i] != t[k] { transpositions += 1 }
            k += 1
        }
        let jaro = (matches / Double(s.count) + matches / Double(t.count) + (matches - transpositions / 2) / matches) / 3
        var prefix = 0.0
        for (x, y) in zip(s, t).prefix(4) {
            guard x == y else { break }
            prefix += 1
        }
        return jaro + prefix * 0.1 * (1 - jaro)
    }

    /// A misspelling of the name rather than a nickname: "dayid", "DATVID"
    /// for Dayvid. Kept to recognise the person, never shown as what they
    /// are called. A shortening ("Manu" for Manuella) is a real nickname.
    static func isMisspelling(_ alias: String, of name: String) -> Bool {
        let alias = alias.folded
        for word in clean(name).wordList where word.count >= 4 {
            if alias == word { return false }
            // The name with its last letter held down, or one letter more.
            if alias.hasPrefix(word) {
                let extra = alias.dropFirst(word.count)
                if extra.count <= 1 || Set(extra) == [word.last] { return true }
                continue
            }
            if word.hasPrefix(alias) { continue }
            // The name missing its first letters: a slip, not a nickname.
            if word.hasSuffix(alias), alias.count >= word.count - 2 { return true }
            if abs(alias.count - word.count) <= 1, likeness(alias, word) >= 0.86 { return true }
        }
        return false
    }
}

// MARK: - Nicknames

nonisolated enum Nicknames {
    enum Owner: Equatable, Sendable {
        case me
        case person(String)
        case nobody
    }

    struct Verdict: Equatable, Sendable {
        var owner: Owner
        /// Whether one sighting is enough: said outright ("meu apelido é"),
        /// or used to call someone who is in the conversation.
        var trusted: Bool
    }

    /// Words that say outright that a name is a nickname.
    private static let declarations = [
        "apelido", "vulgo", "aka", "nickname", "conhecido como", "conhecida como", "me chamam", "me chama de",
        "pode me chamar", "call me", "they call me",
    ]

    /// Words before a name that make it someone talked about, not talked to.
    private static let references: Set<String> = [
        "o", "a", "os", "as", "do", "da", "dos", "das", "no", "na", "pro", "pra", "um", "uma", "de", "com", "que",
        "the", "of", "to", "with", "meu", "minha", "esse", "essa", "e", "em", "por", "pelo", "pela", "ao",
    ]

    /// Words that open a line before the name being called.
    private static let greetings: Set<String> = [
        "o", "oi", "oii", "oie", "ei", "ou", "eai", "fala", "salve", "hey", "hi", "bom", "boa", "dia", "tarde", "noite",
        "valeu", "obrigado", "obrigada", "parabens", "calma", "la", "ne", "mano", "olha", "vem", "bora",
    ]

    /// The line of a moment that holds some words, and who wrote it.
    static func line(holding words: String, in text: String) -> (sender: String, body: String)? {
        let needle = words.folded
        guard needle.count >= 2 else { return nil }
        for line in text.split(separator: "\n").map(String.init) {
            guard line.folded.contains(needle) else { continue }
            // "[2026-01-02 10:00] Sender: text"
            guard let close = line.range(of: "] "), let colon = line.range(of: ": ", range: close.upperBound..<line.endIndex)
            else { continue }
            return (String(line[close.upperBound..<colon.lowerBound]), String(line[colon.upperBound...]))
        }
        return nil
    }

    /// Whether the line calls someone by `nickname`: at its start (after a
    /// greeting), or at its end without an article before it.
    static func isVocative(_ nickname: String, in body: String) -> Bool {
        let words = body.wordList
        let name = nickname.wordList
        guard !name.isEmpty, words.count >= name.count else { return false }
        if Array(words.suffix(name.count)) == name {
            let before = words.dropLast(name.count).last
            return before.map { !references.contains($0) } ?? true
        }
        var start = 0
        while start < words.count - name.count, start < 3, greetings.contains(words[start]) { start += 1 }
        return Array(words[start..<min(words.count, start + name.count)]) == name
    }

    /// Whose nickname it really is. A model says "`nickname` is what
    /// `claimed` is called"; the words that use it say who wrote them, and
    /// nobody calls themselves by a nickname across a table.
    static func judge(nickname: String, claimed: String, evidence: String, in chunk: MemoryChunk, me: String) -> Verdict {
        let found = line(holding: evidence, in: chunk.text) ?? line(holding: nickname, in: chunk.text)
        guard let found else { return Verdict(owner: owner(claimed, me: me), trusted: false) }
        let sender = found.sender
        let senderIsMe = sender.folded == me.folded
        let body = " " + found.body.folded + " "
        let declared = declarations.contains { body.contains($0) }

        // "meu apelido era Jesse": theirs, by their own word.
        if declared, body.contains("meu apelido") || body.contains("me cham") || body.contains("call me") || body.contains("my nickname") {
            return Verdict(owner: senderIsMe ? .me : .person(sender), trusted: true)
        }
        var owner = owner(claimed, me: me)
        // A word that is the name of someone else in the conversation is
        // that person being called, not a nickname of the one claimed.
        if !declared {
            let word = nickname.folded
            let others = (chunk.participants + (chunk.isGroup == false ? [chunk.chatName] : []))
                .filter { $0.folded != claimed.folded && $0.folded != sender.folded }
            if others.contains(where: { PersonName.clean($0).wordList.contains(word) }) {
                return Verdict(owner: .nobody, trusted: false)
            }
        }
        if claimed.folded == sender.folded {
            if declared { return Verdict(owner: owner, trusted: true) }
            // The writer is calling someone else. Alone with one person,
            // that is the other one; in a group it could be anyone.
            guard chunk.isGroup == false, isVocative(nickname, in: found.body) else {
                return Verdict(owner: .nobody, trusted: false)
            }
            // "clarinha", written by Clara, is Clara talking about herself.
            guard !resembles(nickname, name: sender) else { return Verdict(owner: owner, trusted: false) }
            owner = senderIsMe ? .person(chunk.chatName) : .me
        }
        let present: Bool
        switch owner {
        case .me: present = true
        case .person(let name):
            present = (chunk.participants + (chunk.isGroup == false ? [chunk.chatName] : [])).contains { $0.folded == name.folded }
        case .nobody: present = false
        }
        // What the user is called once in passing (a tease, an endearment)
        // is not yet their nickname; a second time makes it one.
        if owner == .me { return Verdict(owner: .me, trusted: declared) }
        return Verdict(owner: owner, trusted: declared || (present && isVocative(nickname, in: found.body)))
    }

    /// Whether a nickname is made from a name: "clarinha" from Clara,
    /// "dayvidd" from Dayvid.
    static func resembles(_ nickname: String, name: String) -> Bool {
        let words = PersonName.clean(name).wordList.filter { $0.count >= 3 }
        return nickname.wordList.contains { part in
            words.contains { word in
                part.hasPrefix(word.prefix(4)) || word.hasPrefix(part.prefix(4)) || PersonName.likeness(part, word) >= 0.85
            }
        }
    }

    private static func owner(_ claimed: String, me: String) -> Owner {
        claimed.folded == me.folded ? .me : .person(claimed)
    }

    /// Whether the word can be anyone's nickname at all.
    static func isPlausible(_ nickname: String) -> Bool {
        let alias = nickname.folded
        guard alias.count >= 2, alias.count <= 30, alias.contains(where: \.isLetter) else { return false }
        if MemoryStore.genericNicknames.contains(alias) || MemoryStore.stopwords.contains(alias) { return false }
        if KnowledgeGraph.notNames.contains(alias) { return false }
        return !alias.wordList.allSatisfy { MemoryStore.genericNicknames.contains($0) || PersonName.descriptors.contains($0) }
    }
}

// MARK: - Store

extension MemoryStore {
    /// The id the user has in links and nicknames. Never a row in `people`:
    /// the user is not someone to tag or to look up by name.
    nonisolated static let me: Int64 = 0

    // MARK: Closeness

    /// How close each person is: how much you write to each other, and how
    /// recently. Used to order every answer to "who is Ana?".
    func salience() throws -> [Int64: Double] {
        if let (date, cached) = salienceCache, Date().timeIntervalSince(date) < 300 { return cached }
        let db = try open()
        let now = Date().timeIntervalSince1970
        var result: [Int64: Double] = [:]
        try db.rows(
            """
            SELECT cp.person_id, cp.role, c.msg_count, c.last_ts FROM chat_people cp
            JOIN chats c ON c.source = cp.source AND c.chat_id = cp.chat_id WHERE cp.role IN ('direct', 'member')
            """
        ) { row in
            let id = Int64(row.int(0))
            let age = max(0, now - row.double(3)) / 86400
            let recent = 0.25 + 0.75 * pow(0.5, age / 240)
            if row.text(1) == "direct" {
                result[id, default: 0] += log1p(Double(row.int(2))) * recent
            } else {
                // Sharing a group is a little closeness, capped.
                result[id, default: 0] += min(0.25, 0.05 * recent)
            }
        }
        // Whoever you have a tie with matters, however little you write.
        try db.rows("SELECT a, b, confidence FROM person_links WHERE (a = 0 OR b = 0) AND ended_ts IS NULL") { row in
            let other = Int64(row.int(0)) == Self.me ? Int64(row.int(1)) : Int64(row.int(0))
            result[other, default: 0] += 2 * row.double(2)
        }
        salienceCache = (.now, result)
        return result
    }

    /// People before groups, the closest first.
    func closestFirst(_ refs: [PersonRef]) throws -> [PersonRef] {
        guard refs.count > 1 else { return refs }
        let close = try salience()
        func rank(_ list: [PersonRef]) -> [PersonRef] {
            list.sorted { a, b in
                let x = close[a.id] ?? 0, y = close[b.id] ?? 0
                return x == y ? a.name < b.name : x > y
            }
        }
        return rank(refs.filter { $0.kind == .person }) + refs.filter { $0.kind == .group }
    }

    // MARK: Who a sentence is about

    nonisolated struct Mention: Sendable, Hashable {
        var ref: PersonRef
        /// The words that pointed at them.
        var alias: String
        /// Others the same words could mean, closest first.
        var others: [PersonRef]
    }

    /// The people a sentence names, by any name they go by: full name,
    /// first name, nickname. A name several people share goes to the
    /// closest one (or to someone already in the conversation, `near`), and
    /// the others are listed so the reader can say it was a guess.
    func peopleMentioned(in text: String, near: Set<Int64> = [], limit: Int = 6) throws -> [Mention] {
        let all = try aliases()
        guard !all.isEmpty else { return [] }
        let longest = min(5, all.keys.map { $0.split(separator: " ").count }.max() ?? 1)
        let close = try salience()
        let mine = Set(try myNicknames().map(\.folded) + [AppSettings.myNameSnapshot.folded])
        let words = text.wordList
        var found: [Mention] = []
        var seen = Set<Int64>()
        var index = 0
        while index < words.count, found.count < limit {
            var step = 1
            for length in stride(from: min(longest, words.count - index), through: 1, by: -1) {
                let key = words[index..<(index + length)].joined(separator: " ")
                guard key.count >= 3, !mine.contains(key), let refs = all[key] else { continue }
                if length == 1, Self.isCommonWord(key) { continue }
                var people = Array(Set(refs.filter { $0.kind == .person }))
                // A group only by its whole name of several words.
                if people.isEmpty, length >= 2 {
                    people = Array(Set(refs.filter { $0.kind == .group && $0.name.folded == key }))
                }
                guard !people.isEmpty else { continue }
                func weight(_ ref: PersonRef) -> Double {
                    let base: Double = close[ref.id] ?? 0
                    return near.contains(ref.id) ? base + 100 : base
                }
                people.sort { a, b in
                    let x = weight(a), y = weight(b)
                    return x == y ? a.name < b.name : x > y
                }
                if seen.insert(people[0].id).inserted {
                    found.append(Mention(ref: people[0], alias: key, others: Array(people.dropFirst().prefix(4))))
                }
                step = length
                break
            }
            index += step
        }
        return found
    }

    /// A word too common to be taken for someone's name on its own.
    nonisolated static func isCommonWord(_ word: String) -> Bool {
        stopwords.contains(word) || KnowledgeGraph.notNames.contains(word) || genericNicknames.contains(word)
            || PersonName.descriptors.contains(word)
    }

    // MARK: Nicknames

    nonisolated struct Nickname: Sendable, Hashable {
        var alias: String
        var folded: String
        var count: Int
        var evidence: String?
    }

    /// What the user is called by others.
    func myNicknames() throws -> [Nickname] {
        try nicknames(of: Self.me)
    }

    /// The nicknames someone really goes by, most heard first.
    func nicknames(of id: Int64, limit: Int = 8) throws -> [Nickname] {
        var result: [Nickname] = []
        try open().rows(
            "SELECT alias, folded, count, evidence FROM person_aliases WHERE person_id = ? AND kind = 'nickname' ORDER BY count DESC, alias LIMIT ?",
            [.int(id), .of(limit)]
        ) { row in
            result.append(Nickname(alias: row.text(0) ?? "", folded: row.text(1) ?? "", count: row.int(2), evidence: row.text(3)))
        }
        return result
    }

    /// Saves a name someone goes by. `trusted` makes it a nickname at once;
    /// otherwise it is only "heard" until it is heard a second time. A
    /// misspelling of their own name is kept to recognise them, not to show.
    @discardableResult
    func learnNickname(_ nickname: String, forID id: Int64, name: String, evidence: String?, trusted: Bool,
                       at date: Date = .now, uses: Int = 1) throws -> Bool {
        let alias = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Nicknames.isPlausible(alias) else { return false }
        let folded = alias.folded
        // Their own name, whole or in part, is not a nickname.
        let own = Set(PersonName.clean(name).wordList)
        if folded == name.folded || folded == PersonName.clean(name).folded
            || (alias.wordList.count == 1 && own.contains(folded)) { return false }
        let kind = PersonName.isMisspelling(alias, of: name) ? "spelling" : (trusted ? "nickname" : "heard")
        try open().run(
            """
            INSERT INTO person_aliases(person_id, alias, folded, kind, evidence, count, ts) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(person_id, folded) DO UPDATE SET
                count = count + excluded.count, ts = MAX(COALESCE(ts, 0), excluded.ts),
                evidence = COALESCE(evidence, excluded.evidence),
                kind = CASE WHEN kind = 'heard' THEN 'nickname' WHEN kind = 'mentioned' THEN excluded.kind ELSE kind END
            """,
            [.int(id), .text(alias), .text(folded), .text(kind), evidence.map { .text($0) } ?? .null,
             .of(max(1, uses)), .double(date.timeIntervalSince1970)])
        aliasCache = nil
        return true
    }

    /// Whether how often a word is used can say it is a nickname: not a
    /// short or common word, and not the name of somebody else, which is
    /// written all the time for other reasons.
    func usageCounts(for alias: String, person id: Int64) throws -> Bool {
        let folded = alias.folded
        guard folded.count >= 4, !Self.isCommonWord(folded) else { return false }
        return try open().scalarInt(
            "SELECT COUNT(*) FROM person_aliases WHERE folded = ? AND person_id != ? AND kind IN ('name', 'first_name')",
            [.text(folded), .int(id)]) == 0
    }

    /// In how many moments a name is used: in one chat, or wherever
    /// someone is (their own chat and the groups they write in).
    func uses(of alias: String, inChat chat: (source: MemorySource, id: String)? = nil, with name: String? = nil) throws -> Int {
        let words = alias.wordList
        guard !words.isEmpty else { return 0 }
        let match = "text: \"" + words.joined(separator: " ") + "\""
        if let chat {
            return try open().scalarInt(
                "SELECT COUNT(*) FROM chunks_fts f JOIN chunks c ON c.id = f.rowid WHERE chunks_fts MATCH ? AND c.source = ? AND c.chat_id = ?",
                [.text(match), .text(chat.source.rawValue), .text(chat.id)])
        }
        guard let name else { return 0 }
        return try open().scalarInt(
            "SELECT COUNT(*) FROM chunks_fts f JOIN chunks c ON c.id = f.rowid WHERE chunks_fts MATCH ? AND (c.chat_name = ? OR c.participants LIKE ?)",
            [.text(match), .text(name), .text("%\(name)%")])
    }

    // MARK: One person, two entries

    /// Makes `id` and `target` one person, under `target`. Everything that
    /// was said by or about the first is now the second's: messages and
    /// moments are rewritten with the name, so nothing brings the old entry
    /// back, and the old name stays as a way to find them.
    func mergePerson(_ id: Int64, into target: Int64) throws {
        guard id != target, id != Self.me, target != Self.me,
              let old = try person(id: id), let new = try person(id: target),
              old.kind == .person, new.kind == .person else { return }
        let db = try open()
        try db.transaction {
            try db.run("INSERT OR REPLACE INTO person_names(old, new) VALUES (?, ?)", [.text(old.name), .text(new.name)])
            // Earlier renames that pointed at the old name follow it.
            try db.run("UPDATE person_names SET new = ? WHERE new = ?", [.text(new.name), .text(old.name)])
            try movePerson(db, from: id, to: target, oldName: old.name, newName: new.name)
        }
        nameOverrides = nil
        try rename([old.name: new.name])
    }

    /// Moves everything filed under one person to another, and removes the
    /// first. The caller renames messages and moments.
    func movePerson(_ db: SQLiteDB, from id: Int64, to target: Int64, oldName: String, newName: String) throws {
        // The old name finds the person from now on; what was a nickname stays one.
        try db.run("UPDATE person_aliases SET kind = 'name' WHERE person_id = ? AND folded = ?", [.int(id), .text(oldName.folded)])
        for table in ["person_aliases", "chat_people"] {
            try db.run("UPDATE OR IGNORE \(table) SET person_id = ? WHERE person_id = ?", [.int(target), .int(id)])
            try db.run("DELETE FROM \(table) WHERE person_id = ?", [.int(id)])
        }
        for side in ["a", "b"] {
            try db.run("UPDATE OR IGNORE person_links SET \(side) = ? WHERE \(side) = ?", [.int(target), .int(id)])
            try db.run("DELETE FROM person_links WHERE \(side) = ?", [.int(id)])
        }
        try db.run("DELETE FROM person_links WHERE a = b")
        try db.run("UPDATE OR IGNORE facts SET subject = ?, subject_id = ? WHERE subject_id = ? OR subject = ?",
                   [.text(newName), .int(target), .int(id), .text(oldName)])
        try db.run("DELETE FROM facts WHERE subject_id = ? OR subject = ?", [.int(id), .text(oldName)])
        try db.run("UPDATE OR IGNORE facts SET object = ? WHERE object = ?", [.text(newName), .text(oldName)])
        try db.run("DELETE FROM person_pairs WHERE a = ? OR b = ?", [.int(id), .int(id)])
        try db.run("DELETE FROM people WHERE id = ?", [.int(id)])
        // A name that is also a nickname of the same person says nothing.
        try db.run("DELETE FROM person_aliases WHERE person_id = ? AND kind IN ('nickname', 'heard', 'spelling') AND folded = ?",
                   [.int(target), .text(newName.folded)])
        aliasCache = nil
        salienceCache = nil
    }

    /// Names that were decided to be someone else's ("+55 91 9…" is Dayvid):
    /// applied to every message as it is read, so a decision holds.
    func overrides() throws -> [String: String] {
        if let nameOverrides { return nameOverrides }
        var result: [String: String] = [:]
        try open().rows("SELECT old, new FROM person_names") { result[$0.text(0) ?? ""] = $0.text(1) ?? "" }
        nameOverrides = result
        return result
    }

    /// Rewrites a person's name everywhere it is stored: messages, chats,
    /// moments (kept in step with the word index), reflections and the graph.
    func rename(_ names: [String: String]) throws {
        let names = names.filter { !$0.key.isEmpty && !$0.value.isEmpty && $0.key != $0.value }
        guard !names.isEmpty else { return }
        let db = try open()
        var chunkIDs = Set<Int64>()
        try db.transaction {
            for (old, new) in names {
                try db.rows("SELECT id FROM chunks WHERE participants LIKE ? OR chat_name = ?",
                            [.text("%\(old)%"), .text(old)]) { chunkIDs.insert(Int64($0.int(0))) }
                try db.run("UPDATE messages SET sender = ? WHERE sender = ? AND is_me = 0", [.text(new), .text(old)])
                try db.run("UPDATE messages SET chat_name = ? WHERE chat_name = ? AND is_group = 0", [.text(new), .text(old)])
                try db.run("UPDATE chats SET name = ? WHERE name = ? AND is_group = 0", [.text(new), .text(old)])
                try db.run("UPDATE reflections SET chat = ? WHERE chat = ?", [.text(new), .text(old)])
                if old.count >= 4 {
                    try db.run("UPDATE reflections SET people = replace(people, ?, ?), summary = replace(summary, ?, ?), title = replace(title, ?, ?) WHERE people LIKE ?",
                               [.text(old), .text(new), .text(old), .text(new), .text(old), .text(new), .text("%\(old)%")])
                }
                // The graph is redrawn from the moments; the old node goes.
                var entity: Int64?
                try db.rows("SELECT id FROM entities WHERE key = ?", [.text(Self.entityKey(kind: .person, name: old))]) {
                    entity = Int64($0.int(0))
                }
                if let entity {
                    try db.run("DELETE FROM edges WHERE src = ? OR dst = ?", [.int(entity), .int(entity)])
                    try db.run("DELETE FROM entities WHERE id = ?", [.int(entity)])
                }
            }
        }
        let ids = Array(chunkIDs)
        for start in stride(from: 0, to: ids.count, by: 300) {
            try rerender(chunks: Array(ids[start..<min(start + 300, ids.count)]))
        }
        nameCache.removeAll()
    }

    /// Writes moments again from their messages, as they are now named.
    /// The moment keeps its id (and so its facts, reflections and whether
    /// it was read); its meaning is embedded again and its graph redrawn.
    /// `relearn` also has it read again, for moments learned under a name
    /// that turned out to be several people.
    @discardableResult
    func rerender(chunks ids: [Int64], relearn: Bool = false) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let db = try open()
        var changed = 0
        try db.transaction {
            var rows: [(Int64, String, String, Double, Double, String, String, String)] = []
            try db.rows("SELECT id, source, chat_id, start_ts, end_ts, text, chat_name, participants FROM chunks WHERE id IN (\(ids.map(String.init).joined(separator: ",")))") { row in
                rows.append((Int64(row.int(0)), row.text(1) ?? "", row.text(2) ?? "", row.double(3), row.double(4),
                             row.text(5) ?? "", row.text(6) ?? "", row.text(7) ?? ""))
            }
            for (id, source, chatID, start, end, oldText, oldChat, oldParticipants) in rows {
                var lines: [String] = []
                var senders: [String] = []
                var chat = oldChat
                try db.rows("SELECT ts, sender, text, chat_name FROM messages WHERE source = ? AND chat_id = ? AND ts >= ? AND ts <= ? ORDER BY ts",
                            [.text(source), .text(chatID), .double(start), .double(end)]) { row in
                    let sender = row.text(1) ?? "?"
                    lines.append("[\(Self.stamp(row.double(0)))] \(sender): \(row.text(2) ?? "")")
                    if !senders.contains(sender) { senders.append(sender) }
                    chat = row.text(3) ?? chat
                }
                guard !lines.isEmpty else { continue }
                let text = lines.joined(separator: "\n")
                let participants = senders.joined(separator: "\u{1F}")
                guard text != oldText || chat != oldChat || participants != oldParticipants else { continue }
                try db.run("INSERT INTO chunks_fts(chunks_fts, rowid, text, chat_name) VALUES ('delete', ?, ?, ?)",
                           [.int(id), .text(oldText), .text(oldChat)])
                try db.run("UPDATE chunks SET text = ?, chat_name = ?, participants = ?, graphed = 0\(relearn ? ", learned = 0" : "") WHERE id = ?",
                           [.text(text), .text(chat), .text(participants), .int(id)])
                try db.run("INSERT INTO chunks_fts(rowid, text, chat_name) VALUES (?, ?, ?)", [.int(id), .text(text), .text(chat)])
                try db.run("DELETE FROM vectors WHERE chunk_id = ?", [.int(id)])
                changed += 1
            }
        }
        if changed > 0 { dropVectorCache() }
        return changed
    }

    // MARK: Maybe the same person

    nonisolated struct Pair: Sendable, Hashable, Identifiable {
        var a: PersonRef
        var b: PersonRef
        var score: Double
        var reason: String

        var id: String { "\(a.id)-\(b.id)" }
    }

    /// Pairs that look like one person, not yet settled.
    func maybePairs(limit: Int = 40) throws -> [Pair] {
        var result: [Pair] = []
        try open().rows(
            """
            SELECT x.a, pa.name, x.b, pb.name, x.score, COALESCE(x.reason, '') FROM person_pairs x
            JOIN people pa ON pa.id = x.a JOIN people pb ON pb.id = x.b
            WHERE x.state = 'maybe' ORDER BY x.score DESC LIMIT ?
            """, [.of(limit)]
        ) { row in
            result.append(Pair(a: PersonRef(id: Int64(row.int(0)), kind: .person, name: row.text(1) ?? ""),
                               b: PersonRef(id: Int64(row.int(2)), kind: .person, name: row.text(3) ?? ""),
                               score: row.double(4), reason: row.text(5) ?? ""))
        }
        return result
    }

    /// Records that two entries are (or are not) one person. "different"
    /// is remembered so the question is not asked again.
    func setPair(_ a: Int64, _ b: Int64, state: String, score: Double = 0, reason: String? = nil) throws {
        let (first, second) = a < b ? (a, b) : (b, a)
        try open().run(
            """
            INSERT INTO person_pairs(a, b, state, score, reason, ts) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(a, b) DO UPDATE SET
                state = CASE WHEN state = 'different' AND excluded.state = 'maybe' THEN state ELSE excluded.state END,
                score = excluded.score, reason = COALESCE(excluded.reason, reason), ts = excluded.ts
            """,
            [.int(first), .int(second), .text(state), .double(score), reason.map { .text($0) } ?? .null,
             .double(Date().timeIntervalSince1970)])
    }

    /// What is needed to compare people: names, where they are, ties.
    nonisolated struct PersonCard: Sendable {
        var ref: PersonRef
        var clean: String
        var names: [String] = []
        var nicknames: [String] = []
        var direct: Set<String> = []
        var groups: Set<String> = []
        var ties: Set<String> = []
        var isPlaceholder: Bool { PersonName.isPlaceholder(ref.name) }
    }

    func personCards() throws -> [Int64: PersonCard] {
        let db = try open()
        var cards: [Int64: PersonCard] = [:]
        try db.rows("SELECT id, name FROM people WHERE kind = 'person'") { row in
            let ref = PersonRef(id: Int64(row.int(0)), kind: .person, name: row.text(1) ?? "")
            cards[ref.id] = PersonCard(ref: ref, clean: PersonName.clean(ref.name))
        }
        try db.rows("SELECT person_id, alias, kind FROM person_aliases") { row in
            let id = Int64(row.int(0))
            guard let alias = row.text(1) else { return }
            switch row.text(2) {
            case "nickname", "heard", "spelling": cards[id]?.nicknames.append(alias)
            default: cards[id]?.names.append(alias)
            }
        }
        try db.rows("SELECT person_id, source, chat_id, role FROM chat_people WHERE role IN ('direct', 'member')") { row in
            let id = Int64(row.int(0))
            let key = "\(row.text(1) ?? "")|\(row.text(2) ?? "")"
            if row.text(3) == "direct" { cards[id]?.direct.insert(row.text(1) ?? "") } else { cards[id]?.groups.insert(key) }
        }
        try db.rows("SELECT a, b, kind FROM person_links WHERE kind IN ('partner', 'ex', 'sibling', 'parent', 'family', 'bestFriend')") { row in
            let a = Int64(row.int(0)), b = Int64(row.int(1)), kind = row.text(2) ?? ""
            cards[a]?.ties.insert("\(kind):\(b)")
            cards[b]?.ties.insert("\(kind):\(a)")
        }
        return cards
    }

    /// How likely two entries are one person, and why. Nil when there is
    /// nothing pointing that way. 1 means their cleaned names are equal.
    ///
    /// `owners` says how many people have each word in their name: being
    /// called "Pedro" points at nobody when there are nine Pedros.
    nonisolated static func likeness(_ x: PersonCard, _ y: PersonCard, owners: [String: Int] = [:]) -> (score: Double, reason: String)? {
        let a = x.clean.folded, b = y.clean.folded
        guard !a.isEmpty, !b.isEmpty else { return nil }
        var score = 0.0
        var reasons: [String] = []
        let wordsA = a.wordList, wordsB = b.wordList
        if a == b, !x.isPlaceholder {
            // A whole name is one person; a lone first name ("Ana" and
            // "Ana 🌸") may well be two.
            score = wordsA.count > 1 ? 1 : 0.7
            reasons.append("same name once emoji and marks are removed")
        } else if !x.isPlaceholder, !y.isPlaceholder {
            let like = PersonName.likeness(a, b)
            let sameFirst = wordsA.first == wordsB.first
            // Only with the same first name: "Gabriel Silva" and "Gabriela
            // Silva", "Maria" and "Mariana" are different people, however
            // alike the letters.
            if sameFirst, wordsA.count > 1, wordsB.count > 1, like >= 0.93 {
                score = 0.7
                reasons.append("names almost equal")
            } else if sameFirst, wordsA.count != wordsB.count, Set(wordsA).isSubset(of: Set(wordsB)) || Set(wordsB).isSubset(of: Set(wordsA)) {
                score = 0.45
                reasons.append("one name is the other plus a surname")
            }
        }
        // A nickname of one that is the other's name: "+55 91 9…" called
        // "deyviy" beside a Dayvid.
        func called(_ card: PersonCard, like other: PersonCard) -> Double {
            // A name both already have says nothing: every Pedro is "Pedrinho".
            let own = Set(card.clean.wordList)
            let targets = other.clean.wordList.filter { $0.count >= 4 && !own.contains($0) && (owners[$0] ?? 1) <= 2 }
            var best = 0.0
            for nickname in card.nicknames.map(\.folded) where nickname.count >= 3 {
                for target in targets {
                    if nickname == target { best = max(best, 0.6) }
                    else if PersonName.likeness(nickname, target) >= 0.8 { best = max(best, 0.45) }
                    else if target.hasPrefix(nickname) { best = max(best, 0.3) }
                }
            }
            return best
        }
        let nick = max(called(x, like: y), called(y, like: x))
        if nick > 0 {
            score += nick + (x.isPlaceholder != y.isPlaceholder ? 0.1 : 0)
            reasons.append("one is called by the other's name")
        }
        guard score > 0 else { return nil }
        // The same girlfriend, the same mother: strong; the same groups: weak.
        func others(_ card: PersonCard, _ other: Int64) -> Set<String> { card.ties.filter { !$0.hasSuffix(":\(other)") } }
        if !others(x, y.ref.id).isDisjoint(with: others(y, x.ref.id)) {
            score += 0.25
            reasons.append("tied to the same person")
        }
        if !x.groups.isDisjoint(with: y.groups) {
            // Two members of one group are two accounts; rarely one person.
            score -= 0.2
            reasons.append("both write in the same group")
        }
        // Two chats of their own on the same app are two numbers.
        if !x.direct.isDisjoint(with: y.direct) { score -= 0.15 }
        return score >= 0.55 ? (min(1, score), reasons.joined(separator: "; ")) : nil
    }

    /// Looks at everyone for entries that are one person. Sure ones (the
    /// same name once cleaned, never both with a chat of their own) are
    /// returned to merge; likely ones become maybes to settle later.
    func findDuplicates() throws -> (sure: [(from: Int64, into: Int64)], maybes: Int) {
        let cards = try personCards()
        let close = try salience()
        var settled = Set<String>()
        try open().rows("SELECT a, b FROM person_pairs WHERE state != 'maybe'") { settled.insert("\($0.int(0))-\($0.int(1))") }
        // Only people who share a word of a name or nickname are compared.
        var blocks: [String: [Int64]] = [:]
        for card in cards.values {
            var keys = Set(card.clean.wordList.filter { $0.count >= 3 })
            keys.formUnion(card.nicknames.flatMap(\.wordList).filter { $0.count >= 3 })
            for key in keys { blocks[String(key.prefix(4)), default: []].append(card.ref.id) }
        }
        var owners: [String: Int] = [:]
        for card in cards.values {
            for word in Set(card.clean.wordList) { owners[word, default: 0] += 1 }
        }
        var sure: [(from: Int64, into: Int64)] = []
        var merged = Set<Int64>()
        var maybes = 0
        var seen = Set<String>()
        for ids in blocks.values where ids.count > 1 && ids.count <= 60 {
            for i in ids.indices {
                for j in ids.indices where j > i {
                    let (first, second) = ids[i] < ids[j] ? (ids[i], ids[j]) : (ids[j], ids[i])
                    let key = "\(first)-\(second)"
                    guard first != second, seen.insert(key).inserted, !settled.contains(key),
                          let x = cards[first], let y = cards[second],
                          let (score, reason) = Self.likeness(x, y, owners: owners) else { continue }
                    if score >= 1, x.direct.isDisjoint(with: y.direct), !merged.contains(first), !merged.contains(second) {
                        // Into the one you actually talk to; else the one named first.
                        let keepFirst = (close[first] ?? 0) >= (close[second] ?? 0)
                        sure.append(keepFirst ? (second, first) : (first, second))
                        merged.insert(first)
                        merged.insert(second)
                    } else if !merged.contains(first), !merged.contains(second) {
                        try setPair(first, second, state: "maybe", score: min(score, 0.95), reason: reason)
                        maybes += 1
                    }
                }
            }
        }
        return (sure, maybes)
    }

    // MARK: The people who matter, always in mind

    /// The few people closest to the user, one line each: tag, name, what
    /// they are called, what they are to the user, who they are with. Small
    /// enough to ride along with every conversation, so "o Garicas" or
    /// "minha mãe" never needs a search.
    func peopleBrief(limit: Int = 16) throws -> String {
        let close = try salience()
        let mine = try myLinks(limit: 400)
        var order: [Int64] = []
        // Whoever has a tie that still holds, then whoever the user talks to most.
        for link in mine where link.isCurrent && link.other.kind == .person && !order.contains(link.other.id) {
            order.append(link.other.id)
        }
        let tied = Array(order.prefix(limit / 2))
        order = tied
        for id in close.sorted(by: { $0.value > $1.value }).map(\.key) where !order.contains(id) && order.count < limit {
            guard (close[id] ?? 0) >= 2 else { break }
            order.append(id)
        }
        var lines: [String] = []
        let called = try myNicknames().prefix(6).map(\.alias)
        if !called.isEmpty {
            lines.append("- \(AppSettings.myNameSnapshot) (the user) is also called " + called.joined(separator: ", "))
        }
        for id in order {
            guard let ref = try person(id: id), ref.kind == .person, !PersonName.looksEncoded(ref.name) else { continue }
            let nicknames = try nicknames(of: id, limit: 4).map(\.alias)
            // Someone known only by a number is in mind once there is a
            // name to call them by.
            if PersonName.isPlaceholder(ref.name), nicknames.isEmpty { continue }
            var line = "\(ref.tag) \(ref.name)"
            if !nicknames.isEmpty { line += " (also called " + nicknames.joined(separator: ", ") + ")" }
            var about = mine.filter { $0.other.id == id }.prefix(2).map(\.toUser)
            // Who they are with, and what is said about that.
            about += try links(of: id, limit: 6).filter { [.partner, .ex, .sibling, .parent].contains($0.kind) && $0.confidence >= 0.6 }
                .prefix(2).map { "\($0.phrase) \($0.other.tag) \($0.other.name) (\($0.when))" }
            if let status = try profile(of: ref, limit: 40).first(where: {
                $0.kind == .relationship && $0.ended == nil && $0.confidence >= 0.6 && Self.isPlainValue($0.object)
                    && $0.predicate.wordList.count <= 3
            }) {
                about.append("\(status.predicate) \(status.object) (\(String(MemoryStore.stamp(status.date.timeIntervalSince1970).prefix(10))))")
            }
            if !about.isEmpty { line += ": " + about.joined(separator: "; ") }
            lines.append("- " + line)
        }
        return lines.joined(separator: "\n")
    }

    /// Nicknames by the folded name of who has them, for lists of people.
    func nicknamesByName() throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        try open().rows(
            """
            SELECT p.name, a.alias FROM person_aliases a JOIN people p ON p.id = a.person_id
            WHERE a.kind = 'nickname' AND p.kind = 'person' ORDER BY a.count DESC
            """
        ) { row in
            let key = (row.text(0) ?? "").folded
            if result[key, default: []].count < 4, let alias = row.text(1) { result[key, default: []].append(alias) }
        }
        return result
    }
}

/// Keeps the always-in-mind list of people current.
enum PeopleBrief {
    static func refresh() async {
        guard let brief = try? await MemoryStore.shared.peopleBrief() else { return }
        if AppSettings.shared.peopleBrief != brief { AppSettings.shared.peopleBrief = brief }
    }
}
