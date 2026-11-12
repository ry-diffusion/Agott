#if os(macOS)
import AppKit
import Foundation
import OSLog
import SafariServices
import Security

/// A page in Safari as Agott's Safari extension reads it from the DOM: one
/// entry per thing that can be pressed or read, in reading order, already
/// compacted by the extension (`AgottSafari/page-core.js`).
nonisolated struct SafariPage: Sendable, Decodable, Equatable {
    struct Entry: Sendable, Decodable, Equatable {
        /// The element's number inside the page, for acting on it.
        var ref: Int
        var role: String
        var label: String
        var value: String?
        var placeholder: String?
        var flags: [String]
        var section: String
        var header: Bool?
        var full: String?
    }

    var url: String
    var title: String
    var items: [Entry]
    var offscreen: Int
    var truncated: Int
    var incomplete: Bool?
    /// How far down the page is scrolled, in percent; nil when it fits.
    var scrolled: Int?

    /// The page's elements in the same numbered list as the rest of the
    /// window. Ids come from the app's id table, by role, words and section
    /// like everything else, so they never clash with the window's own
    /// controls and stay the same from one read to the next (and across pages
    /// that share a menu).
    func items(ids: inout AXCompactor.IDs) -> [AXItem] {
        var seen: [String: Int] = [:]
        var place = title.isEmpty ? url : "\"\(title)\" · \(url)"
        if let scrolled { place += " · scrolled \(scrolled)%" }
        var result = [AXItem(id: 0, role: "section", label: "Web page \(place)", value: nil, placeholder: nil, flags: [],
                             frame: nil, ref: nil, key: "web|page", isHeader: true)]
        for entry in items {
            let header = entry.header == true
            let base = "web|\(entry.role)|\(entry.label)|\(entry.section)"
            let count = seen[base, default: 0]
            seen[base] = count + 1
            let key = count == 0 ? base : "\(base)#\(count)"
            result.append(AXItem(
                id: header ? 0 : ids.id(for: key), role: entry.role, label: entry.label, value: entry.value,
                placeholder: entry.placeholder, flags: entry.flags, fullValue: entry.full, frame: nil, ref: nil, key: key,
                isHeader: header, web: header ? nil : entry.ref))
        }
        return result
    }
}

/// What the page says after an action.
nonisolated struct SafariAnswer: Sendable, Decodable {
    var ok: Bool?
    var error: String?
    /// The option picked in a select.
    var chose: String?
    /// The page went away before it could answer (it navigated).
    var lost: Bool?
    var unreachable: Bool?
}

/// Talks to Agott's Safari Web Extension (`AgottSafari`). Apple's way, from
/// "Messaging between the app and JavaScript in a Safari web extension":
/// the app sends with `SFSafariApplication.dispatchMessage`, which reaches
/// the background script's native port (`browser.runtime.connectNative`);
/// the background script asks the page's content script, and answers with
/// `browser.runtime.sendNativeMessage`, which goes to the extension's own
/// handler. The handler runs sandboxed, so it leaves the answer in the App
/// Group container both share, where this waits for it.
final class SafariBridge {
    static let shared = SafariBridge()

    nonisolated static let extensionID = "br.com.zesmoi.Agott.Safari"
    nonisolated static let safariApps: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    nonisolated struct Request: Sendable, Encodable {
        var op: String
        var action: String? = nil
        var ref: Int? = nil
        var text: String? = nil
        var replace: Bool? = nil
        var submit: Bool? = nil
        var lines: Int? = nil
    }

    enum Failure: LocalizedError {
        case noGroup, noAnswer

        var errorDescription: String? {
            switch self {
            case .noGroup: String(localized: "Agott has no App Group container to share with its Safari extension.")
            case .noAnswer: String(localized: "The Safari page did not answer.")
            }
        }
    }

    /// The last ping: whether the extension answered, and when.
    private var answering: (ok: Bool, at: Date)?
    private let log = Logger(subsystem: "br.com.zesmoi.Agott", category: "safari")

    private init() {}

    /// Whether the extension is turned on in Safari's settings.
    static func isEnabled() async -> Bool {
        (try? await SFSafariExtensionManager.stateOfSafariExtension(withIdentifier: extensionID))?.isEnabled ?? false
    }

    static func openSettings() {
        Task { try? await SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionID) }
    }

    /// Whether the extension answers, asked at most every half minute (every
    /// few seconds after it did not), so a look at Safari costs no wait when
    /// the extension is off.
    func isAnswering() async -> Bool {
        if let answering, Date().timeIntervalSince(answering.at) < (answering.ok ? 30 : 8) { return answering.ok }
        let ok = (try? await send(Request(op: "ping"), timeout: .milliseconds(1200))) != nil
        answering = (ok, Date())
        if !ok { log.debug("the Safari extension did not answer a ping") }
        return ok
    }

    /// The page in front of Safari, or nil when it cannot be read this way
    /// (the extension is off, the page is Safari's own, the site is not allowed).
    func snapshot() async -> SafariPage? {
        guard await isAnswering() else { return nil }
        do {
            let data = try await send(Request(op: "snapshot"), timeout: .seconds(4))
            if let answer = try? JSONDecoder().decode(SafariAnswer.self, from: data), let error = answer.error {
                log.debug("the page cannot be read: \(error, privacy: .public)")
                return nil
            }
            return try JSONDecoder().decode(SafariPage.self, from: data)
        } catch {
            answering = (false, Date())
            log.debug("no snapshot: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Does `request` on the page and waits for it to settle there.
    func act(_ request: Request) async throws -> SafariAnswer {
        do {
            let data = try await send(request, timeout: .seconds(5))
            return try JSONDecoder().decode(SafariAnswer.self, from: data)
        } catch Failure.noAnswer {
            // A click that leaves the page takes the content script with it.
            return SafariAnswer(lost: true)
        }
    }

    private func send(_ request: Request, timeout: Duration) async throws -> Data {
        guard let folder = Self.folder else { throw Failure.noGroup }
        let id = UUID().uuidString
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        try await SFSafariApplication.dispatchMessage(
            withName: "request", toExtensionWithIdentifier: Self.extensionID, userInfo: ["id": id, "request": json])
        return try await Self.wait(for: folder.appending(path: "\(id).json"), timeout: timeout)
    }

    @concurrent nonisolated private static func wait(for file: URL, timeout: Duration) async throws -> Data {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if let data = try? Data(contentsOf: file) {
                try? FileManager.default.removeItem(at: file)
                return data
            }
            try await Task.sleep(for: .milliseconds(15))
        }
        throw Failure.noAnswer
    }

    /// `<group container>/SafariBridge`, emptied of answers nobody waited for.
    /// The group comes from Agott's own entitlements, as in the extension.
    private static let folder: URL? = {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String],
              let group = groups.first,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        let folder = container.appending(path: "SafariBridge", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for stale in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: stale)
        }
        return folder
    }()
}
#endif
