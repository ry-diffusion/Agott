#if os(macOS)
import AppKit
import SwiftUI

/// Agott at work while you are elsewhere: a black island that grows out of
/// the notch (or a pill under the menu bar on a screen without one), the way
/// the iPhone's Dynamic Island does. Closed it shows the orb and how long so
/// far; it opens for a moment when the step changes, and under the pointer
/// it shows the step, any progress, and Stop / Open Agott.
///
/// It appears only while Agott is working and nothing of Agott's is in
/// front: not its window, not the ask pop-up, not quick entry.
@MainActor
final class ActivityIsland {
    static let shared = ActivityIsland()

    @Observable
    final class Model {
        /// Under the pointer, or opened for a moment by a new step.
        var hovering = false
        var peeking = false
        var expanded: Bool { hovering || peeking }
        /// The notch's size on this screen; nil on a screen without one.
        var notch: CGSize?
        var started = Date()
    }

    let model = Model()
    private var panel: NSPanel?
    private var started = false
    private var ticker: Task<Void, Never>?
    private var peekTask: Task<Void, Never>?
    private var lastStage: String?

    /// The space at each side of the notch.
    static let wing: CGFloat = 76
    static let openWidth: CGFloat = 400
    static let openExtra: CGFloat = 90

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification,
                     NSApplication.didChangeScreenParametersNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in ActivityIsland.shared.update() }
            }
        }
        watch()
    }

    /// Follows the agent's work through Observation; a short tick covers
    /// what is not observable (which window is in front).
    private func watch() {
        withObservationTracking {
            _ = Self.working
            _ = Self.stage
        } onChange: {
            Task { @MainActor in
                ActivityIsland.shared.update()
                ActivityIsland.shared.watch()
            }
        }
        update()
    }

    static var working: Bool {
        Agent.shared.isBusy || !LiveWork.shared.jobs.isEmpty || Copilot.shared.mode == .inserting
    }

    /// What it is doing now, in a few words.
    static var stage: String {
        if Copilot.shared.mode == .inserting { return String(localized: "Typing it for you…") }
        if let job = LiveWork.shared.jobs.last {
            return job.stage
        }
        if let status = Agent.shared.status { return EntityText.readable(status) }
        return String(localized: "Working…")
    }

    private var wanted: Bool {
        guard Self.working else { return false }
        if OverlayController.shared.isVisible || QuickEntryController.shared.isShown { return false }
        // Using another app, Agott shows its own pill with Stop over that app.
        if ComputerUseOverlay.shared.isVisible { return false }
        // Agott's own window in front: the chat already shows the work.
        let ownWindowInFront = NSApp.isActive && NSApp.windows.contains {
            $0.isKeyWindow && $0.isVisible && !($0 is NSPanel) && !$0.isMiniaturized
        }
        return !ownWindowInFront
    }

    func update() {
        if wanted {
            if panel?.isVisible != true { show() }
            let stage = Self.stage
            if stage != lastStage {
                if lastStage != nil { peek() }
                lastStage = stage
            }
            keepTicking()
        } else {
            hide()
        }
    }

    private func keepTicking() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.update()
            }
        }
    }

    /// Opens for a moment to say what the new step is.
    private func peek() {
        peekTask?.cancel()
        model.peeking = true
        layout()
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self else { return }
            self.model.peeking = false
            self.layout()
        }
    }

    func setHovering(_ hovering: Bool) {
        guard model.hovering != hovering else { return }
        model.hovering = hovering
        layout()
    }

    private func show() {
        model.started = Date()
        lastStage = nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        layout()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
    }

    private func hide() {
        ticker?.cancel()
        ticker = nil
        peekTask?.cancel()
        model.peeking = false
        model.hovering = false
        lastStage = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }) {
            Task { @MainActor in if !ActivityIsland.working || panel.alphaValue == 0 { panel.orderOut(nil) } }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                            backing: .buffered, defer: false)
        // Over the menu bar, on every space, never in the window cycle.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        // Light ink on black, whatever the system's appearance.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = NSHostingView(rootView: IslandView(model: model))
        return panel
    }

    /// The screen with the menu bar Agott's work is about: the one under the
    /// pointer, else the main one.
    private var screen: NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    }

    /// Sizes the panel to the island, hanging from the top of the screen.
    private func layout() {
        guard let panel, let screen else { return }
        let notch = Self.notch(on: screen)
        model.notch = notch
        let size = Self.size(notch: notch, expanded: model.expanded, hasJob: !LiveWork.shared.jobs.isEmpty)
        let top = notch == nil ? screen.visibleFrame.maxY - 6 : screen.frame.maxY
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().setFrame(frame, display: true)
        }
    }

    static func size(notch: CGSize?, expanded: Bool, hasJob: Bool) -> CGSize {
        let closedHeight = notch?.height ?? 34
        let closedWidth = notch.map { $0.width + wing * 2 } ?? 300
        guard expanded else { return CGSize(width: closedWidth, height: closedHeight) }
        let height = (notch?.height ?? 0) + openExtra + (hasJob ? 26 : 0)
        return CGSize(width: max(closedWidth, openWidth), height: height)
    }

    /// The camera housing's size, from the areas left free beside it.
    static func notch(on screen: NSScreen) -> CGSize? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        let width = screen.frame.width - left.width - right.width
        guard width > 0 else { return nil }
        return CGSize(width: width, height: screen.safeAreaInsets.top)
    }
}

/// The island itself: black, flush with the top, soft at the bottom.
struct IslandView: View {
    var model: ActivityIsland.Model
    @State private var agent = Agent.shared
    @State private var work = LiveWork.shared

    var body: some View {
        VStack(spacing: 0) {
            closedRow
            if model.expanded {
                details
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            // At the notch it hangs from the top edge; under the menu bar it
            // is a floating pill.
            if model.notch != nil {
                UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
                    .fill(.black)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.black)
            }
        }
        .environment(\.colorScheme, .dark)
        .onHover { ActivityIsland.shared.setHovering($0) }
        .animation(.spring(duration: 0.32, bounce: 0.18), value: model.expanded)
    }

    private var radius: CGFloat { model.expanded ? 22 : (model.notch == nil ? 17 : 12) }

    /// Closed: the orb on one side of the notch, the time on the other. On
    /// a screen without a notch, the step sits between them.
    private var closedRow: some View {
        HStack(spacing: 10) {
            ThinkingOrb(mode: .orbits, size: 16, active: true)
                .colorScheme(.dark)
            if let notch = model.notch {
                Spacer(minLength: notch.width)
            } else {
                Text(ActivityIsland.stage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(timerInterval: model.started...Date.distantFuture, countsDown: false)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize()
        }
        .padding(.horizontal, 18)
        .frame(height: model.notch?.height ?? 34)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "Agott")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text(ActivityIsland.stage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
            }
            if let job = work.jobs.last {
                HStack(spacing: 8) {
                    Text(job.title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    if let fraction = job.fraction {
                        ProgressView(value: fraction).progressViewStyle(.linear).tint(.white)
                    } else {
                        ProgressView().progressViewStyle(.linear).tint(.white)
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button {
                    agent.cancel()
                    Copilot.shared.dismiss()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                Button {
                    NSApp.activate()
                    NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
                    Navigator.shared.section = .chat
                } label: {
                    Label("Open Agott", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(.white))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }
}
#endif
