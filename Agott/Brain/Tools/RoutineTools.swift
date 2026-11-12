#if os(macOS)
import Foundation
import FoundationModels

/// "Make me do this every day": a routine Agott brings up at its time with
/// its steps, and keeps asking about until it is done.
nonisolated struct DailyRoutineTool: Tool {
    let name = "daily_routine"
    let description = """
    Start, stop or list daily routines: something the user wants to do every day (a workout, stretching, \
    studying, meditation) that Agott pops up over their screen at its time, with the steps, and keeps nagging \
    about until they mark it done. Use it when they ask Agott to make them do something daily or to hold them \
    to it. For a workout from a video, call watch_video first and put the exercises in steps.
    """

    @Generable
    struct Arguments {
        @Guide(description: "start, stop or list", .anyOf(["start", "stop", "list"]))
        var action: String
        @Guide(description: "Short name of the routine, in the user's language, e.g. \"Calistenia\". For stop: words in its name, or empty for all.")
        var title: String
        @Guide(description: "For start: the time every day, as HH:mm in 24 hours")
        var time: String?
        @Guide(description: "For start: what to do, as a short Markdown list (exercises with sets, reps or seconds, and rest), in the user's language")
        var steps: String?
        @Guide(description: "For start: 4 to 6 short lines Agott says when they keep putting it off, each sharper than the last, in the user's own tone and slang (cheeky and pushy if that is how they talk), naming the routine")
        var nagLines: [String]?
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        switch arguments.action {
        case "stop":
            let stopped = await Nudges.shared.stopRoutines(matching: arguments.title)
            return stopped.isEmpty ? "No routine like that is set." : "Stopped: \(stopped.joined(separator: ", "))."
        case "list":
            let routines = await Nudges.shared.routines
            guard !routines.isEmpty else { return "No routines are set." }
            return routines.map { routine in
                "\(routine.title): every day at \(routine.due.formatted(.dateTime.hour().minute())), next \(ToolDates.format(routine.alert)), \(routine.streak) days in a row"
            }.joined(separator: "\n")
        default:
            guard let (hour, minute) = Self.time(arguments.time) else { return "Ask what time of day it should be." }
            let routine = await Nudges.shared.addRoutine(
                title: arguments.title, hour: hour, minute: minute,
                steps: arguments.steps, nagLines: arguments.nagLines ?? [])
            return "Routine set: \(routine.title), every day at \(String(format: "%02d:%02d", hour, minute)), first on \(ToolDates.format(routine.alert)). Agott will pop it up with the steps and keep asking until it is marked done."
        }
    }

    /// "07:30", "7h30", "7:30 PM" as hour and minute.
    static func time(_ text: String?) -> (Int, Int)? {
        guard let text = text?.lowercased().trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard var hour = numbers.first else { return nil }
        let minute = numbers.count > 1 ? numbers[1] : 0
        if text.contains("pm"), hour < 12 { hour += 12 }
        if text.contains("am"), hour == 12 { hour = 0 }
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return (hour, minute)
    }
}
#endif
