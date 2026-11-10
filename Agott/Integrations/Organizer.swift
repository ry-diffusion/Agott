import EventKit
import Foundation

/// Calendar and Reminders, through EventKit. Works the same on Mac and iPhone.
nonisolated final class Organizer: @unchecked Sendable {
    static let shared = Organizer()

    private let store = EKEventStore()

    func requestAccess() async -> (calendar: Bool, reminders: Bool) {
        let calendar = (try? await store.requestFullAccessToEvents()) ?? false
        let reminders = (try? await store.requestFullAccessToReminders()) ?? false
        return (calendar, reminders)
    }

    var calendarAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    var remindersAuthorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    func events(from start: Date, to end: Date) async throws -> [EKEvent] {
        if !calendarAuthorized { _ = try? await store.requestFullAccessToEvents() }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }

    func createEvent(title: String, start: Date, end: Date, location: String?, notes: String?) throws -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.location = location
        event.notes = notes
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
        return event
    }

    func openReminders() async throws -> [EKReminder] {
        if !remindersAuthorized { _ = try? await store.requestFullAccessToReminders() }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
        return reminders.sorted {
            ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture)
        }
    }

    /// `alarm` false: the reminder is listed with its time but does not ring
    /// (Agott brings it up itself on the Mac).
    func createReminder(title: String, due: Date?, alert: Date? = nil, alarm: Bool = true, notes: String?) throws -> EKReminder {
        if !remindersAuthorized { throw CocoaError(.featureUnsupported) }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            // The alert can come before the time itself ("leave in an hour").
            if alarm { reminder.addAlarm(EKAlarm(absoluteDate: alert ?? due)) }
        }
        try store.save(reminder, commit: true)
        return reminder
    }

    /// Ticks off one reminder, found by its identifier.
    func complete(reminderID: String) throws {
        guard remindersAuthorized, let reminder = store.calendarItem(withIdentifier: reminderID) as? EKReminder,
              !reminder.isCompleted else { return }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
    }

    func complete(reminderTitled title: String) async throws -> Bool {
        let open = try await openReminders()
        guard let match = open.first(where: { ($0.title ?? "").folded.contains(title.folded) }) else { return false }
        match.isCompleted = true
        try store.save(match, commit: true)
        return true
    }
}

#if os(macOS)
import AppKit

/// Mail.app, through Apple Events. Agott drafts; you send.
nonisolated enum MailBridge {
    struct Message: Sendable {
        var sender: String
        var subject: String
        var date: String
        var snippet: String
        var isRead: Bool
    }

    static func recent(count: Int, unreadOnly: Bool) async throws -> [Message] {
        let filter = unreadOnly ? "whose read status is false" : ""
        let script = """
        set output to ""
        tell application "Mail"
            set theMessages to (messages of inbox \(filter))
            set n to count of theMessages
            if n > \(count) then set n to \(count)
            repeat with i from 1 to n
                set m to item i of theMessages
                set body to ""
                try
                    set body to (characters 1 thru 280 of (content of m as string)) as string
                on error
                    try
                        set body to content of m as string
                    end try
                end try
                set output to output & (sender of m) & "\\u001F" & (subject of m) & "\\u001F" & ((date received of m) as string) & "\\u001F" & body & "\\u001F" & (read status of m as string) & "\\u001E"
            end repeat
        end tell
        return output
        """
        let raw = try await run(script)
        return raw.split(separator: "\u{1E}").compactMap { record in
            let fields = record.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5 else { return nil }
            return Message(sender: fields[0], subject: fields[1], date: fields[2],
                           snippet: fields[3].replacingOccurrences(of: "\n", with: " "), isRead: fields[4] == "true")
        }
    }

    /// Opens a filled-in draft in Mail. Never sends.
    static func draft(to: [String], subject: String, body: String) async throws {
        func quote(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let recipients = to.map { "make new to recipient at end of to recipients with properties {address:\(quote($0))}" }
            .joined(separator: "\n")
        let script = """
        tell application "Mail"
            set m to make new outgoing message with properties {subject:\(quote(subject)), content:\(quote(body)), visible:true}
            tell m
                \(recipients)
            end tell
            activate
        end tell
        """
        _ = try await run(script)
    }

    private static func run(_ source: String) async throws -> String {
        try await AppleScriptRunner.run(source)
    }
}
#endif
