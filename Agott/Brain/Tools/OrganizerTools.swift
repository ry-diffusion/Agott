import EventKit
import Foundation
import FoundationModels

nonisolated struct CalendarTool: Tool {
    let name = "calendar"
    let description = "List the user's calendar events in a period."

    @Generable
    struct Arguments {
        @Guide(description: "Start, as yyyy-MM-dd or yyyy-MM-dd HH:mm. Defaults to now.")
        var from: String?
        @Guide(description: "How many days to cover", .range(1...60))
        var days: Int
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await CardBus.status(String(localized: "Checking your calendar…"))
        let start = ToolDates.parse(arguments.from) ?? Calendar.current.startOfDay(for: .now)
        let end = start.addingTimeInterval(Double(arguments.days) * 86400)
        let events = try await Organizer.shared.events(from: start, to: end)
        guard !events.isEmpty else { return "No events between \(ToolDates.format(start)) and \(ToolDates.format(end))." }
        let items = events.prefix(30).map { event in
            Card.EventList.Item(
                title: event.title ?? "", start: event.startDate, end: event.endDate,
                detail: [event.location, event.calendar?.title].compactMap { $0 }.joined(separator: " · "))
        }
        await CardBus.post(.events(.init(title: String(localized: "Calendar"), items: Array(items))))
        return events.prefix(30).map { event in
            "- \(ToolDates.format(event.startDate))–\(ToolDates.format(event.endDate)) \(event.title ?? "")"
                + (event.location.map { " @ \($0)" } ?? "")
        }.joined(separator: "\n") + "\n(Shown to the user as a card.)"
    }
}

nonisolated struct CreateEventTool: Tool {
    let name = "create_event"
    let description = "Add an event to the user's calendar."

    @Generable
    struct Arguments {
        var title: String
        @Guide(description: "Start, as yyyy-MM-dd HH:mm in the user's time zone")
        var start: String
        @Guide(description: "Length in minutes", .range(5...1440))
        var minutes: Int
        var location: String?
        var notes: String?
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        guard let start = ToolDates.parse(arguments.start) else { return "Could not read the start date \(arguments.start)." }
        let end = start.addingTimeInterval(Double(arguments.minutes) * 60)
        guard await Approvals.ask(
            String(localized: "Add to calendar"),
            detail: "\(arguments.title) — \(ToolDates.format(start))")
        else { return "The user declined." }
        _ = try Organizer.shared.createEvent(
            title: arguments.title, start: start, end: end, location: arguments.location, notes: arguments.notes)
        return "Added \(arguments.title) on \(ToolDates.format(start))."
    }
}

nonisolated struct TasksTool: Tool {
    let name = "tasks"
    let description = "List the user's open tasks from Reminders."

    @Generable
    struct Arguments {
        @Guide(description: "Optional word to filter tasks by")
        var filter: String?
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await CardBus.status(String(localized: "Checking your tasks…"))
        var reminders = try await Organizer.shared.openReminders()
        if let filter = arguments.filter, !filter.isEmpty {
            reminders = reminders.filter { ($0.title ?? "").folded.contains(filter.folded) }
        }
        guard !reminders.isEmpty else { return "No open tasks." }
        return reminders.prefix(40).map { reminder in
            "- \(reminder.title ?? "")" + (reminder.dueDateComponents?.date.map { " (due \(ToolDates.format($0)))" } ?? "")
        }.joined(separator: "\n")
    }
}

nonisolated struct CreateTaskTool: Tool {
    let name = "create_task"
    let description = "Add a task to Reminders, optionally with a due date that also alerts."

    @Generable
    struct Arguments {
        var title: String
        @Guide(description: "Due, as yyyy-MM-dd HH:mm, if any")
        var due: String?
        var notes: String?
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        let due = ToolDates.parse(arguments.due)
        guard await Approvals.ask(
            String(localized: "Add a task"),
            detail: arguments.title + (due.map { " — \(ToolDates.format($0))" } ?? ""))
        else { return "The user declined." }
        _ = try Organizer.shared.createReminder(title: arguments.title, due: due, notes: arguments.notes)
        return "Added task \(arguments.title)."
    }
}

nonisolated struct CompleteTaskTool: Tool {
    let name = "complete_task"
    let description = "Mark an open task in Reminders as done."

    @Generable
    struct Arguments {
        @Guide(description: "The task's title, or part of it")
        var title: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        try await Organizer.shared.complete(reminderTitled: arguments.title)
            ? "Marked \(arguments.title) as done." : "No open task matches \(arguments.title)."
    }
}

#if os(macOS)
nonisolated struct ReadMailTool: Tool {
    let name = "read_mail"
    let description = "Read the newest messages in the user's Mail inbox: sender, subject, date and the start of the body."

    @Generable
    struct Arguments {
        @Guide(description: "How many messages", .range(1...30))
        var count: Int
        var unreadOnly: Bool
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await CardBus.status(String(localized: "Reading your inbox…"))
        let messages = try await MailBridge.recent(count: arguments.count, unreadOnly: arguments.unreadOnly)
        guard !messages.isEmpty else { return "The inbox has nothing matching." }
        return messages.map { "- \($0.isRead ? "" : "[unread] ")\($0.sender) — \($0.subject) (\($0.date)): \($0.snippet)" }
            .joined(separator: "\n")
    }
}

nonisolated struct DraftEmailTool: Tool {
    let name = "draft_email"
    let description = "Open a new email in Mail, filled in, for the user to review and send themselves."

    @Generable
    struct Arguments {
        @Guide(description: "Email addresses")
        var to: [String]
        var subject: String
        var body: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        guard await Approvals.ask(
            String(localized: "Draft an email"),
            detail: "\(arguments.to.joined(separator: ", ")) — \(arguments.subject)")
        else { return "The user declined." }
        try await MailBridge.draft(to: arguments.to, subject: arguments.subject, body: arguments.body)
        return "The draft is open in Mail for the user to send."
    }
}
#endif
