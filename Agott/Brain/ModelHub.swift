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

    static func openCodeModel(vision: Bool = false) -> OpenCodeLanguageModel {
        OpenCodeLanguageModel(configuration: .init(
            baseURL: settings.baseURL,
            model: vision ? settings.visionModelName : settings.modelName,
            apiKey: settings.apiKey,
            supportsVision: vision))
    }

    static func session(
        provider: ModelProvider? = nil,
        tools: [any Tool] = [],
        instructions: String,
        vision: Bool = false
    ) -> LanguageModelSession {
        switch resolved(provider) {
        case .openCode:
            LanguageModelSession(model: openCodeModel(vision: vision), tools: tools, instructions: instructions)
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
        provider: ModelProvider? = nil
    ) async throws -> T {
        let session = session(provider: provider, instructions: instructions)
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
    static var learningProvider: ModelProvider {
        resolved(settings.learningProvider)
    }
}
