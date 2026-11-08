#if os(macOS)
import AppKit
import ApplicationServices
import SwiftUI

/// Where the text cursor is in the app in front, from Accessibility: the
/// bounds of the selection (or of the character before an empty one), else
/// the focused text field. In Accessibility's screen coordinates (top-left
/// origin). Off the main thread: a slow app must not stall Agott.
nonisolated enum CaretLocator {
    static func caretRect() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        // A busy app must not stall the key press.
        AXUIElementSetMessagingTimeout(system, 0.25)
        guard let element: AXUIElement = value(system, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)

        if let range: AXValue = value(element, kAXSelectedTextRangeAttribute) {
            var selection = CFRange()
            AXValueGetValue(range, .cfRange, &selection)
            if let rect = bounds(element, range), rect.height > 0 { return rect }
            // An empty selection often has no bounds: use the character before it.
            if selection.location > 0 {
                var before = CFRange(location: selection.location - 1, length: 1)
                if let previous = AXValueCreate(.cfRange, &before),
                   let rect = bounds(element, previous), rect.height > 0 {
                    return CGRect(x: rect.maxX, y: rect.minY, width: 1, height: rect.height)
                }
            }
        }
        // No caret to be had (a browser, a custom view): under the text field.
        if let position: AXValue = value(element, kAXPositionAttribute),
           let size: AXValue = value(element, kAXSizeAttribute) {
            var origin = CGPoint.zero, extent = CGSize.zero
            AXValueGetValue(position, .cgPoint, &origin)
            AXValueGetValue(size, .cgSize, &extent)
            guard extent.height > 0, extent.height < 400 else { return nil }
            return CGRect(origin: origin, size: extent)
        }
        return nil
    }

    private static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? T
    }

    private static func bounds(_ element: AXUIElement, _ range: AXValue) -> CGRect? {
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &raw) == .success,
            let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        AXValueGetValue(raw as! AXValue, .cgRect, &rect)
        return rect
    }

    /// Accessibility counts from the top of the main screen; AppKit from the bottom.
    @MainActor static func flipped(_ rect: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// The small pill that shows dictation right where the words will land:
/// under the text cursor, following it while you dictate (the window can
/// move), or near the pointer when there is no cursor to find.
@MainActor
final class DictationPillController {
    static let shared = DictationPillController()
    private var panel: OverlayPanel?
    private var hideTask: Task<Void, Never>?
    private var followTask: Task<Void, Never>?

    /// The panel is a fixed, generous size and never resizes: the pill sits at
    /// its top-left with room around it for the shadow.
    private static let size = CGSize(width: 560, height: 72)
    /// From the panel's edge to the orb's centre line: margin plus the pill's padding.
    private static let margin: CGFloat = 18
    private static let lead: CGFloat = margin + 12
    private static let pillHeight: CGFloat = 32

    func show() {
        hideTask?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Near the pointer at once; then under the caret as soon as it is found.
        if !panel.isVisible { place(panel, at: nil, animated: false) }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        follow()
    }

    func hide(after delay: TimeInterval = 0) {
        hideTask?.cancel()
        hideTask = Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let panel else { return }
            followTask?.cancel()
            followTask = nil
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { panel.alphaValue = 1; return }
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    /// Looks for the caret a few times a second while the pill is up.
    private func follow() {
        followTask?.cancel()
        followTask = Task { [weak self] in
            var last: CGRect?
            var first = true
            while !Task.isCancelled {
                let caret = await Task.detached(priority: .userInitiated) { CaretLocator.caretRect() }.value
                guard !Task.isCancelled, let self, let panel = self.panel else { return }
                if let caret, caret != last {
                    self.place(panel, at: CaretLocator.flipped(caret), animated: !first)
                    last = caret
                    first = false
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                 styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: DictationPill()
            .padding(Self.margin)
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    /// The pill just under the caret, its orb lined up with it; above it when
    /// there is no room below; kept on the screen.
    private func place(_ panel: NSPanel, at caret: CGRect?, animated: Bool) {
        let size = Self.size
        let anchor = caret ?? CGRect(origin: NSEvent.mouseLocation, size: .zero).offsetBy(dx: 8, dy: -12)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor.insetBy(dx: -1, dy: -1)) } ?? NSScreen.main
        // Pill top 4 pt under the caret.
        var origin = CGPoint(x: anchor.minX - Self.lead - 8, y: anchor.minY - 4 + Self.margin - size.height)
        if let frame = screen?.visibleFrame {
            if origin.y + size.height - Self.margin - Self.pillHeight < frame.minY {
                // No room below: the pill's bottom 4 pt above the caret.
                origin.y = anchor.maxY + 4 + Self.pillHeight + Self.margin - size.height
            }
            origin.x = min(max(origin.x, frame.minX - Self.margin + 4), frame.maxX - 360)
        }
        let frame = NSRect(origin: origin, size: size)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}

/// Orb, a live level meter and the last words heard; then "typing it".
struct DictationPill: View {
    @State private var dictation = Dictation.shared
    @State private var copilot = Copilot.shared
    @State private var levels = Array(repeating: Float(0), count: 5)

    var body: some View {
        HStack(spacing: 8) {
            ThinkingOrb(mode: inserting ? .orbits : .wave, size: 16, active: true)
            if inserting {
                Text("Typing it for you…").foregroundStyle(Ink.muted)
            } else if let notice = copilot.notice {
                Text(notice).foregroundStyle(Ink.muted)
            } else {
                meter
                Text(tail)
                    .foregroundStyle(dictation.transcript.isEmpty ? Ink.muted : Ink.text)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 300, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .animation(Motion.arrive, value: dictation.transcript)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Ink.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
        .fixedSize()
        .onChange(of: dictation.level) { _, level in
            levels.removeFirst()
            levels.append(level)
        }
    }

    private var inserting: Bool { copilot.mode == .inserting }

    /// The last words heard, or the hint before the first (and, while the
    /// fast model is still coming in, that it is).
    private var tail: String {
        let words = dictation.transcript.split(separator: " ")
        guard !words.isEmpty else {
            if let notice = ParakeetSetup.shared.notice { return String(localized: "Listening") + " · " + notice }
            return String(localized: "Listening…")
        }
        return words.suffix(8).joined(separator: " ")
    }

    private var meter: some View {
        HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(Ink.spot)
                    .frame(width: 2.5, height: 4 + CGFloat(min(1, levels[index] * 1.6)) * 12)
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.12), value: levels)
        .accessibilityHidden(true)
    }
}
#endif
