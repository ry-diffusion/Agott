#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

/// What is on the screen right now, read three ways.
///
/// - **Accessibility** gives structure: the app, the window, the focused field,
///   and every control that can be pressed, numbered so the model can say
///   "press 14" instead of guessing at pixels.
/// - **OCR** gives the words, including the ones accessibility cannot see
///   (WhatsApp's chat bubbles, a PDF, a video frame).
/// - **The image** itself, for a model that can see.
///
/// Agott's own windows are never the answer to "what am I looking at", so the
/// reader always looks at the last app that was not Agott.
@Observable
final class ScreenReader {
    static let shared = ScreenReader()

    nonisolated struct Snapshot: Sendable {
        var appName: String
        var bundleID: String
        var windowTitle: String
        var focused: String?
        var text: String
        var elements: [Element]
        var image: CGImage?
        var date = Date()

        /// For the model: compact, numbered, top to bottom.
        func rendered(maxElements: Int = 160, maxText: Int = 6000) -> String {
            var parts = ["App: \(appName)", "Window: \(windowTitle)"]
            if let focused { parts.append("Focused: \(focused)") }
            if !elements.isEmpty {
                parts.append("Controls (use the number to press one):\n" + elements.prefix(maxElements).map(\.line).joined(separator: "\n"))
            }
            if !text.isEmpty { parts.append("Visible text (OCR, top to bottom):\n" + String(text.prefix(maxText))) }
            return parts.joined(separator: "\n")
        }
    }

    nonisolated struct Element: Sendable, Hashable {
        var id: Int
        var role: String
        var label: String
        var frame: CGRect

        var line: String {
            "[\(id)] \(role.replacingOccurrences(of: "AX", with: "")) \"\(label.prefix(80))\" @\(Int(frame.midX)),\(Int(frame.midY))"
        }
    }

    /// The app the person was in before they looked at Agott.
    private(set) var lastExternalApp: NSRunningApplication?
    private(set) var latest: Snapshot?
    /// AX handles from the most recent snapshot, by element number.
    @ObservationIgnored private(set) var handles: [Int: AXUIElement] = [:]

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

    /// Reads the screen. `withImage` keeps the picture for a vision model.
    func capture(withImage: Bool = false, ocr: Bool = true) async -> Snapshot {
        let app = targetApp
        let (title, focused, elements, handles) = Self.accessibility(for: app)
        self.handles = handles

        var image: CGImage?
        if ocr || withImage, hasScreenRecordingPermission {
            image = await Self.captureWindow(of: app)
        }
        var text = ""
        if ocr, let image { text = await Self.recognize(image) }

        let snapshot = Snapshot(
            appName: app?.localizedName ?? "?", bundleID: app?.bundleIdentifier ?? "",
            windowTitle: title, focused: focused, text: text, elements: elements,
            image: withImage ? image : nil)
        latest = snapshot
        return snapshot
    }

    // MARK: Accessibility

    private static let interesting: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXLink", "AXMenuItem", "AXMenuButton", "AXCheckBox",
        "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXTab", "AXSearchField", "AXCell", "AXRow",
        "AXStaticText", "AXImage", "AXDisclosureTriangle", "AXIncrementor", "AXSlider",
    ]

    private static func accessibility(for app: NSRunningApplication?)
        -> (String, String?, [Element], [Int: AXUIElement])
    {
        guard let app, AXIsProcessTrusted() else { return ("", nil, [], [:]) }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let window: AXUIElement? = attribute(root, kAXFocusedWindowAttribute)
        let title = window.flatMap { string($0, kAXTitleAttribute) } ?? ""

        var focusedLine: String?
        if let focused: AXUIElement = attribute(root, kAXFocusedUIElementAttribute) {
            let role = string(focused, kAXRoleAttribute) ?? ""
            let value = string(focused, kAXValueAttribute) ?? ""
            let label = label(of: focused)
            focusedLine = "\(role) \(label) \(value.prefix(200))".trimmingCharacters(in: .whitespaces)
        }

        var elements: [Element] = []
        var handles: [Int: AXUIElement] = [:]
        var visited = 0

        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 18, visited < 3000, elements.count < 300 else { return }
            visited += 1
            let role = string(element, kAXRoleAttribute) ?? ""
            if interesting.contains(role), let frame = frame(of: element), frame.width > 2, frame.height > 2 {
                let text = label(of: element)
                let isStatic = role == "AXStaticText" || role == "AXImage" || role == "AXCell" || role == "AXRow"
                if !(isStatic && text.isEmpty) {
                    let id = elements.count + 1
                    elements.append(Element(id: id, role: role, label: text, frame: frame))
                    handles[id] = element
                }
            }
            let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
            for child in children { walk(child, depth: depth + 1) }
        }
        if let window { walk(window, depth: 0) }
        // The menu bar is part of the app too, and is often how things get done.
        return (title, focusedLine, elements, handles)
    }

    static func label(of element: AXUIElement) -> String {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute] {
            if let value = string(element, key), !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return value.replacingOccurrences(of: "\n", with: " ")
            }
        }
        return ""
    }

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size
        else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        // Both are AXValues by contract; the casts cannot fail for these keys.
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    // MARK: Pixels

    private static func captureWindow(of app: NSRunningApplication?) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let ours = Bundle.main.bundleIdentifier
            let window = content.windows
                .filter { $0.windowLayer == 0 && $0.frame.width > 200 && $0.frame.height > 150 }
                .first { $0.owningApplication?.processID == app?.processIdentifier }
            let filter: SCContentFilter
            let size: CGSize
            if let window {
                filter = SCContentFilter(desktopIndependentWindow: window)
                size = window.frame.size
            } else if let display = content.displays.first {
                let excluded = content.applications.filter { $0.bundleIdentifier == ours }
                filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
                size = CGSize(width: display.width, height: display.height)
            } else {
                return nil
            }
            let configuration = SCStreamConfiguration()
            let scale = min(2.0, 2400 / max(size.width, 1))
            configuration.width = Int(size.width * scale)
            configuration.height = Int(size.height * scale)
            configuration.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            return nil
        }
    }

    private static func recognize(_ image: CGImage) async -> String {
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
        return lines.map(\.1).joined(separator: "\n")
    }
}
#endif
