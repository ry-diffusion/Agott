import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
import UniformTypeIdentifiers

/// DeepSeek V4 Flash (or any OpenAI-compatible model) as a Foundation Models
/// `LanguageModel`.
///
/// This is what lets the rest of Agott be written once. Tools are ordinary
/// `Tool`s with `@Generable` arguments; sessions are ordinary
/// `LanguageModelSession`s. Whether the words come from Apple's on-device model,
/// Private Cloud Compute, or DeepSeek through OpenCode Go is one line in
/// `ModelHub`, and the tool loop, the transcript and guided generation behave
/// the same for all three.
nonisolated struct OpenCodeLanguageModel: LanguageModel {
    typealias Executor = OpenCodeExecutor

    var configuration: OpenCodeExecutor.Configuration

    var capabilities: LanguageModelCapabilities {
        var list: [LanguageModelCapabilities.Capability] = [.toolCalling, .guidedGeneration, .reasoning]
        if configuration.supportsVision { list.append(.vision) }
        return LanguageModelCapabilities(list)
    }

    var executorConfiguration: OpenCodeExecutor.Configuration { configuration }
}

nonisolated struct OpenCodeExecutor: LanguageModelExecutor {
    typealias Model = OpenCodeLanguageModel

    struct Configuration: Hashable, Sendable {
        /// e.g. https://opencode.ai/inference/go/openai/v1
        var baseURL: String
        var model: String
        var apiKey: String
        var supportsVision: Bool = false
        /// Which wire format the model is served in.
        var api: API = .chatCompletions
        /// How hard to think before answering ("low", "high", "max"), or nil
        /// to leave it to the model.
        var reasoningEffort: String?
        /// The model family, for vendor switches such as DeepSeek's thinking flag.
        var family: String = ""
    }

    /// OpenCode Go serves models in different formats; Agott speaks three.
    enum API: String, Hashable, Sendable, Codable {
        case chatCompletions = "chat-completions"
        case responses
        case messages
    }

    enum ExecutorError: LocalizedError {
        case missingKey
        case badURL
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .missingKey: String(localized: "Add your OpenCode Go API key in Settings.")
            case .badURL: String(localized: "The model endpoint URL is not valid.")
            case .http(let code, let body): String(localized: "The model server answered \(code): \(body)")
            }
        }
    }

    let configuration: Configuration

    init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: OpenCodeLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        guard !configuration.apiKey.isEmpty else { throw ExecutorError.missingKey }
        switch configuration.api {
        case .responses: return try await respondResponses(to: request, streamingInto: channel)
        case .messages: return try await respondMessages(to: request, streamingInto: channel)
        case .chatCompletions: break
        }
        let base = configuration.baseURL.hasSuffix("/") ? String(configuration.baseURL.dropLast()) : configuration.baseURL
        guard let url = URL(string: base + "/chat/completions") else { throw ExecutorError.badURL }

        var body: [String: Any] = [
            "model": configuration.model,
            "messages": Self.messages(from: request, vision: configuration.supportsVision),
            "stream": true,
        ]
        if !request.enabledToolDefinitions.isEmpty {
            body["tools"] = request.enabledToolDefinitions.map(Self.tool)
            body["tool_choice"] = "auto"
        }
        if let temperature = request.generationOptions.temperature { body["temperature"] = temperature }
        if let maximum = request.generationOptions.maximumResponseTokens { body["max_tokens"] = maximum }
        if request.schema != nil { body["response_format"] = ["type": "json_object"] }
        if let effort = configuration.reasoningEffort {
            body["reasoning_effort"] = effort
            if configuration.family.hasPrefix("deepseek") { body["thinking"] = ["type": "enabled"] }
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        // OpenCode Go routes and caches by conversation, and asks clients to
        // name themselves. The transcript's first entry is created with the
        // session and never changes, so its id is a stable conversation id.
        urlRequest.setValue(Self.sessionID(for: request), forHTTPHeaderField: "x-opencode-session")
        urlRequest.setValue("Agott/1.0 (macOS; Foundation Models)", forHTTPHeaderField: "User-Agent")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let bytes = try await Self.open(urlRequest)

        let responseID = UUID().uuidString
        let reasoningID = UUID().uuidString
        let toolsID = UUID().uuidString
        let out = ResponseOut(channel, entryID: responseID, structured: request.schema != nil)
        var pendingCalls: [Int: (id: String, name: String, arguments: String)] = [:]

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choice = (object["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any]
            else { continue }

            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                await channel.send(.reasoning(entryID: reasoningID, action: .appendText(reasoning, tokenCount: 1)))
            }
            if let content = delta["content"] as? String, !content.isEmpty {
                await out.append(content)
            }
            for call in (delta["tool_calls"] as? [[String: Any]]) ?? [] {
                let index = call["index"] as? Int ?? 0
                var entry = pendingCalls[index] ?? (id: "", name: "", arguments: "")
                if let id = call["id"] as? String, !id.isEmpty { entry.id = id }
                if let function = call["function"] as? [String: Any] {
                    if let name = function["name"] as? String, !name.isEmpty { entry.name = name }
                    if let arguments = function["arguments"] as? String { entry.arguments += arguments }
                }
                pendingCalls[index] = entry
            }
        }

        await out.finish()
        // Tool calls are handed over whole: the framework parses arguments as
        // generated content, and half an argument object parses as nothing.
        for index in pendingCalls.keys.sorted() {
            guard let call = pendingCalls[index], !call.name.isEmpty else { continue }
            let arguments = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            await channel.send(.toolCalls(
                entryID: toolsID,
                action: .toolCall(
                    id: call.id.isEmpty ? "call_\(index)_\(UUID().uuidString.prefix(8))" : call.id,
                    name: call.name,
                    action: .appendArguments(arguments.isEmpty ? "{}" : arguments, tokenCount: 1))))
        }
    }

    /// Statuses that mean "try again shortly": rate limits, an overloaded
    /// upstream, and gateway hiccups. Anything else is a real answer.
    static let retryable: Set<Int> = [408, 409, 425, 429, 500, 502, 503, 504, 520, 522, 524, 529]
    static let maxAttempts = 5

    /// Opens the stream, retrying transient failures with exponential backoff
    /// and jitter, honouring Retry-After when the server sends one.
    ///
    /// Retrying is safe here because nothing has been streamed yet: a failure
    /// at this point means the request never started generating, so sending
    /// it again cannot duplicate any text or tool call.
    static func open(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else {
                    return bytes
                }
                var text = ""
                for try await line in bytes.lines { text += line; if text.count > 2000 { break } }
                guard retryable.contains(http.statusCode), attempt < maxAttempts else {
                    throw ExecutorError.http(http.statusCode, String(text.prefix(400)))
                }
                let hinted = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
                try await backoff(attempt: attempt, hinted: hinted, reason: http.statusCode)
            } catch let error as URLError where attempt < maxAttempts && Self.isTransient(error) {
                try await backoff(attempt: attempt, hinted: nil, reason: error.errorCode)
            }
        }
    }

    static func isTransient(_ error: URLError) -> Bool {
        [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
         .dnsLookupFailed, .cannotFindHost, .secureConnectionFailed].contains(error.code)
    }

    private static func backoff(attempt: Int, hinted: Double?, reason: Int) async throws {
        // 1s, 2s, 4s, 8s (capped at 20s), plus up to 30% jitter so parallel
        // requests do not retry in lockstep.
        let base = min(20, pow(2, Double(attempt - 1)))
        let delay = min(30, hinted ?? base * Double.random(in: 1...1.3))
        await CardBus.status(String(localized: "The model is busy, retrying in \(Int(delay.rounded(.up)))s…"))
        try await Task.sleep(for: .seconds(delay))
    }

    static func sessionID(for request: LanguageModelExecutorGenerationRequest) -> String {
        guard let first = request.transcript.first else { return request.id.uuidString }
        return "agott-\(first.id)"
    }

    // MARK: Transcript → Chat Completions

    static func messages(from request: LanguageModelExecutorGenerationRequest, vision: Bool) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        var pendingReasoning: String?

        for entry in request.transcript {
            switch entry {
            case .instructions(let instructions):
                messages.append(["role": "system", "content": text(instructions.segments)])
            case .prompt(let prompt):
                messages.append(["role": "user", "content": content(prompt.segments, vision: vision)])
            case .reasoning(let reasoning):
                pendingReasoning = text(reasoning.segments)
            case .toolCalls(let calls):
                var message: [String: Any] = [
                    "role": "assistant",
                    "content": "",
                    "tool_calls": calls.map { call in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": ["name": call.toolName, "arguments": call.arguments.jsonString],
                        ] as [String: Any]
                    },
                ]
                if let reasoning = pendingReasoning, !reasoning.isEmpty { message["reasoning_content"] = reasoning }
                pendingReasoning = nil
                messages.append(message)
            case .toolOutput(let output):
                messages.append([
                    "role": "tool",
                    "tool_call_id": output.id,
                    "content": text(output.segments),
                ])
            case .response(let response):
                messages.append(["role": "assistant", "content": text(response.segments)])
                pendingReasoning = nil
            case .data:
                continue
            @unknown default:
                continue
            }
        }

        if let schema = request.schema,
           let data = try? JSONEncoder().encode(schema),
           let json = String(data: data, encoding: .utf8)
        {
            messages.append([
                "role": "system",
                "content": "Answer with a single JSON object, and nothing else, that satisfies this JSON schema:\n\(json)",
            ])
        }
        return messages
    }

    static func tool(_ definition: Transcript.ToolDefinition) -> [String: Any] {
        var parameters: Any = ["type": "object", "properties": [String: Any]()]
        if let data = try? JSONEncoder().encode(definition.parameters),
           let object = try? JSONSerialization.jsonObject(with: data)
        {
            parameters = object
        }
        return [
            "type": "function",
            "function": [
                "name": definition.name,
                "description": definition.description,
                "parameters": parameters,
            ] as [String: Any],
        ]
    }

    static func text(_ segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            switch segment {
            case .text(let text): text.content
            case .structure(let structure): structure.content.jsonString
            case .attachment(let attachment): attachment.label.map { "[attachment: \($0)]" }
            @unknown default: nil
            }
        }.joined(separator: "\n")
    }

    /// Plain text unless there is an image and the model can see.
    private static func content(_ segments: [Transcript.Segment], vision: Bool) -> Any {
        guard vision, segments.contains(where: { if case .attachment = $0 { true } else { false } }) else {
            return text(segments)
        }
        return segments.compactMap { segment -> [String: Any]? in
            switch segment {
            case .text(let text):
                return ["type": "text", "text": text.content]
            case .structure(let structure):
                return ["type": "text", "text": structure.content.jsonString]
            case .attachment(let attachment):
                guard case .image(let image) = attachment.content, let jpeg = jpegData(image.cgImage) else { return nil }
                return ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]]
            @unknown default:
                return nil
            }
        }
    }

    static func jpegData(_ image: CGImage, quality: Double = 0.7) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
