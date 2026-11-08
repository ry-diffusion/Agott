import Foundation
import SwiftUI

/// Profile photos from the WhatsApp desktop app, by the chat's name.
///
/// WhatsApp keeps each contact's and group's picture in
/// `Media/Profile/<jid>-<n>.jpg` (or a 96 px `.thumb`), and
/// `ZWAPROFILEPICTUREITEM` says which file belongs to which jid. Agott
/// already knows each chat's jid and name, so the two meet on the jid.
/// Read-only, like the rest of the WhatsApp reading.
@MainActor @Observable
final class ContactPhotos {
    static let shared = ContactPhotos()

    private(set) var byName: [String: URL] = [:]
    @ObservationIgnored private var images: [URL: Image] = [:]

    static let root = URL.homeDirectory
        .appending(path: "Library/Group Containers/group.net.whatsapp.WhatsApp.shared", directoryHint: .isDirectory)

    func refresh() async {
        let found = await Self.load()
        if found != byName { byName = found; images = [:] }
    }

    func image(for name: String) -> Image? {
        guard let url = byName[name.lowercased()] else { return nil }
        if let cached = images[url] { return cached }
        #if os(macOS)
        guard let picture = NSImage(contentsOf: url) else { return nil }
        let image = Image(nsImage: picture)
        #else
        guard let picture = UIImage(contentsOfFile: url.path) else { return nil }
        let image = Image(uiImage: picture)
        #endif
        images[url] = image
        return image
    }

    @concurrent nonisolated static func load() async -> [String: URL] {
        let database = root.appending(path: "ChatStorage.sqlite").path
        guard FileManager.default.fileExists(atPath: database),
              let db = try? SQLiteDB(path: database, readOnly: true) else { return [:] }
        var paths: [String: String] = [:]
        try? db.rows("SELECT ZJID, ZPATH FROM ZWAPROFILEPICTUREITEM WHERE ZPATH IS NOT NULL AND ZPATH != ''") { row in
            if let jid = row.text(0), let path = row.text(1) { paths[jid] = path }
        }
        guard !paths.isEmpty else { return [:] }
        let chats = (try? await MemoryStore.shared.chats(limit: 5000, includeGroups: true)) ?? []
        var result: [String: URL] = [:]
        for chat in chats where chat.source == .whatsapp && !chat.name.isEmpty {
            guard let path = paths[chat.chatID], let file = photoFile(path) else { continue }
            // The first chat with a name keeps it: the busiest, as chats come sorted.
            let key = chat.name.lowercased()
            if result[key] == nil { result[key] = file }
        }
        return result
    }

    /// The full picture when WhatsApp downloaded it, the thumbnail otherwise.
    nonisolated static func photoFile(_ path: String) -> URL? {
        let base = root.appending(path: path)
        for candidate in [base.appendingPathExtension("jpg"), base.appendingPathExtension("thumb"), base]
            where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }
}
