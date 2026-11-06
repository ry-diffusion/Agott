import Foundation

/// TypeSafe's Jev: quick typed judgments (yes/no, one of, how much) about a
/// piece of state, with probabilities. Agott uses it where a full model
/// would be slow and wordy: "does this new message need an answer?".
///
/// One request asks several independent questions about the same state;
/// they are answered together.
nonisolated enum Jev {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let keychainAccount = "typesafe-api-key"

    static var apiKey: String { Keychain.get(keychainAccount) ?? "" }
    static var isConfigured: Bool { !apiKey.isEmpty }

    enum Question {
        case noul(String)
        case choice(String, [String: String])
        case score(String, [String])

        var json: [String: Any] {
            switch self {
            case .noul(let instructions): ["type": "noul", "instructions": instructions]
            case .choice(let instructions, let options): ["type": "choice", "instructions": instructions, "criteria": options]
            case .score(let instructions, let levels): ["type": "score", "instructions": instructions, "criteria": levels]
            }
        }
    }

    struct Answer: Sendable {
        /// Probability of yes, for a noul.
        var probability: Double?
        /// The top option, for a choice.
        var choice: String?
        /// The expected level (may be fractional), for a score.
        var score: Double?
        var confidence: Double?
    }

    enum JevError: LocalizedError {
        case missingKey
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .missingKey: String(localized: "Add your TypeSafe API key in Settings.")
            case .http(let code, let body): String(localized: "TypeSafe answered \(code): \(body)")
            }
        }
    }

    /// Asks every question about `state` in one request.
    static func ask(state: Any, questions: [String: Question], model: String = "jev-latest") async throws -> [String: Answer] {
        let key = apiKey
        guard !key.isEmpty else { throw JevError.missingKey }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "state": state,
            "questions": questions.mapValues(\.json),
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw JevError.http(status, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return parse(data)
    }

    static func parse(_ data: Data) -> [String: Answer] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = object["answers"] as? [String: [String: Any]] else { return [:] }
        return answers.mapValues { answer in
            Answer(
                probability: (answer["noul"] as? NSNumber)?.doubleValue,
                choice: answer["choice"] as? String,
                score: (answer["score"] as? NSNumber)?.doubleValue,
                confidence: (answer["confidence"] as? NSNumber)?.doubleValue)
        }
    }
}
