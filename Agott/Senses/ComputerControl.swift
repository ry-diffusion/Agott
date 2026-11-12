#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Agott's hands: press, click, type, key, scroll, open.
///
/// Acting goes through Accessibility first, on the numbered element from the
/// last read (`AXPress`, `AXSelected`, `AXFocused`, `AXShowMenu`…), because
/// it does not move the mouse and does not depend on where the window is.
/// Synthesised clicks are the fallback for apps that draw their own controls.
/// Every action waits for the app to settle and reports what changed.
enum ComputerControl {
    enum Failure: LocalizedError {
        case notTrusted, unknownElement(Int), appNotFound(String), pageElementGone(Int)

        var errorDescription: String? {
            switch self {
            case .notTrusted: String(localized: "Agott needs Accessibility permission to use the computer.")
            case .unknownElement(let id): String(localized: "There is no element \(id) on screen. Look at the screen again.")
            case .appNotFound(let name): String(localized: "Could not find an app or address called \(name).")
            case .pageElementGone(let id): String(localized: "Element \(id) is no longer on the page. Look at the screen again.")
            }
        }
    }

    /// What can be done to an element, by name, for the press tool.
    nonisolated enum ElementAction: String, CaseIterable, Sendable {
        case press, open, menu, focus, select, increment, decrement, show
    }

    static func ensureTrusted() throws {
        guard AXIsProcessTrusted() else { throw Failure.notTrusted }
    }

    /// Brings the app the person was using back to the front, so input lands
    /// there and not in Agott.
    static func focusTarget() async {
        guard let app = ScreenReader.shared.targetApp, !app.isActive else { return }
        app.activate()
        try? await Task.sleep(for: .milliseconds(250))
    }

    /// Acts on element `id` and says what changed.
    static func act(_ action: ElementAction, on id: Int) async throws -> String {
        try await ComputerUseOverlay.shared.announce(action, on: id)
        if let item = ScreenReader.shared.pageElement(id) { return try await actOnPage(action, on: item) }
        try ensureTrusted()
        guard let (handle, item) = await ScreenReader.shared.element(id) else { throw Failure.unknownElement(id) }
        let before = ScreenReader.shared.latest
        await focusTarget()
        let done = await perform(action, on: handle, item: item)
        return await ScreenReader.shared.change(after: done, since: before)
    }

    // MARK: Safari pages

    /// Acts on an element of the Safari page through Agott's extension: the
    /// page hears the same events a click or typing makes, Safari need not be
    /// in front, and the mouse does not move.
    private static func actOnPage(_ action: ElementAction, on item: AXItem) async throws -> String {
        let (verb, js): (String, String) = switch action {
        case .press, .select: ("Pressed", "click")
        case .open: ("Double-clicked", "double")
        case .menu: ("Opened the context menu of", "context")
        case .focus: ("Focused", "focus")
        case .increment: ("Incremented", "increment")
        case .decrement: ("Decremented", "decrement")
        case .show: ("Scrolled into view", "show")
        }
        return try await onPage(SafariBridge.Request(op: "act", action: js, ref: item.web), item: item) { _ in
            "\(verb) \(pageName(item)) on the page."
        }
    }

    private static func pageName(_ item: AXItem) -> String {
        "[\(item.id)]" + (item.label.isEmpty ? " \(item.role)" : " \(item.label)")
    }

    /// Sends `request`, then reads the page again and says what changed.
    private static func onPage(_ request: SafariBridge.Request, item: AXItem?,
                               summary: (SafariAnswer) -> String) async throws -> String {
        let before = ScreenReader.shared.latest
        let answer = try await SafariBridge.shared.act(request)
        if answer.error == "gone", let item { throw Failure.pageElementGone(item.id) }
        if let error = answer.error { return "Could not do it on the page: \(error)" }
        var done = summary(answer)
        if answer.lost == true { done += " The page did not answer; it may have gone to another page." }
        return await ScreenReader.shared.change(after: done, since: before)
    }

    nonisolated private static let textRoles: Set<String> = ["field", "textarea", "search", "password", "combobox", "datefield", "timefield"]
    nonisolated private static let rowRoles: Set<String> = ["row", "cell"]

    @concurrent nonisolated static func perform(_ action: ElementAction, on handle: ScreenReader.Handle, item: AXItem) async -> String {
        let element = handle.element
        let name = "[\(item.id)]" + (item.label.isEmpty ? " \(item.role)" : " \(item.label)")
        let actions = AXReader.actions(element)
        /// A busy app can time out and still carry the action out later, so
        /// a timeout counts as sent: falling back to a click would do it twice.
        func run(_ ax: String) -> Bool {
            guard actions.contains(ax) else { return false }
            let result = AXUIElementPerformAction(element, ax as CFString)
            return result == .success || result == .cannotComplete
        }
        func set(_ attribute: String, _ value: Bool) -> Bool {
            AXReader.isSettable(element, attribute)
                && AXUIElementSetAttributeValue(element, attribute as CFString, value as CFBoolean) == .success
        }
        /// The fallback: a real click on the element's centre, scrolled into view first.
        func click(double: Bool = false, right: Bool = false) async -> String {
            _ = run("AXScrollToVisible")
            guard let frame = AXReader.frame(element) ?? item.frame, frame.width > 0 else {
                return "Could not reach \(name): it has no position on screen."
            }
            ComputerControl.click(at: CGPoint(x: frame.midX, y: frame.midY), double: double, right: right)
            return (double ? "Double-clicked " : right ? "Right-clicked " : "Clicked ") + "\(name) at its centre."
        }

        switch action {
        case .press:
            if textRoles.contains(item.role), !actions.contains(kAXPressAction) {
                return set(kAXFocusedAttribute, true) ? "Focused \(name)." : await click()
            }
            if run(kAXPressAction) { return "Pressed \(name)." }
            if rowRoles.contains(item.role), set(kAXSelectedAttribute, true) { return "Selected \(name)." }
            if run(kAXPickAction) || run(kAXConfirmAction) { return "Pressed \(name)." }
            return await click()
        case .open:
            if run("AXOpen") { return "Opened \(name)." }
            return await click(double: true)
        case .menu:
            if run(kAXShowMenuAction) { return "Opened the menu of \(name)." }
            return await click(right: true)
        case .focus:
            if set(kAXFocusedAttribute, true) { return "Focused \(name)." }
            return await click()
        case .select:
            if set(kAXSelectedAttribute, true) { return "Selected \(name)." }
            if run(kAXPressAction) { return "Pressed \(name)." }
            return await click()
        case .increment:
            return run(kAXIncrementAction) ? "Incremented \(name)." : "\(name) cannot be incremented."
        case .decrement:
            return run(kAXDecrementAction) ? "Decremented \(name)." : "\(name) cannot be decremented."
        case .show:
            return run("AXScrollToVisible") ? "Scrolled \(name) into view." : "\(name) cannot be scrolled to."
        }
    }

    nonisolated static func click(at point: CGPoint, double: Bool = false, right: Bool = false) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let clicks = double ? 2 : 1
        let (downType, upType, button): (CGEventType, CGEventType, CGMouseButton) =
            right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        for index in 1...clicks {
            let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: button)
            let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: button)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    /// Clicks at a point (from a screenshot) and says what changed.
    static func click(_ point: CGPoint, double: Bool) async throws -> String {
        try await ComputerUseOverlay.shared.step(String(localized: "Clicking"), at: point)
        try ensureTrusted()
        let before = ScreenReader.shared.latest
        await focusTarget()
        click(at: point, double: double)
        return await ScreenReader.shared.change(after: "Clicked at \(Int(point.x)),\(Int(point.y)).", since: before)
    }

    /// Types into element `id` (or wherever the cursor is), replacing what is
    /// there when asked. By paste, not by setting the value: every app hears
    /// a paste, while many (web pages, chat apps) ignore a value set from
    /// outside.
    static func type(_ text: String, into id: Int?, replace: Bool, submit: Bool) async throws -> String {
        try await ComputerUseOverlay.shared.announceTyping(into: id)
        if let id, let item = ScreenReader.shared.pageElement(id) {
            // On a page the value is set with the events typing makes; a
            // select picks the option with that text.
            let request = SafariBridge.Request(op: "act", action: "type", ref: item.web, text: text, replace: replace, submit: submit)
            return try await onPage(request, item: item) { answer in
                if let option = answer.chose { return "Chose \"\(option)\" in \(pageName(item))." }
                return (submit ? "Typed and sent" : "Typed") + " into \(pageName(item))."
            }
        }
        try ensureTrusted()
        let before = ScreenReader.shared.latest
        var target = ""
        if let id {
            guard let (handle, item) = await ScreenReader.shared.element(id) else { throw Failure.unknownElement(id) }
            await focusTarget()
            _ = await perform(.focus, on: handle, item: item)
            target = " into [\(id)]"
            if replace, !selectAll(handle) { try keys("cmd+a") }
        } else {
            await focusTarget()
            if replace { try keys("cmd+a") }
        }
        try TextInsertion.insert(text)
        if submit {
            try await Task.sleep(for: .milliseconds(350))
            try keys("return")
        }
        return await ScreenReader.shared.change(after: (submit ? "Typed and sent" : "Typed") + target + ".", since: before)
    }

    /// Selects all the text of a field through Accessibility.
    nonisolated private static func selectAll(_ handle: ScreenReader.Handle) -> Bool {
        var count: CFTypeRef?
        guard AXUIElementCopyAttributeValue(handle.element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
              let length = (count as? NSNumber)?.intValue,
              AXReader.isSettable(handle.element, kAXSelectedTextRangeAttribute) else { return false }
        var range = CFRange(location: 0, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(handle.element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    /// Presses a shortcut and says what changed.
    static func press(keys combo: String) async throws -> String {
        try await ComputerUseOverlay.shared.step(String(localized: "Pressing \(combo)"))
        try ensureTrusted()
        let before = ScreenReader.shared.latest
        await focusTarget()
        try keys(combo)
        return await ScreenReader.shared.change(after: "Pressed \(combo).", since: before)
    }

    /// Scrolls inside element `id` (or under the mouse) and says what changed.
    static func scroll(lines: Int, in id: Int?) async throws -> String {
        try await ComputerUseOverlay.shared.step(String(localized: "Scrolling"), at: ComputerUseOverlay.point(of: id))
        let item = id.flatMap { ScreenReader.shared.pageElement($0) }
        if item != nil || (id == nil && ScreenReader.shared.readsPage) {
            let request = SafariBridge.Request(op: "act", action: "scroll", ref: item?.web, lines: lines)
            return try await onPage(request, item: item) { _ in "Scrolled the page \(lines) lines." }
        }
        try ensureTrusted()
        let before = ScreenReader.shared.latest
        var point: CGPoint?
        if let id {
            guard let (handle, item) = await ScreenReader.shared.element(id) else { throw Failure.unknownElement(id) }
            if let frame = AXReader.frame(handle.element) ?? item.frame { point = CGPoint(x: frame.midX, y: frame.midY) }
        }
        await focusTarget()
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(lines), wheel2: 0, wheel3: 0)
        if let point { event?.location = point }
        event?.post(tap: .cghidEventTap)
        return await ScreenReader.shared.change(after: "Scrolled \(lines) lines.", since: before)
    }

    /// "cmd+shift+t", "return", "escape", "down"…
    static func keys(_ combo: String) throws {
        try ensureTrusted()
        let parts = combo.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        var flags: CGEventFlags = []
        var code: CGKeyCode?
        for part in parts {
            switch part {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: code = keyCodes[part]
            }
        }
        guard let code else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Opens an app by name, or a URL, waits for its window and shows it, so
    /// the model can act on it straight away.
    static func open(_ target: String) async throws -> String {
        try await ComputerUseOverlay.shared.step(String(localized: "Opening \(target)…"))
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: trimmed), url.scheme != nil {
            NSWorkspace.shared.open(url)
            return await shown("Opened \(trimmed).", app: nil)
        }
        if trimmed.contains("."), !trimmed.contains(" "), let url = URL(string: "https://\(trimmed)") {
            NSWorkspace.shared.open(url)
            return await shown("Opened \(url.absoluteString).", app: nil)
        }
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       URL.homeDirectory.appending(path: "Applications").path]
        for folder in folders {
            let candidates = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            if let match = candidates.first(where: { $0.folded == "\(trimmed).app".folded })
                ?? candidates.first(where: { $0.folded.hasPrefix(trimmed.folded) && $0.hasSuffix(".app") })
            {
                let url = URL(fileURLWithPath: folder).appending(path: match)
                let app = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
                return await shown("Opened \(match.replacingOccurrences(of: ".app", with: "")).", app: app)
            }
        }
        throw Failure.appNotFound(trimmed)
    }

    /// Waits (up to three seconds) for the app to come to the front with a
    /// window, then reads it.
    private static func shown(_ summary: String, app: NSRunningApplication?) async -> String {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        try? await Task.sleep(for: .milliseconds(200))
        while clock.now < deadline {
            if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier,
               app == nil || front.processIdentifier == app?.processIdentifier,
               AXReader.element(AXUIElementCreateApplication(front.processIdentifier), kAXFocusedWindowAttribute) != nil {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard AXIsProcessTrusted() else { return summary }
        await ScreenReader.settle(pid: ScreenReader.shared.targetApp?.processIdentifier ?? 0)
        return "\(summary)\n\(await ScreenReader.shared.capture().rendered())"
    }

    /// Positions, not letters: these are ANSI key codes, which is what a
    /// synthesised event means regardless of the keyboard layout.
    static let keyCodes: [String: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08,
        "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12,
        "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B,
        "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25,
        "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29, "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E,
        ".": 0x2F, "`": 0x32,
        "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "backspace": 0x33,
        "escape": 0x35, "esc": 0x35, "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79, "forwarddelete": 0x75,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60,
    ]
}

/// Puts text where the cursor is, by paste rather than keystrokes. Borrowed
/// from Shirusu: a paste is one event on any keyboard layout, survives
/// autocomplete, and is instant.
enum TextInsertion {
    static func insert(_ text: String) throws {
        guard !text.isEmpty else { return }
        guard AXIsProcessTrusted() else { throw ComputerControl.Failure.notTrusted }
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        try ComputerControl.keys("cmd+v")
        guard let saved, !saved.isEmpty else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            pasteboard.clearContents()
            pasteboard.writeObjects(saved)
        }
    }
}
#endif
