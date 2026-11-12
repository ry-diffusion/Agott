#if os(iOS)
import Charts
import SwiftUI

/// How a routine's sets go over time, per exercise: reps per set, pace,
/// rest and heart rate, from Apple Health and from workouts synced from the
/// Watch and other devices.
struct RoutineProgressView: View {
    let routine: RoutineRecord
    @State private var history: [Exercise: [ExerciseEfficiency]] = [:]
    @State private var loaded = false

    var body: some View {
        List {
            if loaded && history.isEmpty {
                Text("Count a workout with your Watch or AirPods and it shows here: reps per set, pace, rest and heart rate.")
                    .font(.callout).foregroundStyle(Ink.muted)
            }
            ForEach(Exercise.allCases.filter { history[$0]?.isEmpty == false }) { exercise in
                let entries = history[exercise] ?? []
                Section {
                    if let trend = EfficiencyTrend.of(entries) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(trend.latest.summary).font(.callout).foregroundStyle(Ink.text)
                            if let change = trend.summary {
                                Text("Against your last workouts: \(change)").font(.caption).foregroundStyle(Ink.spot)
                            }
                        }
                    }
                    Chart(entries) { entry in
                        BarMark(x: .value("Day", entry.date, unit: .day), y: .value("Reps", entry.reps))
                            .foregroundStyle(Ink.spot.opacity(0.35))
                        if let pace = entry.repsPerMinute {
                            LineMark(x: .value("Day", entry.date, unit: .day), y: .value("Reps per minute", pace))
                                .foregroundStyle(Ink.spot)
                                .symbol(.circle)
                        }
                    }
                    .chartYAxisLabel(String(localized: "Reps · reps per minute"))
                    .frame(height: 160)
                    ForEach(entries.reversed().prefix(8)) { entry in
                        HStack {
                            Text(entry.date.formatted(.dateTime.day().month(.abbreviated)))
                                .font(.caption.monospacedDigit()).foregroundStyle(Ink.muted)
                                .frame(width: 56, alignment: .leading)
                            Text(entry.summary).font(.caption).foregroundStyle(Ink.text)
                        }
                    }
                } header: {
                    Label(exercise.name, systemImage: exercise.symbol)
                }
            }
            Section {
                Text("Every workout Agott counts is saved to Apple Health as functional strength training, each set as one of its activities.")
                    .font(.caption).foregroundStyle(Ink.muted)
            }
        }
        .navigationTitle(routine.title)
        .task {
            history = await EfficiencyHistory.load(routine.id)
            loaded = true
        }
    }
}
#endif
