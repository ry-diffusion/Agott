#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Agott's hands: press, click, type, key, scroll, open.
///
/// Pressing goes through Accessibility first (`AXPress` on the numbered
/// element from the last snapshot) because it does not move your mouse or
/// depend on the window not having shifted. Synthesised clicks are the
/// fallback for apps that draw their own controls.
enum ComputerControl {
    enum Failure: LocalizedError {
        case notTrusted, unknownElement(Int), appNotFound(String)

        var errorDescription: String? {
            switch self {
            case .notTrusted: String(localized: "Agott needs Accessibility permission to use the computer.")
            case .unknownElement(let id): String(localized: "There is no element \(id) on screen. Look at the screen again.")
            case .appNotFound(let name): String(localized: "Could not find an app or address called \(name).")
            }
        }
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

    static func press(element id: Int) async throws -> String {
        try ensureTrusted()
        guard let element = ScreenReader.shared.handles[id],
              let info = ScreenReader.shared.latest?.elements.first(where: { $0.id == id })
        else { throw Failure.unknownElement(id) }
        await focusTarget()
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return "Pressed [\(id)] \(info.label)"
        }
        click(at: CGPoint(x: info.frame.midX, y: info.frame.midY))
        return "Clicked [\(id)] \(info.label) at its centre"
    }

    static func click(at point: CGPoint, double: Bool = false) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let clicks = double ? 2 : 1
        for index in 1...clicks {
            let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
            let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    static func type(_ text: String, submit: Bool) async throws {
        try ensureTrusted()
        await focusTarget()
        try TextInsertion.insert(text)
        if submit {
            try await Task.sleep(for: .milliseconds(350))
            try keys("return")
        }
    }

    static func scroll(lines: Int) {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(lines), wheel2: 0, wheel3: 0)
        event?.post(tap: .cghidEventTap)
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

    /// Opens an app by name, or a URL.
    static func open(_ target: String) async throws -> String {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: trimmed), url.scheme != nil {
            NSWorkspace.shared.open(url)
            return "Opened \(trimmed)"
        }
        if trimmed.contains("."), !trimmed.contains(" "), let url = URL(string: "https://\(trimmed)") {
            NSWorkspace.shared.open(url)
            return "Opened \(url.absoluteString)"
        }
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       URL.homeDirectory.appending(path: "Applications").path]
        for folder in folders {
            let candidates = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            if let match = candidates.first(where: { $0.folded == "\(trimmed).app".folded })
                ?? candidates.first(where: { $0.folded.hasPrefix(trimmed.folded) && $0.hasSuffix(".app") })
            {
                let url = URL(fileURLWithPath: folder).appending(path: match)
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
                try? await Task.sleep(for: .milliseconds(600))
                return "Opened \(match.replacingOccurrences(of: ".app", with: ""))"
            }
        }
        throw Failure.appNotFound(trimmed)
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
