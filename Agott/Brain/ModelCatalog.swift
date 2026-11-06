import Foundation
import Observation

/// Every model OpenCode Go offers, from its public catalogue.
///
/// Each entry says which APIs it speaks and where. Agott talks Chat
/// Completions, so models offered there can be picked; the rest are listed
/// (so you can see what exists) but not selectable yet. Picking a model also
/// sets the endpoint and the context window that memory analysis batches to.
nonisolated struct CatalogModel: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var summary: String
    var family: String
    var context: Int
    var output: Int
    /// The endpoint and wire format Agott will use for this model.
    var chatBaseURL: String?
    var api: String?
    var vision: Bool
    var reasoning: Bool
    /// Reasoning effort levels the model accepts, lowest first ("low", "high", "max").
    var efforts: [String]?
    var tools: Bool
    var priceIn: Double?
    var priceOut: Double?
    var released: String?

    var isSupported: Bool { chatBaseURL != nil && tools }

    var executorAPI: OpenCodeExecutor.API {
        OpenCodeExecutor.API(rawValue: api ?? "") ?? .chatCompletions
    }
}

@Observable
final class ModelCatalog {
    static let shared = ModelCatalog()
    static let url = URL(string: "https://opencode.ai/inference/go/v1/models")!

    private(set) var models: [CatalogModel] = []
    private(set) var isLoading = false
    private(set) var error: String?

    private init() {
        if let data = UserDefaults.standard.data(forKey: "modelCatalog"),
           let cached = try? JSONDecoder().decode([CatalogModel].self, from: data) {
            models = cached
        }
    }

    func model(_ id: String) -> CatalogModel? { models.first { $0.id == id } }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var request = URLRequest(url: Self.url)
            request.setValue("Agott/1.0 (macOS; Foundation Models)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            let parsed = try Self.parse(data)
            models = parsed
            error = nil
            if let encoded = try? JSONEncoder().encode(parsed) {
                UserDefaults.standard.set(encoded, forKey: "modelCatalog")
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    nonisolated static func parse(_ data: Data) throws -> [CatalogModel] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { item -> CatalogModel? in
            guard let id = item["id"] as? String else { return nil }
            let api = item["api"] as? [String: Any] ?? [:]
            // Prefer Chat Completions, then Responses, then Messages.
            let format = ["chat-completions", "responses", "messages"].first { api[$0] != nil }
            let chat = format.flatMap { api[$0] as? [String: Any] }
            let caps = item["capabilities"] as? [String: Any] ?? [:]
            let limit = item["limit"] as? [String: Any] ?? [:]
            let inputs = (item["modalities"] as? [String: Any])?["input"] as? [String] ?? []
            let text = ((item["cost"] as? [String: Any])?["text"] as? [String: Any]) ?? [:]
            func price(_ key: String) -> Double? { (text[key] as? [String: Any])?["price"] as? Double }
            return CatalogModel(
                id: id,
                name: item["name"] as? String ?? id,
                summary: item["description"] as? String ?? "",
                family: item["family"] as? String ?? "",
                context: limit["context"] as? Int ?? 128_000,
                output: limit["output"] as? Int ?? 8_192,
                chatBaseURL: chat?["base_url"] as? String,
                api: format,
                vision: inputs.contains { $0.hasPrefix("image") },
                reasoning: ((caps["reasoning"] as? [String: Any])?["supported"] as? Bool) ?? false,
                efforts: (caps["reasoning"] as? [String: Any])?["effort"] as? [String],
                tools: ((caps["tools"] as? [String: Any])?["supported"] as? Bool) ?? false,
                priceIn: price("input"), priceOut: price("output"),
                released: item["release_date"] as? String)
        }
        .sorted { ($0.isSupported ? 0 : 1, $0.name) < ($1.isSupported ? 0 : 1, $1.name) }
    }
}
