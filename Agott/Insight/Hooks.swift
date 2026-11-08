import Foundation
import Observation
import UserNotifications

/// Rules for when a new message arrives: "when Clara writes, tell me",
/// "when anyone needs an answer, help me reply".
nonisolated struct Hook: Codable, Hashable, Identifiable, Sendable {
    enum Action: String, Codable, CaseIterable, Sendable {
        /// A notification with the message.
        case notify
        /// A notification that opens Agott with reply ideas.
        case draftReplies
    }

    var id = UUID()
    /// A name, or part of one; empty means anyone.
    var person: String = ""
    /// Only when it needs you: Jev judges that it wants an answer (or, without
    /// Jev, it asks a question).
    var onlyWhenItMatters = true
    var action: Action = .notify
    var enabled = true

    func matches(name: String, sender: String) -> Bool {
        guard enabled else { return false }
        let needle = person.trimmingCharacters(in: .whitespaces).folded
        return needle.isEmpty || name.folded.contains(needle) || sender.folded.contains(needle)
    }
}

@Observable
final class HookStore {
    static let shared = HookStore()
    private static let key = "hooks"

    var hooks: [Hook] {
        didSet {
            if let data = try? JSONEncoder().encode(hooks) { UserDefaults.standard.set(data, forKey: Self.key) }
            if hooks.contains(where: \.enabled) { Notifier.requestPermission() }
        }
    }

    private init() {
        hooks = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([Hook].self, from: $0) } ?? []
    }

    /// New messages from one chat: fire every hook that applies, once.
    func fire(name: String, sender: String, text: String, chatKey: String, followUp: FollowUp?) {
        let matching = hooks.filter { $0.matches(name: name, sender: sender) }
        guard !matching.isEmpty else { return }
        let matters = followUp?.matters ?? text.contains("?")
        let applicable = matching.filter { !$0.onlyWhenItMatters || matters }
        guard !applicable.isEmpty else { return }
        let draft = applicable.contains { $0.action == .draftReplies }
        Notifier.post(name: name, text: text, chatKey: chatKey, offerReplies: draft, urgent: (followUp?.urgency ?? 0) >= 2)
    }
}

/// System notifications for hooks, and what tapping them does.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static let replyAction = "agott.reply"
    static let category = "agott.message"

    static func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: category,
                actions: [UNNotificationAction(identifier: replyAction, title: String(localized: "Help me reply"), options: [.foreground])],
                intentIdentifiers: [])
        ])
    }

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func post(name: String, text: String, chatKey: String, offerReplies: Bool, urgent: Bool) {
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = String(text.prefix(240))
        content.sound = urgent ? .default : nil
        content.threadIdentifier = chatKey
        content.userInfo = ["name": name, "text": String(text.prefix(800)), "replies": offerReplies]
        if offerReplies { content.categoryIdentifier = category }
        content.interruptionLevel = urgent ? .timeSensitive : .active
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Show banners even while Agott is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let name = info["name"] as? String, let text = info["text"] as? String else { return }
        let wantsReplies = response.actionIdentifier == Self.replyAction || (info["replies"] as? Bool ?? false)
        await MainActor.run {
            Navigator.shared.section = .chat
            guard wantsReplies else { return }
            Agent.shared.newConversation()
            Agent.shared.send(String(localized: "\(name) just wrote: “\(text)”. How should I answer?"))
        }
    }
}

/// Which screen is showing, so a notification can bring you to the chat.
@Observable
final class Navigator {
    static let shared = Navigator()
    var section: AppSection = LaunchOptions.section ?? .home
    /// The sidebar tucked away: only the page.
    var zen = LaunchOptions.arguments.contains("-AgottZen")
    #if os(macOS)
    /// Settings open in the window, on this page; nil when they are closed.
    var settingsPage: SettingsPage?
    #endif
}
