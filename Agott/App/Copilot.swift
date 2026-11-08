import Foundation
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
    private(set) var notice: String?

    #if os(macOS)
    let keys = HoldKeyMonitor()
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
        Dictation.shared.start()
        mode = .listening(ask: purpose == .ask)
        Agent.shared.setMood(.listening)
        OverlayController.shared.show(focus: false)
    }

    private func released(_ purpose: HoldKeyMonitor.Purpose, after duration: TimeInterval) {
        Task {
            // A tap, not a hold: open for typing.
            if duration < 0.35, purpose == .ask {
                Dictation.shared.cancel()
                beginTyping()
                return
            }
            let text = await Dictation.shared.stop()
            guard !text.isEmpty else {
                notice = Dictation.shared.problem ?? String(localized: "I didn't catch that.")
                Agent.shared.setMood(.confused)
                OverlayController.shared.hide(after: 1.6)
                mode = .hidden
                return
            }
            switch purpose {
            case .ask:
                ask(text)
            case .dictate:
                mode = .inserting
                Agent.shared.setMood(.working)
                let polished = await Rambler.polish(text)
                do {
                    try TextInsertion.insert(polished)
                    Agent.shared.setMood(.happy)
                } catch {
                    notice = error.localizedDescription
                    Agent.shared.setMood(.confused)
                }
                OverlayController.shared.hide(after: 0.9)
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

    func ask(_ text: String, attachments: [FileAttachment] = [], newChat: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        draft = ""
        mode = .answering
        if newChat { Agent.shared.newConversation() }
        let before = Agent.shared.turns.count
        // Screenshots sent along say what is on screen; otherwise Agott looks.
        Agent.shared.send(trimmed, lookAtScreen: attachments.isEmpty, attachments: attachments)
        if Agent.shared.turns.count > before { sinceTurn = Agent.shared.turns[before].id }
        #if os(macOS)
        OverlayController.shared.show(focus: false)
        #endif
    }

    func abandon() {
        #if os(macOS)
        Dictation.shared.cancel()
        #endif
        if mode != .answering { mode = .hidden }
        if case .listening = mode { mode = .hidden }
        Agent.shared.setMood(.idle)
        #if os(macOS)
        OverlayController.shared.hide(after: 0.2)
        #endif
    }

    func dismiss() {
        if Agent.shared.isBusy { Agent.shared.cancel() }
        mode = .hidden
        sinceTurn = nil
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
        guard let sinceTurn, let index = Agent.shared.turns.firstIndex(where: { $0.id == sinceTurn }) else { return [] }
        return Array(Agent.shared.turns[index...])
    }
}
