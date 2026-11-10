#if os(macOS)
import AppKit
import Foundation
import Observation

/// A reminder Agott brings up itself: at its time it appears in Agott's
/// pop-up over whatever you are doing, with a sound, until you mark it done
/// or put it off. It is kept in Reminders too (without an alarm there, so it
/// does not ring twice), and done here is done there.
nonisolated struct Nudge: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    /// When the thing happens.
    var due: Date
    /// When to bring it up (the same, or earlier for "leave in an hour").
    var alert: Date
    /// Its copy in Reminders, if one was made.
    var reminderID: String?
}

@MainActor @Observable
final class Nudges {
    static let shared = Nudges()

    /// Waiting for their time, soonest first.
    private(set) var pending: [Nudge] = []
    /// The one in the pop-up now.
    private(set) var showing: Nudge?

    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var started = false
    private static let url = URL.applicationSupportDirectory.appending(path: "Agott/nudges.json")

    private init() {
        if let data = try? Data(contentsOf: Self.url),
           let saved = try? JSONDecoder().decode([Nudge].self, from: data) {
            pending = saved.sorted { $0.alert < $1.alert }
        }
    }

    /// Starts the clock. One missed while the Mac was off comes up now.
    func start() {
        guard !started else { return }
        started = true
        // The wait counts sleep, but a wake is a cheap moment to look again.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in Nudges.shared.arm() }
        }
        arm()
    }

    func add(title: String, due: Date, alert: Date, reminderID: String?) {
        pending.append(Nudge(title: title, due: due, alert: alert, reminderID: reminderID))
        pending.sort { $0.alert < $1.alert }
        save()
        arm()
    }

    /// Seen and done: gone here, and ticked off in Reminders.
    func done(_ nudge: Nudge) {
        remove(nudge)
        if let id = nudge.reminderID {
            Task.detached { try? Organizer.shared.complete(reminderID: id) }
        }
    }

    /// Again in a while.
    func snooze(_ nudge: Nudge, minutes: Int) {
        guard let index = pending.firstIndex(where: { $0.id == nudge.id }) else { return }
        pending[index].alert = Date().addingTimeInterval(Double(minutes) * 60)
        pending.sort { $0.alert < $1.alert }
        close()
    }

    /// The pop-up is wanted for something else (a question, dictation): the
    /// reminder steps aside and comes back once it is free.
    func stepAside() {
        guard showing != nil else { return }
        showing = nil
        arm()
    }

    private func remove(_ nudge: Nudge) {
        pending.removeAll { $0.id == nudge.id }
        close()
    }

    private func close() {
        showing = nil
        save()
        OverlayController.shared.hide(after: 0)
        arm()
    }

    private func arm() {
        timer?.cancel()
        guard showing == nil, let next = pending.first else { return }
        timer = Task { [weak self] in
            let wait = next.alert.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            await self?.bringUp()
        }
    }

    /// Shows the reminder whose time has come, once the pop-up is free: it
    /// never cuts into dictation, an answer on screen or quick entry.
    private func bringUp() async {
        while OverlayController.shared.isVisible || Dictation.shared.isRunning || QuickEntryController.shared.isShown {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
        }
        guard showing == nil, let nudge = pending.first, nudge.alert <= Date().addingTimeInterval(1) else {
            arm()
            return
        }
        showing = nudge
        OverlayController.shared.show(focus: false)
        NSSound(named: "Glass")?.play()
        if AppSettings.shared.speakAnswers { VoiceSetup.shared.speak(nudge.title) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }
}
#endif
