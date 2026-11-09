#if os(macOS)
import AppKit
import SwiftUI

/// A floating panel that can take typing without taking focus from the app
/// you were in, the way Spotlight does. That matters: when Agott inserts a
/// reply, it has to land in WhatsApp, not in Agott.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController {
    static let shared = OverlayController()

    private var panel: OverlayPanel?
    private var hideTask: Task<Void, Never>?

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 664, height: 420),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: OverlayView())
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host
        return panel
    }

    func show(focus: Bool) {
        hideTask?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let screen, !panel.isVisible {
            let frame = screen.visibleFrame
            let width: CGFloat = 664
            // The card sits 32 pt inside the panel; keep it 12 pt under the menu bar.
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - width / 2, y: frame.maxY + 20))
        }
        panel.alphaValue = 1
        if focus {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func hide(after delay: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let panel else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { panel.alphaValue = 1; return }
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }
}

struct OverlayView: View {
    @State private var agent = Agent.shared
    @State private var copilot = Copilot.shared
    @State private var dictation = Dictation.shared
    @State private var voice = VoiceSetup.shared
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ThinkingOrb(mode: orbMode, size: 22, active: isListening || agent.isBusy)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 10) {
                header
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(width: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Ink.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 18, y: 6)
        .tint(Ink.spot)
        // Room for the whole shadow inside the panel: with less, it was cut
        // into a visible rectangle around the card.
        .padding(32)
        .onExitCommand { copilot.dismiss() }
        .onChange(of: copilot.mode) { _, mode in
            fieldFocused = mode == .typing
        }
    }

    private var orbMode: ThinkingOrb.Mode {
        if isListening { return .wave }
        if agent.isBusy || copilot.mode == .inserting { return .orbits }
        return .ring
    }

    private var isListening: Bool {
        if case .listening = copilot.mode { return true }
        return false
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            switch copilot.mode {
            case .listening(let ask):
                Text(ask ? "Listening…" : "Dictating…").font(.headline)
            case .inserting:
                Text("Typing it for you…").font(.headline)
            case .typing:
                Text("Ask Agott").font(.headline)
            default:
                if let status = agent.status {
                    Text(EntityText.readable(status)).font(.system(size: 15)).foregroundStyle(Ink.muted).lineLimit(1)
                } else {
                    Text(verbatim: "Agott").font(.headline)
                }
            }
            Spacer()
            if voice.isSpeaking {
                Button { voice.stop() } label: {
                    Image(systemName: "speaker.wave.2.fill").symbolEffect(.variableColor.iterative, isActive: true)
                        .foregroundStyle(Ink.muted)
                }
                .buttonStyle(.plain)
                .help(Text("Stop reading aloud"))
            }
            if let app = copilot.overlayTurns.first?.screenApp {
                Chip(text: app, symbol: "eye")
                    .help(Text("Agott looked at this app"))
            }
            Button {
                copilot.dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Ink.muted)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch copilot.mode {
        case .listening:
            Text(dictation.transcript.isEmpty ? String(localized: "Say what you need. Let go when you're done.") : dictation.transcript)
                .font(.system(size: 16))
                .foregroundStyle(dictation.transcript.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(Motion.arrive, value: dictation.transcript)
        case .typing:
            TextField("Ask about this screen, your chats, your day…", text: $copilot.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .lineLimit(1...5)
                .focused($fieldFocused)
                .onSubmit { copilot.ask(copilot.draft) }
        case .answering, .inserting, .hidden:
            if let notice = copilot.notice {
                Text(notice).font(.system(size: 15)).foregroundStyle(Ink.muted)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Only the answers: you know what you asked, and the
                    // header line already says what it is doing.
                    ForEach(copilot.overlayTurns) { turn in
                        if turn.role != .user {
                            // Reading size, not caption size: this is the answer.
                            AssistantTurnView(turn: turn, compact: true)
                                .font(.system(size: 16))
                                .lineSpacing(3)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)

            if !agent.isBusy, copilot.mode == .answering {
                HStack {
                    TextField("Follow up…", text: $copilot.draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .onSubmit { copilot.ask(copilot.draft) }
                    Text("esc to close").font(.caption).foregroundStyle(Ink.muted)
                }
                .padding(.top, 4)
            }
        }
    }
}
#endif
