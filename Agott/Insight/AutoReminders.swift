import EventKit
import Foundation
import FoundationModels
import UserNotifications

/// Reminders Agott sets on its own: when a new message sets up something at
/// a time you could forget (a call at 8, a deadline on Friday, "me lembra
/// de levar o carregador amanhã"), it lands in Reminders with an alert, and
/// Agott tells you it did.
///
/// Jev decides *whether* (one more question in the check every new message
/// already gets); the learning model only reads out what and when, so
/// ordinary chat never costs a call.
enum AutoReminders {
    @Generable
    struct Draft {
        @Guide(description: "What to remind the user of, short and in their language, naming who it involves: \"Ligar pra Ana\", \"Entregar o trabalho de Física\"")
        var title: String
        @Guide(description: "When it happens, as yyyy-MM-dd HH:mm in the user's time zone; empty when no time can be worked out")
        var due: String
        @Guide(description: "How many minutes before it to alert: 0 for things at an exact time like a call, 60 to 180 for leaving somewhere, 720 for something due that day", .range(0...1440))
        var leadMinutes: Int
        @Guide(description: "true when missing it would really cost them (waking up, medication, leaving for a trip, an appointment, a meeting or call with someone), so it should ring on their phone and watch too; false for small things")
        var alarm: Bool
    }

    /// Jev's probability needed to act.
    static let threshold = 0.75
    private static let madeKey = "autoReminders.made"

    /// The Jev question, asked with the rest of the follow-up check.
    static let question = Jev.Question.noul("""
    Do `new_messages`, read with `conversation`, set up something at a specific time or day that the user \
    could forget and would want a reminder for: a plan or meeting, a call, a deadline, an appointment, \
    something they promised to do or bring? Small talk, past events and vague "sometime" plans do not count.
    """)

    /// Reads the time and title out of the conversation and sets the reminder.
    static func create(from recent: [RawMessage], with name: String, probability: Double) async {
        guard probability >= threshold, AppSettings.shared.autoReminders else { return }
        let me = AppSettings.myNameSnapshot
        let now = Date()
        let lines = recent.suffix(12).map { message in
            "[\(message.date.formatted(.dateTime.weekday().day().month().hour().minute()))] \(message.isFromMe ? me : name): \(message.text.prefix(400))"
        }.joined(separator: "\n")
        guard let draft = try? await ModelHub.generate(
            Draft.self,
            prompt: "Now: \(now.formatted(.dateTime.weekday(.wide).day().month().year().hour().minute())) (\(TimeZone.current.identifier)).\nChat between \(me) (the user) and \(name):\n\(lines)",
            instructions: "Read the reminder the user would want from the latest messages. Write in \(Persona.languageName).",
            provider: ModelHub.learningProvider, modelName: ModelHub.learningModel)
        else { return }
        guard let due = ToolDates.parse(draft.due), due > now.addingTimeInterval(5 * 60) else { return }
        let alert = max(now.addingTimeInterval(60), due.addingTimeInterval(-Double(draft.leadMinutes) * 60))
        await make(title: draft.title, due: due, alert: alert, notes: String(localized: "From your chat with \(name)"), alarm: draft.alarm)
    }

    /// Sets a reminder once (the same title at the same time is never made
    /// twice). On the Mac, Agott brings it up in its pop-up at the alert
    /// time; the copy in Reminders rings too only with `alarm` (something
    /// that must not be missed, even away from the Mac: it then rings on the
    /// iPhone and the Watch). On the iPhone, Reminders always alerts.
    /// `announce`: say so in a notification (for ones Agott set on its own;
    /// one asked for in the chat is confirmed there).
    @discardableResult
    static func make(title: String, due: Date, alert: Date, notes: String?, alarm: Bool = false, announce: Bool = true) async -> Bool {
        let key = "\(title.folded)|\(Int(due.timeIntervalSince1970 / 300))"
        var made = UserDefaults.standard.stringArray(forKey: madeKey) ?? []
        guard !made.contains(key) else { return false }
        if !Organizer.shared.remindersAuthorized { _ = await Organizer.shared.requestAccess() }
        #if os(macOS)
        // The pop-up works without Reminders; the copy there is a bonus.
        let copy = try? Organizer.shared.createReminder(title: title, due: due, alert: alert, alarm: alarm, notes: notes)
        Nudges.shared.add(title: title, due: due, alert: alert, reminderID: copy?.calendarItemIdentifier)
        #else
        guard (try? Organizer.shared.createReminder(title: title, due: due, alert: alert, notes: notes)) != nil else { return false }
        #endif
        made.append(key)
        UserDefaults.standard.set(Array(made.suffix(300)), forKey: madeKey)
        guard announce else { return true }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Reminder set")
        content.body = "\(title) · \(due.formatted(.dateTime.weekday().day().month().hour().minute()))"
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "reminder-\(key)", content: content, trigger: nil))
        return true
    }
}

/// "Me lembra de…": a reminder the user asked for, with an alert.
nonisolated struct RemindMeTool: Tool {
    let name = "remind_me"
    let description = """
    Set a reminder that alerts the user at the right time: on the Mac, Agott itself pops it up over whatever \
    they are doing; it is kept in Reminders too. Use it whenever they ask to be reminded ("me lembra de…", \
    "remind me in 20 minutes", "I'm going upstairs, remind me to come back down at 3"), working the time out \
    from now, or offer it when they mention something with a time they might forget.
    """

    @Generable
    struct Arguments {
        @Guide(description: "What to remind them of, short, in their language")
        var title: String
        @Guide(description: "When it happens, as yyyy-MM-dd HH:mm")
        var due: String
        @Guide(description: "Minutes before it to alert; 0 to alert at the time", .range(0...1440))
        var leadMinutes: Int
        @Guide(description: "true when missing it would really cost them (waking up, medication, leaving for a trip, an appointment, a meeting or call): it also rings as an alarm on their iPhone and Watch, even away from the Mac. false for small things while at the computer")
        var alarm: Bool
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        guard let due = ToolDates.parse(arguments.due) else { return "That time could not be read; ask when." }
        let alert = due.addingTimeInterval(-Double(arguments.leadMinutes) * 60)
        // They asked for it in words, so no approval card on top.
        let made = await AutoReminders.make(title: arguments.title, due: due, alert: max(Date(), alert), notes: nil, alarm: arguments.alarm, announce: false)
        #if os(macOS)
        let failure = "A reminder like that already exists."
        #else
        let failure = "A reminder like that already exists, or Reminders is not allowed for Agott."
        #endif
        return made
            ? "Reminder set: \(arguments.title), \(ToolDates.format(due)), alert \(ToolDates.format(alert))" + (arguments.alarm ? ", with an alarm on their phone and watch." : ".")
            : failure
    }
}
