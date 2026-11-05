import Foundation

/// Somewhere messages live. Each source reads incrementally: it is handed the
/// newest timestamp already stored and returns only what came after.
nonisolated protocol MessageSource: Sendable {
    var kind: MemorySource { get }
    /// Whether the data is present on this machine at all.
    var isPresent: Bool { get }
    /// Reads messages newer than `after` (seconds since 1970), oldest first,
    /// at most `limit` of them.
    func read(after: Double, limit: Int, contacts: ContactBook) throws -> [RawMessage]
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

    func read(after: Double, limit: Int, contacts: ContactBook) throws -> [RawMessage] {
        guard isPresent else { throw SourceError.missing("Messages") }
        guard FileManager.default.isReadableFile(atPath: Self.path),
              let db = try? SQLiteDB(path: Self.path, readOnly: true),
              (try? db.scalarInt("SELECT COUNT(*) FROM message LIMIT 1")) != nil
        else { throw SourceError.needsFullDiskAccess("Messages") }

        // `date` is nanoseconds since 2001 on anything recent, seconds before.
        let afterApple = max(0, after - appleEpochOffset) * 1_000_000_000
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
            WHERE m.date > ? AND m.associated_message_type = 0
            ORDER BY m.date LIMIT ?
            """,
            [.double(afterApple), .of(limit)]
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

    func read(after: Double, limit: Int, contacts: ContactBook) throws -> [RawMessage] {
        guard isPresent else { throw SourceError.missing("WhatsApp") }
        guard let db = try? SQLiteDB(path: Self.path, readOnly: true),
              (try? db.scalarInt("SELECT COUNT(*) FROM ZWAMESSAGE LIMIT 1")) != nil
        else { throw SourceError.needsFullDiskAccess("WhatsApp") }

        let afterApple = after - appleEpochOffset
        var result: [RawMessage] = []
        // Message types: 0 text, 1 image, 2 video, 3 voice, 7 link…
        // Only text carries words; a caption on an image is in ZTEXT too.
        try db.rows(
            """
            SELECT m.Z_PK, COALESCE(m.ZSTANZAID, m.Z_PK), m.ZTEXT, m.ZMESSAGEDATE, m.ZISFROMME,
                   s.Z_PK, COALESCE(s.ZPARTNERNAME, ''), COALESCE(s.ZCONTACTJID, ''), s.ZSESSIONTYPE,
                   COALESCE(g.ZCONTACTNAME, g.ZFIRSTNAME, m.ZPUSHNAME, ''), COALESCE(g.ZMEMBERJID, m.ZFROMJID, '')
            FROM ZWAMESSAGE m
            JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION
            LEFT JOIN ZWAGROUPMEMBER g ON g.Z_PK = m.ZGROUPMEMBER
            WHERE m.ZMESSAGEDATE > ? AND m.ZTEXT IS NOT NULL AND m.ZTEXT != ''
              AND COALESCE(s.ZCONTACTJID, '') NOT LIKE '%status%'
              AND COALESCE(s.ZREMOVED, 0) = 0
            ORDER BY m.ZMESSAGEDATE LIMIT ?
            """,
            [.double(afterApple), .of(limit)]
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

// MARK: - Claude Code history

/// Reads Claude Code's session transcripts in `~/.claude/projects`.
///
/// These are the best record there is of who you are at work: what you build,
/// how you think about it, what you care about getting right. Your own turns
/// are kept whole; Claude's are trimmed, because a page of generated code says
/// little about you.
nonisolated struct ClaudeHistorySource: MessageSource {
    var kind: MemorySource { .claude }

    static let root = URL.homeDirectory.appending(path: ".claude/projects", directoryHint: .isDirectory)

    var isPresent: Bool { FileManager.default.fileExists(atPath: Self.root.path) }

    func read(after: Double, limit: Int, contacts: ContactBook) throws -> [RawMessage] {
        guard isPresent else { throw SourceError.missing("Claude Code history") }
        let files = (FileManager.default.enumerator(
            at: Self.root, includingPropertiesForKeys: [.contentModificationDateKey])?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "jsonl" && !$0.path.contains("/subagents/") }
            .filter { url in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return (modified?.timeIntervalSince1970 ?? 0) > after
            }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var result: [RawMessage] = []

        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            let project = file.deletingLastPathComponent().lastPathComponent
                .replacingOccurrences(of: "-Users-\(NSUserName())-", with: "")
                .replacingOccurrences(of: "-", with: "/")
            let session = file.deletingPathExtension().lastPathComponent
            var title: String?
            var index = 0

            for line in data.split(separator: UInt8(ascii: "\n")) {
                index += 1
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let type = object["type"] as? String, type == "user" || type == "assistant",
                      object["isMeta"] as? Bool != true,
                      let message = object["message"] as? [String: Any]
                else { continue }
                let date = (object["timestamp"] as? String).flatMap(iso.date(from:)) ?? .now
                guard date.timeIntervalSince1970 > after else { continue }

                let text = Self.text(of: message["content"])
                guard !text.isEmpty, !Self.isNoise(text) else { continue }
                let isMe = type == "user"
                if isMe, title == nil { title = String(text.prefix(60)) }

                result.append(RawMessage(
                    source: .claude, externalID: (object["uuid"] as? String) ?? "\(session)#\(index)",
                    chatID: session, chatName: "\(project) — \(title ?? session.prefix(8).description)",
                    isGroup: false, sender: isMe ? AppSettings.myNameSnapshot : "Claude",
                    isFromMe: isMe, date: date,
                    text: String(text.prefix(isMe ? 2400 : 500))))
            }
        }
        result.sort { $0.date < $1.date }
        return Array(result.prefix(limit))
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
