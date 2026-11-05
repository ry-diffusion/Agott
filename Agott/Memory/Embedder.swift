import Accelerate
import Foundation
import NaturalLanguage

/// Turns text into vectors, on the device.
///
/// `NLContextualEmbedding` for Latin script is one multilingual model, so
/// Portuguese and English land in the same space: a question asked in English
/// finds the moment it happened in Portuguese. It is a token model rather than
/// a sentence model, so a chunk is the mean of its tokens, normalised. That is
/// weaker than a trained sentence encoder, which is why search never relies on
/// it alone: keywords and the graph vote too.
actor Embedder {
    static let shared = Embedder()

    private var model: NLContextualEmbedding?
    private(set) var isReady = false

    var dimension: Int { model.map { Int($0.dimension) } ?? 0 }

    /// Loads the model, downloading its assets the first time.
    func prepare() async throws {
        guard !isReady else { return }
        guard let model = NLContextualEmbedding(language: .portuguese) ?? NLContextualEmbedding(script: .latin) else {
            throw EmbedderError.unavailable
        }
        if !model.hasAvailableAssets {
            let result = try await model.requestAssets()
            guard result == .available else { throw EmbedderError.assetsUnavailable }
        }
        try model.load()
        self.model = model
        isReady = true
    }

    /// One unit-length vector per text, or nil where the text produced none.
    func embed(_ text: String) throws -> [Float]? {
        guard let model else { throw EmbedderError.unavailable }
        // The model has a maximum sequence length; the opening of a moment
        // carries what it is about, so the tail is what gets dropped.
        let clipped = String(text.prefix(1800))
        let result = try model.embeddingResult(for: clipped, language: nil)
        let dimension = Int(model.dimension)
        var sum = [Double](repeating: 0, count: dimension)
        var count = 0
        result.enumerateTokenVectors(in: clipped.startIndex..<clipped.endIndex) { vector, _ in
            if vector.count == dimension {
                vDSP.add(sum, vector, result: &sum)
                count += 1
            }
            return true
        }
        guard count > 0 else { return nil }
        var mean = sum.map { Float($0 / Double(count)) }
        Self.normalize(&mean)
        return mean
    }

    static func normalize(_ vector: inout [Float]) {
        let norm = sqrt(vDSP.sumOfSquares(vector))
        guard norm > 0 else { return }
        vDSP.divide(vector, norm, result: &vector)
    }

    enum EmbedderError: LocalizedError {
        case unavailable, assetsUnavailable

        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "The on-device embedding model is not available on this Mac.")
            case .assetsUnavailable: String(localized: "The embedding model could not be downloaded.")
            }
        }
    }
}

extension VectorIndex {
    /// Cosine similarity against every row (rows are unit length), best first.
    nonisolated func nearest(to query: [Float], limit: Int) -> [(Int64, Float)] {
        guard query.count == dimension, !ids.isEmpty else { return [] }
        var scores = [Float](repeating: 0, count: ids.count)
        matrix.withUnsafeBufferPointer { m in
            query.withUnsafeBufferPointer { q in
                scores.withUnsafeMutableBufferPointer { out in
                    vDSP_mmul(m.baseAddress!, 1, q.baseAddress!, 1, out.baseAddress!, 1,
                              vDSP_Length(ids.count), 1, vDSP_Length(dimension))
                }
            }
        }
        let order = scores.indices.sorted { scores[$0] > scores[$1] }.prefix(limit)
        return order.map { (ids[$0], scores[$0]) }
    }
}
