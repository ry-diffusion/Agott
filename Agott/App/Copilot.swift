import Foundation
import OSLog
import Observation

/// The "Muse" half of Agott: a face that appears over whatever you are doing.
///
/// Hold the ask key and speak: Agott looks at your screen, listens, and
/// answers in a floating panel. Tap it instead and the panel opens for typing.
/// Hold the dictate key and your words are cleaned up and typed where your
/// cursor is, Shirusu style.
@Observable
final class Copilot {
    static let shared = Copilot()

    enum Mode: Equatable {
        case hidden
        case listening(ask: Bool)
        case typing
        case answering
        case inserting
    }

    private(set) var mode: Mode = .hidden
    var draft = ""
    /// The id of the first turn of this overlay session, so the panel shows
    /// only what was asked from it.
    private(set) var sinceTurn: UUID?
    /// When the question was asked from the overlay. The turns of a run are
    /// added a moment after `send` returns, so the overlay shows everything
    /// from this time on rather than looking for a turn that is not there yet.
    private(set) var askedAt: Date?
    private(set) var notice: String?

    #if os(macOS)
    let keys = HoldKeyMonitor()
    /// The press that started the current dictation; a press while the last
    /// one is still being read or typed is ignored, and so is its release.
    @ObservationIgnored private var holding: HoldKeyMonitor.Purpose?
    @ObservationIgnored private let log = Logger(subsystem: "br.com.zesmoi.Agott", category: "dictation")
    #endif

    private init() {}

    func start() {
        #if os(macOS)
        keys.onPress = { [weak self] purpose in self?.pressed(purpose) }
        keys.onRelease = { [weak self] purpose, duration in self?.released(purpose, after: duration) }
        keys.onCancel = { [weak self] _ in self?.abandon() }
        keys.enable()
        registerTextShortcut()
        #endif
    }

    #if os(macOS)
    /// The text shortcut from Settings opens (or closes) quick entry.
    func registerTextShortcut() {
        let shortcut = TextShortcut(rawValue: AppSettings.shared.textShortcut) ?? .optionSpace
        GlobalHotKey.shared.register(shortcut) {
            if QuickEntryController.shared.isShown { QuickEntryController.shared.hide() } else { Copilot.shared.beginTyping() }
        }
    }
    #endif

    #if os(macOS)
    private func pressed(_ purpose: HoldKeyMonitor.Purpose) {
        notice = nil
        if purpose == .ask, Agent.shared.isBusy { return }
        guard !Dictation.shared.isRunning, mode != .inserting else { return }
        holding = purpose
        VoiceSetup.shared.stop()
        // The answer will be read aloud: load the voice while you talk.
        if purpose == .ask { VoiceSetup.shared.prepare() }
        Dictation.shared.start()
        mode = .listening(ask: purpose == .ask)
        Agent.shared.setMood(.listening)
        // Dictation shows at the text cursor, where the words will go.
        if purpose == .dictate { DictationPillController.shared.show() } else { OverlayController.shared.show(focus: false) }
    }

    private func released(_ purpose: HoldKeyMonitor.Purpose, after duration: TimeInterval) {
        guard holding == purpose else { return }
        holding = nil
        Task {
            // A tap, not a hold: open for typing, and put away the
            // "Listening" overlay the press brought up.
            if duration < 0.35, purpose == .ask {
                Dictation.shared.cancel()
                mode = .hidden
                OverlayController.shared.hide(after: 0)
                beginTyping()
                return
            }
            let releasedAt = ContinuousClock.now
            let text = await Dictation.shared.stop()
            let heard = ContinuousClock.now - releasedAt
            // Lengths only, never the words.
            log.notice("Dictation (\(Dictation.shared.engineName, privacy: .public)) stopped after \(duration, format: .fixed(precision: 1))s, transcribed in \(heard.description, privacy: .public): \(text.count) characters, problem: \(Dictation.shared.problem ?? "none", privacy: .public)")
            guard !text.isEmpty else {
                notice = Dictation.shared.problem ?? String(localized: "I didn't catch that.")
                Agent.shared.setMood(.confused)
                if purpose == .dictate { DictationPillController.shared.hide(after: 1.6) } else { OverlayController.shared.hide(after: 1.6) }
                mode = .hidden
                return
            }
            switch purpose {
            case .ask:
                ask(text, spoken: true)
            case .dictate:
                mode = .inserting
                Agent.shared.setMood(.working)
                // The clean-up is a nicety, chosen in Settings: never worth
                // more than a few seconds of "Typing it for you…".
                let started = ContinuousClock.now
                let polished = await Rambler.polish(text, within: Rambler.limit)
                do {
                    try TextInsertion.insert(polished)
                    log.notice("Dictation typed \(polished.count) characters, cleaned up in \((ContinuousClock.now - started).description, privacy: .public)")
                    Agent.shared.setMood(.happy)
                } catch {
                    log.error("Dictation could not type: \(error.localizedDescription, privacy: .public)")
                    notice = error.localizedDescription
                    Agent.shared.setMood(.confused)
                }
                DictationPillController.shared.hide(after: notice == nil ? 0.3 : 1.6)
                mode = .hidden
            }
        }
    }
    #endif

    /// A tap of the ask key, the text shortcut or "Ask Agott…": quick entry
    /// over the screen, to type and to send screenshots.
    func beginTyping() {
        Agent.shared.setMood(.idle)
        #if os(macOS)
        QuickEntryController.shared.show()
        #else
        mode = .typing
        #endif
    }

    /// `spoken`: asked by voice, so the answer is read aloud when that is on.
    func ask(_ text: String, attachments: [FileAttachment] = [], newChat: Bool = false, spoken: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        draft = ""
        mode = .answering
        if newChat { Agent.shared.newConversation() }
        askedAt = Date()
        sinceTurn = nil
        // Screenshots sent along say what is on screen; otherwise Agott looks.
        Agent.shared.send(trimmed, lookAtScreen: attachments.isEmpty, attachments: attachments)
        #if os(macOS)
        OverlayController.shared.show(focus: false)
        VoiceSetup.shared.stop()
        if spoken, let askedAt { speakWhenAnswered(askedAt) }
        #endif
    }

    #if os(macOS)
    /// Reads the answer aloud once it is all in, if the overlay still shows it.
    private func speakWhenAnswered(_ asked: Date) {
        guard AppSettings.shared.speakAnswers else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            while Agent.shared.isBusy { try? await Task.sleep(for: .milliseconds(200)) }
            guard askedAt == asked, mode == .answering,
                  let answer = overlayTurns.last(where: { $0.role == .assistant }), answer.error == nil,
                  !answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            VoiceSetup.shared.speak(answer.text)
        }
    }
    #endif

    func abandon() {
        #if os(macOS)
        holding = nil
        VoiceSetup.shared.stop()
        Dictation.shared.cancel()
        #endif
        if mode != .answering { mode = .hidden }
        if case .listening = mode { mode = .hidden }
        Agent.shared.setMood(.idle)
        #if os(macOS)
        OverlayController.shared.hide(after: 0.2)
        DictationPillController.shared.hide()
        #endif
    }

    func dismiss() {
        if Agent.shared.isBusy { Agent.shared.cancel() }
        #if os(macOS)
        VoiceSetup.shared.stop()
        #endif
        mode = .hidden
        sinceTurn = nil
        askedAt = nil
        #if os(macOS)
        OverlayController.shared.hide(after: 0)
        #endif
    }

    /// Puts the overlay up with the demo conversation, for screenshots.
    func showDemoOverlay() {
        sinceTurn = Agent.shared.turns.dropFirst(2).first?.id
        mode = .answering   
        #if os(macOS)
        OverlayController.shared.show(focus: false)
        #endif
    }

    /// The turns this overlay session produced.
    var overlayTurns: [Turn] {
        if let askedAt {
            // A second earlier, for a clock that ticks between the two.
            return Agent.shared.turns.filter { $0.date >= askedAt.addingTimeInterval(-1) }
        }
        guard let sinceTurn, let index = Agent.shared.turns.firstIndex(where: { $0.id == sinceTurn }) else { return [] }
        return Array(Agent.shared.turns[index...])
    }
}
