#if os(macOS)
import CoreGraphics
import Foundation
import FoundationModels

/// Computer use, accessibility first: look once, act on elements by their
/// [id], and read what changed in the action's own result. A screenshot only
/// comes along when the accessibility tree cannot show the app (a canvas, a
/// game, a web page without accessibility) or when the model asks for one.
/// Every action that changes something in another app asks first unless
/// Autopilot is on.

nonisolated struct LookAtScreenTool: Tool {
    let name = "look_at_screen"
    let description = """
    Read the app in front: its window (or the dialog over it), the focused field, and every control and text in view, \
    each with an [id] to act on with press, type_text or scroll. Call it once before acting in another app; actions \
    report what changed, so look again only when you need the whole picture. Use find to search the screen for \
    words (it also shows the whole text of a matching field, e.g. find "textarea"). Set screenshot to true only when the list does not show what you need (images, a canvas, a video); a \
    screenshot comes on its own when the app cannot be read. In Safari, when Agott's extension is on, the page is \
    read from the page itself (under "Web page"); its elements take the same ids and tools.
    """

    @Generable
    struct Arguments {
        @Guide(description: "Why you are looking, in a few words")
        var reason: String
        @Guide(description: "Optional words to search for; only matching elements are listed")
        var find: String?
        @Guide(description: "True to also take a screenshot. Leave out unless the list is not enough")
        var screenshot: Bool?
    }

    @concurrent func call(arguments: Arguments) async throws -> Prompt {
        await CardBus.status(String(localized: "Looking at your screen…"))
        let snapshot = await ScreenReader.shared.capture(pixels: arguments.screenshot == true ? .always : .auto)
        if snapshot.isEmpty {
            return Prompt("Could not read the screen. Agott needs Accessibility (and, for screenshots, Screen Recording) permission.")
        }
        let text = snapshot.rendered(find: arguments.find)
        // The picture goes along only when there is one and the model sees.
        let sees = await MainActor.run { Agent.chatSeesImages }
        guard sees, let image = snapshot.image else { return Prompt(text) }
        return Prompt {
            text + "\nThe screenshot of the window is attached."
            Attachment(image).label("Screenshot of \(snapshot.appName)")
        }
    }
}

nonisolated struct PressTool: Tool {
    let name = "press"
    let description = """
    Act on an element by its [id] from look_at_screen (or from an earlier action's result): press a button, \
    link, checkbox, tab, menu or row. action is "press" (default), "open" (double-click, e.g. a file), "menu" \
    (its context menu), "focus", "select", "increment", "decrement" or "show" (scroll it into view). \
    Returns what changed on screen.
    """

    @Generable
    struct Arguments {
        @Guide(description: "The element's id, the number in brackets")
        var element: Int
        @Guide(description: "What to do; press unless another fits", .anyOf(ComputerControl.ElementAction.allCases.map(\.rawValue)))
        var action: String?
        @Guide(description: "What it will do, for the user to approve")
        var intent: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        let action = arguments.action.flatMap(ComputerControl.ElementAction.init(rawValue:)) ?? .press
        // Showing something does not change it; no need to ask.
        if action != .show, action != .focus {
            guard await Approvals.ask(String(localized: "Press a button"), detail: arguments.intent) else {
                return "The user declined."
            }
        }
        await CardBus.status(String(localized: "Pressing…"))
        return try await ComputerControl.act(action, on: arguments.element)
    }
}

nonisolated struct ClickTool: Tool {
    let name = "click_at"
    let description = """
    Click at screen coordinates (points, origin top-left). Only for things that have no [id], such as words in \
    a screenshot's text (they come with @x,y). Prefer press with an id whenever there is one. Returns what changed.
    """

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
        return try await ComputerControl.click(CGPoint(x: arguments.x, y: arguments.y), double: arguments.doubleClick)
    }
}

nonisolated struct TypeTextTool: Tool {
    let name = "type_text"
    let description = """
    Type text into a field: give element (its [id]) to type there, or leave it out to type wherever the cursor \
    is (for example the WhatsApp message box). Set replace to true to replace what the field holds. Set submit to \
    true only if the user asked to send. For a select on a web page, text is the option to choose (find shows its \
    options). Returns what changed.
    """

    @Generable
    struct Arguments {
        var text: String
        @Guide(description: "The field's id; leave out to type where the cursor is")
        var element: Int?
        @Guide(description: "True to replace the field's current text instead of adding to it")
        var replace: Bool?
        @Guide(description: "Press Return afterwards, which usually sends the message")
        var submit: Bool
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        let title = arguments.submit ? String(localized: "Type and send") : String(localized: "Type text")
        guard await Approvals.ask(title, detail: arguments.text) else { return "The user declined." }
        await CardBus.status(String(localized: "Typing…"))
        return try await ComputerControl.type(arguments.text, into: arguments.element, replace: arguments.replace ?? false,
                                              submit: arguments.submit)
    }
}

nonisolated struct PressKeysTool: Tool {
    let name = "press_keys"
    let description = """
    Press a key or shortcut in the app in front, like "cmd+f", "return", "escape", "down", "cmd+shift+t". \
    Menu items in look_at_screen's menu bar line can be pressed by id instead. Returns what changed.
    """

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
        return try await ComputerControl.press(keys: arguments.keys)
    }
}

nonisolated struct ScrollTool: Tool {
    let name = "scroll"
    let description = """
    Scroll a list, page or area: give element (the id of a list, a row or anything inside the area) or leave it \
    out to scroll under the mouse. Positive lines scroll up, negative scroll down. Returns what came into view.
    """

    @Generable
    struct Arguments {
        @Guide(description: "Lines to scroll", .range(-40...40))
        var lines: Int
        @Guide(description: "An element inside the area to scroll; leave out for under the mouse")
        var element: Int?
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        try await ComputerControl.scroll(lines: arguments.lines, in: arguments.element)
    }
}

nonisolated struct OpenTool: Tool {
    let name = "open"
    let description = "Open an app by name (\"WhatsApp\", \"Safari\") or a URL. Returns the app's window, ready to act on."

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
