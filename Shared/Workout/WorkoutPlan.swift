import Foundation

/// The exercises Agott can count by itself.
nonisolated enum Exercise: String, Codable, CaseIterable, Sendable, Identifiable {
    case pushUp, squat, pullUp

    var id: String { rawValue }

    var name: String {
        switch self {
        case .pushUp: String(localized: "Push-ups")
        case .squat: String(localized: "Squats")
        case .pullUp: String(localized: "Pull-ups")
        }
    }

    var symbol: String {
        switch self {
        case .pushUp: "figure.strengthtraining.functional"
        case .squat: "figure.cross.training"
        case .pullUp: "figure.climbing"
        }
    }

    /// Words that name it, folded (no accents, lower case), in English and
    /// Portuguese.
    fileprivate var words: [String] {
        switch self {
        case .pushUp: ["flexao", "flexoes", "push-up", "push up", "pushup", "apoio"]
        case .squat: ["agach", "squat"]
        case .pullUp: ["barra fixa", "pull-up", "pull up", "pullup", "chin-up", "chin up", "chinup", "barra"]
        }
    }
}

/// What counted the reps.
nonisolated enum MotionSensor: String, Codable, Sendable {
    case watch, airpods, manual
}

/// One line of a routine's steps, and what it asks for if Agott can tell.
nonisolated struct WorkoutStep: Codable, Hashable, Sendable, Identifiable {
    var id: Int
    var text: String
    var exercise: Exercise?
    /// Reps in all (sets × reps), when the line says.
    var reps: Int?

    /// Counted by motion; anything else is ticked by hand.
    var isCountable: Bool { exercise != nil && reps != nil }
}

/// A routine's steps (Markdown, as the model wrote them) read as targets:
/// "3x10 flexões" is 30 push-ups, "4 séries de 12 agachamentos" 48 squats,
/// "20 push-ups" 20. Timed things ("30s de prancha") and anything Agott can't
/// count are steps to tick by hand.
nonisolated struct WorkoutPlan: Codable, Hashable, Sendable {
    var steps: [WorkoutStep]

    /// Reps asked for each exercise, all lines together.
    var targets: [Exercise: Int] {
        steps.reduce(into: [:]) { totals, step in
            if let exercise = step.exercise, let reps = step.reps { totals[exercise, default: 0] += reps }
        }
    }

    /// Counted reps prove an exercise once they reach this share of the
    /// target: motion can miss a shallow rep, and a hand can be honest.
    static let enough = 0.9

    static func required(_ target: Int) -> Int { Int((Double(target) * enough).rounded(.up)) }

    /// Done for real: every exercise counted up to its target and every
    /// other step ticked.
    func isProven(counts: [Exercise: Int], ticked: Set<Int>) -> Bool {
        let countsMet = targets.allSatisfy { counts[$0.key, default: 0] >= Self.required($0.value) }
        let ticksMet = steps.filter { !$0.isCountable }.allSatisfy { ticked.contains($0.id) }
        return countsMet && ticksMet
    }

    static func parse(_ markdown: String?) -> WorkoutPlan {
        let lines = (markdown ?? "")
            .split(whereSeparator: \.isNewline)
            .map { line in
                line.trimmingCharacters(in: .whitespaces)
                    .replacing(try! Regex(#"^([-*+•]|\d+[.)])\s+"#), with: "")
                    .replacing(try! Regex(#"\*\*|__|`"#), with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return WorkoutPlan(steps: lines.enumerated().map { index, line in
            let folded = line.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            let exercise = Exercise.allCases.first { exercise in exercise.words.contains { folded.contains($0) } }
            return WorkoutStep(id: index, text: line, exercise: exercise, reps: exercise == nil ? nil : reps(in: folded))
        })
    }

    /// "3x10", "3 x 10 reps", "3 séries de 12", "4 sets of 8", "20 flexões";
    /// not "30s", "1 min", "60 segundos".
    static func reps(in folded: String) -> Int? {
        let time = #"\s*(s\b|seg|sec|min|segundo|second)"#
        // Sets × reps (but not 3x30s).
        if let match = folded.firstMatch(of: try! Regex(#"(\d+)\s*[x×]\s*(\d+)(?!\d)"#)),
           let sets = Int(match.output[1].substring ?? ""), let reps = Int(match.output[2].substring ?? "") {
            let rest = folded[match.range.upperBound...]
            if rest.firstMatch(of: try! Regex("^" + time)) == nil { return sets * reps }
            return nil
        }
        if let match = folded.firstMatch(of: try! Regex(#"(\d+)\s*(series|serie|sets?|rounds?|rodadas?)\s*(de|of|x|com|with)?\s*(\d+)"#)),
           let sets = Int(match.output[1].substring ?? ""), let reps = Int(match.output[4].substring ?? "") {
            let rest = folded[match.range.upperBound...]
            if rest.firstMatch(of: try! Regex("^" + time)) == nil { return sets * reps }
            return nil
        }
        // A single number that is not a time.
        for match in folded.matches(of: try! Regex(#"(\d+)"#)) {
            let rest = folded[match.range.upperBound...]
            guard rest.firstMatch(of: try! Regex("^" + time)) == nil,
                  rest.firstMatch(of: try! Regex(#"^\s*(kg|km|m\b|%)"#)) == nil else { continue }
            return Int(match.output[1].substring ?? "")
        }
        return nil
    }
}
