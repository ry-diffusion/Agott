import AVFoundation
import Foundation
import Observation
import Speech

/// Speech to text, on the device, with Apple's SpeechAnalyzer.
///
/// Shirusu uses Parakeet through FluidAudio; Agott uses the system transcriber
/// instead so it has no model to download and manage, and so the same code
/// runs on the iPhone. It speaks Portuguese and English; you pick which in
/// Settings, because a transcriber that guesses the language guesses wrong on
/// exactly the short phrases you hold a key for.
@Observable
final class Dictation {
    static let shared = Dictation()

    private(set) var isRunning = false
    private(set) var finalized = ""
    private(set) var volatile = ""
    private(set) var level: Float = 0
    private(set) var problem: String?

    var transcript: String {
        (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var feed: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var results: Task<Void, Never>?
    @ObservationIgnored private var starting: Task<Void, Error>?

    private init() {}

    enum Failure: LocalizedError {
        case microphoneDenied, unsupportedLanguage

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: String(localized: "Agott needs the microphone to hear you.")
            case .unsupportedLanguage: String(localized: "Speech recognition is not available for this language.")
            }
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        finalized = ""
        volatile = ""
        problem = nil
        starting = Task { try await begin() }
    }

    private func begin() async throws {
        do {
            guard await AVAudioApplication.requestRecordPermission() else { throw Failure.microphoneDenied }
            let requested = Locale(identifier: AppSettings.shared.speechLocale)
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
                throw Failure.unsupportedLanguage
            }
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await install.downloadAndInstall()
            }
            try Task.checkCancellation()

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let converter = try await AnalyzerInputConverter.converter(compatibleWith: [transcriber])
            let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: stream)
            self.analyzer = analyzer
            self.feed = feed

            results = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        guard let self else { return }
                        if result.isFinal {
                            self.finalized += text
                            self.volatile = ""
                        } else {
                            self.volatile = text
                        }
                    }
                } catch {}
            }

            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let engine = AVAudioEngine()
            let input = engine.inputNode
            try Self.tap(input, converter: converter, feed: feed) { level in
                Task { @MainActor in Dictation.shared.level = level }
            }
            engine.prepare()
            try engine.start()
            self.engine = engine
        } catch {
            problem = error.localizedDescription
            throw error
        }
    }

    /// Installed from a nonisolated context: the tap block runs on the audio
    /// thread and must not inherit the main actor.
    nonisolated private static func tap(
        _ input: AVAudioInputNode,
        converter: AnalyzerInputConverter,
        feed: AsyncStream<AnalyzerInput>.Continuation,
        level: @escaping @Sendable (Float) -> Void
    ) throws {
        nonisolated(unsafe) let converter = converter
        let format = input.outputFormat(forBus: 0)
        try input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, time in
            if let samples = buffer.floatChannelData?[0] {
                var sum: Float = 0
                let count = Int(buffer.frameLength)
                for index in 0..<count { sum += samples[index] * samples[index] }
                level(min(1, sqrt(sum / Float(max(count, 1))) * 8))
            }
            if let inputs = try? converter.convert(buffer, at: time) {
                for item in inputs { feed.yield(item) }
            }
        }
    }

    /// Stops listening and returns everything heard.
    @discardableResult
    func stop() async -> String {
        guard isRunning else { return transcript }
        _ = try? await starting?.value
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        feed?.finish()
        feed = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
        analyzer = nil
        results = nil
        isRunning = false
        level = 0
        return transcript
    }

    /// Abandons a run without waiting for the last words.
    func cancel() {
        starting?.cancel()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        feed?.finish()
        feed = nil
        results?.cancel()
        analyzer = nil
        isRunning = false
        level = 0
    }
}
