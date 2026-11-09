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
    /// Which engine the latest run listened with, for the log.
    private(set) var engineName = "apple"

    /// What to show while nothing has been heard yet: that it listens, or
    /// that the transcription model is still loading (or downloading).
    var hint: String {
        #if os(macOS)
        if engineName == "parakeet", !ParakeetSetup.shared.isLoaded {
            return String(localized: "Loading the transcription model…")
        }
        if let notice = ParakeetSetup.shared.notice {
            return String(localized: "Listening") + " · " + notice
        }
        #endif
        return String(localized: "Listening…")
    }

    var transcript: String {
        Self.join(finalized, volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Two pieces of what was heard, as one text. The transcriber hands over
    /// sentences one at a time, and not always with a space in front:
    /// glued together, "tudo bem." and "E você?" became "tudo bem.E você?".
    nonisolated static func join(_ first: String, _ second: String) -> String {
        guard let last = first.last else { return second }
        guard let next = second.first else { return first }
        if last.isWhitespace || next.isWhitespace { return first + second }
        // "ok" + ", então" or "ok" + "." stays tight; anything else gets a space.
        if ",.;:!?…)]}".contains(next) { return first + second }
        return first + " " + second
    }

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var feed: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var results: Task<Void, Never>?
    @ObservationIgnored private var starting: Task<Void, Error>?
    /// Which run is current: a start still waiting on the microphone
    /// permission after it was cancelled must not open the microphone.
    @ObservationIgnored private var runID = 0
    /// Stop is reading the last words; a second stop gets nothing, so the
    /// same words are never typed twice.
    @ObservationIgnored private var stopping = false
    #if os(macOS)
    /// This run listens with Parakeet: audio is kept and read on release.
    @ObservationIgnored private var parakeetRun = false
    @ObservationIgnored private var capture: SpeechCapture?
    @ObservationIgnored private var preview: Task<Void, Never>?
    #endif

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
        runID += 1
        let id = runID
        finalized = ""
        volatile = ""
        problem = nil
        #if os(macOS)
        // Parakeet when chosen and on this Mac; Apple's engine otherwise, so
        // a missing model never means a silent download mid-press.
        parakeetRun = AppSettings.shared.speechEngine == SpeechEngine.parakeet.rawValue && Parakeet.isInstalled
            && !ParakeetSetup.shared.failedToLoad
        engineName = parakeetRun ? "parakeet" : "apple"
        if parakeetRun {
            starting = Task { try await beginParakeet(id) }
            return
        }
        #endif
        starting = Task { try await begin(id) }
    }

    /// Throws when this run was stopped or replaced while it waited.
    private func ensureCurrent(_ id: Int) throws {
        try Task.checkCancellation()
        guard runID == id, isRunning, !stopping else { throw CancellationError() }
    }

    #if os(macOS)
    /// Records at 16 kHz while the key is held; Parakeet loads meanwhile and
    /// reads the last seconds now and then so the pill shows words as you go.
    private func beginParakeet(_ id: Int) async throws {
        do {
            guard await AVAudioApplication.requestRecordPermission() else { throw Failure.microphoneDenied }
            try ensureCurrent(id)
            let language = Parakeet.language(for: AppSettings.shared.speechLocale)
            Task.detached(priority: .userInitiated) { try? await Parakeet.shared.prepare() }
            let capture = SpeechCapture()
            let engine = AVAudioEngine()
            try Self.tap(engine.inputNode, capture: capture) { level in
                Task { @MainActor in Dictation.shared.level = level }
            }
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.capture = capture
            preview = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(350))
                    let samples = capture.recent(seconds: 12)
                    guard samples.count >= Parakeet.minimumSamples / 3, await Parakeet.shared.isLoaded else { continue }
                    let text = try? await Parakeet.shared.transcribe(samples, language: language)
                    guard !Task.isCancelled, let text, let self else { continue }
                    self.volatile = text
                }
            }
        } catch {
            // A run that was stopped or replaced meanwhile is not this one's
            // to tear down.
            if runID == id, !(error is CancellationError), !Task.isCancelled {
                problem = error.localizedDescription
                tearDown()
            }
            throw error
        }
    }

    nonisolated private static func tap(
        _ input: AVAudioInputNode,
        capture: SpeechCapture,
        level: @escaping @Sendable (Float) -> Void
    ) throws {
        let format = input.outputFormat(forBus: 0)
        try input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            if let samples = buffer.floatChannelData?[0] {
                var sum: Float = 0
                let count = Int(buffer.frameLength)
                for index in 0..<count { sum += samples[index] * samples[index] }
                level(min(1, sqrt(sum / Float(max(count, 1))) * 8))
            }
            capture.append(buffer)
        }
    }

    /// The release pass: the whole utterance, read at once.
    private func stopParakeet() async -> String {
        let starting = starting
        if await !Self.within(.seconds(3), { _ = try? await starting?.value }) { starting?.cancel() }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        preview?.cancel()
        preview = nil
        let samples = capture?.all ?? []
        let language = Parakeet.language(for: AppSettings.shared.speechLocale)
        // Under a third of a second is a stray tap, not speech.
        if samples.count > 5_000 {
            // Bounded: a model that is still loading (or stuck) gives way to
            // the last preview instead of holding the key's words forever.
            let outcome = await Deadline.run(.seconds(20)) { () -> Result<String, Error> in
                do { return .success(try await Parakeet.shared.transcribe(samples, language: language)) } catch { return .failure(error) }
            }
            switch outcome {
            case .success(let text):
                finalized = text
            case .failure(let error):
                problem = error.localizedDescription
                finalized = volatile
            case nil:
                problem = String(localized: "The transcription model took too long.")
                finalized = volatile
            }
            volatile = ""
        }
        tearDown()
        return transcript
    }
    #endif

    private func begin(_ id: Int) async throws {
        do {
            guard await AVAudioApplication.requestRecordPermission() else { throw Failure.microphoneDenied }
            try ensureCurrent(id)
            let requested = AppSettings.shared.speechLocaleForApple
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
                throw Failure.unsupportedLanguage
            }
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await install.downloadAndInstall()
            }
            try ensureCurrent(id)

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
                            self.finalized = Self.join(self.finalized, text)
                            self.volatile = ""
                        } else {
                            self.volatile = text
                        }
                    }
                } catch {}
            }

            try ensureCurrent(id)
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
            // A run that could not start (no microphone, no language, the
            // model download failed) ends here instead of staying on
            // "Listening…" until someone presses the button again.
            if runID == id, !(error is CancellationError), !Task.isCancelled {
                problem = error.localizedDescription
                tearDown()
            }
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

    /// Stops listening and returns everything heard. Never hangs: each wait
    /// (still starting, the last words being finalised) has a limit, and
    /// after it the run is torn down with whatever was heard.
    @discardableResult
    func stop() async -> String {
        guard isRunning else { return transcript }
        guard !stopping else { return "" }
        stopping = true
        #if os(macOS)
        if parakeetRun { return await stopParakeet() }
        #endif
        let starting = starting
        if await !Self.within(.seconds(3), { _ = try? await starting?.value }) { starting?.cancel() }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        feed?.finish()
        feed = nil
        let analyzer = analyzer
        let results = results
        _ = await Self.within(.seconds(2)) { try? await analyzer?.finalizeAndFinishThroughEndOfInput() }
        _ = await Self.within(.seconds(1.5)) { await results?.value }
        tearDown()
        return transcript
    }

    /// Abandons a run without waiting for the last words.
    func cancel() {
        starting?.cancel()
        tearDown()
    }

    /// Everything off and back to rest.
    private func tearDown() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        feed?.finish()
        feed = nil
        results?.cancel()
        results = nil
        analyzer = nil
        starting = nil
        stopping = false
        #if os(macOS)
        preview?.cancel()
        preview = nil
        capture = nil
        parakeetRun = false
        #endif
        isRunning = false
        level = 0
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Runs `work`, giving up after `limit`. True when it finished in time.
    private static func within(_ limit: Duration, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        await Deadline.run(limit) { await work(); return true } ?? false
    }
}

/// Waits for some work at most `limit`, then goes on without it (the work is
/// cancelled and its result dropped). A task group cannot do this: it waits
/// for every child, so work that ignores cancellation — a model still
/// loading — held the "timeout" for as long as it took.
nonisolated enum Deadline {
    static func run<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
        let gate = Gate<T>()
        return await withCheckedContinuation { continuation in
            gate.hold(continuation)
            let timer = Task {
                try? await Task.sleep(for: limit)
                gate.resume(nil)
            }
            let worker = Task {
                let value = await work()
                timer.cancel()
                gate.resume(value)
            }
            gate.onTimeout = { worker.cancel() }
        }
    }

    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        var onTimeout: (@Sendable () -> Void)? {
            get { lock.withLock { timeout } }
            set { lock.withLock { timeout = newValue } }
        }
        private var timeout: (@Sendable () -> Void)?

        func hold(_ continuation: CheckedContinuation<T?, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        /// The first value wins; a nil (time is up) also cancels the work.
        func resume(_ value: T?) {
            let (waiting, cancel) = lock.withLock { () -> (CheckedContinuation<T?, Never>?, (@Sendable () -> Void)?) in
                defer { continuation = nil }
                return (continuation, value == nil ? timeout : nil)
            }
            guard let waiting else { return }
            waiting.resume(returning: value)
            cancel?()
        }
    }
}
