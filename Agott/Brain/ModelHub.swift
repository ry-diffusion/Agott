import Foundation
import FoundationModels

/// The one place that knows which model is answering.
enum ModelHub {
    static var settings: AppSettings { .shared }

    static func isAvailable(_ provider: ModelProvider) -> Bool {
        switch provider {
        case .openCode: settings.hasAPIKey
        case .privateCloud: PrivateCloudComputeLanguageModel().isAvailable
        case .onDevice: SystemLanguageModel.default.isAvailable
        }
    }

    /// The provider to use: the chosen one if it works, else the best that does.
    static func resolved(_ preferred: ModelProvider? = nil) -> ModelProvider {
        let first = preferred ?? settings.provider
        if isAvailable(first) { return first }
        return ModelProvider.allCases.first(where: { isAvailable($0) }) ?? first
    }

    /// An OpenCode model, by id. Each model's own endpoint comes from the
    /// catalogue, so models served from different paths just work.
    static func openCodeModel(vision: Bool = false, modelName: String? = nil, thinking: Bool = false) -> OpenCodeLanguageModel {
        let id = modelName ?? (vision ? settings.visionModelName : settings.modelName)
        let entry = ModelCatalog.shared.model(id)
        return OpenCodeLanguageModel(configuration: .init(
            baseURL: entry?.chatBaseURL ?? settings.baseURL,
            model: id,
            apiKey: settings.apiKey,
            supportsVision: vision && (entry?.vision ?? true),
            api: entry?.executorAPI ?? .chatCompletions,
            reasoningEffort: effort(for: entry, thinking: thinking),
            family: entry?.family ?? ""))
    }

    /// Conversations think properly; background reading thinks as little as
    /// the model allows, to stay fast and cheap.
    static func effort(for entry: CatalogModel?, thinking: Bool) -> String? {
        // Messages-format thinking needs its signed blocks replayed on every
        // tool turn, which Agott does not keep yet; leave those models be.
        guard let entry, entry.reasoning, entry.executorAPI != .messages,
              let efforts = entry.efforts, !efforts.isEmpty else { return nil }
        if thinking { return efforts.contains("high") ? "high" : efforts.last }
        return efforts.first
    }

    static func session(
        provider: ModelProvider? = nil,
        tools: [any Tool] = [],
        instructions: String,
        vision: Bool = false,
        modelName: String? = nil,
        thinking: Bool = false,
        history: [Turn]
    ) -> LanguageModelSession {
        guard !history.isEmpty else {
            return session(provider: provider, tools: tools, instructions: instructions, vision: vision,
                           modelName: modelName, thinking: thinking)
        }
        // Rebuild the conversation as a transcript: instructions, then each
        // turn as a prompt or a response.
        var entries: [Transcript.Entry] = [
            .instructions(.init(segments: [.text(.init(content: instructions))],
                                toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) }))
        ]
        for turn in history where !turn.text.isEmpty {
            let segment = Transcript.Segment.text(.init(content: turn.text))
            entries.append(turn.role == .user ? .prompt(.init(segments: [segment])) : .response(.init(assetIDs: [], segments: [segment])))
        }
        let transcript = Transcript(entries: entries)
        switch resolved(provider) {
        case .openCode:
            return LanguageModelSession(model: openCodeModel(vision: vision, modelName: modelName, thinking: thinking),
                                        tools: tools, transcript: transcript)
        case .privateCloud:
            return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools, transcript: transcript)
        case .onDevice:
            return LanguageModelSession(model: SystemLanguageModel.default, tools: tools, transcript: transcript)
        }
    }

    static func session(
        provider: ModelProvider? = nil,
        tools: [any Tool] = [],
        instructions: String,
        vision: Bool = false,
        modelName: String? = nil,
        thinking: Bool = false
    ) -> LanguageModelSession {
        switch resolved(provider) {
        case .openCode:
            LanguageModelSession(model: openCodeModel(vision: vision, modelName: modelName, thinking: thinking),
                                 tools: tools, instructions: instructions)
        case .privateCloud:
            LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools, instructions: instructions)
        case .onDevice:
            LanguageModelSession(model: SystemLanguageModel.default, tools: tools, instructions: instructions)
        }
    }

    /// A single structured answer, in a session of its own.
    static func generate<T: Generable>(
        _ type: T.Type,
        prompt: String,
        instructions: String,
        provider: ModelProvider? = nil,
        modelName: String? = nil
    ) async throws -> T {
        let session = session(provider: provider, instructions: instructions, modelName: modelName)
        do {
            return try await session.respond(to: prompt, generating: type).content
        } catch where "\(error)".localizedCaseInsensitiveContains("pars") || "\(error)".localizedCaseInsensitiveContains("decod") {
            // The model answered, but not in a shape that parsed. Ask once more
            // for plain JSON and read it ourselves.
            let schema = (try? JSONEncoder().encode(T.generationSchema)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let retry = self.session(
                provider: provider,
                instructions: instructions + "\n\nAnswer with one JSON object and nothing else. It must match this JSON schema:\n\(schema)",
                modelName: modelName)
            let text = try await retry.respond(to: prompt).content
            return try T(GeneratedContent(json: OpenCodeExecutor.cleanJSON(text)))
        }
    }

    /// Whether an error means the model could not be reached (network,
    /// blocked site, missing key, an overloaded server), as opposed to an
    /// answer that came back wrong. Reading must stop and wait on the first
    /// kind, not skip what it was reading.
    nonisolated static func isConnectionProblem(_ error: Error) -> Bool {
        if error is URLError || error is CancellationError { return true }
        if let executor = error as? OpenCodeExecutor.ExecutorError {
            switch executor {
            case .unreachable, .missingKey: return true
            case .http(let code, _): return code >= 500 || [401, 403, 408, 409, 425, 429].contains(code)
            default: return false
            }
        }
        // Jev busy, down or without a key is TypeSafe being unreachable too.
        if let jev = error as? Jev.JevError {
            switch jev {
            case .missingKey: return true
            case .http(let code, _): return code >= 500 || [401, 403, 408, 429].contains(code)
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isConnectionProblem(underlying) }
        let text = "\(error)".lowercased()
        return text.contains("nsurlerrordomain") || text.contains("urlerror") || text.contains("unreachable")
    }

    /// The request itself can never work as set up (a model that does not
    /// exist, no credit, an endpoint that is wrong): every try fails the same
    /// way, so work should stop and keep what is unread for later.
    nonisolated static func isConfigurationProblem(_ error: Error) -> Bool {
        guard let executor = error as? OpenCodeExecutor.ExecutorError else { return false }
        switch executor {
        case .badURL, .missingKey: return true
        case .http(let code, _): return [400, 402, 404, 405, 410, 413, 415, 422].contains(code)
        default: return false
        }
    }

    static func text(_ prompt: String, instructions: String, provider: ModelProvider? = nil) async throws -> String {
        let session = session(provider: provider, instructions: instructions)
        return try await session.respond(to: prompt).content
    }

    /// The private choice for bulk reading of your messages: on-device when it
    /// exists, the chosen model when it does not.
    static var bulkProvider: ModelProvider {
        isAvailable(.onDevice) ? .onDevice : resolved()
    }

    /// Who reads your messages to learn about you: your choice in Settings,
    /// falling back to whatever works.
    /// What the header shows: the model's own name when it is an OpenCode one.
    static var currentModelLabel: String {
        let provider = resolved()
        guard provider == .openCode else { return provider.title }
        return ModelCatalog.shared.model(settings.modelName)?.name ?? settings.modelName
    }

    /// The OpenCode model used for analyzing memories, if it differs.
    static var learningModel: String? {
        settings.learningModelName.isEmpty ? nil : settings.learningModelName
    }

    static var learningProvider: ModelProvider {
        resolved(settings.learningProvider)
    }
}
