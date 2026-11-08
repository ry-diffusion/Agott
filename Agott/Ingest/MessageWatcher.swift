#if os(macOS)
import Foundation

/// Notices new messages within seconds, for hooks, follow-ups and memory.
///
/// The indexer reads everything every ten minutes; that is too slow for "Clara
/// just wrote". This looks only at messages newer than its own bookmark,
/// every fifteen seconds, and stores nothing (the indexer does). For each
/// chat with something new it asks Jev what the conversation needs, keeps
/// what is worth remembering, and fires your hooks.
@Observable
final class MessageWatcher {
    static let shared = MessageWatcher()

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let contacts = ContactBook()
    @ObservationIgnored private var lastCheck: [String: Date] = [:]

    private init() {}

    func start() {
        guard task == nil else { return }
        task = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func cursorKey(_ kind: MemorySource) -> String { "watcher.cursor.\(kind.rawValue)" }

    private func poll() async {
        let contacts = self.contacts
        if !contacts.isLoaded { await Task.detached(priority: .utility) { contacts.load() }.value }
        let sources: [any MessageSource] = [WhatsAppSource(), IMessageSource()]
        for source in sources where AppSettings.shared.enabledSources.contains(source.kind) && source.isPresent {
            let key = cursorKey(source.kind)
            // First run starts from now: history is not "new".
            var cursor = UserDefaults.standard.double(forKey: key)
            if cursor == 0 {
                cursor = Date().timeIntervalSince1970
                UserDefaults.standard.set(cursor, forKey: key)
                continue
            }
            let after = cursor
            guard let fresh = try? await Task.detached(priority: .utility, operation: {
                try source.read(after: after, before: nil, newestFirst: false, limit: 300, contacts: contacts)
            }).value, !fresh.isEmpty else { continue }
            if let newest = fresh.map(\.date.timeIntervalSince1970).max() {
                UserDefaults.standard.set(newest, forKey: key)
            }
            await handle(fresh, source: source.kind)
        }
    }

    private func handle(_ fresh: [RawMessage], source: MemorySource) async {
        let byChat = Dictionary(grouping: fresh, by: \.chatID)
        for (chatID, messages) in byChat {
            let chatKey = "\(source.rawValue)|\(chatID)"
            let name = messages.last?.chatName ?? ""
            // You answered there: nothing is waiting on you any more.
            if let last = messages.last, last.isFromMe {
                FollowUpCenter.shared.clear(chatKey)
                continue
            }
            let incoming = messages.filter { !$0.isFromMe }
            guard let latest = incoming.last else { continue }
            let isGroup = latest.isGroup

            var followUp: FollowUp?
            // Jev reads direct chats; groups would cost a call per chatter.
            if Jev.isConfigured, !isGroup, Date().timeIntervalSince(lastCheck[chatKey] ?? .distantPast) > 20 {
                lastCheck[chatKey] = .now
                let earlier = (try? await MemoryStore.shared.lines(source: source, chatID: chatID, limit: 16)) ?? []
                let context = earlier
                    .filter { line in line.date < (messages.first?.date ?? .now) }
                    .map { RawMessage(source: source, externalID: "", chatID: chatID, chatName: name, isGroup: false,
                                      sender: $0.sender, isFromMe: $0.isFromMe, date: $0.date, text: $0.text) }
                if let result = try? await FollowUps.check(
                    name: name, source: source, chatKey: chatKey, recent: context + messages, fresh: messages) {
                    followUp = result.followUp
                    FollowUpCenter.shared.update(result.followUp)
                    if let memorable = result.memorable {
                        Task(priority: .utility) {
                            await Remembering.save(memorable, from: name, probability: result.memorability)
                        }
                    }
                    // Something set up for a time: a reminder with an alert.
                    if result.reminder >= AutoReminders.threshold {
                        let recent = context + messages
                        Task(priority: .utility) {
                            await AutoReminders.create(from: recent, with: name, probability: result.reminder)
                        }
                    }
                }
            }
            HookStore.shared.fire(
                name: name, sender: latest.sender,
                text: incoming.suffix(3).map(\.text).joined(separator: "\n"),
                chatKey: chatKey, followUp: followUp)
        }
    }
}
#endif
