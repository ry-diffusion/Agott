#if os(macOS)
import CoreGraphics
import Foundation
import FoundationModels

/// Computer use, in the shape Claude and Codex use it: look, then act on what
/// you saw, then look again. Every action that changes something in another
/// app asks first unless Autopilot is on.

nonisolated struct LookAtScreenTool: Tool {
    let name = "look_at_screen"
    let description = """
    See what is on the user's screen right now: the app, window, focused field, numbered controls and all visible \
    text. Call this before acting in another app, and again after acting to check the result.
    """

    @Generable
    struct Arguments {
        @Guide(description: "Why you are looking, in a few words")
        var reason: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await CardBus.status(String(localized: "Looking at your screen…"))
        let snapshot = await ScreenReader.shared.capture(withImage: false, ocr: true)
        if snapshot.elements.isEmpty && snapshot.text.isEmpty {
            return "Could not read the screen. Agott needs Accessibility and Screen Recording permission."
        }
        return snapshot.rendered()
    }
}

nonisolated struct PressTool: Tool {
    let name = "press"
    let description = "Press a numbered control from the last look_at_screen result."

    @Generable
    struct Arguments {
        @Guide(description: "The control number shown in brackets by look_at_screen")
        var element: Int
        @Guide(description: "What pressing it will do, for the user to approve")
        var intent: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        guard await Approvals.ask(String(localized: "Press a button"), detail: arguments.intent) else {
            return "The user declined."
        }
        await CardBus.status(String(localized: "Pressing…"))
        return try await ComputerControl.press(element: arguments.element)
    }
}

nonisolated struct ClickTool: Tool {
    let name = "click_at"
    let description = "Click at screen coordinates (points, origin top-left), for things look_at_screen did not number."

    @Generable
    struct Arguments {
        var x: Int
        var y: Int
        var doubleClick: Bool
        @Guide(description: "What the click will do, for the user to approve")
        var intent: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        guard await Approvals.ask(String(localized: "Click on the screen"), detail: arguments.intent) else {
            return "The user declined."
        }
        try await MainActor.run { try ComputerControl.ensureTrusted() }
        await ComputerControl.focusTarget()
        await MainActor.run {
            ComputerControl.click(at: CGPoint(x: arguments.x, y: arguments.y), double: arguments.doubleClick)
        }
        return "Clicked at \(arguments.x),\(arguments.y)."
    }
}

nonisolated struct TypeTextTool: Tool {
    let name = "type_text"
    let description = """
    Type text into whatever field has focus in the user's app (for example the WhatsApp message box). \
    Set submit to true only if the user asked to send.
    """

    @Generable
    struct Arguments {
        var text: String
        @Guide(description: "Press Return afterwards, which usually sends the message")
        var submit: Bool
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        let title = arguments.submit ? String(localized: "Type and send") : String(localized: "Type text")
        guard await Approvals.ask(title, detail: arguments.text) else { return "The user declined." }
        await CardBus.status(String(localized: "Typing…"))
        try await ComputerControl.type(arguments.text, submit: arguments.submit)
        return arguments.submit ? "Typed and sent." : "Typed."
    }
}

nonisolated struct PressKeysTool: Tool {
    let name = "press_keys"
    let description = "Press a key or shortcut, like \"cmd+f\", \"return\", \"escape\", \"down\", \"cmd+shift+t\"."

    @Generable
    struct Arguments {
        var keys: String
        @Guide(description: "What it will do, for the user to approve")
        var intent: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        guard await Approvals.ask(String(localized: "Press \(arguments.keys)"), detail: arguments.intent) else {
            return "The user declined."
        }
        await ComputerControl.focusTarget()
        try await MainActor.run { try ComputerControl.keys(arguments.keys) }
        return "Pressed \(arguments.keys)."
    }
}

nonisolated struct ScrollTool: Tool {
    let name = "scroll"
    let description = "Scroll the window under the mouse. Positive lines scroll up, negative scroll down."

    @Generable
    struct Arguments {
        @Guide(description: "Lines to scroll", .range(-40...40))
        var lines: Int
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await ComputerControl.focusTarget()
        await MainActor.run { ComputerControl.scroll(lines: arguments.lines) }
        return "Scrolled \(arguments.lines) lines."
    }
}

nonisolated struct OpenTool: Tool {
    let name = "open"
    let description = "Open an app by name (\"WhatsApp\", \"Safari\") or a URL."

    @Generable
    struct Arguments {
        var target: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await CardBus.status(String(localized: "Opening \(arguments.target)…"))
        return try await ComputerControl.open(arguments.target)
    }
}
#endif
