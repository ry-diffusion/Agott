#if os(macOS)
import AVFoundation
import Foundation

/// Voice notes and photos from WhatsApp, turned into words memory can read.
///
/// A voice note is transcribed on this Mac with the same speech engine as
/// dictation; a photo becomes what Apple's on-device classifier sees in it
/// and any text written in it. Each lands in the conversation as a message
/// at the time it was sent ("[voice note] tô chegando em dez minutos"), so
/// moments, learning and recall read it in context with the words around it.
///
/// Only media WhatsApp already downloaded to this Mac can be read; nothing
/// leaves the Mac for this.
enum MediaIngestor {
    enum Kind: Int, Sendable { case photo = 1, voice = 3 }

    struct Item: Sendable {
        var message: RawMessage
        var file: URL
        var kind: Kind
        var caption: String?
    }

    /// Batches read in one indexing run (30 each): about 90 items, a few
    /// minutes of voice notes at most.
    static let batchesPerRun = 3

    /// How far it has read, in WhatsApp's own clock: photos and voice notes
    /// apart, so voice notes can be read again with a better engine without
    /// describing every photo twice.
    private static func cursorKey(_ kind: Kind) -> String {
        kind == .voice ? voiceCursorKey : "media.whatsapp.after"
    }
    /// Voice notes read with Parakeet; the Apple-engine transcripts were
    /// thrown away when this key changed.
    static let voiceCursorKey = "media.whatsapp.voice.parakeet.after"
    static let root = URL.homeDirectory
        .appending(path: "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message", directoryHint: .isDirectory)

    /// Voice notes or photos after their cursor that are on disk, oldest first.
    static func pending(_ kind: Kind, limit: Int, contacts: ContactBook) throws -> [Item] {
        let settings = AppSettings.shared
        // Voice notes are only read with Parakeet: anything else would be
        // thrown away and read again once it is here.
        let wanted = kind == .voice ? settings.transcribeVoiceNotes && Parakeet.isInstalled : settings.describePhotos
        guard wanted, let db = try? SQLiteDB(path: WhatsAppSource.path, readOnly: true) else { return [] }
        let types = [kind.rawValue]
        let after = UserDefaults.standard.double(forKey: cursorKey(kind))
        var items: [Item] = []
        try db.rows(
            """
            SELECT \(WhatsAppSource.messageColumnsSQL), m.ZMESSAGETYPE, mi.ZMEDIALOCALPATH
            \(WhatsAppSource.messageJoinsSQL)
            JOIN ZWAMEDIAITEM mi ON mi.Z_PK = m.ZMEDIAITEM
            WHERE m.ZMESSAGEDATE > ? AND m.ZMESSAGETYPE IN (\(types.map(String.init).joined(separator: ",")))
              AND mi.ZMEDIALOCALPATH IS NOT NULL AND mi.ZMEDIALOCALPATH != ''
              AND COALESCE(s.ZCONTACTJID, '') NOT LIKE '%status%'
              AND COALESCE(s.ZREMOVED, 0) = 0
            ORDER BY m.ZMESSAGEDATE ASC LIMIT ?
            """,
            [.double(after), .of(limit)]
        ) { row in
            guard let kind = Kind(rawValue: row.int(13)), let path = row.text(14) else { return }
            let file = root.appending(path: path)
            let caption = row.text(2).flatMap { $0.isEmpty ? nil : $0 }
            var message = WhatsAppSource.message(from: row, text: "", contacts: contacts, externalPrefix: "media-")
            message.date = Date(timeIntervalSince1970: row.double(3) + appleEpochOffset)
            items.append(Item(message: message, file: file, kind: kind, caption: caption))
        }
        return items
    }

    /// Reads one batch into memory. Returns how many of each were added, or
    /// nil when there was nothing to read.
    static func run(contacts: ContactBook, limit: Int = 30) async -> (voice: Int, photos: Int)? {
        let voiceItems = (try? pending(.voice, limit: limit, contacts: contacts)) ?? []
        let photoItems = (try? pending(.photo, limit: limit, contacts: contacts)) ?? []
        guard !voiceItems.isEmpty || !photoItems.isEmpty else { return nil }
        var voice = 0, photos = 0
        for (kind, items) in [(Kind.voice, voiceItems), (Kind.photo, photoItems)] where !items.isEmpty {
            let added = await read(items, kind: kind)
            if kind == .voice { voice += added } else { photos += added }
        }
        return (voice, photos)
    }

    /// Reads items of one kind into memory and moves that kind's cursor.
    private static func read(_ items: [Item], kind: Kind) async -> Int {
        var messages: [RawMessage] = []
        var last = UserDefaults.standard.double(forKey: cursorKey(kind))
        var added = 0
        for item in items {
            guard !Task.isCancelled else { break }
            // Dictation comes first: wait while you are talking (a minute at most).
            for _ in 0..<120 where await MainActor.run(body: { Dictation.shared.isRunning }) {
                try? await Task.sleep(for: .milliseconds(500))
            }
            if FileManager.default.fileExists(atPath: item.file.path), let text = await words(for: item) {
                var message = item.message
                message.text = text
                messages.append(message)
                added += 1
            }
            // Read or unreadable, it is not tried again.
            last = item.message.date.timeIntervalSince1970 - appleEpochOffset
        }
        if !messages.isEmpty { _ = try? await MemoryStore.shared.ingest(messages) }
        UserDefaults.standard.set(last, forKey: cursorKey(kind))
        return added
    }

    /// The words a voice note or a photo stands for.
    static func words(for item: Item) async -> String? {
        switch item.kind {
        case .voice:
            guard let transcript = await transcribe(item.file), !transcript.isEmpty else { return nil }
            return String(localized: "[voice note] \(transcript)")
        case .photo:
            var parts: [String] = []
            // Vision on a background thread: on the main one every photo
            // in a batch froze the window for a moment.
            let file = item.file
            if let labels = await Task.detached(priority: .utility, operation: { ImageDescriber.labels(file) }).value {
                parts.append(labels)
            }
            if let written = await AttachmentStore.recognizedText(in: item.file) {
                parts.append(String(localized: "text in it: \(String(written.prefix(600)))"))
            }
            guard !parts.isEmpty else { return nil }
            return String(localized: "[photo] \(parts.joined(separator: "; "))")
        }
    }

    /// A whole audio file to text, on the Mac: Parakeet when chosen and
    /// installed, Apple's engine otherwise. Gives up after a minute.
    static func transcribe(_ url: URL) async -> String? {
        guard Parakeet.isInstalled else { return nil }
        let language = Parakeet.language(for: AppSettings.shared.speechLocale)
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await Parakeet.shared.transcribe(file: url, language: language) }
            group.addTask {
                try? await Task.sleep(for: .seconds(60))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
#endif
