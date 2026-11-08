import Foundation
import FoundationModels

/// The two other wire formats OpenCode Go serves models in.
///
/// - **Responses** (OpenAI's newer API): GPT-6 Luna, GPT-5.6 Luna, Grok,
///   Muse Spark.
/// - **Messages** (Anthropic's API): Claude Haiku, MiniMax M3, Qwen.
///
/// Both are translated to and from the same Foundation Models transcript as
/// Chat Completions, so tools, steps, retries and guided generation behave
/// identically whichever model answers.
/// Where a reply's text goes. Free text streams straight through; a
/// structured (JSON) answer is held until it is complete and then cleaned,
/// because models like to wrap JSON in code fences or a friendly sentence,
/// and Foundation Models parses the text exactly as given.
nonisolated final class ResponseOut: @unchecked Sendable {
    private let channel: LanguageModelExecutorGenerationChannel
    private let entryID: String
    private let structured: Bool
    private var buffer = ""

    init(_ channel: LanguageModelExecutorGenerationChannel, entryID: String, structured: Bool) {
        self.channel = channel
        self.entryID = entryID
        self.structured = structured
    }

    func append(_ text: String) async {
        if structured { buffer += text; return }
        await channel.send(.response(entryID: entryID, action: .appendText(text, tokenCount: 1)))
    }

    func finish() async {
        guard structured, !buffer.isEmpty else { return }
        await channel.send(.response(entryID: entryID, action: .appendText(OpenCodeExecutor.cleanJSON(buffer), tokenCount: 1)))
    }
}

extension OpenCodeExecutor {
    /// The JSON object inside a model's answer: no fences, no prose.
    static func cleanJSON(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = body.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            if let fence = body.range(of: "```", options: .backwards) { body = String(body[..<fence.lowerBound]) }
        }
        guard let open = body.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return body }
        let closer: Character = body[open] == "{" ? "}" : "]"
        guard let close = body.lastIndex(of: closer), close > open else { return String(body[open...]) }
        return String(body[open...close])
    }

    // MARK: Shared

    func makeRequest(path: String, body: [String: Any], for request: LanguageModelExecutorGenerationRequest,
                     extraHeaders: [String: String] = [:]) throws -> URLRequest {
        let base = configuration.baseURL.hasSuffix("/") ? String(configuration.baseURL.dropLast()) : configuration.baseURL
        guard let url = URL(string: base + path) else { throw ExecutorError.badURL }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        // Seconds of silence before giving up. Thinking models stream their
        // reasoning, so a quiet connection is a dead one, not a slow answer.
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(Self.sessionID(for: request), forHTTPHeaderField: "x-opencode-session")
        urlRequest.setValue("Agott/1.0 (macOS; Foundation Models)", forHTTPHeaderField: "User-Agent")
        for (key, value) in extraHeaders { urlRequest.setValue(value, forHTTPHeaderField: key) }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    static func parameters(_ definition: Transcript.ToolDefinition) -> Any {
        if let data = try? JSONEncoder().encode(definition.parameters),
           let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }
        return ["type": "object", "properties": [String: Any]()]
    }

    static func schemaInstruction(_ request: LanguageModelExecutorGenerationRequest) -> String? {
        guard let schema = request.schema,
              let data = try? JSONEncoder().encode(schema),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "Answer with a single JSON object, and nothing else, that satisfies this JSON schema:\n\(json)"
    }

    static func lines(_ bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<[String: Any], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let data = payload.data(using: .utf8),
                           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            continuation.yield(object)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Responses

    static func responsesInput(_ request: LanguageModelExecutorGenerationRequest) -> (instructions: String, input: [[String: Any]]) {
        var instructions: [String] = []
        var input: [[String: Any]] = []
        for entry in request.transcript {
            switch entry {
            case .instructions(let value):
                instructions.append(text(value.segments))
            case .prompt(let prompt):
                input.append(["role": "user", "content": text(prompt.segments)])
            case .response(let response):
                let content = text(response.segments)
                if !content.isEmpty { input.append(["role": "assistant", "content": content]) }
            case .toolCalls(let calls):
                for call in calls {
                    input.append(["type": "function_call", "call_id": call.id, "name": call.toolName,
                                  "arguments": call.arguments.jsonString])
                }
            case .toolOutput(let output):
                input.append(["type": "function_call_output", "call_id": output.id, "output": text(output.segments)])
            default:
                continue
            }
        }
        // OpenAI requires the word JSON in the messages themselves (not only
        // in the instructions) for JSON answers, so the schema goes in both.
        if let schema = schemaInstruction(request) {
            instructions.append(schema)
            input.append(["role": "developer", "content": schema])
        }
        return (instructions.joined(separator: "\n\n"), input)
    }

    func respondResponses(to request: LanguageModelExecutorGenerationRequest,
                          streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        let (instructions, input) = Self.responsesInput(request)
        var body: [String: Any] = [
            "model": configuration.model,
            "input": input,
            "stream": true,
            "store": false,
        ]
        if !instructions.isEmpty { body["instructions"] = instructions }
        if !request.enabledToolDefinitions.isEmpty {
            body["tools"] = request.enabledToolDefinitions.map { definition -> [String: Any] in
                ["type": "function", "name": definition.name, "description": definition.description,
                 "parameters": Self.parameters(definition)]
            }
            body["tool_choice"] = "auto"
        }
        if let maximum = request.generationOptions.maximumResponseTokens { body["max_output_tokens"] = maximum }
        if let schema = request.schema,
           let data = try? JSONEncoder().encode(schema),
           let object = try? JSONSerialization.jsonObject(with: data) {
            body["text"] = ["format": ["type": "json_schema", "name": "answer", "schema": object, "strict": false]]
        }
        var reasoning: [String: Any] = ["summary": "auto"]
        if let effort = configuration.reasoningEffort { reasoning["effort"] = effort }
        body["reasoning"] = reasoning

        let bytes = try await Self.open(makeRequest(path: "/responses", body: body, for: request))
        let responseID = UUID().uuidString
        let out = ResponseOut(channel, entryID: responseID, structured: request.schema != nil)
        let reasoningID = UUID().uuidString
        let toolsID = UUID().uuidString
        var calls: [(id: String, name: String, arguments: String)] = []

        for try await event in Self.lines(bytes) {
            try Task.checkCancellation()
            switch event["type"] as? String {
            case "response.output_text.delta":
                if let delta = event["delta"] as? String, !delta.isEmpty {
                    await out.append(delta)
                }
            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                if let delta = event["delta"] as? String, !delta.isEmpty {
                    await channel.send(.reasoning(entryID: reasoningID, action: .appendText(delta, tokenCount: 1)))
                }
            case "response.output_item.done":
                if let item = event["item"] as? [String: Any], item["type"] as? String == "function_call",
                   let name = item["name"] as? String {
                    calls.append((item["call_id"] as? String ?? UUID().uuidString, name, item["arguments"] as? String ?? "{}"))
                }
            case "response.failed", "error":
                let message = ((event["response"] as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
                    ?? (event["message"] as? String) ?? "The model failed."
                throw ExecutorError.streamFailed(message)
            default:
                continue
            }
        }
        await out.finish()
        for call in calls {
            await channel.send(.toolCalls(entryID: toolsID, action: .toolCall(
                id: call.id, name: call.name,
                action: .appendArguments(call.arguments.isEmpty ? "{}" : call.arguments, tokenCount: 1))))
        }
    }

    // MARK: Messages

    static func anthropicInput(_ request: LanguageModelExecutorGenerationRequest) -> (system: String, messages: [[String: Any]]) {
        var system: [String] = []
        var messages: [[String: Any]] = []
        /// Anthropic wants strictly alternating roles; same-role content merges.
        func append(_ role: String, _ blocks: [[String: Any]]) {
            guard !blocks.isEmpty else { return }
            if var last = messages.last, last["role"] as? String == role,
               var content = last["content"] as? [[String: Any]] {
                content += blocks
                last["content"] = content
                messages[messages.count - 1] = last
            } else {
                messages.append(["role": role, "content": blocks])
            }
        }
        for entry in request.transcript {
            switch entry {
            case .instructions(let value):
                system.append(text(value.segments))
            case .prompt(let prompt):
                append("user", [["type": "text", "text": text(prompt.segments)]])
            case .response(let response):
                let content = text(response.segments)
                if !content.isEmpty { append("assistant", [["type": "text", "text": content]]) }
            case .toolCalls(let calls):
                append("assistant", calls.map { call in
                    let input = (try? JSONSerialization.jsonObject(with: Data(call.arguments.jsonString.utf8))) ?? [String: Any]()
                    return ["type": "tool_use", "id": call.id, "name": call.toolName, "input": input]
                })
            case .toolOutput(let output):
                append("user", [["type": "tool_result", "tool_use_id": output.id, "content": text(output.segments)]])
            default:
                continue
            }
        }
        if let schema = schemaInstruction(request) { system.append(schema) }
        return (system.joined(separator: "\n\n"), messages)
    }

    func respondMessages(to request: LanguageModelExecutorGenerationRequest,
                         streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        let (system, messages) = Self.anthropicInput(request)
        var body: [String: Any] = [
            "model": configuration.model,
            "messages": messages,
            "max_tokens": request.generationOptions.maximumResponseTokens ?? 8192,
            "stream": true,
        ]
        if !system.isEmpty { body["system"] = system }
        if let temperature = request.generationOptions.temperature { body["temperature"] = temperature }
        if !request.enabledToolDefinitions.isEmpty {
            body["tools"] = request.enabledToolDefinitions.map { definition -> [String: Any] in
                ["name": definition.name, "description": definition.description, "input_schema": Self.parameters(definition)]
            }
        }

        let bytes = try await Self.open(makeRequest(
            path: "/messages", body: body, for: request,
            extraHeaders: ["x-api-key": configuration.apiKey, "anthropic-version": "2023-06-01"]))
        let responseID = UUID().uuidString
        let out = ResponseOut(channel, entryID: responseID, structured: request.schema != nil)
        let reasoningID = UUID().uuidString
        let toolsID = UUID().uuidString
        var blocks: [Int: (type: String, id: String, name: String, json: String)] = [:]

        for try await event in Self.lines(bytes) {
            try Task.checkCancellation()
            switch event["type"] as? String {
            case "content_block_start":
                let index = event["index"] as? Int ?? 0
                let block = event["content_block"] as? [String: Any] ?? [:]
                blocks[index] = (block["type"] as? String ?? "", block["id"] as? String ?? "", block["name"] as? String ?? "", "")
            case "content_block_delta":
                let index = event["index"] as? Int ?? 0
                let delta = event["delta"] as? [String: Any] ?? [:]
                switch delta["type"] as? String {
                case "text_delta":
                    if let text = delta["text"] as? String, !text.isEmpty {
                        await out.append(text)
                    }
                case "thinking_delta":
                    if let thinking = delta["thinking"] as? String, !thinking.isEmpty {
                        await channel.send(.reasoning(entryID: reasoningID, action: .appendText(thinking, tokenCount: 1)))
                    }
                case "input_json_delta":
                    if let part = delta["partial_json"] as? String { blocks[index]?.json += part }
                default:
                    continue
                }
            case "error":
                let message = (event["error"] as? [String: Any])?["message"] as? String ?? "The model failed."
                throw ExecutorError.streamFailed(message)
            default:
                continue
            }
        }
        await out.finish()
        for index in blocks.keys.sorted() {
            guard let block = blocks[index], block.type == "tool_use", !block.name.isEmpty else { continue }
            await channel.send(.toolCalls(entryID: toolsID, action: .toolCall(
                id: block.id.isEmpty ? UUID().uuidString : block.id, name: block.name,
                action: .appendArguments(block.json.isEmpty ? "{}" : block.json, tokenCount: 1))))
        }
    }
}
