import Foundation

/// Somewhere messages live. Each source reads incrementally: it is handed the
/// newest timestamp already stored and returns only what came after.
nonisolated protocol MessageSource: Sendable {
    var kind: MemorySource { get }
    /// Whether the data is present on this machine at all.
    var isPresent: Bool { get }
    /// Reads messages newer than `after` (seconds since 1970), oldest first,
    /// at most `limit` of them.
    /// Reads messages strictly between `after` and `before` (seconds since
    /// 1970), oldest first, or newest first when `newestFirst` is set.
    func read(after: Double, before: Double?, newestFirst: Bool, limit: Int, contacts: ContactBook) throws -> [RawMessage]
    /// Whether the source can page newest-first. Message databases can;
    /// append-only transcripts cannot.
    var supportsNewestFirst: Bool { get }
    /// How many messages lie between `after` and `before`, if the source can
    /// tell cheaply. Used for progress.
    func estimatedCount(after: Double, before: Double?) -> Int?
}

extension MessageSource {
    var supportsNewestFirst: Bool { false }
    func estimatedCount(after: Double, before: Double?) -> Int? { nil }

    func read(after: Double, limit: Int, contacts: ContactBook) throws -> [RawMessage] {
        try read(after: after, before: nil, newestFirst: false, limit: limit, contacts: contacts)
    }
}

nonisolated enum SourceError: LocalizedError {
    case needsFullDiskAccess(String)
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .needsFullDiskAccess(let what):
            String(localized: "Agott needs Full Disk Access to read \(what). Open System Settings → Privacy & Security → Full Disk Access and turn Agott on.")
        case .missing(let what):
            String(localized: "\(what) was not found on this Mac.")
        }
    }
}

/// Apple counts from 2001; Unix from 1970.
nonisolated let appleEpochOffset: Double = 978_307_200

#if os(macOS)

// MARK: - iMessage

/// Reads `~/Library/Messages/chat.db`, read-only.
///
/// Since macOS Ventura most message bodies are not in `text` at all but in
/// `attributedBody`, an `NSAttributedString` in the old typedstream archive
/// format. `NSUnarchiver` still reads it; a byte scan is the fallback for the
/// rows it refuses.
nonisolated struct IMessageSource: MessageSource {
    var kind: MemorySource { .imessage }

    static let path = URL.homeDirectory.appending(path: "Library/Messages/chat.db").path

    var isPresent: Bool { FileManager.default.fileExists(atPath: Self.path) }

    var supportsNewestFirst: Bool { true }

    static func appleNanos(_ unix: Double?) -> Double {
        guard let unix, unix < 1e14 else { return 9e30 }
        return max(0, unix - appleEpochOffset) * 1_000_000_000
    }

    func estimatedCount(after: Double, before: Double?) -> Int? {
        guard let db = try? SQLiteDB(path: Self.path, readOnly: true) else { return nil }
        return try? db.scalarInt(
            "SELECT COUNT(*) FROM message WHERE date > ? AND date < ? AND associated_message_type = 0",
            [.double(Self.appleNanos(after)), .double(Self.appleNanos(before))])
    }

    func read(after: Double, before: Double?, newestFirst: Bool, limit: Int, contacts: ContactBook) throws -> [RawMessage] {
        guard isPresent else { throw SourceError.missing("Messages") }
        guard FileManager.default.isReadableFile(atPath: Self.path),
              let db = try? SQLiteDB(path: Self.path, readOnly: true),
              (try? db.scalarInt("SELECT COUNT(*) FROM message LIMIT 1")) != nil
        else { throw SourceError.needsFullDiskAccess("Messages") }

        // `date` is nanoseconds since 2001 on anything recent, seconds before.
        let afterApple = Self.appleNanos(after)
        let beforeApple = Self.appleNanos(before)
        var result: [RawMessage] = []
        try db.rows(
            """
            SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.date, m.is_from_me,
                   COALESCE(h.id, ''), COALESCE(c.chat_identifier, ''), COALESCE(c.display_name, ''),
                   COALESCE(c.style, 45)
            FROM message m
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN chat c ON c.ROWID = cmj.chat_id
            WHERE m.date > ? AND m.date < ? AND m.associated_message_type = 0
            ORDER BY m.date \(newestFirst ? "DESC" : "ASC") LIMIT ?
            """,
            [.double(afterApple), .double(beforeApple), .of(limit)]
        ) { row in
            let rawDate = row.double(4)
            let seconds = rawDate > 1e12 ? rawDate / 1e9 : rawDate
            let date = Date(timeIntervalSince1970: seconds + appleEpochOffset)

            var text = row.text(2) ?? ""
            if text.isEmpty, let blob = row.blob(3) { text = Self.decodeAttributedBody(blob) ?? "" }
            text = text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }

            let handle = row.text(6) ?? ""
            let chatIdentifier = row.text(7).flatMap { $0.isEmpty ? nil : $0 } ?? handle
            let isGroup = row.int(9) == 43
            let displayName = row.text(8) ?? ""
            let isFromMe = row.int(5) != 0
            let chatName = !displayName.isEmpty ? displayName : contacts.display(chatIdentifier)

            result.append(RawMessage(
                source: .imessage, externalID: row.text(1) ?? String(row.int(0)),
                chatID: chatIdentifier, chatName: chatName, isGroup: isGroup,
                sender: isFromMe ? AppSettings.myNameSnapshot : contacts.display(handle),
                isFromMe: isFromMe, date: date, text: text))
        }
        return result
    }

    static func decodeAttributedBody(_ data: Data) -> String? {
        if let string = NSUnarchiver.unarchiveObject(with: data) as? NSAttributedString {
            return string.string
        }
        // Typedstream fallback: the string follows "NSString", a few marker
        // bytes, then a length (one byte, or 0x81 + two little-endian bytes).
        let bytes = [UInt8](data)
        guard let marker = bytes.firstRange(of: Array("NSString".utf8)) else { return nil }
        var index = marker.upperBound + 5
        guard index < bytes.count else { return nil }
        var length = Int(bytes[index])
        index += 1
        if length == 0x81, index + 1 < bytes.count {
            length = Int(bytes[index]) | Int(bytes[index + 1]) << 8
            index += 2
        }
        guard index + length <= bytes.count else { return nil }
        return String(decoding: bytes[index..<index + length], as: UTF8.self)
    }
}

// MARK: - WhatsApp

/// Reads the WhatsApp desktop app's Core Data store, read-only.
nonisolated struct WhatsAppSource: MessageSource {
    var kind: MemorySource { .whatsapp }

    static let path = URL.homeDirectory
        .appending(path: "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite").path

    var isPresent: Bool { FileManager.default.fileExists(atPath: Self.path) }

    var supportsNewestFirst: Bool { true }

    static func appleSeconds(_ unix: Double?) -> Double {
        guard let unix, unix < 1e14 else { return 9e30 }
        return unix - appleEpochOffset
    }

    func estimatedCount(after: Double, before: Double?) -> Int? {
        guard let db = try? SQLiteDB(path: Self.path, readOnly: true) else { return nil }
        return try? db.scalarInt(
            "SELECT COUNT(*) FROM ZWAMESSAGE WHERE ZMESSAGEDATE > ? AND ZMESSAGEDATE < ? AND ZTEXT IS NOT NULL AND ZTEXT != ''",
            [.double(Self.appleSeconds(after)), .double(Self.appleSeconds(before))])
    }

    func read(after: Double, before: Double?, newestFirst: Bool, limit: Int, contacts: ContactBook) throws -> [RawMessage] {
        guard isPresent else { throw SourceError.missing("WhatsApp") }
        guard let db = try? SQLiteDB(path: Self.path, readOnly: true),
              (try? db.scalarInt("SELECT COUNT(*) FROM ZWAMESSAGE LIMIT 1")) != nil
        else { throw SourceError.needsFullDiskAccess("WhatsApp") }

        let afterApple = Self.appleSeconds(after)
        let beforeApple = Self.appleSeconds(before)
        var result: [RawMessage] = []
        // Message types: 0 text, 1 image, 2 video, 3 voice, 7 link…
        // Only text carries words; a caption on an image is in ZTEXT too.
        try db.rows(
            """
            SELECT m.Z_PK, COALESCE(m.ZSTANZAID, m.Z_PK), m.ZTEXT, m.ZMESSAGEDATE, m.ZISFROMME,
                   s.Z_PK, COALESCE(s.ZPARTNERNAME, ''), COALESCE(s.ZCONTACTJID, ''), s.ZSESSIONTYPE,
                   COALESCE(g.ZCONTACTNAME, g.ZFIRSTNAME, p.ZPUSHNAME, m.ZPUSHNAME, ''), COALESCE(g.ZMEMBERJID, m.ZFROMJID, '')
            FROM ZWAMESSAGE m
            JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
            LEFT JOIN ZWAGROUPMEMBER g ON g.Z_PK = m.ZGROUPMEMBER
            LEFT JOIN ZWAPROFILEPUSHNAME p ON p.ZJID = COALESCE(g.ZMEMBERJID, m.ZFROMJID)
            WHERE m.ZMESSAGEDATE > ? AND m.ZMESSAGEDATE < ? AND m.ZTEXT IS NOT NULL AND m.ZTEXT != ''
              AND COALESCE(s.ZCONTACTJID, '') NOT LIKE '%status%'
              AND COALESCE(s.ZREMOVED, 0) = 0
            ORDER BY m.ZMESSAGEDATE \(newestFirst ? "DESC" : "ASC") LIMIT ?
            """,
            [.double(afterApple), .double(beforeApple), .of(limit)]
        ) { row in
            let text = row.text(2) ?? ""
            let date = Date(timeIntervalSince1970: row.double(3) + appleEpochOffset)
            let isFromMe = row.int(4) != 0
            let jid = row.text(7) ?? ""
            let isGroup = row.int(8) == 1 || jid.hasSuffix("@g.us")
            let partner = row.text(6) ?? ""
            let chatName = !partner.isEmpty ? partner : contacts.display(jid)

            let sender: String
            if isFromMe {
                sender = AppSettings.myNameSnapshot
            } else if isGroup {
                let memberName = row.text(9) ?? ""
                let memberJID = row.text(10) ?? ""
                sender = contacts.name(forHandle: memberJID) ?? (memberName.isEmpty ? contacts.display(memberJID) : memberName)
            } else {
                sender = chatName
            }

            result.append(RawMessage(
                source: .whatsapp, externalID: row.text(1) ?? String(row.int(0)),
                chatID: jid.isEmpty ? String(row.int(5)) : jid, chatName: chatName, isGroup: isGroup,
                sender: sender, isFromMe: isFromMe, date: date, text: text))
        }
        return result
    }
}

extension WhatsAppSource {
    /// Display names WhatsApp knows for people who are not in your contacts,
    /// keyed by the name Agott used before it knew them: the id as digits.
    static func profileNames() -> [String: String] {
        guard let db = try? SQLiteDB(path: path, readOnly: true) else { return [:] }
        var names: [String: String] = [:]
        try? db.rows("SELECT ZJID, ZPUSHNAME FROM ZWAPROFILEPUSHNAME WHERE ZPUSHNAME IS NOT NULL AND ZPUSHNAME != ''") { row in
            guard let jid = row.text(0), let name = row.text(1) else { return }
            let bare = jid.components(separatedBy: "@").first ?? jid
            guard bare.allSatisfy(\.isNumber), bare.count > 6 else { return }
            names["+" + bare] = name.trimmingCharacters(in: .whitespaces)
        }
        return names
    }
}

// MARK: - Claude Code history

/// Reads Claude Code's session transcripts in `~/.claude/projects`.
///
/// These are the best record there is of who you are at work: what you build,
/// how you think about it, what you care about getting right. Your own turns
/// are kept whole; Claude's are trimmed, because a page of generated code says
/// little about you.
nonisolated struct ClaudeHistorySource: MessageSource {
    var kind: MemorySource { .claude }

    static let defaultRoot = URL.homeDirectory.appending(path: ".claude/projects", directoryHint: .isDirectory)
    var root: URL = Self.defaultRoot

    var isPresent: Bool { FileManager.default.fileExists(atPath: root.path) }

    /// Bytes already read per transcript, so each file is parsed once and a
    /// growing session only costs its new lines.
    static let progressKey = "claudeFileProgress"

    static func resetProgress() {
        UserDefaults.standard.removeObject(forKey: progressKey)
        pending = nil
    }

    /// Offsets reached by the last read, saved only once its messages are
    /// stored. Saving them before would lose messages if the app stopped in
    /// between.
    nonisolated(unsafe) private static var pending: [String: Int]?

    static func commitProgress() {
        guard let pending else { return }
        UserDefaults.standard.set(pending, forKey: progressKey)
        Self.pending = nil
    }

    /// Reads everything new in one pass and ignores `limit`: transcripts are
    /// appended to, so the unit of progress is a byte offset per file, not a
    /// date. Re-reading files to page through dates was what pinned a core.
    func read(after: Double, before: Double?, newestFirst: Bool, limit: Int, contacts: ContactBook) throws -> [RawMessage] {
        guard isPresent else { throw SourceError.missing("Claude Code history") }
        var progress = UserDefaults.standard.dictionary(forKey: Self.progressKey) as? [String: Int] ?? [:]
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "jsonl" && !$0.path.contains("/subagents/") }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var result: [RawMessage] = []

        for file in files {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let done = progress[file.path] ?? 0
            guard size > done else { continue }
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            try? handle.seek(toOffset: UInt64(done > size ? 0 : done))
            guard let data = try? handle.readToEnd(), !data.isEmpty else { continue }

            let project = file.deletingLastPathComponent().lastPathComponent
                .replacingOccurrences(of: "-Users-\(NSUserName())-", with: "")
                .replacingOccurrences(of: "-", with: "/")
            let session = file.deletingPathExtension().lastPathComponent
            var consumed = 0

            Self.lines(in: data) { line, end in
                consumed = end
                guard let object = Self.parse(line),
                      let type = object["type"] as? String,
                      object["isMeta"] as? Bool != true,
                      let message = object["message"] as? [String: Any]
                else { return }
                let text = Self.text(of: message["content"])
                guard !text.isEmpty, !Self.isNoise(text) else { return }
                let isMe = type == "user"
                let date = (object["timestamp"] as? String).flatMap(iso.date(from:)) ?? .now
                let title = String((isMe ? text : session).prefix(60))
                result.append(RawMessage(
                    source: .claude, externalID: (object["uuid"] as? String) ?? "\(session)#\(done + end)",
                    chatID: session, chatName: "\(project) — \(title)",
                    isGroup: false, sender: isMe ? AppSettings.myNameSnapshot : "Claude",
                    isFromMe: isMe, date: date,
                    text: String(text.prefix(isMe ? 2400 : 500))))
            }
            // Only whole lines count as read; a half-written last line is
            // picked up next time.
            progress[file.path] = done + consumed
        }
        Self.pending = progress
        // One chat name per session: the first thing you asked in it.
        var titles: [String: String] = [:]
        for message in result.sorted(by: { $0.date < $1.date }) where message.isFromMe && titles[message.chatID] == nil {
            titles[message.chatID] = message.chatName
        }
        return result
            .map { message in
                var message = message
                if let title = titles[message.chatID] { message.chatName = title }
                return message
            }
            .sorted { $0.date < $1.date }
    }

    /// Calls `body` with each complete line and the offset just past it.
    private static func lines(in data: Data, _ body: (UnsafeRawBufferPointer, Int) -> Void) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var start = 0
            while start < raw.count {
                guard let hit = memchr(base + start, 0x0A, raw.count - start) else { return }
                let end = base.distance(to: UnsafeRawPointer(hit))
                body(UnsafeRawBufferPointer(start: base + start, count: end - start), end + 1)
                start = end + 1
            }
        }
    }

    private static let userMarker = Array(#""type":"user""#.utf8)
    private static let assistantMarker = Array(#""type":"assistant""#.utf8)
    private static let toolResultMarker = Array(#""tool_use_id""#.utf8)

    /// Cheap byte checks first; JSON only for lines that can hold your words.
    /// Tool results (file dumps, command output) are most of the bytes and
    /// none of the meaning, so they are never decoded.
    private static func parse(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        guard line.count > 20, line.count < 400_000 else { return nil }
        func contains(_ needle: [UInt8]) -> Bool {
            needle.withUnsafeBytes { n in memmem(line.baseAddress, line.count, n.baseAddress, n.count) != nil }
        }
        guard contains(userMarker) || contains(assistantMarker), !contains(toolResultMarker) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
    }

    static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block in
            block["type"] as? String == "text" ? block["text"] as? String : nil
        }.joined(separator: "\n")
    }

    static func isNoise(_ text: String) -> Bool {
        text.hasPrefix("<command-") || text.hasPrefix("<local-command") || text.hasPrefix("Caveat:")
            || text.contains("<system-reminder>") || text.hasPrefix("[Request interrupted")
    }
}

/// A claude.ai data export (`conversations.json`), imported once from a file
/// you pick.
nonisolated enum ClaudeExportImporter {
    static func read(_ url: URL) throws -> [RawMessage] {
        let data = try Data(contentsOf: url)
        guard let conversations = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var result: [RawMessage] = []
        for conversation in conversations {
            let id = conversation["uuid"] as? String ?? UUID().uuidString
            let name = conversation["name"] as? String ?? "claude.ai"
            for (index, message) in ((conversation["chat_messages"] as? [[String: Any]]) ?? []).enumerated() {
                let isMe = message["sender"] as? String == "human"
                var text = message["text"] as? String ?? ""
                if text.isEmpty { text = ClaudeHistorySource.text(of: message["content"]) }
                guard !text.isEmpty else { continue }
                let date = (message["created_at"] as? String).flatMap(iso.date(from:)) ?? .now
                result.append(RawMessage(
                    source: .claude, externalID: message["uuid"] as? String ?? "\(id)#\(index)",
                    chatID: id, chatName: "claude.ai — \(name)", isGroup: false,
                    sender: isMe ? AppSettings.myNameSnapshot : "Claude", isFromMe: isMe, date: date,
                    text: String(text.prefix(isMe ? 2400 : 500))))
            }
        }
        return result
    }
}

#endif
