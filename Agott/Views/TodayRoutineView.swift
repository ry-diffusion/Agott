#if os(iOS)
import SwiftUI

/// The iPhone's routines: today's, with their steps and streak, done by
/// counting reps with AirPods (or the Watch), or ticked by hand.
struct TodayRoutineView: View {
    @State private var sync = RoutineSync.shared
    @State private var workout: RoutineRecord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Today")
                        .font(Lettering.display(34, relativeTo: .largeTitle))
                        .foregroundStyle(Ink.text)
                    Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.callout).foregroundStyle(Ink.muted)
                }
                if !sync.isConnected {
                    empty("lock.icloud", "Connect sync in Settings to see the routines you set on your Mac, and to do them from here or your Watch.")
                } else if sync.active.isEmpty {
                    empty("figure.strengthtraining.functional", "No routines yet. Ask Agott on your Mac to make you do something every day.")
                }
                ForEach(sync.active) { routine in
                    RoutineCard(routine: routine) { workout = routine }
                }
                if let problem = sync.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(20)
        }
        .background(Ink.canvas)
        .refreshable { await sync.sync() }
        .sheet(item: $workout) { routine in
            WorkoutSheet(routine: routine)
        }
    }

    private func empty(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Ink.muted)
            Text(text).font(.callout).foregroundStyle(Ink.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).fill(Ink.surface))
    }
}

private struct RoutineCard: View {
    var routine: RoutineRecord
    var start: () -> Void
    @State private var sync = RoutineSync.shared

    var body: some View {
        let done = sync.doneToday(routine.id)
        let streak = sync.streak(routine.id)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.title).font(.title3.weight(.semibold)).foregroundStyle(Ink.text)
                    Text("Every day at \(routine.time)").font(.caption).foregroundStyle(Ink.muted)
                }
                Spacer()
                if streak > 0 {
                    Label("\(streak)", systemImage: "flame.fill")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Ink.spot)
                        .accessibilityLabel(Text("\(streak) days in a row"))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(routine.plan.steps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: step.exercise.map(\.symbol) ?? "circle.fill")
                            .font(step.exercise == nil ? .system(size: 5) : .caption)
                            .frame(width: 18)
                            .foregroundStyle(Ink.muted)
                        Text(step.text).font(.callout).foregroundStyle(Ink.text)
                    }
                }
            }
            if let done {
                Label {
                    if let proof = done.proof {
                        Text("Done on the \(done.device): \(proof.summary)")
                    } else {
                        Text("Done on the \(done.device)")
                    }
                } icon: {
                    Image(systemName: done.proof == nil ? "checkmark.circle.fill" : "checkmark.seal.fill")
                }
                .font(.callout)
                .foregroundStyle(Ink.spot)
            } else {
                Button(action: start) {
                    Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.candy(.primary))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).fill(Ink.surface))
    }
}

/// Doing it: reps counted from AirPods against each target, the other
/// steps ticked, then marked done with the proof.
private struct WorkoutSheet: View {
    let routine: RoutineRecord
    @State private var session: WorkoutSession
    @State private var motion = HeadphoneMotion.shared
    @State private var confirmUnproven = false
    @Environment(\.dismiss) private var dismiss

    init(routine: RoutineRecord) {
        self.routine = routine
        _session = State(initialValue: WorkoutSession(routine: routine, sensor: .airpods))
    }

    var body: some View {
        NavigationStack {
            List {
                if !session.exercises.isEmpty {
                    Section {
                        counter
                        if !motion.isAvailable {
                            Label("Counting needs AirPods Pro, AirPods Max or AirPods (3rd generation or later). You can also count on your Watch.", systemImage: "airpods")
                                .font(.caption).foregroundStyle(Ink.muted)
                        } else if motion.isDenied {
                            Label("Agott can't read your AirPods' motion. Allow Motion & Fitness for Agott in Settings.", systemImage: "hand.raised")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Section("Exercises") {
                        ForEach(session.exercises) { exercise in
                            Button { session.select(exercise) } label: {
                                HStack {
                                    Image(systemName: exercise.symbol).frame(width: 24)
                                    Text(exercise.name)
                                    Spacer()
                                    Text("\(session.count(exercise))/\(session.target(exercise))")
                                        .monospacedDigit()
                                        .foregroundStyle(session.isMet(exercise) ? Ink.spot : Ink.muted)
                                    if session.current == exercise {
                                        Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Ink.spot)
                                    }
                                }
                            }
                            .foregroundStyle(Ink.text)
                        }
                    }
                }
                if !session.manualSteps.isEmpty {
                    Section("Tick when done") {
                        ForEach(session.manualSteps) { step in
                            Button { session.toggle(step) } label: {
                                Label(step.text, systemImage: session.ticked.contains(step.id) ? "checkmark.circle.fill" : "circle")
                            }
                            .foregroundStyle(Ink.text)
                        }
                    }
                }
            }
            .navigationTitle(routine.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if session.isProven { finish(proven: true) } else { confirmUnproven = true }
                    }
                    .fontWeight(.semibold)
                }
            }
            .confirmationDialog("Not everything was counted yet.", isPresented: $confirmUnproven, titleVisibility: .visible) {
                Button("Mark done anyway") { finish(proven: false) }
                Button("Keep going", role: .cancel) {}
            } message: {
                Text("The day counts for your streak, without proof.")
            }
        }
        .onAppear {
            session.onRep = { _, _ in UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            session.onExerciseDone = { _ in UINotificationFeedbackGenerator().notificationOccurred(.success) }
            motion.start { gravity, acceleration, time in
                session.add(gravity: gravity, acceleration: acceleration, at: time)
            }
        }
        .onDisappear { motion.stop() }
    }

    private var counter: some View {
        VStack(spacing: 6) {
            if let current = session.current {
                Text("\(session.count(current))")
                    .font(.system(size: 72, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Ink.text)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: session.count(current))
                Text("of \(session.target(current)) \(current.name.lowercased())")
                    .font(.callout).foregroundStyle(Ink.muted)
            }
            Label(motion.isRunning ? String(localized: "Counting with your AirPods") : String(localized: "Put in your AirPods to count"),
                  systemImage: "airpods")
                .font(.caption).foregroundStyle(motion.isRunning ? Ink.spot : Ink.muted)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func finish(proven: Bool) {
        motion.stop()
        RoutineSync.shared.markDone(routine.id, proof: proven || session.proof().counts.contains { $0.counted > 0 } ? session.proof() : nil)
        Task {
            await RoutineSync.shared.sync()
            await PhoneRoutines.reschedule()
        }
        dismiss()
    }
}
#endif
