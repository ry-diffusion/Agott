#if os(macOS)
import AVFoundation
import CoreML
import FluidAudio
import Foundation
import NaturalLanguage
import OSLog

/// Agott's voice: answers read aloud on this Mac with Supertonic-3, a
/// multilingual model (Portuguese and English among 31 languages) that runs
/// on the Neural Engine through FluidAudio, like Parakeet. Nothing is sent
/// anywhere to be spoken.
///
/// A reply is spoken sentence by sentence: the first one plays while the
/// next is being made, so the voice starts in about the time one sentence
/// takes, not the whole answer.
actor Voice {
    static let shared = Voice()

    nonisolated static let voiceStyle = Supertonic3Voice.f1
    nonisolated static let estimator = Supertonic3VectorEstimator.default
    /// The ANE int4 build: the variant token FluidAudio downloads by.
    nonisolated static let variant = "ane-int4"
    nonisolated static let root = URL.applicationSupportDirectory.appending(path: "FluidAudio/Models", directoryHint: .isDirectory)
    nonisolated static var folder: URL { root.appending(path: "supertonic-3-coreml", directoryHint: .isDirectory) }

    /// Every model file and the voice are on disk.
    nonisolated static var isInstalled: Bool {
        let files = ModelNames.Supertonic3.requiredFiles(veVariant: variant).union([voiceStyle.fileName])
        return files.allSatisfy { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }
    }

    private let log = Logger(subsystem: "br.com.zesmoi.Agott", category: "voice")
    private var manager: Supertonic3Manager?
    private var style: Supertonic3VoiceStyle?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    /// Bumped by every speak and stop: an older reading stops at its next sentence.
    private var generation = 0

    /// Downloads what is missing (the models, then the voice).
    nonisolated static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await Supertonic3ResourceDownloader.ensureModels(directory: root, veVariant: variant) { update in
            progress(update.fractionCompleted * 0.98)
        }
        try await Supertonic3ResourceDownloader.downloadVoiceStyle(voiceStyle, directory: root)
        progress(1)
    }

    private func load() async throws -> (Supertonic3Manager, Supertonic3VoiceStyle) {
        if let manager, let style { return (manager, style) }
        let manager = Supertonic3Manager(directory: Self.root, computeUnits: .cpuAndNeuralEngine, vectorEstimator: Self.estimator)
        try await manager.initialize()
        let style = try Supertonic3VoiceStyle.load(from: Self.folder.appending(path: Self.voiceStyle.fileName))
        self.manager = manager
        self.style = style
        log.info("Supertonic-3 loaded")
        return (manager, style)
    }

    /// Loads the model ahead of the first answer.
    func prepare() async {
        guard Self.isInstalled else { return }
        do { _ = try await load() } catch { log.error("Voice could not load: \(error.localizedDescription, privacy: .public)") }
    }

    /// Reads `text` aloud, replacing anything being read. Returns when it has
    /// been spoken, or stopped.
    func speak(_ text: String, language: String) async {
        generation += 1
        let mine = generation
        stopPlayback()
        guard Self.isInstalled else { return }
        let sentences = Self.sentences(text)
        guard !sentences.isEmpty else { return }
        do {
            let (manager, style) = try await load()
            guard mine == generation else { return }
            let started = ContinuousClock.now
            for (index, sentence) in sentences.enumerated() {
                let (samples, _) = try await manager.synthesize(text: sentence, language: language, style: style)
                guard mine == generation else { return }
                if index == 0 {
                    log.notice("Voice: first sentence ready in \((ContinuousClock.now - started).description, privacy: .public)")
                }
                try schedule(samples) { [weak self] in Task { await self?.played() } }
            }
            // Wait for the last buffer to finish, unless something else took over.
            while mine == generation, isPlaying { try? await Task.sleep(for: .milliseconds(150)) }
        } catch {
            log.error("Voice failed: \(error.localizedDescription, privacy: .public)")
        }
        if mine == generation { stopPlayback() }
    }

    /// Seconds of audio a text makes, without playing it (for tests).
    func render(_ text: String, language: String) async throws -> Double {
        let (manager, style) = try await load()
        let (samples, _) = try await manager.synthesize(text: text, language: language, style: style)
        return Double(samples.count) / Double(Supertonic3Constants.sampleRate)
    }

    /// Stops reading at once.
    func stop() {
        generation += 1
        stopPlayback()
    }

    private var queued = 0
    private var isPlaying: Bool { queued > 0 }

    private func played() { queued = max(0, queued - 1) }

    private func schedule(_ samples: [Float], done: @escaping @Sendable () -> Void) throws {
        let rate = Double(Supertonic3Constants.sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        if engine == nil {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            player.play()
            self.engine = engine
            self.player = player
        }
        queued += 1
        player?.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in done() }
    }

    private func stopPlayback() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        queued = 0
    }

    /// Sentences short enough to come out quickly, long enough to sound whole.
    nonisolated static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard sentence.contains(where: \.isLetter) || sentence.contains(where: \.isNumber) else { return true }
            // Very short ones ride with the next, so "Ok." is not a sentence alone.
            if let last = result.last, last.count < 24 {
                result[result.count - 1] = last + " " + sentence
            } else {
                result.append(sentence)
            }
            return true
        }
        return result
    }

    /// The Supertonic code for the language a text is in: the speech
    /// language from Settings when set, else what the text looks like.
    nonisolated static func language(for text: String, preferred: String) -> String {
        let supported = Set(Supertonic3Constants.availableLanguages)
        let chosen = String(preferred.prefix(2)).lowercased()
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let detected = recognizer.dominantLanguage.map { String($0.rawValue.prefix(2)) }
        // The text itself wins when it is clearly another language (an
        // English answer while you speak Portuguese).
        if let detected, supported.contains(detected),
           let confidence = recognizer.languageHypotheses(withMaximum: 1)[NLLanguage(rawValue: detected)], confidence > 0.8 {
            return detected
        }
        if preferred != "auto", supported.contains(chosen) { return chosen }
        if let detected, supported.contains(detected) { return detected }
        return "en"
    }
}

/// The voice's download, for Settings and the overlay.
@MainActor @Observable
final class VoiceSetup {
    static let shared = VoiceSetup()

    enum State: Equatable {
        case missing
        case downloading(Double)
        case ready
        case failed(String)
    }

    private(set) var state: State = Voice.isInstalled ? .ready : .missing
    /// Agott is reading an answer aloud.
    var isSpeaking = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var speaking: Task<Void, Never>?

    /// Downloads the voice when speaking is on and it is not here yet.
    func start() {
        guard AppSettings.shared.speakAnswers else { return }
        // Loaded on the first press of the ask key, not at launch: it is
        // memory a Mac that never asks aloud should not spend.
        if Voice.isInstalled {
            state = .ready
            return
        }
        guard task == nil else { return }
        state = .downloading(0)
        task = Task {
            do {
                try await Voice.download { fraction in
                    Task { @MainActor in
                        if case .downloading = VoiceSetup.shared.state { VoiceSetup.shared.state = .downloading(fraction) }
                    }
                }
                state = Voice.isInstalled ? .ready : .failed(String(localized: "The download finished incomplete."))
            } catch {
                state = .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    /// Reads an answer aloud: Markdown, tags and links become plain words.
    func speak(_ answer: String) {
        guard AppSettings.shared.speakAnswers, state == .ready else { return }
        let text = Self.spoken(answer)
        let language = Voice.language(for: text, preferred: AppSettings.shared.speechLocale)
        speaking?.cancel()
        isSpeaking = true
        speaking = Task {
            await Voice.shared.speak(text, language: language)
            isSpeaking = false
        }
    }

    /// An answer as words to say: names for tags, no links, no Markdown,
    /// and each line a sentence of its own (a list item without a full stop
    /// would otherwise run into the next).
    static func spoken(_ answer: String) -> String {
        EntityText.plain(answer, hidden: AppSettings.shared.hideNames)
            .replacing(/https?:\/\/\S+/, with: "")
            .components(separatedBy: .newlines)
            .map { $0.markdownStripped.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) && !$0.allSatisfy { "|-: ".contains($0) } }
            .map { line in ".!?:;…".contains(line.last ?? ".") ? line : line + "." }
            .joined(separator: " ")
    }

    /// Loads the voice ahead of an answer, if it will be spoken.
    func prepare() {
        guard AppSettings.shared.speakAnswers, state == .ready else { return }
        Task.detached(priority: .utility) { await Voice.shared.prepare() }
    }

    func stop() {
        guard isSpeaking else { return }
        isSpeaking = false
        speaking?.cancel()
        Task { await Voice.shared.stop() }
    }
}
#endif
