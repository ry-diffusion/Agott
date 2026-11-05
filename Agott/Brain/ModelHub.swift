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
    static func openCodeModel(vision: Bool = false, modelName: String? = nil) -> OpenCodeLanguageModel {
        let id = modelName ?? (vision ? settings.visionModelName : settings.modelName)
        let entry = ModelCatalog.shared.model(id)
        return OpenCodeLanguageModel(configuration: .init(
            baseURL: entry?.chatBaseURL ?? settings.baseURL,
            model: id,
            apiKey: settings.apiKey,
            supportsVision: vision && (entry?.vision ?? true),
            api: entry?.executorAPI ?? .chatCompletions))
    }

    static func session(
        provider: ModelProvider? = nil,
        tools: [any Tool] = [],
        instructions: String,
        vision: Bool = false,
        modelName: String? = nil
    ) -> LanguageModelSession {
        switch resolved(provider) {
        case .openCode:
            LanguageModelSession(model: openCodeModel(vision: vision, modelName: modelName), tools: tools, instructions: instructions)
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
        return try await session.respond(to: prompt, generating: type).content
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
