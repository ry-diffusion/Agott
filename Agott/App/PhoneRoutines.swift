#if os(iOS)
import BackgroundTasks
import Foundation
import UserNotifications

/// The iPhone holds you to your routines on its own: at its time each one
/// comes up as a notification, and if it is not done, again and again with
/// the nag lines, sharper each time, until it is marked done here, on the
/// Watch or on the Mac.
///
/// Notifications are laid out ahead (today and tomorrow), so they ring even
/// if Agott is not opened; every sync lays them out again, which is how a day
/// done on the Watch silences the phone. iOS also wakes Agott now and then
/// in the background to sync.
enum PhoneRoutines {
    static let refreshTask = "br.com.zesmoi.Agott.routines"
    /// Minutes after the routine's time when it asks again.
    static let nagMinutes = [10, 20, 30, 45, 60, 90]

    /// Before launch finishes: the background sync.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTask, using: nil) { task in
            nonisolated(unsafe) let task = task
            Task { @MainActor in
                await RoutineSync.shared.sync()
                await reschedule()
                scheduleRefresh()
                task.setTaskCompleted(success: true)
            }
        }
    }

    static func start() async {
        RoutineSync.shared.onReceive = { _ in Task { await reschedule() } }
        WatchLink.shared.activate()
        await RoutineSync.shared.sync()
        await reschedule()
        scheduleRefresh()
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 20 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Lays out the routines' notifications again from what sync knows.
    static func reschedule(now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let sync = RoutineSync.shared
        let pendingNow = await center.pendingNotificationRequests()
        guard !sync.active.isEmpty || pendingNow.contains(where: { $0.identifier.hasPrefix("routine.") }) else { return }
        guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return }
        let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("routine.") }
        center.removePendingNotificationRequests(withIdentifiers: old)
        let calendar = Calendar.current
        for routine in sync.active {
            for offset in 0...1 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                      let at = calendar.date(bySettingHour: routine.hour, minute: routine.minute, second: 0, of: day) else { continue }
                if sync.done[DoneRecord.name(routine.id, day: RoutineDays.day(day))] != nil { continue }
                let nags = routine.nags
                let times = [0] + nagMinutes
                for (index, minutes) in times.enumerated() {
                    let when = at.addingTimeInterval(Double(minutes) * 60)
                    guard when > now else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = routine.title
                    content.body = index == 0
                        ? (routine.plan.steps.prefix(3).map(\.text).joined(separator: " · ").nilIfEmpty ?? String(localized: "Time for it."))
                        : nags[min(index - 1, nags.count - 1)]
                    content.sound = .default
                    content.threadIdentifier = "routine.\(routine.id.uuidString)"
                    content.userInfo = ["routine": routine.id.uuidString]
                    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: when)
                    let request = UNNotificationRequest(
                        identifier: "routine.\(routine.id.uuidString).\(RoutineDays.day(day)).\(index)",
                        content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
                    try? await center.add(request)
                }
            }
        }
        // Done ones leave the notification list too.
        let delivered = await center.deliveredNotifications().filter { note in
            guard let id = (note.request.content.userInfo["routine"] as? String).flatMap(UUID.init(uuidString:)) else { return false }
            return sync.doneToday(id, now: now) != nil
        }
        center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
