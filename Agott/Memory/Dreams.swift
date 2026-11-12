import Foundation
import FoundationModels
import Observation

/// Dreams: memory going over itself while nobody is asking it anything.
///
/// Reading conversations adds to memory; it never looks back. So memory
/// drifts: one person under three names, a nickname filed under the wrong
/// friend, a couple that broke up a year ago still "dating". A dream is the
/// pass that looks back and puts things where they belong:
///
/// 1. **Names.** Every stored message gets the name its sender has today.
/// 2. **Who is who.** Names without their emoji, nicknames checked against
///    the words that used them, entries that are one person joined, and
///    lookalikes set aside as maybes.
/// 3. **Time.** What ended is marked as ended; a newer answer replaces the
///    older one. Nothing is deleted for being old.
/// 4. **Facts.** The same thing said twice becomes one fact.
/// 5. **Maybes.** With a model at hand, pairs that look like one person are
///    judged with everything known about both, and joined only when sure.
/// 6. **In mind.** The short list of people every conversation starts
///    from is written again.
///
/// It runs by itself once a day after memory updates, and on demand.
@Observable
final class Dreams {
    static let shared = Dreams()

    private(set) var isRunning = false
    private(set) var note: String?
    private(set) var last: Report?
    /// Pairs that may be one person, for the user to settle.
    private(set) var maybes: [MemoryStore.Pair] = []

    /// What one dream changed.
    struct Report: Codable, Sendable, Equatable {
        var date: Date
        var named = 0
        var strangers = 0
        var merged: [String] = []
        var dropped = 0
        var nicknamesFixed = 0
        var nicknamesMine = 0
        var linksEnded = 0
        var factsEnded = 0
        var factsMerged = 0
        var settled: [String] = []
        var maybes = 0
        var reread = 0

        var changedAnything: Bool {
            named + strangers + merged.count + dropped + nicknamesFixed + nicknamesMine + linksEnded + factsEnded
                + factsMerged + settled.count > 0
        }

        /// What happened, one line each, for people to read.
        var lines: [String] {
            func count(_ n: Int, _ one: String, _ many: String) -> String? { n == 0 ? nil : (n == 1 ? one : many) }
            var lines = [
                count(named, String(localized: "1 message got its sender's real name"),
                      String(localized: "\(named) messages got their sender's real name")),
                count(strangers, String(localized: "1 name that was really several people was told apart"),
                      String(localized: "\(strangers) names that were really several people were told apart")),
                count(merged.count + settled.count, String(localized: "2 entries that were one person were joined"),
                      String(localized: "\(merged.count + settled.count) pairs of entries that were one person were joined")),
                count(nicknamesFixed, String(localized: "1 nickname went back to who it belongs to"),
                      String(localized: "\(nicknamesFixed) nicknames went back to who they belong to")),
                count(nicknamesMine, String(localized: "1 nickname turned out to be yours"),
                      String(localized: "\(nicknamesMine) nicknames turned out to be yours")),
                count(linksEnded, String(localized: "1 relationship marked as over"),
                      String(localized: "\(linksEnded) relationships marked as over")),
                count(factsEnded, String(localized: "1 fact replaced by a newer one"),
                      String(localized: "\(factsEnded) facts replaced by newer ones")),
                count(factsMerged, String(localized: "1 repeated fact merged"),
                      String(localized: "\(factsMerged) repeated facts merged")),
                count(dropped, String(localized: "1 entry that named nobody was removed"),
                      String(localized: "\(dropped) entries that named nobody were removed")),
                count(reread, String(localized: "1 moment will be read again with the right names"),
                      String(localized: "\(reread) moments will be read again with the right names")),
            ].compactMap { $0 }
            if lines.isEmpty { lines.append(String(localized: "Everything was already in place.")) }
            return lines
        }
    }

    private init() {}

    /// Loads the last dream and what is waiting to be settled.
    func load() async {
        let store = MemoryStore.shared
        if let (json, _) = try? await store.insight(key: "dream"), let data = json.data(using: .utf8) {
            last = try? JSONDecoder().decode(Report.self, from: data)
        }
        maybes = (try? await store.maybePairs(limit: 6)) ?? []
    }

    var isDue: Bool {
        let settings = AppSettings.shared
        return settings.dreams && Date().timeIntervalSince1970 - settings.lastDream > 20 * 3600
    }

    /// Dreams if a day has passed since the last one.
    func runIfDue() {
        guard isDue, !isRunning, !LaunchOptions.isDemo else { return }
        Task(priority: .utility) { await run() }
    }

    /// Answers a maybe: the two entries are one person, or they are not.
    func settle(_ pair: MemoryStore.Pair, same: Bool) async {
        let store = MemoryStore.shared
        if same {
            let (from, into) = await Self.direction(pair.a, pair.b)
            try? await store.mergePerson(from.id, into: into.id)
            await PeopleDirectory.shared.refresh()
            await PeopleBrief.refresh()
            Indexer.shared.run()
        } else {
            try? await store.setPair(pair.a.id, pair.b.id, state: "different")
        }
        maybes = (try? await store.maybePairs(limit: 6)) ?? []
    }

    /// Which of two entries stays: the one with a real name, then the one
    /// the user is closest to.
    static func direction(_ a: PersonRef, _ b: PersonRef, in store: MemoryStore = .shared) async -> (from: PersonRef, into: PersonRef) {
        if PersonName.isPlaceholder(a.name) != PersonName.isPlaceholder(b.name) {
            return PersonName.isPlaceholder(a.name) ? (a, b) : (b, a)
        }
        let close = (try? await store.salience()) ?? [:]
        return (close[a.id] ?? 0) >= (close[b.id] ?? 0) ? (b, a) : (a, b)
    }

    @discardableResult
    func run() async -> Report {
        guard !isRunning, !LaunchOptions.isDemo else { return Report(date: .now) }
        isRunning = true
        defer {
            isRunning = false
            note = nil
        }
        let store = MemoryStore.shared
        #if os(macOS)
        let contacts: ContactBook? = await Indexer.shared.contactBook()
        #else
        let contacts: ContactBook? = nil
        #endif
        let deep = AppSettings.shared.autoLearn && ModelHub.isAvailable(ModelHub.learningProvider)
        let report = await Self.dream(in: store, me: AppSettings.shared.myName, contacts: contacts, deep: deep) { [weak self] note in
            self?.note = note
        }
        await PeopleDirectory.shared.refresh()
        await PeopleBrief.refresh()
        if let data = try? JSONEncoder().encode(report), let json = String(data: data, encoding: .utf8) {
            try? await store.saveInsight(json, key: "dream")
        }
        AppSettings.shared.lastDream = Date().timeIntervalSince1970
        last = report
        maybes = (try? await store.maybePairs(limit: 6)) ?? []
        // Moments that changed are understood, drawn and read again.
        if report.named + report.merged.count + report.settled.count > 0 { Indexer.shared.run() }
        return report
    }

    /// One dream over a store. `contacts` is the address book messages are
    /// named from (nil skips renaming); `deep` lets a model settle the maybes.
    static func dream(in store: MemoryStore, me: String, contacts: ContactBook?, deep: Bool,
                      note: (String) -> Void = { _ in }) async -> Report {
        var report = Report(date: .now)

        #if os(macOS)
        if let contacts {
            note(String(localized: "Giving people their right names…"))
            await refreshNames(in: store, contacts: contacts, &report)
        }
        #endif

        note(String(localized: "Working out who is who…"))
        _ = try? await store.syncPeople()
        report.dropped = (try? await store.dropDescriptors()) ?? 0
        _ = try? await store.refreshNameAliases()
        if let nicknames = try? await store.rejudgeNicknames(me: me) {
            report.nicknamesFixed = nicknames.fixed
            report.nicknamesMine = nicknames.mine
        }
        if let found = try? await store.findDuplicates() {
            for (from, into) in found.sure {
                let batch = ContinuousClock.now
                guard let old = try? await store.person(id: from), let new = try? await store.person(id: into) else { continue }
                try? await store.mergePerson(from, into: into)
                report.merged.append("\(old.name) → \(new.name)")
                await Pace.rest(after: batch)
            }
        }

        // "Mãe" and "Pai" in the contacts say who they are.
        _ = try? await store.tiesFromContactNames()

        note(String(localized: "Putting things in their time…"))
        report.linksEnded = (try? await store.settleLinks()) ?? 0
        report.factsEnded = (try? await store.settleFacts()) ?? 0

        note(String(localized: "Tidying up what I know…"))
        let before = (try? await store.totals().facts) ?? 0
        try? await store.cleanFacts(me: me)
        try? await store.linkFactsToPeople()
        report.factsMerged = max(0, before - ((try? await store.totals().facts) ?? before))

        if deep {
            note(String(localized: "Deciding who is the same person…"))
            await settleMaybes(in: store, &report)
        }

        note(String(localized: "Rewriting who matters to you…"))
        _ = try? await store.syncPeople()
        report.maybes = (try? await store.maybePairs(limit: 400).count) ?? 0
        return report
    }

    #if os(macOS)
    /// Asks WhatsApp who wrote each stored message, and rewrites what changed.
    private static func refreshNames(in store: MemoryStore, contacts: ContactBook, _ report: inout Report) async {
        guard WhatsAppSource().isPresent else { return }
        let overrides = (try? await store.overrides()) ?? [:]
        var changes = MemoryStore.NameChanges()
        var after: Int64 = 0
        while !Task.isCancelled {
            let batch = ContinuousClock.now
            guard let page = try? await store.senders(source: .whatsapp, after: after, limit: 2000), let last = page.last else { break }
            after = last.id
            let names = await Task.detached(priority: .utility) { WhatsAppSource.names(of: page, contacts: contacts) }.value
            var writes: [(id: Int64, sender: String, chatName: String)] = []
            for message in page {
                guard let now = names[message.id] else { continue }
                // A name already decided to be someone else's stays decided.
                let sender = overrides[now.sender] ?? now.sender
                let chat = message.isGroup ? now.chatName : (overrides[now.chatName] ?? now.chatName)
                guard sender != message.sender || chat != message.chatName else { continue }
                writes.append((message.id, sender, chat))
                if sender != message.sender { changes.moved[message.sender, default: [:]][sender, default: 0] += 1 }
                if chat != message.chatName { changes.chatNames[message.chatID] = chat }
                changes.chats.insert(message.chatID)
                changes.messages += 1
            }
            try? await store.write(names: writes)
            await Pace.rest(after: batch)
        }
        guard !changes.isEmpty, let outcome = try? await store.settle(changes, source: .whatsapp) else { return }
        report.named = changes.messages
        report.strangers = outcome.split.count
        let again = outcome.chunks.filter { outcome.relearn.contains($0) }
        let plain = outcome.chunks.filter { !outcome.relearn.contains($0) }
        for (ids, relearn) in [(again, true), (plain, false)] {
            for start in stride(from: 0, to: ids.count, by: 300) {
                let batch = ContinuousClock.now
                let changed = (try? await store.rerender(chunks: Array(ids[start..<min(start + 300, ids.count)]), relearn: relearn)) ?? 0
                if relearn { report.reread += changed }
                await Pace.rest(after: batch)
            }
        }
    }
    #endif

    // MARK: Maybes

    @Generable
    struct Verdicts {
        @Guide(description: "One verdict per pair given", .maximumCount(20))
        var verdicts: [Verdict]

        @Generable
        struct Verdict {
            @Guide(description: "The number of the pair, as given in its header")
            var pair: Int
            @Guide(description: "Whether the two entries are the same real person")
            var answer: Answer
            @Guide(description: "How sure, from 0.0 to 1.0", .range(0.0...1.0))
            var confidence: Double
        }

        @Generable
        enum Answer { case same, different, unsure }
    }

    /// Has the learning model judge the likeliest maybes, a dozen at a
    /// time, and joins only the ones it is sure of.
    private static func settleMaybes(in store: MemoryStore, _ report: inout Report) async {
        let pairs = (try? await store.maybePairs(limit: 36)) ?? []
        let provider = ModelHub.learningProvider
        for start in stride(from: 0, to: pairs.count, by: 12) {
            let batch = Array(pairs[start..<min(start + 12, pairs.count)])
            var text = ""
            for (index, pair) in batch.enumerated() {
                let a = (try? await store.describe(pair.a.id)) ?? pair.a.name
                let b = (try? await store.describe(pair.b.id)) ?? pair.b.name
                text += "### Pair \(index + 1) (why it came up: \(pair.reason))\nA. \(a)\nB. \(b)\n\n"
            }
            guard let verdicts = try? await ModelHub.generate(
                Verdicts.self, prompt: text,
                instructions: """
                You keep one person's private address book tidy. Each pair shows two entries from it that might \
                be the same real person filed twice: under a contact name and a number, with and without an \
                emoji, or under a nickname. Decide for each pair: same, different or unsure. \
                Same needs evidence that points at one human: one entry is called by the other's name, they \
                have the same partner or family, a number-only entry is addressed by the other's name. Two \
                people who only share a first name are different. Two entries that write in the same group \
                are almost always two people. A name plus a surname is not proof that it is the bare first \
                name. When the evidence is thin, answer unsure: joining two people is far worse than leaving \
                one person as two. Never make a name up.
                """,
                provider: provider,
                modelName: provider == .openCode ? ModelHub.learningModel : nil)
            else { break }
            for verdict in verdicts.verdicts where batch.indices.contains(verdict.pair - 1) {
                let pair = batch[verdict.pair - 1]
                let odds = MemoryStore.odds(verdict.confidence)
                switch verdict.answer {
                case .same where odds >= 0.85:
                    let (from, into) = await direction(pair.a, pair.b, in: store)
                    try? await store.mergePerson(from.id, into: into.id)
                    report.settled.append("\(from.name) → \(into.name)")
                case .different where odds >= 0.7:
                    try? await store.setPair(pair.a.id, pair.b.id, state: "different")
                default:
                    break
                }
            }
        }
    }
}

// MARK: - What a dream does to the store

extension MemoryStore {
    /// Removes people who are a description ("irmão", "her ex") or an
    /// encoded id, and who have no chat of their own.
    func dropDescriptors() throws -> Int {
        let db = try open()
        var names: [String] = []
        try db.rows("SELECT name FROM people p WHERE kind = 'person' AND NOT EXISTS (SELECT 1 FROM chat_people c WHERE c.person_id = p.id)") { row in
            if let name = row.text(0), PersonName.isDescriptor(name) || PersonName.looksEncoded(name) { names.append(name) }
        }
        guard !names.isEmpty else { return 0 }
        try db.transaction {
            for name in names { try dropPerson(db, named: name) }
        }
        aliasCache = nil
        return names.count
    }

    /// What a contact is to the user when their saved name says it: "Mãe",
    /// "Pai", "Vó Maria", "Tia Márcia". Returns how many ties it added.
    @discardableResult
    func tiesFromContactNames() throws -> Int {
        let kin: [String: (LinkKind, String)] = [
            "mãe": (.parent, "mãe"), "mae": (.parent, "mãe"), "mamãe": (.parent, "mãe"), "mainha": (.parent, "mãe"),
            "mom": (.parent, "mother"), "mother": (.parent, "mother"), "mum": (.parent, "mother"),
            "pai": (.parent, "pai"), "papai": (.parent, "pai"), "painho": (.parent, "pai"),
            "dad": (.parent, "father"), "father": (.parent, "father"),
            "vó": (.family, "avó"), "vovó": (.family, "avó"), "avó": (.family, "avó"), "grandma": (.family, "grandmother"),
            "vô": (.family, "avô"), "vovô": (.family, "avô"), "avô": (.family, "avô"), "grandpa": (.family, "grandfather"),
            "tia": (.family, "tia"), "tio": (.family, "tio"), "aunt": (.family, "aunt"), "uncle": (.family, "uncle"),
            "irmã": (.sibling, "irmã"), "irmão": (.sibling, "irmão"), "mana": (.sibling, "irmã"), "mano": (.sibling, "irmão"),
            "sister": (.sibling, "sister"), "brother": (.sibling, "brother"),
            "madrinha": (.family, "madrinha"), "padrinho": (.family, "padrinho"),
        ]
        let db = try open()
        var people: [(Int64, String)] = []
        // Only someone the user has a chat of their own with.
        try db.rows("SELECT DISTINCT p.id, p.name FROM people p JOIN chat_people c ON c.person_id = p.id WHERE p.kind = 'person' AND c.role = 'direct'") {
            people.append((Int64($0.int(0)), $0.text(1) ?? ""))
        }
        var added = 0
        for (id, name) in people {
            let words = PersonName.clean(name).lowercased().split(separator: " ").map(String.init)
            guard let first = words.first, words.count <= 3, let (kind, detail) = kin[first] else { continue }
            // "Mano" alone is a friend's nickname more often than a brother.
            if first == "mano" || first == "mana", words.count == 1 { continue }
            guard try db.scalarInt("SELECT COUNT(*) FROM person_links WHERE (a = ? AND b = 0) OR (a = 0 AND b = ?)", [.int(id), .int(id)]) == 0
            else { continue }
            try link(id, Self.me, kind: kind, detail: detail, confidence: 0.9, evidence: nil, chunkID: nil, at: .now)
            added += 1
        }
        return added
    }

    /// The moment some words were said in, found by the words.
    func chunk(holding words: String) throws -> MemoryChunk? {
        let terms = words.folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
        guard !terms.isEmpty else { return nil }
        var ids: [Int64] = []
        try open().rows("SELECT rowid FROM chunks_fts WHERE chunks_fts MATCH ? LIMIT 12",
                        [.text(terms.prefix(8).map { "\"\($0)\"" }.joined(separator: " "))]) { ids.append(Int64($0.int(0))) }
        let needle = words.folded
        return try chunks(ids: ids).first { $0.text.folded.contains(needle) }
    }

    /// Checks every nickname learned so far against the words it came
    /// from: generic words and the person's own name go, a misspelling is
    /// kept only to recognise them, and one that was used to call someone
    /// else moves to that person (or to the user). Returns how many
    /// changed, and how many turned out to be the user's.
    func rejudgeNicknames(me: String) throws -> (fixed: Int, mine: Int) {
        let db = try open()
        struct Row { var id: Int64; var alias: String; var folded: String; var evidence: String?; var count: Int; var name: String }
        var rows: [Row] = []
        try db.rows(
            """
            SELECT a.person_id, a.alias, a.folded, a.evidence, a.count, p.name FROM person_aliases a
            JOIN people p ON p.id = a.person_id WHERE a.kind = 'nickname' AND p.kind = 'person'
            """
        ) { row in
            rows.append(Row(id: Int64(row.int(0)), alias: row.text(1) ?? "", folded: row.text(2) ?? "",
                            evidence: row.text(3), count: row.int(4), name: row.text(5) ?? ""))
        }
        var fixed = 0, mine = 0
        func remove(_ row: Row) throws {
            try db.run("DELETE FROM person_aliases WHERE person_id = ? AND folded = ?", [.int(row.id), .text(row.folded)])
        }
        func setKind(_ row: Row, _ kind: String) throws {
            try db.run("UPDATE person_aliases SET kind = ? WHERE person_id = ? AND folded = ?", [.text(kind), .int(row.id), .text(row.folded)])
        }
        for row in rows {
            let own = Set(PersonName.clean(row.name).wordList)
            if !Nicknames.isPlausible(row.alias) || row.folded == PersonName.clean(row.name).folded
                || (row.alias.wordList.count == 1 && own.contains(row.folded)) {
                try remove(row)
                fixed += 1
                continue
            }
            if PersonName.isMisspelling(row.alias, of: row.name) {
                try setKind(row, "spelling")
                fixed += 1
                continue
            }
            guard let evidence = row.evidence, evidence.count >= 3, let chunk = try chunk(holding: evidence) else { continue }
            let verdict = Nicknames.judge(nickname: row.alias, claimed: row.name, evidence: evidence, in: chunk, me: me)
            switch verdict.owner {
            case .nobody:
                try remove(row)
                fixed += 1
            case .me:
                try remove(row)
                // The user's when it is how that person keeps calling them,
                // not a word said once.
                let used = try usageCounts(for: row.alias, person: Self.me) ? try uses(of: row.alias, inChat: (chunk.source, chunk.chatID)) : 1
                if try learnNickname(row.alias, forID: Self.me, name: me, evidence: evidence, trusted: verdict.trusted || used >= 3,
                                     at: chunk.end, uses: used) {
                    mine += 1
                } else {
                    fixed += 1
                }
            case .person(let name) where name.folded != row.name.folded:
                try remove(row)
                if let other = try resolvePeople(name).first(where: { $0.kind == .person && $0.name.folded == name.folded }) {
                    let used = try usageCounts(for: row.alias, person: other.id) ? try uses(of: row.alias, with: other.name) : 1
                    try learnNickname(row.alias, forID: other.id, name: other.name, evidence: evidence,
                                      trusted: verdict.trusted || used >= 2, at: chunk.end, uses: used)
                }
                fixed += 1
            case .person:
                // How often it is really used where they are, which the
                // first reading never counted.
                let used = try usageCounts(for: row.alias, person: row.id) ? max(row.count, try uses(of: row.alias, with: row.name)) : row.count
                try db.run("UPDATE person_aliases SET count = ? WHERE person_id = ? AND folded = ?",
                           [.of(used), .int(row.id), .text(row.folded)])
                // Theirs, but used once and not said to them: not yet a nickname.
                if !verdict.trusted, used < 2 {
                    try setKind(row, "heard")
                    fixed += 1
                }
            }
        }
        aliasCache = nil
        return (fixed, mine)
    }

    /// Puts links in time, across everything known: a couple who became
    /// exes are no longer dating (and the other way round when they got
    /// back together), a crush that became dating is over as a crush, and
    /// someone seen with a new partner, well after the last word of the old
    /// one, is no longer with the old one. Returns how many links ended.
    func settleLinks() throws -> Int {
        let db = try open()
        try db.execute("UPDATE person_links SET first_ts = ts WHERE first_ts IS NULL")
        struct Row { var a: Int64; var b: Int64; var kind: String; var ts: Double; var first: Double; var confidence: Double }
        var rows: [Row] = []
        try db.rows("SELECT a, b, kind, ts, COALESCE(first_ts, ts), confidence FROM person_links WHERE ended_ts IS NULL AND kind IN ('partner', 'ex', 'crush')") { row in
            rows.append(Row(a: Int64(row.int(0)), b: Int64(row.int(1)), kind: row.text(2) ?? "", ts: row.double(3),
                            first: row.double(4), confidence: row.double(5)))
        }
        var ended = 0
        func end(_ row: Row, at ts: Double) throws {
            try db.run("UPDATE person_links SET ended_ts = ? WHERE a = ? AND b = ? AND kind = ? AND ended_ts IS NULL",
                       [.double(max(ts, row.ts)), .int(row.a), .int(row.b), .text(row.kind)])
            ended += db.changes
        }
        var gone = Set<String>()
        func key(_ row: Row) -> String { "\(row.a)-\(row.b)-\(row.kind)" }
        try db.transaction {
            // Between the same two people.
            let byPair = Dictionary(grouping: rows) { $0.a < $0.b ? "\($0.a)-\($0.b)" : "\($0.b)-\($0.a)" }
            for (_, pair) in byPair where pair.count > 1 {
                let partner = pair.first { $0.kind == "partner" }, ex = pair.first { $0.kind == "ex" }
                if let partner, let ex, min(partner.confidence, ex.confidence) >= 0.6 {
                    let over = ex.ts >= partner.ts ? partner : ex
                    try end(over, at: max(partner.ts, ex.ts))
                    gone.insert(key(over))
                }
                let later = [partner, ex].compactMap { $0 }.filter { $0.confidence >= 0.6 }.map(\.ts).max()
                for crush in pair where crush.kind == "crush" {
                    if let later, later >= crush.ts {
                        try end(crush, at: later)
                        gone.insert(key(crush))
                    }
                }
            }
            // One partner at a time: a newer one, sure enough and seen two
            // months or more after the last word of an older one, ends it.
            var partners: [Int64: [Row]] = [:]
            for row in rows where row.kind == "partner" && !gone.contains(key(row)) {
                partners[row.a, default: []].append(row)
                partners[row.b, default: []].append(row)
            }
            for (_, list) in partners where list.count > 1 {
                guard let newest = list.filter({ $0.confidence >= 0.75 }).max(by: { $0.ts < $1.ts }) else { continue }
                for older in list where key(older) != key(newest) && !gone.contains(key(older))
                    && older.ts < newest.first - 60 * 86400 {
                    try end(older, at: newest.first)
                    gone.insert(key(older))
                }
            }
        }
        salienceCache = nil
        return ended
    }

    /// Puts facts in time, across everything known: where someone lives,
    /// their age and whether they are single have one answer at a time,
    /// and the newest sure one ends the older ones. Returns how many ended.
    func settleFacts() throws -> Int {
        let db = try open()
        // Facts filed before "relationship" was a kind of fact, and ones
        // filed as where someone lives or their age because a word looked
        // like it ("namorada" has "mora" in it).
        var rekind: [(Int64, String)] = []
        try db.rows("SELECT id, predicate, kind FROM facts WHERE kind IS NULL OR kind IN ('other', 'livesIn', 'age')") { row in
            let kind = FactKind.guess(row.text(1) ?? "")
            let stored = row.text(2) ?? "other"
            if kind.rawValue != stored, kind != .other || stored != "other" { rekind.append((Int64(row.int(0)), kind.rawValue)) }
        }
        struct Row { var id: Int64; var subject: String; var object: String; var ts: Double; var confidence: Double }
        var ended = 0
        try db.transaction {
            for (id, kind) in rekind { try db.run("UPDATE facts SET kind = ? WHERE id = ?", [.text(kind), .int(id)]) }
            for kind in FactKind.allCases where kind.singleValued {
                var rows: [Row] = []
                try db.rows(
                    "SELECT id, CASE WHEN COALESCE(subject_id, 0) > 0 THEN '#' || subject_id ELSE lower(subject) END, object, ts, confidence FROM facts WHERE kind = ? AND ended_ts IS NULL",
                    [.text(kind.rawValue)]
                ) { row in
                    rows.append(Row(id: Int64(row.int(0)), subject: row.text(1) ?? "", object: row.text(2) ?? "",
                                    ts: row.double(3), confidence: row.double(4)))
                }
                for (_, group) in Dictionary(grouping: rows.filter { Self.isPlainValue($0.object) }, by: \.subject) where group.count > 1 {
                    guard let newest = group.filter({ $0.confidence >= 0.7 }).max(by: { $0.ts < $1.ts }) else { continue }
                    for older in group where older.id != newest.id && older.ts < newest.ts - Self.replaceAfter
                        && !KnowledgeGraph.sameMeaning(older.object, newest.object) {
                        try db.run("UPDATE facts SET ended_ts = ? WHERE id = ?", [.double(newest.ts), .int(older.id)])
                        ended += 1
                    }
                }
            }
        }
        return ended
    }

    /// Everything that helps tell whether an entry is someone already
    /// known: names, where they write, ties and a few facts.
    func describe(_ id: Int64) throws -> String {
        guard let ref = try person(id: id) else { return "" }
        var parts = ["\"\(ref.name)\""]
        let db = try open()
        var names: [String] = []
        try db.rows("SELECT alias, kind FROM person_aliases WHERE person_id = ? AND kind IN ('nickname', 'heard', 'spelling') ORDER BY count DESC LIMIT 8",
                    [.int(id)]) { if let alias = $0.text(0) { names.append(alias) } }
        if !names.isEmpty { parts.append("called " + names.joined(separator: ", ")) }
        let places = try connections(of: ref, limit: 6)
        for chat in places.direct.prefix(2) {
            let years = "\(Self.stamp(chat.firstDate.timeIntervalSince1970).prefix(7)) to \(Self.stamp(chat.lastDate.timeIntervalSince1970).prefix(7))"
            parts.append("own chat on \(chat.source.displayName): \(chat.messageCount) messages, \(years)")
        }
        if places.direct.isEmpty { parts.append("no chat of their own with the user") }
        if !places.others.isEmpty { parts.append("writes in the groups " + places.others.map { "\"\($0.name)\"" }.joined(separator: ", ")) }
        let ties = try tiesToUser(of: id).prefix(2).map(\.toUser)
            + links(of: id, limit: 5).map { "\($0.phrase) \($0.other.name)" }
        if !ties.isEmpty { parts.append(ties.joined(separator: ", ")) }
        let facts = try profile(of: ref, limit: 4).filter { !$0.sensitive }.map { "\($0.predicate) \($0.object)" }
        if !facts.isEmpty { parts.append("known: " + facts.joined(separator: "; ")) }
        return parts.joined(separator: "; ")
    }
}
