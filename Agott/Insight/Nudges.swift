#if os(macOS)
import AppKit
import Foundation
import Observation

/// A reminder Agott brings up itself: at its time it appears in Agott's
/// pop-up over whatever you are doing, with a sound, until you mark it done
/// or put it off. A one-off is kept in Reminders too (without an alarm there,
/// so it does not ring twice), and done here is done there.
///
/// A routine comes back every day at its time with its steps, and does not
/// let go: closing it only puts it off ten minutes, and while it sits on
/// screen undone it asks again, sharper each time, in the user's own tone.
nonisolated struct Nudge: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    /// When the thing happens (for a routine: today's, or the next one).
    var due: Date
    /// When to bring it up (the same, or earlier for "leave in an hour").
    var alert: Date
    /// Its copy in Reminders, if one was made.
    var reminderID: String?
    /// Every day at the same time, until stopped.
    var repeatsDaily = false
    /// What to do, in Markdown (a routine's steps).
    var details: String?
    /// What Agott says when it is put off again and again, sharper each time.
    var nagLines: [String] = []
    /// Times it was put off (or left waiting) since it came up.
    var nagged = 0
    /// Days in a row it was done.
    var streak = 0
    var lastDone: Date?

    init(title: String, due: Date, alert: Date, reminderID: String? = nil,
         repeatsDaily: Bool = false, details: String? = nil, nagLines: [String] = []) {
        self.title = title
        self.due = due
        self.alert = alert
        self.reminderID = reminderID
        self.repeatsDaily = repeatsDaily
        self.details = details
        self.nagLines = nagLines
    }

    // Saved before routines existed: the new fields take their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        due = try c.decode(Date.self, forKey: .due)
        alert = try c.decode(Date.self, forKey: .alert)
        reminderID = try c.decodeIfPresent(String.self, forKey: .reminderID)
        repeatsDaily = try c.decodeIfPresent(Bool.self, forKey: .repeatsDaily) ?? false
        details = try c.decodeIfPresent(String.self, forKey: .details)
        nagLines = try c.decodeIfPresent([String].self, forKey: .nagLines) ?? []
        nagged = try c.decodeIfPresent(Int.self, forKey: .nagged) ?? 0
        streak = try c.decodeIfPresent(Int.self, forKey: .streak) ?? 0
        lastDone = try c.decodeIfPresent(Date.self, forKey: .lastDone)
    }

    /// What the pop-up says: the thing itself at first, then the nag lines,
    /// one sharper each time it is put off.
    var line: String {
        guard nagged > 0 else { return title }
        let lines = nagLines.isEmpty ? Self.defaultNags(title) : nagLines
        return lines[min(nagged - 1, lines.count - 1)]
    }

    static func defaultNags(_ title: String) -> [String] {
        [String(localized: "Still waiting on this: \(title)."),
         String(localized: "Come on, \(title). Now."),
         String(localized: "Seriously, where is the \(title)? I'm not letting this go."),
         String(localized: "Still nothing? \(title). Get up.")]
    }

    /// The next time this time of day comes, after `date`.
    func next(after date: Date, calendar: Calendar = .current) -> Date {
        let time = calendar.dateComponents([.hour, .minute], from: due)
        return calendar.nextDate(after: date, matching: time, matchingPolicy: .nextTime) ?? date.addingTimeInterval(86_400)
    }

    /// A routine done now: the streak goes on if it was done yesterday (or
    /// already today), else starts again; it comes back at its time tomorrow.
    mutating func markDone(at now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        // Twice in a day counts once, and never skips tomorrow.
        if let lastDone, calendar.isDate(lastDone, inSameDayAs: now) { return }
        if let lastDone, calendar.startOfDay(for: lastDone) >= calendar.date(byAdding: .day, value: -1, to: today)! {
            if calendar.startOfDay(for: lastDone) < today { streak += 1 }
        } else {
            streak = 1
        }
        lastDone = now
        nagged = 0
        due = next(after: max(now, due), calendar: calendar)
        alert = due
    }

    func doneToday(at now: Date = Date(), calendar: Calendar = .current) -> Bool {
        lastDone.map { calendar.isDate($0, inSameDayAs: now) } ?? false
    }

    /// A routine whose day went by undone (the Mac was off, or it was
    /// ignored past midnight): the streak is lost and it is due today.
    mutating func catchUp(at now: Date = Date(), calendar: Calendar = .current) {
        guard repeatsDaily, calendar.startOfDay(for: due) < calendar.startOfDay(for: now) else { return }
        streak = 0
        nagged = 0
        due = next(after: calendar.startOfDay(for: now), calendar: calendar)
        alert = due
    }
}

@MainActor @Observable
final class Nudges {
    static let shared = Nudges()

    /// Waiting for their time, soonest first.
    private(set) var pending: [Nudge] = []
    /// The one in the pop-up now.
    private(set) var showing: Nudge?

    /// How long a routine on screen waits before asking again.
    static let nagEvery: Duration = .seconds(10 * 60)

    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var nagTimer: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var syncLoop: Task<Void, Never>?
    private static let url = URL.applicationSupportDirectory.appending(path: "Agott/nudges.json")

    private init() {
        if let data = try? Data(contentsOf: Self.url),
           let saved = try? JSONDecoder().decode([Nudge].self, from: data) {
            pending = saved.sorted { $0.alert < $1.alert }
        }
    }

    var routines: [Nudge] { pending.filter(\.repeatsDaily) }

    /// Starts the clock. One missed while the Mac was off comes up now.
    func start() {
        guard !started else { return }
        started = true
        // The wait counts sleep, but a wake is a cheap moment to look again.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                Nudges.shared.arm()
                await RoutineSync.shared.sync()
            }
        }
        arm()
        startSync()
    }

    // MARK: Sync

    /// Routines go to the iPhone and Watch through the sync Worker, and a day
    /// done there is done here: the pop-up closes and the streak goes on.
    private func startSync() {
        let sync = RoutineSync.shared
        sync.onReceive = { payload in Nudges.shared.receive(payload) }
        publishAll()
        syncLoop = Task { [weak self] in
            while !Task.isCancelled {
                await RoutineSync.shared.sync()
                // While a routine is on screen, look often: it may be done on the Watch.
                let often = self?.showing?.repeatsDaily == true
                try? await Task.sleep(for: .seconds(often ? 30 : 300))
            }
        }
    }

    /// Every routine here, up to the Worker (the ones it already has are left).
    /// A streak kept before sync becomes the days it stands for.
    func publishAll() {
        let sync = RoutineSync.shared
        guard sync.isConnected else { return }
        for routine in routines {
            if sync.routines[routine.id] == nil { sync.save(record(routine)) }
            if sync.days(routine.id).isEmpty, routine.streak > 0, let lastDone = routine.lastDone {
                for offset in 0..<routine.streak {
                    if let day = Calendar.current.date(byAdding: .day, value: -offset, to: lastDone) {
                        sync.markDone(routine.id, at: day)
                    }
                }
            }
        }
    }

    private func record(_ routine: Nudge, stopped: Bool = false) -> RoutineRecord {
        let time = Calendar.current.dateComponents([.hour, .minute], from: routine.due)
        return RoutineRecord(id: routine.id, title: routine.title, hour: time.hour ?? 8, minute: time.minute ?? 0,
                             steps: routine.details, nagLines: routine.nagLines, stopped: stopped, updatedAt: Date())
    }

    private func receive(_ payload: SyncPayload) {
        switch payload {
        case .routine(let remote):
            let index = pending.firstIndex { $0.id == remote.id }
            if remote.stopped {
                guard let index else { return }
                let id = pending[index].id
                pending.remove(at: index)
                if showing?.id == id { close() } else { save(); arm() }
                return
            }
            var routine = index.map { pending[$0] }
                ?? Nudge(title: remote.title, due: Date(), alert: Date(), repeatsDaily: true)
            routine.id = remote.id
            routine.title = remote.title
            routine.details = remote.steps
            routine.nagLines = remote.nagLines
            let time = Calendar.current.dateComponents([.hour, .minute], from: routine.due)
            if index == nil || time.hour != remote.hour || time.minute != remote.minute {
                let now = Date()
                let today = Calendar.current.date(bySettingHour: remote.hour, minute: remote.minute, second: 0, of: now) ?? now
                let doneToday = routine.lastDone.map { Calendar.current.isDateInToday($0) } ?? false
                routine.due = today > now && !doneToday ? today : Calendar.current.date(byAdding: .day, value: 1, to: today)!
                routine.alert = routine.due
            }
            routine.streak = RoutineSync.shared.streak(remote.id)
            if let index { pending[index] = routine } else { pending.append(routine) }
            pending.sort { $0.alert < $1.alert }
            save()
            if showing == nil { arm() }
        case .done(let record):
            guard record.day == RoutineDays.day(Date()),
                  let index = pending.firstIndex(where: { $0.id == record.routineID && $0.repeatsDaily }) else { return }
            if let lastDone = pending[index].lastDone, Calendar.current.isDateInToday(lastDone) { return }
            pending[index].markDone(at: record.at)
            pending[index].streak = max(pending[index].streak, RoutineSync.shared.streak(record.routineID))
            pending.sort { $0.alert < $1.alert }
            if showing?.id == record.routineID { close() } else { save(); arm() }
        case .keys:
            break
        }
    }

    func add(title: String, due: Date, alert: Date, reminderID: String?) {
        insert(Nudge(title: title, due: due, alert: alert, reminderID: reminderID))
    }

    /// A routine every day at `time`, replacing one with the same name.
    @discardableResult
    func addRoutine(title: String, hour: Int, minute: Int, steps: String?, nagLines: [String]) -> Nudge {
        for replaced in pending where replaced.repeatsDaily && replaced.title.folded == title.folded {
            RoutineSync.shared.save(record(replaced, stopped: true))
        }
        pending.removeAll { $0.repeatsDaily && $0.title.folded == title.folded }
        let now = Date()
        let today = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        let first = today > now ? today : Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let routine = Nudge(title: title, due: first, alert: first, repeatsDaily: true,
                            details: steps, nagLines: nagLines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        insert(routine)
        RoutineSync.shared.save(record(routine))
        return routine
    }

    /// Stops routines whose name has these words; returns their names.
    func stopRoutines(matching words: String) -> [String] {
        let match = pending.filter { $0.repeatsDaily && (words.isEmpty || $0.title.folded.contains(words.folded)) }
        guard !match.isEmpty else { return [] }
        for routine in match { RoutineSync.shared.save(record(routine, stopped: true)) }
        pending.removeAll { item in match.contains { $0.id == item.id } }
        if let showing, match.contains(where: { $0.id == showing.id }) { close() } else { save(); arm() }
        return match.map(\.title)
    }

    /// Seen and done: a one-off is gone (and ticked off in Reminders); a
    /// routine counts the day and comes back tomorrow.
    func done(_ nudge: Nudge) {
        guard let index = pending.firstIndex(where: { $0.id == nudge.id }) else { return finish(nudge) }
        if pending[index].repeatsDaily {
            pending[index].markDone()
            if RoutineSync.shared.isConnected {
                RoutineSync.shared.markDone(nudge.id)
                pending[index].streak = max(pending[index].streak, RoutineSync.shared.streak(nudge.id))
            }
            pending.sort { $0.alert < $1.alert }
        } else {
            pending.remove(at: index)
            if let id = nudge.reminderID {
                Task.detached { try? Organizer.shared.complete(reminderID: id) }
            }
        }
        finish(nudge)
    }

    /// Again in a while; each time sharper.
    func snooze(_ nudge: Nudge, minutes: Int) {
        guard let index = pending.firstIndex(where: { $0.id == nudge.id }) else { return finish(nudge) }
        pending[index].alert = Date().addingTimeInterval(Double(minutes) * 60)
        pending[index].nagged += 1
        pending.sort { $0.alert < $1.alert }
        finish(nudge)
    }

    /// Gone for good (from the Routines page).
    func delete(_ nudge: Nudge) {
        pending.removeAll { $0.id == nudge.id }
        finish(nudge)
    }

    /// A routine at another time of day, from its next day on.
    func setTime(_ routine: Nudge, hour: Int, minute: Int) {
        guard let index = pending.firstIndex(where: { $0.id == routine.id }) else { return }
        let now = Date()
        let base = routine.doneToday(at: now) ? Calendar.current.date(byAdding: .day, value: 1, to: now)! : now
        var due = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
        if due < now { due = Calendar.current.date(byAdding: .day, value: 1, to: due)! }
        pending[index].due = due
        pending[index].alert = due
        pending[index].nagged = 0
        pending.sort { $0.alert < $1.alert }
        finish(routine)
    }

    /// After a change: the pop-up closes if it was showing this one;
    /// anything else on screen is left alone.
    private func finish(_ nudge: Nudge) {
        if showing?.id == nudge.id {
            close()
        } else {
            save()
            arm()
        }
    }

    /// Closed without doing it: a routine only goes away for ten minutes.
    func dismiss(_ nudge: Nudge) {
        if nudge.repeatsDaily { snooze(nudge, minutes: 10) } else { done(nudge) }
    }

    /// The pop-up is wanted for something else (a question, dictation): the
    /// reminder steps aside and comes back once it is free.
    func stepAside() {
        guard showing != nil else { return }
        showing = nil
        nagTimer?.cancel()
        arm()
    }

    private func insert(_ nudge: Nudge) {
        pending.append(nudge)
        pending.sort { $0.alert < $1.alert }
        save()
        arm()
    }

    private func close() {
        showing = nil
        nagTimer?.cancel()
        save()
        OverlayController.shared.hide(after: 0)
        arm()
    }

    private func arm() {
        timer?.cancel()
        guard showing == nil else { return }
        // A routine whose day went by comes due today, streak lost.
        var changed = false
        for index in pending.indices where pending[index].repeatsDaily {
            let before = pending[index]
            pending[index].catchUp()
            if pending[index] != before { changed = true }
        }
        if changed {
            pending.sort { $0.alert < $1.alert }
            save()
        }
        guard let next = pending.first else { return }
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
        present(nudge)
        if nudge.repeatsDaily { keepNagging(nudge.id) }
    }

    private func present(_ nudge: Nudge) {
        showing = nudge
        OverlayController.shared.show(focus: false)
        NSSound(named: nudge.nagged > 1 ? "Sosumi" : "Glass")?.play()
        if AppSettings.shared.speakAnswers { VoiceSetup.shared.speak(nudge.line) }
    }

    /// A routine left on screen undone asks again every few minutes.
    private func keepNagging(_ id: UUID) {
        nagTimer?.cancel()
        nagTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.nagEvery)
                guard !Task.isCancelled, let self, self.showing?.id == id,
                      let index = self.pending.firstIndex(where: { $0.id == id }) else { return }
                self.pending[index].nagged += 1
                self.save()
                self.present(self.pending[index])
            }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }
}
#endif
