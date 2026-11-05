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
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
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
            let width: CGFloat = 620
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - width / 2, y: frame.maxY - 12))
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
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            MuseFace(mood: agent.mood, size: 54, level: dictation.level)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 10) {
                header
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(width: 600)
        .glassEffect(agent.isBusy || isListening ? .regular.tint(Ink.spot.opacity(0.25)) : .regular, in: .rect(cornerRadius: 26))
        .tint(Ink.spot)
        .padding(10)
        .onExitCommand { copilot.dismiss() }
        .onChange(of: copilot.mode) { _, mode in
            fieldFocused = mode == .typing
        }
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
                Text(ask ? "Listening…" : "Dictating…").font(Lettering.display(16, relativeTo: .headline))
            case .inserting:
                Text("Typing it for you…").font(Lettering.display(16, relativeTo: .headline))
            case .typing:
                Text("Ask Agott").font(Lettering.display(16, relativeTo: .headline))
            default:
                if let status = agent.status {
                    Text(status).font(.subheadline).foregroundStyle(Ink.muted)
                } else {
                    Text(verbatim: "Agott").font(Lettering.display(16, relativeTo: .headline))
                }
            }
            Spacer()
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
                .font(.title3)
                .foregroundStyle(dictation.transcript.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(Motion.arrive, value: dictation.transcript)
        case .typing:
            TextField("Ask about this screen, your chats, your day…", text: $copilot.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title3)
                .lineLimit(1...5)
                .focused($fieldFocused)
                .onSubmit { copilot.ask(copilot.draft) }
        case .answering, .inserting, .hidden:
            if let notice = copilot.notice {
                Text(notice).foregroundStyle(Ink.muted)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(copilot.overlayTurns) { turn in
                        if turn.role == .user {
                            Text(turn.text).font(.callout).foregroundStyle(Ink.muted)
                        } else {
                            AssistantTurnView(turn: turn, compact: true)
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
                        .onSubmit { copilot.ask(copilot.draft) }
                    Text("esc to close").font(.caption).foregroundStyle(Ink.muted)
                }
                .padding(.top, 4)
            }
        }
    }
}
#endif
