#if os(macOS)
import AppKit
import SwiftUI

/// What you see while Agott uses another app:
///
/// - a quiet purple frame around the app's window, so it is clear which app
///   Agott has its hands on;
/// - a black pill at the bottom of that window, "Agott is using Finder", the
///   step it is on, and **Stop**;
/// - Agott's own pointer, a purple arrow with its name, that glides to each
///   thing before Agott presses, types into or scrolls it, and pulses when it
///   acts. Accessibility actions do not move your mouse, so without it the
///   work would be invisible.
///
/// None of it takes focus or clicks: only Stop does. Stop cancels the reply
/// and refuses any action still on its way until you ask for something new.
@MainActor
final class ComputerUseOverlay {
    static let shared = ComputerUseOverlay()

    @Observable
    final class Model {
        var appName = ""
        var step = ""
        /// Bumped when the pointer arrives and acts, to pulse.
        var pulse = 0
        var stopped = false
    }

    enum Stopped: LocalizedError {
        case byUser
        var errorDescription: String? { String(localized: "The user pressed Stop. Do not continue; wait for them.") }
    }

    let model = Model()
    private var pill: NSPanel?
    private var frame: NSPanel?
    private var pointer: NSPanel?
    private var watching = false
    private var hideTask: Task<Void, Never>?
    private var wasBusy = false

    var isVisible: Bool { pill?.isVisible ?? false }

    static let pointerSize = CGSize(width: 96, height: 52)
    /// Where the arrow's tip sits inside the pointer panel.
    static let tip = CGPoint(x: 6, y: 6)
    static let pillSize = CGSize(width: 380, height: 54)

    // MARK: Steps

    /// Called before each action: shows the overlay over `app`, says `step`,
    /// glides the pointer to `point` (screen points, origin top-left, as
    /// Accessibility gives them) and waits for it to get there. Throws when
    /// the user has pressed Stop.
    func step(_ step: String, at point: CGPoint? = nil, in app: NSRunningApplication? = nil) async throws {
        watch()
        if model.stopped { throw Stopped.byUser }
        try Task.checkCancellation()
        let app = app ?? ScreenReader.shared.targetApp
        hideTask?.cancel()
        model.appName = app?.localizedName ?? model.appName
        model.step = step
        let window = app.flatMap { Self.windowFrame(of: $0.processIdentifier) }
        show(around: window)
        if let point {
            await glide(to: point)
            if model.stopped { throw Stopped.byUser }
            model.pulse += 1
        }
    }

    /// The step for an action on element `id`, with the pointer on it.
    func announce(_ action: ComputerControl.ElementAction, on id: Int) async throws {
        let name = Self.name(of: id)
        let step = switch action {
        case .press: String(localized: "Pressing “\(name)”")
        case .open: String(localized: "Opening “\(name)”")
        case .menu: String(localized: "Opening the menu of “\(name)”")
        case .focus: String(localized: "Going to “\(name)”")
        case .select: String(localized: "Selecting “\(name)”")
        case .increment, .decrement: String(localized: "Adjusting “\(name)”")
        case .show: String(localized: "Scrolling to “\(name)”")
        }
        try await self.step(step, at: Self.point(of: id))
    }

    func announceTyping(into id: Int?) async throws {
        let name = Self.name(of: id)
        try await step(name.isEmpty ? String(localized: "Typing") : String(localized: "Typing into “\(name)”"),
                       at: Self.point(of: id))
    }

    /// Stop: cancels the reply and refuses what is still on its way.
    func stop() {
        model.stopped = true
        model.step = String(localized: "Stopped")
        Agent.shared.cancel()
        Copilot.shared.dismiss()
        scheduleHide(after: .seconds(1.2))
    }

    /// Follows the agent: the overlay goes when the reply ends, and a new
    /// reply clears an earlier Stop.
    private func watch() {
        guard !watching else { return }
        watching = true
        track()
    }

    private func track() {
        withObservationTracking {
            _ = Agent.shared.isBusy
        } onChange: {
            Task { @MainActor in
                let overlay = ComputerUseOverlay.shared
                overlay.busyChanged(Agent.shared.isBusy)
                overlay.track()
            }
        }
    }

    func busyChanged(_ busy: Bool) {
        if busy, !wasBusy { model.stopped = false }
        if !busy { scheduleHide(after: .seconds(1.5)) }
        wasBusy = busy
    }

    private func scheduleHide(after delay: Duration) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !Agent.shared.isBusy || self.model.stopped else { return }
            self.hide()
        }
    }

    // MARK: Panels

    private func show(around window: CGRect?) {
        let screen = window.flatMap(Self.screen(containing:)) ?? NSScreen.main
        guard let screen else { return }
        // The pill: at the bottom of the window, else above the Dock.
        let anchor = window ?? screen.visibleFrame
        let pill = self.pill ?? makePill()
        self.pill = pill
        let width = Self.pillSize.width
        let pillFrame = NSRect(x: anchor.midX - width / 2, y: max(anchor.minY + 18, screen.visibleFrame.minY + 12),
                               width: width, height: Self.pillSize.height)
        place(pill, at: pillFrame)

        // The frame around the window.
        if let window {
            let frame = self.frame ?? makeFrame()
            self.frame = frame
            place(frame, at: window.insetBy(dx: -3, dy: -3))
        } else {
            frame?.orderOut(nil)
        }

        // The pointer starts where your mouse is, then moves on its own.
        if pointer?.isVisible != true {
            let pointer = self.pointer ?? makePointer()
            self.pointer = pointer
            let mouse = NSEvent.mouseLocation
            pointer.setFrame(Self.pointerFrame(tipAt: CGPoint(x: mouse.x + 24, y: mouse.y - 24)), display: true)
            pointer.alphaValue = 0
            pointer.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; pointer.animator().alphaValue = 1 }
        }
    }

    private func place(_ panel: NSPanel, at rect: NSRect) {
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().setFrame(rect, display: true)
            }
        } else {
            panel.setFrame(rect, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        }
    }

    private func glide(to point: CGPoint) async {
        guard let pointer else { return }
        let target = Self.pointerFrame(tipAt: Self.appKitPoint(fromAX: point))
        let distance = hypot(target.minX - pointer.frame.minX, target.minY - pointer.frame.minY)
        // Quick for a short hop, never slow for a long one.
        let duration = min(0.45, max(0.18, Double(distance) / 2400))
        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
                pointer.animator().setFrame(target, display: true)
            }, completionHandler: { continuation.resume() })
        }
    }

    private func hide() {
        for panel in [pill, frame, pointer].compactMap({ $0 }) where panel.isVisible {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) {
                Task { @MainActor in if panel.alphaValue == 0 { panel.orderOut(nil) } }
            }
        }
    }

    private func panel(level: NSWindow.Level, clickThrough: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = clickThrough
        return panel
    }

    private func makePill() -> NSPanel {
        let panel = panel(level: .statusBar, clickThrough: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = NSHostingView(rootView: UsingAppPill(model: model) { [weak self] in self?.stop() })
        return panel
    }

    private func makeFrame() -> NSPanel {
        let panel = panel(level: .floating, clickThrough: true)
        panel.contentView = NSHostingView(rootView: UsingAppFrame(model: model))
        return panel
    }

    private func makePointer() -> NSPanel {
        // Above menus and pop-ups, under the real cursor.
        let panel = panel(level: .screenSaver, clickThrough: true)
        panel.contentView = NSHostingView(rootView: AgottPointer(model: model))
        return panel
    }

    // MARK: Geometry

    /// Accessibility measures from the top of the main screen; AppKit from
    /// the bottom.
    static func appKitPoint(fromAX point: CGPoint, mainHeight: CGFloat? = nil) -> CGPoint {
        let height = mainHeight ?? NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: height - point.y)
    }

    static func appKitRect(fromAX rect: CGRect, mainHeight: CGFloat? = nil) -> CGRect {
        let height = mainHeight ?? NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The pointer panel's frame that puts the arrow's tip on `tip`.
    static func pointerFrame(tipAt point: CGPoint) -> NSRect {
        NSRect(x: point.x - Self.tip.x, y: point.y - pointerSize.height + Self.tip.y,
               width: pointerSize.width, height: pointerSize.height)
    }

    /// The app's focused window, in AppKit coordinates.
    static func windowFrame(of pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let window = AXReader.element(app, kAXFocusedWindowAttribute) ?? AXReader.element(app, kAXMainWindowAttribute) else {
            return nil
        }
        AXUIElementSetMessagingTimeout(window, 0.3)
        return AXReader.frame(window).map { appKitRect(fromAX: $0) }
    }

    static func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area }
    }

    /// The centre of element `id` from the last read, for the pointer.
    static func point(of id: Int?) -> CGPoint? {
        guard let id, let snapshot = ScreenReader.shared.latest,
              let frame = (snapshot.items + snapshot.menuBar).first(where: { $0.id == id })?.frame,
              frame.width > 0 else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// The words for a step, from the element's line.
    static func name(of id: Int?) -> String {
        guard let id, let item = ScreenReader.shared.latest.flatMap({ ($0.items + $0.menuBar).first { $0.id == id } }) else {
            return ""
        }
        return item.label.isEmpty ? item.role : item.label
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

// MARK: Views

/// "Agott is using Finder", the step, and Stop.
struct UsingAppPill: View {
    var model: ComputerUseOverlay.Model
    var stop: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ThinkingOrb(mode: .orbits, size: 18, active: !model.stopped)
                .colorScheme(.dark)
            VStack(alignment: .leading, spacing: 2) {
                Text("Agott is using \(model.appName)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(model.step)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            Button(action: stop) {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(model.stopped ? .white.opacity(0.14) : .red))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(model.stopped)
            .help(String(localized: "Stop Agott now"))
        }
        .padding(.leading, 16).padding(.trailing, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(.black.opacity(0.92)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
        .animation(.easeOut(duration: 0.2), value: model.step)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Agott is using \(model.appName)"))
    }
}

/// The purple line around the window Agott is working in.
struct UsingAppFrame: View {
    var model: ComputerUseOverlay.Model

    var body: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(Ink.spot.opacity(model.stopped ? 0.25 : 0.85), lineWidth: 3)
            .shadow(color: Ink.spot.opacity(0.35), radius: 6)
            .padding(1)
            .allowsHitTesting(false)
    }
}

/// Agott's pointer: a purple arrow with its name, pulsing when it acts.
struct AgottPointer: View {
    var model: ComputerUseOverlay.Model

    var body: some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .stroke(Ink.spot, lineWidth: 2)
                .frame(width: 30, height: 30)
                .keyframeAnimator(initialValue: 0.0, trigger: model.pulse) { ring, t in
                    ring.scaleEffect(0.2 + t * 1.2).opacity(t == 0 ? 0 : 1 - t)
                } keyframes: { _ in
                    LinearKeyframe(1.0, duration: 0.5)
                }
                .offset(x: ComputerUseOverlay.tip.x - 15, y: ComputerUseOverlay.tip.y - 15)
            Arrow()
                .fill(Ink.spot)
                .overlay(Arrow().stroke(.white, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)))
                .frame(width: 18, height: 24)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .offset(x: ComputerUseOverlay.tip.x, y: ComputerUseOverlay.tip.y)
            Text(verbatim: "Agott")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Ink.spot))
                .overlay(Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 1))
                .offset(x: ComputerUseOverlay.tip.x + 14, y: ComputerUseOverlay.tip.y + 20)
        }
        .frame(width: ComputerUseOverlay.pointerSize.width, height: ComputerUseOverlay.pointerSize.height, alignment: .topLeading)
        .opacity(model.stopped ? 0.4 : 1)
        .allowsHitTesting(false)
    }

    /// The classic arrow, tip at the top-left corner.
    struct Arrow: Shape {
        func path(in rect: CGRect) -> Path {
            let w = rect.width, h = rect.height
            var path = Path()
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: h * 0.82))
            path.addLine(to: CGPoint(x: w * 0.3, y: h * 0.62))
            path.addLine(to: CGPoint(x: w * 0.5, y: h))
            path.addLine(to: CGPoint(x: w * 0.68, y: h * 0.92))
            path.addLine(to: CGPoint(x: w * 0.48, y: h * 0.56))
            path.addLine(to: CGPoint(x: w * 0.9, y: h * 0.56))
            path.closeSubpath()
            return path.offsetBy(dx: rect.minX, dy: rect.minY)
        }
    }
}
#endif
