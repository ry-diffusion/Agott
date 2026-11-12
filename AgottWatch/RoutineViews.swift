import SwiftUI
import WatchKit

/// Today's routines.
struct RoutineList: View {
    @State private var sync = RoutineSync.shared

    var body: some View {
        NavigationStack {
            List {
                if !sync.isConnected {
                    Text("Open Agott on your iPhone and connect sync in Settings.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if sync.active.isEmpty {
                    Text("No routines yet. Ask Agott on your Mac to make you do something every day.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(sync.active) { routine in
                    NavigationLink(value: routine) { RoutineRow(routine: routine) }
                }
                if let problem = sync.problem {
                    Text(problem).font(.footnote).foregroundStyle(.orange)
                }
            }
            .navigationTitle("Agott")
            .navigationDestination(for: RoutineRecord.self) { RoutineDetail(routine: $0) }
        }
    }
}

private struct RoutineRow: View {
    var routine: RoutineRecord
    @State private var sync = RoutineSync.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(routine.title).font(.headline)
                Spacer()
                if sync.doneToday(routine.id) != nil {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
            }
            HStack(spacing: 6) {
                Text(routine.time)
                let streak = sync.streak(routine.id)
                if streak > 0 { Label("\(streak)", systemImage: "flame.fill").foregroundStyle(.orange) }
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// The steps, and the way into counting them.
private struct RoutineDetail: View {
    var routine: RoutineRecord
    @State private var sync = RoutineSync.shared
    @State private var counting = false

    var body: some View {
        List {
            if let done = sync.doneToday(routine.id) {
                Label(done.proof?.summary ?? String(localized: "Done today"), systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Button { counting = true } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .tint(.green)
            }
            Section("Steps") {
                ForEach(routine.plan.steps) { step in
                    Text(step.text).font(.footnote)
                }
            }
        }
        .navigationTitle(routine.title)
        .fullScreenCover(isPresented: $counting) { CountingView(routine: routine) }
    }
}

/// Reps counted from the wrist, one exercise at a time.
private struct CountingView: View {
    let routine: RoutineRecord
    @State private var session: WorkoutSession
    @State private var wrist = WristWorkout()
    @State private var finishing = false
    @Environment(\.dismiss) private var dismiss

    init(routine: RoutineRecord) {
        self.routine = routine
        _session = State(initialValue: WorkoutSession(routine: routine, sensor: .watch))
    }

    var body: some View {
        TabView {
            counter
            checklist
        }
        .tabViewStyle(.verticalPage)
        .task {
            session.onRep = { _, _ in WKInterfaceDevice.current().play(.click) }
            session.onExerciseDone = { _ in WKInterfaceDevice.current().play(.success) }
            await wrist.start(session)
        }
    }

    private var counter: some View {
        VStack(spacing: 4) {
            if let current = session.current {
                Label(current.name, systemImage: current.symbol)
                    .font(.footnote).foregroundStyle(.secondary)
                Text("\(session.count(current))")
                    .font(.system(size: 64, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.snappy, value: session.count(current))
                Text("of \(session.target(current))").font(.footnote).foregroundStyle(.secondary)
                if session.exercises.count > 1 {
                    Button("Next exercise") {
                        let all = session.exercises
                        if let index = all.firstIndex(of: current) { session.select(all[(index + 1) % all.count]) }
                    }
                    .font(.footnote)
                }
            } else {
                Text("Nothing to count in this routine; tick the steps.")
                    .font(.footnote).multilineTextAlignment(.center)
            }
        }
    }

    private var checklist: some View {
        List {
            ForEach(session.exercises) { exercise in
                HStack {
                    Image(systemName: exercise.symbol)
                    Text(exercise.name)
                    Spacer()
                    Text("\(session.count(exercise))/\(session.target(exercise))").monospacedDigit()
                        .foregroundStyle(session.isMet(exercise) ? .green : .secondary)
                }
            }
            ForEach(session.manualSteps) { step in
                Button { session.toggle(step) } label: {
                    Label(step.text, systemImage: session.ticked.contains(step.id) ? "checkmark.circle.fill" : "circle")
                        .font(.footnote)
                }
            }
            Button(session.isProven ? String(localized: "Done") : String(localized: "Done without proof")) {
                Task { await finish() }
            }
            .tint(session.isProven ? .green : .orange)
            .disabled(finishing)
            Button("Cancel", role: .cancel) {
                Task {
                    await wrist.end()
                    dismiss()
                }
            }
        }
    }

    private func finish() async {
        finishing = true
        await wrist.end()
        let proof = session.proof()
        RoutineSync.shared.markDone(routine.id, proof: proof.counts.contains { $0.counted > 0 } || !proof.ticked.isEmpty ? proof : nil)
        await RoutineSync.shared.sync()
        dismiss()
    }
}
