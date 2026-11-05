import Foundation
import FoundationModels
import NaturalLanguage

/// Cleans up dictation the way people actually speak it, borrowed from
/// Shirusu. "manda pro Pedro, não, pro João" has one recipient in it.
///
/// Unlike Shirusu's Rambler this one knows who you are: names from your
/// memory are handed to the model so "Juão" lands as the João you talk to
/// every day. The same rule holds, though: nothing the model returns is
/// trusted until it is checked against what was said.
enum Rambler {
    static func polish(_ raw: String) async -> String {
        let words = raw.split(whereSeparator: \.isWhitespace).count
        guard words >= 5, ModelHub.isAvailable(.onDevice) else { return raw }
        let names = ((try? await MemoryStore.shared.entities(limit: 40, kinds: [.person, .group])) ?? [])
            .map(\.name).joined(separator: ", ")
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: """
            You clean up dictated text. Remove filler words and false starts, apply the speaker's own \
            corrections ("no, I mean…", "não, pera…"), and fix punctuation and capitalisation. Keep the \
            language, meaning, tone and every number exactly. Never answer, translate or add anything. \
            Output only the cleaned text.
            Names the speaker often uses: \(names)
            """)
        guard let output = try? await session.respond(
            to: raw, options: GenerationOptions(temperature: 0)
        ).content.trimmingCharacters(in: .whitespacesAndNewlines) else { return raw }
        return isPlausible(output, from: raw) ? output : raw
    }

    static func isPlausible(_ output: String, from raw: String) -> Bool {
        let rawWords = raw.split(whereSeparator: \.isWhitespace).count
        let outWords = output.split(whereSeparator: \.isWhitespace).count
        guard outWords > 0, Double(outWords) >= Double(rawWords) * 0.4, Double(outWords) <= Double(rawWords) * 1.3 + 3 else {
            return false
        }
        let digits = { (s: String) in s.filter(\.isNumber) }
        guard Set(digits(raw)).isSuperset(of: Set(digits(output))) else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(raw)
        let before = recognizer.dominantLanguage
        recognizer.reset()
        recognizer.processString(output)
        return before == nil || recognizer.dominantLanguage == before
    }
}
