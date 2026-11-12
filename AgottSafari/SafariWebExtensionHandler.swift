import Foundation
import os.log
import SafariServices
import Security

/// The native side of Agott's Safari extension. The background script sends
/// each answer for Agott here (`browser.runtime.sendNativeMessage`); this
/// writes it into the App Group container Agott shares with the extension,
/// where Agott is waiting for it. Nothing else is kept.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let log = Logger(subsystem: "br.com.zesmoi.Agott.Safari", category: "bridge")

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        var answer: [String: Any] = ["ok": true]

        if message?["type"] as? String == "reply", let id = message?["id"] as? String, let body = message?["body"] as? String {
            do {
                try Self.deliver(body, id: id)
            } catch {
                log.error("Could not hand the answer to Agott: \(error.localizedDescription, privacy: .public)")
                answer = ["ok": false, "error": error.localizedDescription]
            }
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: answer]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    enum Failure: LocalizedError {
        case noGroup, badID
        var errorDescription: String? {
            switch self {
            case .noGroup: "The extension has no App Group container."
            case .badID: "The answer has no valid id."
            }
        }
    }

    /// Ids are UUIDs made by Agott; anything else is not written.
    private static func deliver(_ body: String, id: String) throws {
        guard UUID(uuidString: id) != nil else { throw Failure.badID }
        guard let folder = folder() else { throw Failure.noGroup }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(body.utf8).write(to: folder.appending(path: "\(id).json"), options: .atomic)
    }

    /// `<group container>/SafariBridge`, the group read from the extension's
    /// own entitlements so the team prefix is never spelled out.
    private static func folder() -> URL? {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String],
              let group = groups.first,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return container.appending(path: "SafariBridge", directoryHint: .isDirectory)
    }
}
