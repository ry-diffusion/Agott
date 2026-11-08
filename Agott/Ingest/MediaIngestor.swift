#if os(macOS)
import AVFoundation
import Foundation
import Speech

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

    /// How far it has read, in WhatsApp's own clock.
    private static let cursorKey = "media.whatsapp.after"
    static let root = URL.homeDirectory
        .appending(path: "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message", directoryHint: .isDirectory)

    /// Voice notes and photos after the cursor that are on disk, oldest first.
    static func pending(limit: Int, contacts: ContactBook) throws -> [Item] {
        let settings = AppSettings.shared
        var types: [Int] = []
        if settings.transcribeVoiceNotes { types.append(Kind.voice.rawValue) }
        if settings.describePhotos { types.append(Kind.photo.rawValue) }
        guard !types.isEmpty, let db = try? SQLiteDB(path: WhatsAppSource.path, readOnly: true) else { return [] }
        let after = UserDefaults.standard.double(forKey: cursorKey)
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

    /// Reads one batch into memory. Returns how many were added, or nil when
    /// there was nothing to read.
    static func run(contacts: ContactBook, limit: Int = 30) async -> Int? {
        guard let items = try? pending(limit: limit, contacts: contacts), !items.isEmpty else { return nil }
        var messages: [RawMessage] = []
        var last = UserDefaults.standard.double(forKey: cursorKey)
        for item in items {
            guard !Task.isCancelled else { break }
            if FileManager.default.fileExists(atPath: item.file.path), let text = await words(for: item) {
                var message = item.message
                message.text = text
                messages.append(message)
            }
            // Read or unreadable, it is not tried again.
            last = item.message.date.timeIntervalSince1970 - appleEpochOffset
        }
        if !messages.isEmpty { _ = try? await MemoryStore.shared.ingest(messages) }
        UserDefaults.standard.set(last, forKey: cursorKey)
        return messages.count
    }

    /// The words a voice note or a photo stands for.
    static func words(for item: Item) async -> String? {
        switch item.kind {
        case .voice:
            guard let transcript = await transcribe(item.file), !transcript.isEmpty else { return nil }
            return String(localized: "[voice note] \(transcript)")
        case .photo:
            var parts: [String] = []
            if let labels = await MainActor.run(body: { ImageDescriber.labels(item.file) }) { parts.append(labels) }
            if let written = await AttachmentStore.recognizedText(in: item.file) {
                parts.append(String(localized: "text in it: \(String(written.prefix(600)))"))
            }
            guard !parts.isEmpty else { return nil }
            return String(localized: "[photo] \(parts.joined(separator: "; "))")
        }
    }

    /// A whole audio file to text, on the Mac. Gives up after a minute.
    static func transcribe(_ url: URL) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await transcription(of: url) }
            group.addTask {
                try? await Task.sleep(for: .seconds(60))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func transcription(of url: URL) async throws -> String? {
        let requested = Locale(identifier: AppSettings.shared.speechLocale)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else { return nil }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: url)
        let collect = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text = Dictation.join(text, String(result.text.characters))
            }
            return text
        }
        _ = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
        let text = try await collect.value
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
