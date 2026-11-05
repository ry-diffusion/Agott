import Foundation

/// Everything Agott remembers, in one SQLite file.
///
/// Four layers, each built from the one below:
///
/// 1. **messages**: what was said, verbatim, from every source.
/// 2. **chunks**: messages grouped into moments (a burst of conversation),
///    indexed twice: FTS5 for words, a vector for meaning.
/// 3. **entities + edges**: the knowledge graph. People, groups, places,
///    projects and topics, and how they connect. Built partly from structure
///    (who talks to whom, who is in which group) and partly from reading
///    (names mentioned, facts extracted by the on-device model).
/// 4. **facts**: sentences Agott believes about you and the people around you,
///    each with a confidence and a source.
///
/// It is an actor so indexing hundreds of thousands of messages never touches
/// the main thread.
actor MemoryStore {
    static let shared: MemoryStore = {
        if LaunchOptions.isDemo { return MemoryStore(url: DemoData.databaseURL) }
        let folder = URL.applicationSupportDirectory.appending(path: "Agott", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return MemoryStore(url: folder.appending(path: "memory.sqlite"))
    }()

    let url: URL
    private var db: SQLiteDB?
    private var vectorCache: VectorIndex?

    init(url: URL) {
        self.url = url
    }

    private func open() throws -> SQLiteDB {
        if let db { return db }
        let db = try SQLiteDB(path: url.path)
        try db.execute(Self.schema)
        self.db = db
        return db
    }

    // MARK: Schema

    private static let schema = """
    CREATE TABLE IF NOT EXISTS messages(
        id INTEGER PRIMARY KEY,
        source TEXT NOT NULL, ext_id TEXT NOT NULL,
        chat_id TEXT NOT NULL, chat_name TEXT NOT NULL, is_group INTEGER NOT NULL DEFAULT 0,
        sender TEXT NOT NULL, is_me INTEGER NOT NULL, ts REAL NOT NULL, text TEXT NOT NULL,
        UNIQUE(source, ext_id));
    CREATE INDEX IF NOT EXISTS messages_chat_ts ON messages(source, chat_id, ts);

    CREATE TABLE IF NOT EXISTS chunks(
        id INTEGER PRIMARY KEY,
        source TEXT NOT NULL, chat_id TEXT NOT NULL, chat_name TEXT NOT NULL,
        start_ts REAL NOT NULL, end_ts REAL NOT NULL,
        text TEXT NOT NULL, participants TEXT NOT NULL,
        graphed INTEGER NOT NULL DEFAULT 0,
        learned INTEGER NOT NULL DEFAULT 0,
        UNIQUE(source, chat_id, start_ts));
    CREATE INDEX IF NOT EXISTS chunks_chat ON chunks(source, chat_id, start_ts);

    CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
        text, chat_name, content='chunks', content_rowid='id',
        tokenize='unicode61 remove_diacritics 2');
    CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
        INSERT INTO chunks_fts(rowid, text, chat_name) VALUES (new.id, new.text, new.chat_name);
    END;
    CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
        INSERT INTO chunks_fts(chunks_fts, rowid, text, chat_name) VALUES ('delete', old.id, old.text, old.chat_name);
        DELETE FROM vectors WHERE chunk_id = old.id;
    END;

    CREATE TABLE IF NOT EXISTS vectors(chunk_id INTEGER PRIMARY KEY, dim INTEGER NOT NULL, v BLOB NOT NULL);

    CREATE TABLE IF NOT EXISTS chats(
        source TEXT NOT NULL, chat_id TEXT NOT NULL, name TEXT NOT NULL, is_group INTEGER NOT NULL,
        msg_count INTEGER NOT NULL, my_count INTEGER NOT NULL,
        first_ts REAL NOT NULL, last_ts REAL NOT NULL,
        PRIMARY KEY(source, chat_id));

    CREATE TABLE IF NOT EXISTS entities(
        id INTEGER PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, key TEXT NOT NULL UNIQUE,
        mentions INTEGER NOT NULL DEFAULT 0, first_ts REAL, last_ts REAL);
    CREATE TABLE IF NOT EXISTS edges(
        src INTEGER NOT NULL, dst INTEGER NOT NULL, rel TEXT NOT NULL,
        weight REAL NOT NULL DEFAULT 0, first_ts REAL, last_ts REAL,
        PRIMARY KEY(src, dst, rel));
    CREATE INDEX IF NOT EXISTS edges_dst ON edges(dst);

    CREATE TABLE IF NOT EXISTS facts(
        id INTEGER PRIMARY KEY, subject TEXT NOT NULL, predicate TEXT NOT NULL, object TEXT NOT NULL,
        confidence REAL NOT NULL, source TEXT NOT NULL, chunk_id INTEGER, ts REAL NOT NULL,
        UNIQUE(subject, predicate, object));

    CREATE TABLE IF NOT EXISTS cursors(source TEXT PRIMARY KEY, value REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS insights(key TEXT PRIMARY KEY, json TEXT NOT NULL, ts REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS plays(
        ts REAL NOT NULL, track TEXT NOT NULL, artist TEXT NOT NULL, album TEXT NOT NULL, app TEXT NOT NULL,
        PRIMARY KEY(ts, track));
    CREATE INDEX IF NOT EXISTS plays_ts ON plays(ts);
    """

    /// For one-time repairs that need raw SQL.
    func openForRepair() throws -> SQLiteDB { try open() }
    func dropVectorCache() { vectorCache = nil }

    // MARK: Cursors

    func cursor(for source: MemorySource) throws -> Double {
        var value = 0.0
        try open().rows("SELECT value FROM cursors WHERE source = ?", [.text(source.rawValue)]) {
            value = $0.double(0)
        }
        return value
    }

    func setCursor(_ value: Double, for source: MemorySource) throws {
        try open().run(
            "INSERT INTO cursors(source, value) VALUES(?, ?) ON CONFLICT(source) DO UPDATE SET value = excluded.value",
            [.text(source.rawValue), .double(value)])
    }

    /// Named progress markers beyond the one per source (e.g. how far back a
    /// newest-first pass has reached).
    func cursor(named name: String) throws -> Double {
        var value = 0.0
        try open().rows("SELECT value FROM cursors WHERE source = ?", [.text(name)]) { value = $0.double(0) }
        return value
    }

    func setCursor(_ value: Double, named name: String) throws {
        try open().run(
            "INSERT INTO cursors(source, value) VALUES(?, ?) ON CONFLICT(source) DO UPDATE SET value = excluded.value",
            [.text(name), .double(value)])
    }

    // MARK: Ingestion

    /// Stores new messages and rebuilds the moments they belong to.
    /// Returns how many messages were new.
    @discardableResult
    func ingest(_ messages: [RawMessage]) throws -> Int {
        guard !messages.isEmpty else { return 0 }
        let db = try open()
        var earliestByChat: [String: (MemorySource, String, Double)] = [:]
        var latestByChat: [String: Double] = [:]
        var inserted = 0

        try db.transaction {
            let insert = try db.prepare("""
                INSERT OR IGNORE INTO messages(source, ext_id, chat_id, chat_name, is_group, sender, is_me, ts, text)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for message in messages {
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let ts = message.date.timeIntervalSince1970
                try insert.bind([
                    .text(message.source.rawValue), .text(message.externalID),
                    .text(message.chatID), .text(message.chatName), .of(message.isGroup),
                    .text(message.sender), .of(message.isFromMe), .double(ts), .text(text),
                ])
                try insert.step()
                guard db.changes > 0 else { continue }
                inserted += 1
                let key = "\(message.source.rawValue)|\(message.chatID)"
                latestByChat[key] = max(latestByChat[key] ?? ts, ts)
                if let existing = earliestByChat[key], existing.2 <= ts { continue }
                earliestByChat[key] = (message.source, message.chatID, ts)
            }
        }

        guard inserted > 0 else { return 0 }
        try db.transaction {
            for (key, (source, chatID, earliest)) in earliestByChat {
                try rechunk(db: db, source: source, chatID: chatID, from: earliest, through: latestByChat[key] ?? earliest)
            }
        }
        try refreshChats(db: db, keys: Array(earliestByChat.values.map { ($0.0, $0.1) }))
        vectorCache = nil
        return inserted
    }

    /// Gaps longer than this start a new moment.
    private static let momentGap: Double = 45 * 60
    private static let momentCharacters = 1400
    private static let momentMessages = 24

    /// Rebuilds the moments that new messages between `earliest` and `latest`
    /// touch, and only those. Reading newest-first adds history *before*
    /// moments that already exist; rebuilding everything after the insertion
    /// point would throw away (and re-embed) a whole chat on every page.
    private func rechunk(db: SQLiteDB, source: MemorySource, chatID: String, from earliest: Double, through latest: Double) throws {
        // Start at the moment the earliest new message falls into, so a
        // conversation that carried on is extended rather than split.
        var start = earliest
        try db.rows(
            "SELECT start_ts FROM chunks WHERE source = ? AND chat_id = ? AND start_ts <= ? ORDER BY start_ts DESC LIMIT 1",
            [.text(source.rawValue), .text(chatID), .double(earliest)]
        ) { start = $0.double(0) }
        // End where the moment holding the latest new message ends.
        var stop = latest
        try db.rows(
            "SELECT end_ts FROM chunks WHERE source = ? AND chat_id = ? AND start_ts <= ? ORDER BY start_ts DESC LIMIT 1",
            [.text(source.rawValue), .text(chatID), .double(latest)]
        ) { stop = max(latest, $0.double(0)) }

        // A later moment that begins within the gap belongs to the same
        // conversation as the new messages: absorb it, and keep going.
        var nextStart = Double.greatestFiniteMagnitude
        while true {
            var next: (start: Double, end: Double)?
            try db.rows(
                "SELECT start_ts, end_ts FROM chunks WHERE source = ? AND chat_id = ? AND start_ts > ? ORDER BY start_ts LIMIT 1",
                [.text(source.rawValue), .text(chatID), .double(stop)]
            ) { next = ($0.double(0), $0.double(1)) }
            guard let next else { break }
            if next.start - stop <= Self.momentGap {
                stop = next.end
            } else {
                nextStart = next.start
                break
            }
        }

        try db.run(
            "DELETE FROM chunks WHERE source = ? AND chat_id = ? AND start_ts >= ? AND start_ts <= ?",
            [.text(source.rawValue), .text(chatID), .double(start), .double(stop)])

        struct Line { var ts: Double; var sender: String; var text: String; var chat: String }
        var lines: [Line] = []
        try db.rows(
            "SELECT ts, sender, text, chat_name FROM messages WHERE source = ? AND chat_id = ? AND ts >= ? AND ts < ? ORDER BY ts",
            [.text(source.rawValue), .text(chatID), .double(start), .double(nextStart)]
        ) { row in
            lines.append(Line(ts: row.double(0), sender: row.text(1) ?? "?", text: row.text(2) ?? "", chat: row.text(3) ?? ""))
        }

        let insert = try db.prepare("""
            INSERT OR REPLACE INTO chunks(source, chat_id, chat_name, start_ts, end_ts, text, participants)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """)
        var window: [Line] = []
        var characters = 0

        func flush() throws {
            guard let first = window.first, let last = window.last else { return }
            let body = window.map { line in
                "[\(Self.stamp(line.ts))] \(line.sender): \(line.text)"
            }.joined(separator: "\n")
            var seen = Set<String>()
            let participants = window.map(\.sender).filter { seen.insert($0).inserted }
            try insert.bind([
                .text(source.rawValue), .text(chatID), .text(last.chat),
                .double(first.ts), .double(last.ts), .text(body),
                .text(participants.joined(separator: "\u{1F}")),
            ])
            try insert.step()
            window.removeAll(keepingCapacity: true)
            characters = 0
        }

        for line in lines {
            if let last = window.last,
                line.ts - last.ts > Self.momentGap
                    || characters + line.text.count > Self.momentCharacters
                    || window.count >= Self.momentMessages
            {
                try flush()
            }
            window.append(line)
            characters += line.text.count
        }
        try flush()
    }

    nonisolated static func stamp(_ ts: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: ts))
    }

    private func refreshChats(db: SQLiteDB, keys: [(MemorySource, String)]) throws {
        try db.transaction {
            let upsert = try db.prepare("""
                INSERT OR REPLACE INTO chats(source, chat_id, name, is_group, msg_count, my_count, first_ts, last_ts)
                SELECT source, chat_id,
                       (SELECT chat_name FROM messages m2 WHERE m2.source = m.source AND m2.chat_id = m.chat_id ORDER BY ts DESC LIMIT 1),
                       MAX(is_group), COUNT(*), SUM(is_me), MIN(ts), MAX(ts)
                FROM messages m WHERE source = ? AND chat_id = ? GROUP BY source, chat_id
                """)
            for (source, chatID) in keys {
                try upsert.bind([.text(source.rawValue), .text(chatID)])
                try upsert.step()
            }
        }
    }

    // MARK: Reading chunks

    func chunks(ids: [Int64]) throws -> [MemoryChunk] {
        guard !ids.isEmpty else { return [] }
        let list = ids.map(String.init).joined(separator: ",")
        var byID: [Int64: MemoryChunk] = [:]
        try open().rows(
            "SELECT id, source, chat_id, chat_name, start_ts, end_ts, text, participants FROM chunks WHERE id IN (\(list))"
        ) { row in
            let chunk = Self.chunk(row)
            byID[chunk.id] = chunk
        }
        return ids.compactMap { byID[$0] }
    }

    private static func chunk(_ row: SQLiteDB.Statement) -> MemoryChunk {
        MemoryChunk(
            id: Int64(row.int(0)),
            source: MemorySource(rawValue: row.text(1) ?? "") ?? .note,
            chatID: row.text(2) ?? "",
            chatName: row.text(3) ?? "",
            start: Date(timeIntervalSince1970: row.double(4)),
            end: Date(timeIntervalSince1970: row.double(5)),
            text: row.text(6) ?? "",
            participants: (row.text(7) ?? "").split(separator: "\u{1F}").map(String.init))
    }

    nonisolated struct Filter: Sendable {
        var sources: Set<MemorySource> = []
        var chatName: String?
        var since: Date?
        var until: Date?

        static let none = Filter()
    }

    private func filterSQL(_ filter: Filter, alias: String) -> (String, [SQLiteDB.Value]) {
        var clauses: [String] = []
        var values: [SQLiteDB.Value] = []
        if !filter.sources.isEmpty {
            clauses.append("\(alias).source IN (\(filter.sources.map { _ in "?" }.joined(separator: ",")))")
            values += filter.sources.map { .text($0.rawValue) }
        }
        if let name = filter.chatName, !name.isEmpty {
            clauses.append("(\(alias).chat_name LIKE ? OR \(alias).participants LIKE ?)")
            values += [.text("%\(name)%"), .text("%\(name)%")]
        }
        if let since = filter.since {
            clauses.append("\(alias).end_ts >= ?")
            values.append(.double(since.timeIntervalSince1970))
        }
        if let until = filter.until {
            clauses.append("\(alias).start_ts <= ?")
            values.append(.double(until.timeIntervalSince1970))
        }
        return (clauses.isEmpty ? "" : " AND " + clauses.joined(separator: " AND "), values)
    }

    /// BM25 over FTS5. Every word is optional and prefix-matched, so
    /// "aniversario" finds "aniversário" and "aniversariante" alike.
    func keywordSearch(_ query: String, filter: Filter = .none, limit: Int = 40) throws -> [Int64] {
        let terms = query
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !Self.stopwords.contains($0) }
        guard !terms.isEmpty else { return [] }
        let match = terms.prefix(12).map { "\"\($0)\"*" }.joined(separator: " OR ")
        let (clause, values) = filterSQL(filter, alias: "c")
        var ids: [Int64] = []
        try open().rows(
            """
            SELECT c.id FROM chunks_fts f JOIN chunks c ON c.id = f.rowid
            WHERE chunks_fts MATCH ?\(clause)
            ORDER BY bm25(chunks_fts) LIMIT ?
            """,
            [.text(match)] + values + [.of(limit)]
        ) { ids.append(Int64($0.int(0))) }
        return ids
    }

    /// Chunks that pass `filter`, newest first. Used when a question is about
    /// a person or a period rather than about particular words.
    func recentChunkIDs(filter: Filter, limit: Int) throws -> [Int64] {
        let (clause, values) = filterSQL(filter, alias: "c")
        var ids: [Int64] = []
        try open().rows(
            "SELECT c.id FROM chunks c WHERE 1=1\(clause) ORDER BY c.end_ts DESC LIMIT ?",
            values + [.of(limit)]
        ) { ids.append(Int64($0.int(0))) }
        return ids
    }

    nonisolated static let stopwords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "what", "who", "how", "about", "from", "was", "are", "you",
        "my", "me", "is", "it", "to", "of", "in", "on", "a", "an", "do", "did", "does",
        "que", "com", "para", "por", "uma", "um", "de", "da", "do", "das", "dos", "no", "na", "nos", "nas",
        "eu", "voce", "ele", "ela", "isso", "esse", "essa", "como", "qual", "quem", "sobre", "foi", "ser",
        "meu", "minha", "se", "em", "o", "os", "as", "e", "ou", "mas", "ja", "nao", "sim", "tem",
    ]

    // MARK: Vectors

    func chunksNeedingVectors(limit: Int) throws -> [(Int64, String)] {
        var result: [(Int64, String)] = []
        try open().rows(
            """
            SELECT c.id, c.text FROM chunks c LEFT JOIN vectors v ON v.chunk_id = c.id
            WHERE v.chunk_id IS NULL ORDER BY c.end_ts DESC LIMIT ?
            """,
            [.of(limit)]
        ) { result.append((Int64($0.int(0)), $0.text(1) ?? "")) }
        return result
    }

    func storeVectors(_ vectors: [(Int64, [Float])]) throws {
        let db = try open()
        try db.transaction {
            let insert = try db.prepare("INSERT OR REPLACE INTO vectors(chunk_id, dim, v) VALUES (?, ?, ?)")
            for (id, vector) in vectors {
                let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
                try insert.bind([.int(id), .of(vector.count), .blob(data)])
                try insert.step()
            }
        }
        vectorCache = nil
    }

    /// Every vector in one contiguous matrix, loaded once and kept until
    /// something changes. Brute force over a matrix is faster than any index
    /// at the size a person's messages reach.
    func vectorIndex() throws -> VectorIndex? {
        if let vectorCache { return vectorCache }
        var ids: [Int64] = []
        var matrix: [Float] = []
        var dimension = 0
        try open().rows("SELECT chunk_id, dim, v FROM vectors") { row in
            let dim = row.int(1)
            guard dim > 1 else { return }
            guard let data = row.blob(2), data.count == dim * MemoryLayout<Float>.size else { return }
            if dimension == 0 { dimension = dim }
            guard dim == dimension else { return }
            ids.append(Int64(row.int(0)))
            data.withUnsafeBytes { matrix.append(contentsOf: $0.bindMemory(to: Float.self)) }
        }
        guard dimension > 0 else { return nil }
        let index = VectorIndex(ids: ids, matrix: matrix, dimension: dimension)
        vectorCache = index
        return index
    }

    // MARK: Chats

    func chats(limit: Int = 500, includeGroups: Bool = true, since: Date? = nil) throws -> [ChatSummary] {
        var result: [ChatSummary] = []
        var sql = """
            SELECT c.source, c.chat_id, c.name, c.is_group, c.msg_count, c.my_count, c.first_ts, c.last_ts,
                   (SELECT is_me FROM messages m WHERE m.source = c.source AND m.chat_id = c.chat_id ORDER BY ts DESC LIMIT 1),
                   (SELECT text FROM messages m WHERE m.source = c.source AND m.chat_id = c.chat_id ORDER BY ts DESC LIMIT 1)
            FROM chats c WHERE c.source != 'claude'
            """
        var values: [SQLiteDB.Value] = []
        if !includeGroups { sql += " AND c.is_group = 0" }
        if let since {
            sql += " AND c.last_ts >= ?"
            values.append(.double(since.timeIntervalSince1970))
        }
        sql += " ORDER BY c.last_ts DESC LIMIT ?"
        values.append(.of(limit))
        try open().rows(sql, values) { row in
            result.append(ChatSummary(
                source: MemorySource(rawValue: row.text(0) ?? "") ?? .note,
                chatID: row.text(1) ?? "", name: row.text(2) ?? "",
                isGroup: row.int(3) != 0, messageCount: row.int(4), myCount: row.int(5),
                firstDate: Date(timeIntervalSince1970: row.double(6)),
                lastDate: Date(timeIntervalSince1970: row.double(7)),
                lastFromMe: row.int(8) != 0, lastText: row.text(9) ?? ""))
        }
        return result
    }

    func findChats(named name: String, limit: Int = 5) throws -> [ChatSummary] {
        let all = try chats(limit: 4000)
        let needle = name.folded
        return all
            .filter { $0.name.folded.contains(needle) }
            .sorted { lhs, rhs in
                // Direct chats first, then the most active.
                if lhs.isGroup != rhs.isGroup { return !lhs.isGroup }
                return lhs.messageCount > rhs.messageCount
            }
            .prefix(limit)
            .map { $0 }
    }

    func lines(source: MemorySource, chatID: String, limit: Int, before: Date? = nil) throws -> [ChatLine] {
        var result: [ChatLine] = []
        try open().rows(
            "SELECT id, sender, is_me, ts, text FROM messages WHERE source = ? AND chat_id = ? AND ts < ? ORDER BY ts DESC LIMIT ?",
            [.text(source.rawValue), .text(chatID), .double((before ?? .distantFuture).timeIntervalSince1970), .of(limit)]
        ) { row in
            result.append(ChatLine(
                id: Int64(row.int(0)), sender: row.text(1) ?? "", isFromMe: row.int(2) != 0,
                date: Date(timeIntervalSince1970: row.double(3)), text: row.text(4) ?? ""))
        }
        return result.reversed()
    }

    /// Lightweight rows for statistics: no text beyond what sentiment needs.
    func timeline(source: MemorySource, chatID: String, since: Date) throws -> [ChatLine] {
        try lines(source: source, chatID: chatID, limit: 20000, before: nil)
            .filter { $0.date >= since }
    }

    func counts() throws -> [MemorySource: Int] {
        var result: [MemorySource: Int] = [:]
        try open().rows("SELECT source, COUNT(*) FROM messages GROUP BY source") { row in
            if let source = MemorySource(rawValue: row.text(0) ?? "") { result[source] = row.int(1) }
        }
        return result
    }

    func totals() throws -> (messages: Int, chunks: Int, vectors: Int, entities: Int, facts: Int) {
        let db = try open()
        return (
            try db.scalarInt("SELECT COUNT(*) FROM messages"),
            try db.scalarInt("SELECT COUNT(*) FROM chunks"),
            try db.scalarInt("SELECT COUNT(*) FROM vectors"),
            try db.scalarInt("SELECT COUNT(*) FROM entities"),
            try db.scalarInt("SELECT COUNT(*) FROM facts"))
    }

    /// Who speaks in which group chat, and how much. The raw material for
    /// circles.
    func groupMembership(since: Date) throws -> [(chat: String, chatName: String, person: String, count: Int)] {
        var result: [(String, String, String, Int)] = []
        try open().rows(
            """
            SELECT chat_id, MAX(chat_name), sender, COUNT(*) FROM messages
            WHERE is_group = 1 AND is_me = 0 AND ts >= ? AND source != 'claude'
            GROUP BY chat_id, sender HAVING COUNT(*) >= 3
            """,
            [.double(since.timeIntervalSince1970)]
        ) { row in
            result.append((row.text(0) ?? "", row.text(1) ?? "", row.text(2) ?? "", row.int(3)))
        }
        return result.map { (chat: $0.0, chatName: $0.1, person: $0.2, count: $0.3) }
    }

    /// Messages in *other* chats that mention someone by name: what gets said
    /// about a person when they are not the one being spoken to.
    func mentions(of names: [String], outside chatID: String, limit: Int = 80) throws -> [(line: ChatLine, chatName: String)] {
        let terms = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 }
        guard !terms.isEmpty else { return [] }
        let clause = terms.map { _ in "text LIKE ?" }.joined(separator: " OR ")
        var result: [(ChatLine, String)] = []
        try open().rows(
            """
            SELECT id, sender, is_me, ts, text, chat_name FROM messages
            WHERE chat_id != ? AND source != 'claude' AND (\(clause))
            ORDER BY ts DESC LIMIT ?
            """,
            [.text(chatID)] + terms.map { .text("%\($0)%") } + [.of(limit)]
        ) { row in
            result.append((ChatLine(
                id: Int64(row.int(0)), sender: row.text(1) ?? "", isFromMe: row.int(2) != 0,
                date: Date(timeIntervalSince1970: row.double(3)), text: row.text(4) ?? ""), row.text(5) ?? ""))
        }
        return result.map { (line: $0.0, chatName: $0.1) }
    }

    // MARK: Knowledge graph

    func chunksNeedingGraph(limit: Int) throws -> [MemoryChunk] {
        var result: [MemoryChunk] = []
        try open().rows(
            "SELECT id, source, chat_id, chat_name, start_ts, end_ts, text, participants FROM chunks WHERE graphed = 0 ORDER BY end_ts DESC LIMIT ?",
            [.of(limit)]
        ) { result.append(Self.chunk($0)) }
        return result
    }

    func markGraphed(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try open().execute("UPDATE chunks SET graphed = 1 WHERE id IN (\(ids.map(String.init).joined(separator: ",")))")
    }

    nonisolated static func entityKey(kind: EntityKind, name: String) -> String {
        switch kind {
        case .me: "me"
        case .person, .group: "\(kind.rawValue):\(name.folded)"
        default: "\(kind.rawValue):\(name.folded)"
        }
    }

    /// Finds or creates an entity, bumping how often it has been seen.
    @discardableResult
    func upsertEntity(kind: EntityKind, name: String, at date: Date, mentions: Int = 1) throws -> Int64 {
        let db = try open()
        let key = Self.entityKey(kind: kind, name: name)
        let ts = date.timeIntervalSince1970
        try db.run(
            """
            INSERT INTO entities(kind, name, key, mentions, first_ts, last_ts) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET mentions = mentions + excluded.mentions,
                first_ts = MIN(COALESCE(first_ts, excluded.first_ts), excluded.first_ts),
                last_ts = MAX(COALESCE(last_ts, excluded.last_ts), excluded.last_ts)
            """,
            [.text(kind.rawValue), .text(name), .text(key), .of(mentions), .double(ts), .double(ts)])
        var id: Int64 = 0
        try db.rows("SELECT id FROM entities WHERE key = ?", [.text(key)]) { id = Int64($0.int(0)) }
        return id
    }

    func addEdge(_ source: Int64, _ target: Int64, relation: String, weight: Double = 1, at date: Date) throws {
        guard source != target else { return }
        let ts = date.timeIntervalSince1970
        try open().run(
            """
            INSERT INTO edges(src, dst, rel, weight, first_ts, last_ts) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(src, dst, rel) DO UPDATE SET weight = weight + excluded.weight,
                first_ts = MIN(COALESCE(first_ts, excluded.first_ts), excluded.first_ts),
                last_ts = MAX(COALESCE(last_ts, excluded.last_ts), excluded.last_ts)
            """,
            [.int(source), .int(target), .text(relation), .double(weight), .double(ts), .double(ts)])
    }

    /// Runs a batch of graph writes in one transaction.
    func graphBatch(_ body: (isolated MemoryStore) throws -> Void) throws {
        let db = try open()
        try db.transaction { try body(self) }
    }

    func entities(limit: Int, kinds: Set<EntityKind> = []) throws -> [GraphEntity] {
        var sql = "SELECT id, kind, name, mentions, last_ts FROM entities"
        var values: [SQLiteDB.Value] = []
        if !kinds.isEmpty {
            sql += " WHERE kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))"
            values = kinds.map { .text($0.rawValue) }
        }
        sql += " ORDER BY (kind = 'me') DESC, mentions DESC LIMIT ?"
        values.append(.of(limit))
        var result: [GraphEntity] = []
        try open().rows(sql, values) { result.append(Self.entity($0)) }
        return result
    }

    private static func entity(_ row: SQLiteDB.Statement) -> GraphEntity {
        GraphEntity(
            id: Int64(row.int(0)), kind: EntityKind(rawValue: row.text(1) ?? "") ?? .thing,
            name: row.text(2) ?? "", mentions: row.int(3),
            lastSeen: row.isNull(4) ? nil : Date(timeIntervalSince1970: row.double(4)))
    }

    func edges(among ids: [Int64]) throws -> [GraphEdge] {
        guard !ids.isEmpty else { return [] }
        let list = ids.map(String.init).joined(separator: ",")
        var result: [GraphEdge] = []
        try open().rows(
            "SELECT src, dst, rel, weight, last_ts FROM edges WHERE src IN (\(list)) AND dst IN (\(list)) ORDER BY weight DESC LIMIT 2000"
        ) { row in
            result.append(GraphEdge(
                source: Int64(row.int(0)), target: Int64(row.int(1)), relation: row.text(2) ?? "",
                weight: row.double(3), lastSeen: row.isNull(4) ? nil : Date(timeIntervalSince1970: row.double(4))))
        }
        return result
    }

    /// The strongest connections of one entity, in both directions.
    func neighbors(of id: Int64, limit: Int = 24) throws -> [(GraphEntity, GraphEdge)] {
        var result: [(GraphEntity, GraphEdge)] = []
        try open().rows(
            """
            SELECT e.id, e.kind, e.name, e.mentions, e.last_ts, x.src, x.dst, x.rel, x.weight, x.last_ts
            FROM edges x JOIN entities e ON e.id = CASE WHEN x.src = ? THEN x.dst ELSE x.src END
            WHERE x.src = ? OR x.dst = ? ORDER BY x.weight DESC LIMIT ?
            """,
            [.int(id), .int(id), .int(id), .of(limit)]
        ) { row in
            let entity = Self.entity(row)
            let edge = GraphEdge(
                source: Int64(row.int(5)), target: Int64(row.int(6)), relation: row.text(7) ?? "",
                weight: row.double(8), lastSeen: row.isNull(9) ? nil : Date(timeIntervalSince1970: row.double(9)))
            result.append((entity, edge))
        }
        return result
    }

    /// Entities whose names appear in `text`. This is how a question gets
    /// anchored in the graph: "what's going on with Ana and the trip?"
    /// lights up Ana, and from Ana the graph reaches the trip.
    func entitiesMentioned(in text: String, limit: Int = 8) throws -> [GraphEntity] {
        let folded = " " + text.folded.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: " ") + " "
        var result: [GraphEntity] = []
        try open().rows(
            "SELECT id, kind, name, mentions, last_ts, key FROM entities WHERE kind != 'me' ORDER BY mentions DESC LIMIT 6000"
        ) { row in
            let entity = Self.entity(row)
            let name = entity.name.folded
            guard name.count >= 3 else { return }
            let first = name.split(separator: " ").first.map(String.init) ?? name
            if folded.contains(" \(name) ") || (entity.kind == .person && first.count >= 4 && folded.contains(" \(first) ")) {
                result.append(entity)
            }
        }
        return Array(result.prefix(limit))
    }

    func entity(id: Int64) throws -> GraphEntity? {
        var result: GraphEntity?
        try open().rows("SELECT id, kind, name, mentions, last_ts FROM entities WHERE id = ?", [.int(id)]) {
            result = Self.entity($0)
        }
        return result
    }

    /// Moments worth learning from, alternating your Claude sessions (who
    /// you are at work) with your own chats (who you are with people), newest
    /// first. Taking Claude first left every personal chat unread.
    func learningCandidateIDs(me: String, limit: Int) throws -> [Int64] {
        var work: [Int64] = []
        var personal: [Int64] = []
        let db = try open()
        try db.rows(
            "SELECT id FROM chunks WHERE learned = 0 AND source = 'claude' ORDER BY end_ts DESC LIMIT ?",
            [.of(limit)]
        ) { work.append(Int64($0.int(0))) }
        try db.rows(
            """
            SELECT id FROM chunks
            WHERE learned = 0 AND source != 'claude' AND participants LIKE ? AND length(text) > 300
            ORDER BY end_ts DESC LIMIT ?
            """,
            [.text("%\(me)%"), .of(limit)]
        ) { personal.append(Int64($0.int(0))) }
        var ids: [Int64] = []
        var w = work.makeIterator(), p = personal.makeIterator()
        while ids.count < limit {
            let a = p.next(), b = w.next()
            if a == nil && b == nil { break }
            if let a { ids.append(a) }
            if let b, ids.count < limit { ids.append(b) }
        }
        return ids
    }

    func markLearned(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try open().execute("UPDATE chunks SET learned = 1 WHERE id IN (\(ids.map(String.init).joined(separator: ",")))")
    }

    func learnedCount() throws -> (done: Int, total: Int) {
        let db = try open()
        return (try db.scalarInt("SELECT COUNT(*) FROM chunks WHERE learned = 1"),
                try db.scalarInt("SELECT COUNT(*) FROM chunks WHERE source = 'claude' OR length(text) > 300"))
    }

    // MARK: Facts

    func addFact(subject: String, predicate: String, object: String, confidence: Double,
                 source: MemorySource, chunkID: Int64?, at date: Date) throws {
        try open().run(
            """
            INSERT INTO facts(subject, predicate, object, confidence, source, chunk_id, ts) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(subject, predicate, object) DO UPDATE SET
                confidence = MIN(1.0, MAX(confidence, excluded.confidence) + 0.05), ts = MAX(ts, excluded.ts)
            """,
            [.text(subject), .text(predicate), .text(object), .double(confidence), .text(source.rawValue),
             chunkID.map { .int($0) } ?? .null, .double(date.timeIntervalSince1970)])
    }

    func facts(about subject: String? = nil, matching text: String? = nil, limit: Int = 40) throws -> [MemoryFact] {
        var sql = "SELECT id, subject, predicate, object, confidence, source, ts FROM facts WHERE 1=1"
        var values: [SQLiteDB.Value] = []
        if let subject {
            sql += " AND subject LIKE ?"
            values.append(.text("%\(subject)%"))
        }
        if let text, !text.isEmpty {
            sql += " AND (subject LIKE ? OR object LIKE ? OR predicate LIKE ?)"
            values += [.text("%\(text)%"), .text("%\(text)%"), .text("%\(text)%")]
        }
        sql += " ORDER BY confidence DESC, ts DESC LIMIT ?"
        values.append(.of(limit))
        var result: [MemoryFact] = []
        try open().rows(sql, values) { row in
            result.append(MemoryFact(
                id: Int64(row.int(0)), subject: row.text(1) ?? "", predicate: row.text(2) ?? "",
                object: row.text(3) ?? "", confidence: row.double(4),
                source: MemorySource(rawValue: row.text(5) ?? "") ?? .note,
                date: Date(timeIntervalSince1970: row.double(6))))
        }
        return result
    }

    func deleteFact(id: Int64) throws {
        try open().run("DELETE FROM facts WHERE id = ?", [.int(id)])
    }

    // MARK: Music

    func logPlay(_ play: Play) throws {
        try open().run(
            "INSERT OR IGNORE INTO plays(ts, track, artist, album, app) VALUES (?, ?, ?, ?, ?)",
            [.double(play.date.timeIntervalSince1970), .text(play.track), .text(play.artist), .text(play.album), .text(play.app)])
    }

    func plays(since: Date) throws -> [Play] {
        var result: [Play] = []
        try open().rows(
            "SELECT ts, track, artist, album, app FROM plays WHERE ts >= ? ORDER BY ts DESC LIMIT 2000",
            [.double(since.timeIntervalSince1970)]
        ) { row in
            result.append(Play(date: Date(timeIntervalSince1970: row.double(0)), track: row.text(1) ?? "",
                               artist: row.text(2) ?? "", album: row.text(3) ?? "", app: row.text(4) ?? ""))
        }
        return result
    }

    /// Your own messages in a time window, for lining up mood with words.
    func myMessages(from: Date, to: Date) throws -> [String] {
        var result: [String] = []
        try open().rows(
            "SELECT text FROM messages WHERE is_me = 1 AND source != 'claude' AND ts BETWEEN ? AND ? LIMIT 60",
            [.double(from.timeIntervalSince1970), .double(to.timeIntervalSince1970)]
        ) { result.append($0.text(0) ?? "") }
        return result
    }

    // MARK: Insights cache

    func saveInsight(_ json: String, key: String) throws {
        try open().run(
            "INSERT OR REPLACE INTO insights(key, json, ts) VALUES (?, ?, ?)",
            [.text(key), .text(json), .double(Date().timeIntervalSince1970)])
    }

    func insight(key: String) throws -> (String, Date)? {
        var result: (String, Date)?
        try open().rows("SELECT json, ts FROM insights WHERE key = ?", [.text(key)]) {
            result = ($0.text(0) ?? "", Date(timeIntervalSince1970: $0.double(1)))
        }
        return result
    }

    // MARK: Maintenance

    func forget(source: MemorySource) throws {
        let db = try open()
        try db.transaction {
            try db.run("DELETE FROM chunks WHERE source = ?", [.text(source.rawValue)])
            try db.run("DELETE FROM messages WHERE source = ?", [.text(source.rawValue)])
            try db.run("DELETE FROM chats WHERE source = ?", [.text(source.rawValue)])
            try db.run("DELETE FROM facts WHERE source = ?", [.text(source.rawValue)])
            try db.run("DELETE FROM cursors WHERE source = ?", [.text(source.rawValue)])
        }
        vectorCache = nil
    }
}

/// All chunk vectors, unit length, row-major.
nonisolated struct VectorIndex: Sendable {
    var ids: [Int64]
    var matrix: [Float]
    var dimension: Int
}

extension String {
    /// Lowercased, accents removed, whitespace collapsed: the form names are
    /// compared in, so "João" and "joao " are the same person.
    nonisolated var folded: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
