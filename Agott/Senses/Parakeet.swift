#if os(macOS)
import AVFoundation
import FluidAudio
import Foundation
import OSLog

/// Which speech-to-text engine Agott listens with on the Mac.
nonisolated enum SpeechEngine: String, CaseIterable, Identifiable, Sendable {
    /// Parakeet TDT v3 through FluidAudio, the model Shirusu uses: much
    /// faster than Apple's, and better at Portuguese with English mixed in.
    case parakeet
    /// Apple's SpeechAnalyzer: nothing to download, also on the iPhone.
    case apple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parakeet: "Parakeet"
        case .apple: String(localized: "Apple")
        }
    }
}

/// Parakeet, loaded once and shared by dictation and the voice-note reader.
///
/// The weights live where FluidAudio keeps them
/// (`~/Library/Application Support/FluidAudio/Models`), so a Mac that has
/// Shirusu already has them. They are let go after a while unused and loaded
/// again on the next press.
actor Parakeet {
    static let shared = Parakeet()

    nonisolated static let version: AsrModelVersion = .v3
    nonisolated static var directory: URL { AsrModels.defaultCacheDirectory(for: version) }
    nonisolated static var isInstalled: Bool { AsrModels.modelsExist(at: directory, version: version) }

    /// The decoder rejects anything shorter than a second.
    nonisolated static let minimumSamples = 16_000
    /// How long the weights stay in memory after the last use. Loading them
    /// again costs CoreML ~20 s of compiling for the Neural Engine, which a
    /// press of the dictation key must never wait for, so this is long.
    private static let idle: Duration = .seconds(2 * 60 * 60)

    private let log = Logger(subsystem: "br.com.zesmoi.Agott", category: "parakeet")
    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?
    private var isWarm = false
    private var busy = 0
    private var sweep: Task<Void, Never>?

    var isLoaded: Bool { manager != nil }

    /// The language hint for the decoder, from the speech language setting.
    nonisolated static func language(for locale: String) -> Language? {
        Language(rawValue: String(locale.prefix(2)).lowercased())
    }

    /// Loads the weights (downloading them first if they are missing) and runs
    /// one throwaway pass, so the first real one does not pay for CoreML
    /// specialising the graph for the Neural Engine.
    func prepare() async throws {
        _ = try await load()
        guard !isWarm else { return }
        isWarm = true
        var noise = [Float](repeating: 0, count: Self.minimumSamples)
        for index in noise.indices { noise[index] = Float.random(in: -0.001...0.001) }
        _ = try? await transcribe(noise, language: nil)
    }

    private func load() async throws -> AsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        let task = Task { () throws -> AsrManager in
            let models = Self.isInstalled
                ? try await AsrModels.load(from: Self.directory, version: Self.version)
                : try await AsrModels.downloadAndLoad(version: Self.version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loading = task
        defer { loading = nil }
        let manager = try await task.value
        self.manager = manager
        log.info("Parakeet loaded")
        scheduleUnload()
        return manager
    }

    /// Text for 16 kHz mono samples.
    func transcribe(_ samples: [Float], language: Language?) async throws -> String {
        guard !samples.isEmpty else { return "" }
        let manager = try await load()
        busy += 1
        defer {
            busy -= 1
            scheduleUnload()
        }
        // A short "ok" is still words: pad it up to what the decoder takes.
        var input = samples
        if input.count < Self.minimumSamples {
            input += [Float](repeating: 0, count: Self.minimumSamples - input.count)
        }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(input, decoderState: &state, language: language)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Text for an audio file (a WhatsApp voice note, Ogg Opus included).
    func transcribe(file url: URL, language: Language?) async throws -> String {
        let samples = try AudioConverter().resampleAudioFile(url)
        return try await transcribe(samples, language: language)
    }

    private func scheduleUnload() {
        sweep?.cancel()
        sweep = Task {
            try? await Task.sleep(for: Self.idle)
            guard !Task.isCancelled else { return }
            await unloadIfIdle()
        }
    }

    private func unloadIfIdle() async {
        guard busy == 0, let manager else { return }
        self.manager = nil
        isWarm = false
        await manager.cleanup()
        log.info("Parakeet released after being idle")
    }
}

/// Fetches Parakeet once, in the background, and says how far along it is.
/// Until it is here, dictation uses Apple's engine and voice notes wait.
@MainActor @Observable
final class ParakeetSetup {
    static let shared = ParakeetSetup()

    enum State: Equatable {
        case missing
        case downloading(Double)
        case ready
        case failed(String)
    }

    private(set) var state: State = Parakeet.isInstalled ? .ready : .missing
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var attempts = 0

    var isReady: Bool { state == .ready }
    var isDownloading: Bool { if case .downloading = state { true } else { false } }

    /// "Downloading the fast transcription model… 42%", while it does.
    var notice: String? {
        guard case .downloading(let fraction) = state else { return nil }
        return String(localized: "Downloading the fast transcription model… \(Int((fraction * 100).rounded()))%")
    }

    /// Starts the download if Parakeet is the engine and is not here yet.
    func start() {
        guard AppSettings.shared.speechEngine == SpeechEngine.parakeet.rawValue else { return }
        if Parakeet.isInstalled {
            state = .ready
            // Loaded and warmed now, so the first press is as fast as any.
            Task.detached(priority: .utility) { try? await Parakeet.shared.prepare() }
            return
        }
        guard task == nil else { return }
        attempts += 1
        // A second try starts clean: a broken first one left half a folder.
        let force = attempts > 1
        state = .downloading(0)
        task = Task {
            do {
                _ = try await AsrModels.download(force: force, version: Parakeet.version) { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        if case .downloading = ParakeetSetup.shared.state {
                            ParakeetSetup.shared.state = .downloading(fraction)
                        }
                    }
                }
                state = Parakeet.isInstalled ? .ready : .failed(String(localized: "The download finished incomplete."))
            } catch {
                state = .failed(error.localizedDescription)
            }
            task = nil
            // Voice notes waited for it; dictation should not wait for the load.
            if state == .ready {
                Indexer.shared.run()
                Task.detached(priority: .utility) { try? await Parakeet.shared.prepare() }
            }
        }
    }
}

/// The microphone at 16 kHz, kept whole while the key is held. Written from
/// the audio thread, read from anywhere.
nonisolated final class SpeechCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let converter = AudioConverter()
    private var samples: [Float] = []

    /// On the audio thread, in order.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = try? converter.resampleBuffer(buffer), !converted.isEmpty else { return }
        lock.lock()
        samples.append(contentsOf: converted)
        lock.unlock()
    }

    var all: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    /// The last `seconds`, for a preview that does not slow down as you talk.
    func recent(seconds: Double) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let wanted = Int(seconds * 16_000)
        return samples.count > wanted ? Array(samples.suffix(wanted)) : samples
    }
}
#endif
