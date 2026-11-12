#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog
import ScreenCaptureKit
import Vision

/// What is on the screen right now, accessibility first.
///
/// - **Accessibility** is the default: the app, the window (or the dialog over
///   it), the focused field, and every control and text in view, numbered so
///   the model can say "press 14" instead of guessing at pixels. Ids stay the
///   same from one read to the next, so after an action Agott reports only
///   what changed.
/// - **Pixels** (a screenshot, read with OCR, and the image itself for a model
///   that can see) only when accessibility is not enough: no window, almost
///   nothing readable, a canvas or a web page without accessibility, or when
///   the model asks.
///
/// Agott's own windows are never the answer to "what am I looking at", so the
/// reader always looks at the last app that was not Agott.
@Observable
final class ScreenReader {
    static let shared = ScreenReader()

    enum Pixels: Sendable { case auto, always, never }

    nonisolated struct Snapshot: Sendable {
        var appName: String
        var bundleID: String
        var pid: pid_t
        var windowTitle: String
        var focused: String?
        var items: [AXItem]
        var menuBar: [AXItem]
        var offscreen = 0
        var truncated = 0
        /// The read stopped at its size or time cap: there is more than listed.
        var incomplete = false
        /// OCR of the screenshot, with positions, when one was taken.
        var text = ""
        var image: CGImage?
        var pixels: PixelsReason?
        var readable: Bool
        var nodes = 0
        var axTime: Duration = .zero
        var pixelsTime: Duration = .zero
        var date = Date()

        var isEmpty: Bool { items.isEmpty && text.isEmpty }

        /// For the model: compact, numbered, in reading order.
        func rendered(find query: String? = nil, maxCharacters: Int = .max) -> String {
            var parts = ["App: \(appName)" + (windowTitle.isEmpty ? "" : " · Window: \"\(windowTitle)\"")]
            if let focused { parts.append("Focused: \(focused)") }
            if !readable {
                parts.append("Accessibility is off for Agott, so only pixels can be read.")
            }
            if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                let found = AXCompactor.filter(items + menuBar, matching: query)
                parts.append(found.isEmpty
                    ? "Nothing on screen matches \"\(query)\"."
                    : "Matching \"\(query)\":\n" + found.map { item in
                        // A field found by name shows all of its text.
                        item.fullValue.map { "\(item.line)\nFull text of [\(item.id)]:\n\($0)" } ?? item.line
                    }.joined(separator: "\n"))
            } else if !items.isEmpty {
                var lines: [String] = []
                var used = 0
                for item in items {
                    used += item.line.count + 1
                    if used > maxCharacters {
                        lines.append("… \(items.count - lines.count) more not shown")
                        break
                    }
                    lines.append(item.line)
                }
                parts.append(lines.joined(separator: "\n"))
                if offscreen > 0 { parts.append("(\(offscreen) more are scrolled out of view.)") }
                if incomplete { parts.append("(The window is very large; only part of it was read.)") }
                if truncated > 0 { parts.append("(\(truncated) more left out to keep this short: look_at_screen with find to search them.)") }
            }
            if !menuBar.isEmpty, query == nil {
                parts.append("Menu bar: " + menuBar.map { "[\($0.id)] \($0.label)" }.joined(separator: " · "))
            }
            if let pixels, !text.isEmpty {
                parts.append("Screen text read from a screenshot (\(pixels.rawValue)), with positions for click_at:\n"
                    + String(text.prefix(4000)))
            } else if let pixels, image == nil {
                parts.append("A screenshot was needed (\(pixels.rawValue)) but Agott has no Screen Recording permission.")
            }
            return parts.joined(separator: "\n")
        }
    }

    /// An `AXUIElement` that can travel between tasks. Accessibility objects
    /// are plain references to another process; using one from any thread is
    /// what the API is for.
    nonisolated struct Handle: @unchecked Sendable {
        let element: AXUIElement
    }

    /// The app the person was in before they looked at Agott.
    private(set) var lastExternalApp: NSRunningApplication?
    private(set) var latest: Snapshot?
    /// AX handles from the most recent snapshot, by element id.
    @ObservationIgnored private(set) var handles: [Int: Handle] = [:]
    @ObservationIgnored private var ids = AXCompactor.IDs()
    @ObservationIgnored private var idsPID: pid_t = 0
    @ObservationIgnored private let log = Logger(subsystem: "br.com.zesmoi.Agott", category: "computer-use")

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app.bundleIdentifier != Bundle.main.bundleIdentifier {
                    ScreenReader.shared.lastExternalApp = app
                }
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApp = front
        }
    }

    var targetApp: NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            return front
        }
        return lastExternalApp
    }

    var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    func requestScreenRecordingPermission() {
        CGRequestScreenCaptureAccess()
    }

    /// Reads the screen: accessibility always, pixels when `pixels` says so
    /// (`.auto`: only when accessibility is not enough).
    func capture(pixels: Pixels = .auto, of app: NSRunningApplication? = nil) async -> Snapshot {
        let app = app ?? targetApp
        let pid = app?.processIdentifier ?? 0
        if pid != idsPID {
            ids = AXCompactor.IDs()
            idsPID = pid
        }
        let read = await Self.read(pid: pid, ids: ids)
        ids = read.ids

        var snapshot = Snapshot(
            appName: app?.localizedName ?? "?", bundleID: app?.bundleIdentifier ?? "", pid: pid,
            windowTitle: read.read?.windowTitle ?? "", focused: read.focused, items: read.items, menuBar: read.menuBar,
            offscreen: (read.read?.offscreen ?? 0) + read.offscreen, truncated: read.truncated,
            incomplete: read.read?.hitLimit ?? false, readable: AXIsProcessTrusted(), nodes: read.read?.visited ?? 0,
            axTime: read.read?.duration ?? .zero)

        switch pixels {
        case .never: snapshot.pixels = nil
        case .always: snapshot.pixels = .asked
        case .auto:
            snapshot.pixels = read.read.map { PixelsReason.check(roots: $0.roots, items: read.items, window: $0.windowFrame) }
                ?? .noWindow
        }
        if snapshot.pixels != nil, hasScreenRecordingPermission {
            let clock = ContinuousClock()
            let start = clock.now
            if let (image, frame) = await Self.captureWindow(of: app) {
                snapshot.image = image
                snapshot.text = await Self.recognize(image, in: frame)
            }
            snapshot.pixelsTime = clock.now - start
        }

        var table: [Int: Handle] = [:]
        if let handles = read.read?.handles {
            for item in snapshot.items + snapshot.menuBar {
                if let ref = item.ref, ref < handles.count { table[item.id] = Handle(element: handles[ref]) }
            }
        }
        handles = table
        latest = snapshot
        log.debug("""
            look at \(snapshot.appName, privacy: .public): \(snapshot.items.count) items from \(snapshot.nodes) nodes \
            in \(snapshot.axTime, privacy: .public), \(snapshot.rendered().count) characters, \
            pixels \(snapshot.pixels?.rawValue ?? "no", privacy: .public) in \(snapshot.pixelsTime, privacy: .public)
            """)
        return snapshot
    }

    private struct Compacted: Sendable {
        var read: AXReader.Read?
        var items: [AXItem] = []
        var menuBar: [AXItem] = []
        var focused: String?
        var offscreen = 0
        var truncated = 0
        var ids: AXCompactor.IDs
    }

    @concurrent private nonisolated static func read(pid: pid_t, ids: AXCompactor.IDs) async -> Compacted {
        var result = Compacted(ids: ids)
        guard pid > 0, let read = AXReader.read(pid: pid) else { return result }
        result.read = read
        let compact = AXCompactor.compact(read.roots, viewport: read.viewport, ids: &result.ids)
        result.items = compact.items
        result.offscreen = compact.offscreen
        result.truncated = compact.truncated
        if let bar = read.menuBar {
            result.menuBar = AXCompactor.compact([bar], viewport: nil, ids: &result.ids).items
        }
        if let focused = read.focused {
            let role = AXCompactor.shortRole(focused)
            let name = AXCompactor.name(of: focused, limit: 60).map { " \"\($0)\"" } ?? ""
            let value = AXCompactor.value(of: focused, options: .init()).map { " =\"\($0)\"" } ?? ""
            let id = result.items.first { $0.flags.contains("focused") }.map { "[\($0.id)] " } ?? ""
            result.focused = "\(id)\(role)\(name)\(value)"
        }
        return result
    }

    // MARK: Acting on what was read

    /// The element the model means by `id`, re-read if the app has redrawn it
    /// since (ids survive a re-read; handles may not).
    func element(_ id: Int) async -> (Handle, AXItem)? {
        if let found = current(id), Self.isAlive(found.0) { return found }
        _ = await capture(pixels: .never)
        return current(id)
    }

    private func current(_ id: Int) -> (Handle, AXItem)? {
        guard let snapshot = latest, let handle = handles[id],
              let item = (snapshot.items + snapshot.menuBar).first(where: { $0.id == id }) else { return nil }
        return (handle, item)
    }

    nonisolated static func isAlive(_ handle: Handle) -> Bool {
        var role: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(handle.element, kAXRoleAttribute as CFString, &role)
        return result != .invalidUIElement && result != .cannotComplete
    }

    /// After an action: waits for the app to settle, reads it again, and says
    /// what changed, so the model rarely needs to look again.
    func change(after summary: String, since before: Snapshot?) async -> String {
        let pid = targetApp?.processIdentifier ?? 0
        await Self.settle(pid: pid)
        let after = await capture()
        guard let before, before.pid == after.pid else {
            return "\(summary)\nNow in \(after.appName):\n\(after.rendered())"
        }
        if before.windowTitle != after.windowTitle || after.pixels != nil {
            return "\(summary)\nThe window is now:\n\(after.rendered())"
        }
        let diff = AXDiff(before: before.items + before.menuBar, after: after.items + after.menuBar)
        if diff.isEmpty { return "\(summary)\nNothing changed on screen." }
        if diff.count > max(14, after.items.count / 2) {
            return "\(summary)\nMuch changed; the window is now:\n\(after.rendered())"
        }
        var lines = [summary, "What changed (+ new, - gone, ~ changed):", diff.rendered()]
        if let focused = after.focused, focused != before.focused { lines.append("Focused: \(focused)") }
        return lines.joined(separator: "\n")
    }

    /// Polls a cheap signature of the app until it stops changing (two equal
    /// readings in a row), within a second and a half.
    @concurrent nonisolated static func settle(pid: pid_t) async {
        guard pid > 0 else { return }
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(1500)
        var last = AXReader.fingerprint(pid: pid)
        var steady = 0
        while clock.now < deadline, steady < 2 {
            try? await Task.sleep(for: .milliseconds(60))
            let now = AXReader.fingerprint(pid: pid)
            if now == last { steady += 1 } else { steady = 0; last = now }
        }
    }

    // MARK: Pixels

    /// The target app's frontmost window (the whole display if it has none),
    /// and where it is on screen.
    static func captureWindow(of app: NSRunningApplication?) async -> (CGImage, CGRect)? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let ours = Bundle.main.bundleIdentifier
            let window = content.windows
                .filter { $0.windowLayer == 0 && $0.frame.width > 200 && $0.frame.height > 150 }
                .first { $0.owningApplication?.processID == app?.processIdentifier }
            let filter: SCContentFilter
            let frame: CGRect
            if let window {
                filter = SCContentFilter(desktopIndependentWindow: window)
                frame = window.frame
            } else if let display = content.displays.first {
                let excluded = content.applications.filter { $0.bundleIdentifier == ours }
                filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
                frame = display.frame
            } else {
                return nil
            }
            let configuration = SCStreamConfiguration()
            // Big enough for OCR, small enough to send: 1600 points at most.
            let scale = min(2.0, 1600 / max(frame.width, frame.height, 1))
            configuration.width = Int(frame.width * scale)
            configuration.height = Int(frame.height * scale)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return (image, frame)
        } catch {
            return nil
        }
    }

    /// The words in `image`, top to bottom, each with its centre on screen
    /// (in points, origin top-left, as `click_at` takes them).
    static func recognize(_ image: CGImage, in frame: CGRect) async -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = [Locale.Language(identifier: "pt-BR"), Locale.Language(identifier: "en-US")]
        guard let observations = try? await request.perform(on: image) else { return "" }
        // Vision measures from the bottom; reading goes from the top.
        let lines = observations
            .compactMap { observation -> (CGRect, String)? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                return (observation.boundingBox.cgRect, text)
            }
            .sorted { lhs, rhs in
                abs(lhs.0.midY - rhs.0.midY) > 0.008 ? lhs.0.midY > rhs.0.midY : lhs.0.minX < rhs.0.minX
            }
        return lines.map { box, text in
            let x = Int(frame.minX + box.midX * frame.width)
            let y = Int(frame.minY + (1 - box.midY) * frame.height)
            return "\"\(text)\" @\(x),\(y)"
        }.joined(separator: "\n")
    }
}

#endif
