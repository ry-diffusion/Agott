import SwiftUI

/// Everything Agott holds you to: daily routines (with their streak, time
/// and steps), the reminders it will pop up, and your open tasks in
/// Reminders. Done, moved, or removed from here.
struct RoutinesView: View {
    @State private var tasks: [Organizer.OpenTask] = []
    @State private var tasksAllowed = Organizer.shared.remindersAuthorized
    #if os(macOS)
    @State private var nudges = Nudges.shared
    @State private var adding = false
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Routines")
                        .font(Lettering.display(34, relativeTo: .largeTitle))
                        .foregroundStyle(Ink.text)
                    Text("What Agott holds you to, every day and today.")
                        .font(.callout)
                        .foregroundStyle(Ink.muted)
                }

                #if os(macOS)
                section("Every day", trailing: {
                    Button { adding.toggle() } label: { Label("New routine", systemImage: "plus") }
                        .buttonStyle(.candy(.soft, compact: true))
                }) {
                    if adding {
                        NewRoutineForm { adding = false }
                    }
                    if nudges.routines.isEmpty && !adding {
                        empty("figure.strengthtraining.functional",
                              "Ask Agott to make you do something every day, like a workout from a video, or add one here.")
                    }
                    ForEach(nudges.routines) { routine in
                        RoutineRow(routine: routine)
                    }
                }

                let reminders = nudges.pending.filter { !$0.repeatsDaily }
                section("Reminders", trailing: { EmptyView() }) {
                    if reminders.isEmpty {
                        empty("bell", "Reminders you ask Agott for pop up here at their time.")
                    }
                    ForEach(reminders) { reminder in
                        ReminderRow(reminder: reminder)
                    }
                }
                #endif

                section("Tasks in Reminders", trailing: {
                    if tasksAllowed {
                        Button { Task { await loadTasks() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(HoverIconStyle(size: 28))
                            .help(Text("Refresh"))
                    }
                }) {
                    if !tasksAllowed {
                        HStack {
                            Text("Agott can show and tick off your tasks from Reminders.")
                                .font(.callout).foregroundStyle(Ink.muted)
                            Spacer()
                            Button("Connect Reminders") {
                                Task {
                                    _ = await Organizer.shared.requestAccess()
                                    tasksAllowed = Organizer.shared.remindersAuthorized
                                    await loadTasks()
                                }
                            }
                            .buttonStyle(.candy(.soft, compact: true))
                        }
                        .padding(14)
                    } else if tasks.isEmpty {
                        empty("checklist", "No open tasks.")
                    }
                    ForEach(tasks) { task in
                        TaskRow(task: task) {
                            withAnimation(Motion.settle) { tasks.removeAll { $0.id == task.id } }
                            Task.detached { try? Organizer.shared.complete(reminderID: task.id) }
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, WindowBar.height + 8)
            .padding(.bottom, 40)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .background(Ink.canvas)
        .task { await loadTasks() }
    }

    private func loadTasks() async {
        guard Organizer.shared.remindersAuthorized else { return }
        tasks = (try? await Organizer.shared.openTasks()) ?? []
    }

    private func section<Trailing: View, Content: View>(
        _ title: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline).foregroundStyle(Ink.text)
                Spacer()
                trailing()
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                .quietSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func empty(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Ink.muted)
            Text(text).font(.callout).foregroundStyle(Ink.muted)
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}

/// An open task in Reminders: tick it off.
private struct TaskRow: View {
    var task: Organizer.OpenTask
    var complete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: complete) { Image(systemName: "circle").font(.system(size: 17)) }
                .buttonStyle(.plain)
                .foregroundStyle(Ink.muted)
                .help(Text("Mark as done"))
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).font(.callout).foregroundStyle(Ink.text).lineLimit(2)
                if let detail { Text(detail).font(.caption).foregroundStyle(overdue ? Ink.spot : Ink.muted) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.hairline).frame(height: 1).padding(.leading, 44) }
    }

    private var overdue: Bool { (task.due ?? .distantFuture) < .now }

    private var detail: String? {
        let when = task.due.map { $0.formatted(.relative(presentation: .named)) }
        return [when, task.list].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

#if os(macOS)
/// A daily routine: done today or not, its streak, its time, its steps.
private struct RoutineRow: View {
    var routine: Nudge
    @State private var nudges = Nudges.shared
    @State private var open = false
    @State private var time = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: done ? "checkmark.circle.fill" : "figure.strengthtraining.functional")
                    .font(.system(size: 18))
                    .foregroundStyle(done ? Ink.mint : Ink.spot)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.title).font(.body.weight(.semibold)).foregroundStyle(Ink.text)
                    Text(status).font(.caption).foregroundStyle(Ink.muted)
                }
                Spacer(minLength: 8)
                DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .fixedSize()
                    .help(Text("Time every day"))
                if !done {
                    Button { nudges.done(routine) } label: { Label("Routine done", systemImage: "checkmark") }
                        .buttonStyle(.candy(.primary, compact: true))
                }
                Menu {
                    if routine.details != nil {
                        Button(open ? "Hide steps" : "Show steps", systemImage: "list.bullet") { open.toggle() }
                    }
                    Divider()
                    Button("Stop this routine", systemImage: "trash", role: .destructive) { nudges.delete(routine) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(HoverIconStyle(size: 28))
                .fixedSize()
            }
            if open, let steps = routine.details {
                MarkdownView(text: steps)
                    .font(.callout)
                    .padding(.leading, 36)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.hairline).frame(height: 1).padding(.leading, 50) }
        .onAppear { time = routine.due }
        .onChange(of: time) { _, new in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: new)
            let old = Calendar.current.dateComponents([.hour, .minute], from: routine.due)
            guard parts != old, let hour = parts.hour, let minute = parts.minute else { return }
            nudges.setTime(routine, hour: hour, minute: minute)
        }
        .animation(Motion.settle, value: open)
    }

    private var done: Bool { routine.doneToday() }

    private var status: String {
        let time = routine.due.formatted(.dateTime.hour().minute())
        var parts = [String(localized: "every day at \(time)")]
        if routine.streak > 0 { parts.append(String(localized: "\(routine.streak) days in a row")) }
        if done { parts.append(String(localized: "done today")) }
        return parts.joined(separator: " · ")
    }
}

/// A reminder Agott will pop up: when, and done or gone.
private struct ReminderRow: View {
    var reminder: Nudge
    @State private var nudges = Nudges.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell").foregroundStyle(Ink.spot).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title).font(.callout).foregroundStyle(Ink.text).lineLimit(2)
                Text(reminder.alert.formatted(.dateTime.weekday().day().month().hour().minute()))
                    .font(.caption).foregroundStyle(Ink.muted)
            }
            Spacer(minLength: 8)
            Button { nudges.done(reminder) } label: { Image(systemName: "checkmark") }
                .buttonStyle(HoverIconStyle(size: 28))
                .help(Text("Reminder done"))
            Button { nudges.delete(reminder) } label: { Image(systemName: "trash") }
                .buttonStyle(HoverIconStyle(size: 28))
                .help(Text("Delete"))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.hairline).frame(height: 1).padding(.leading, 50) }
    }
}

/// A routine typed in by hand: a name, a time, and the steps.
private struct NewRoutineForm: View {
    var close: () -> Void
    @State private var title = ""
    @State private var time = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: .now) ?? .now
    @State private var steps = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Name, like Calisthenics", text: $title)
                    .textFieldStyle(.roundedBorder)
                DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .fixedSize()
            }
            TextField("Steps, one per line (optional)", text: $steps, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...8)
            HStack {
                Spacer()
                Button("Cancel", action: close).buttonStyle(.candy(.soft, compact: true))
                Button("Add routine") {
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                    let lines = steps.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    let markdown = lines.map { $0.hasPrefix("-") ? $0 : "- \($0)" }.joined(separator: "\n")
                    Nudges.shared.addRoutine(title: title.trimmingCharacters(in: .whitespaces),
                                             hour: parts.hour ?? 7, minute: parts.minute ?? 0,
                                             steps: markdown.isEmpty ? nil : markdown, nagLines: [])
                    close()
                }
                .buttonStyle(.candy(.primary, compact: true))
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.hairline).frame(height: 1) }
    }
}
#endif

/// Home's look at today: routines (done or still to do), reminders coming,
/// and tasks due or late, with a way to the Routines page.
struct TodayCard: View {
    @State private var tasks: [Organizer.OpenTask] = []
    #if os(macOS)
    @State private var nudges = Nudges.shared
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Today").font(.headline).foregroundStyle(Ink.text)
                Spacer()
                Button("See all") { Navigator.shared.section = .routines }
                    .buttonStyle(.candy(.soft, compact: true))
            }
            if isEmpty {
                Text("Nothing to do today.").font(.callout).foregroundStyle(Ink.muted)
            }
            #if os(macOS)
            ForEach(routines) { routine in
                let done = routine.doneToday()
                HStack(spacing: 10) {
                    Image(systemName: done ? "checkmark.circle.fill" : "figure.strengthtraining.functional")
                        .foregroundStyle(done ? Ink.mint : Ink.spot)
                        .frame(width: 20)
                    Text(routine.title).font(.callout).foregroundStyle(done ? Ink.muted : Ink.text)
                        .strikethrough(done, color: Ink.muted)
                    Text(routine.due.formatted(.dateTime.hour().minute()))
                        .font(.caption.monospacedDigit()).foregroundStyle(Ink.muted)
                    if routine.streak > 0 {
                        Text("\(routine.streak) days in a row").font(.caption).foregroundStyle(Ink.muted)
                    }
                    Spacer(minLength: 0)
                    if !done {
                        Button { nudges.done(routine) } label: { Label("Routine done", systemImage: "checkmark") }
                            .buttonStyle(.candy(.soft, compact: true))
                    }
                }
            }
            ForEach(reminders) { reminder in
                row(symbol: "bell", title: reminder.title,
                    detail: reminder.alert.formatted(.dateTime.hour().minute()), late: false)
            }
            #endif
            ForEach(dueTasks.prefix(5)) { task in
                row(symbol: "circle", title: task.title,
                    detail: task.due.map { $0.formatted(.relative(presentation: .named)) } ?? "",
                    late: (task.due ?? .distantFuture) < .now)
            }
        }
        .padding(18)
        .quietSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task {
            guard Organizer.shared.remindersAuthorized else { return }
            tasks = (try? await Organizer.shared.openTasks()) ?? []
        }
    }

    private func row(symbol: String, title: String, detail: String, late: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Ink.muted).frame(width: 20)
            Text(title).font(.callout).foregroundStyle(Ink.text).lineLimit(1)
            Text(detail).font(.caption).foregroundStyle(late ? Ink.spot : Ink.muted)
            Spacer(minLength: 0)
        }
    }

    /// Open tasks due by the end of today, late ones included.
    private var dueTasks: [Organizer.OpenTask] {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now)) ?? .now
        return tasks.filter { ($0.due ?? .distantFuture) < end }
    }

    #if os(macOS)
    /// Every routine: each one is for today, done or not.
    private var routines: [Nudge] { nudges.routines }

    private var reminders: [Nudge] {
        nudges.pending.filter { !$0.repeatsDaily && Calendar.current.isDateInToday($0.alert) }
    }

    private var isEmpty: Bool { routines.isEmpty && reminders.isEmpty && dueTasks.isEmpty }
    #else
    private var isEmpty: Bool { dueTasks.isEmpty }
    #endif
}
