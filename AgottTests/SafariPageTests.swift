#if os(macOS)
import AppKit
import Foundation
import JavaScriptCore
import Testing
@testable import Agott

// MARK: The extension's page compaction, run in JavaScriptCore

/// `AgottSafari/page-core.js` is the part of the content script with no DOM:
/// it turns what the page walk found into the list the model reads. Run here
/// as it is shipped.
struct PageCoreTests {
    private func core() throws -> JSContext {
        let source = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "AgottSafari/page-core.js")
        let context = try #require(JSContext())
        var failure: String?
        context.exceptionHandler = { _, error in failure = error?.toString() }
        context.evaluateScript(try String(contentsOf: source, encoding: .utf8))
        #expect(failure == nil)
        return context
    }

    /// Runs `compact` on `entries` (JSON) and decodes the answer.
    private func compact(_ entries: String, options: String = "{}") throws -> (items: [SafariPage.Entry], offscreen: Int, truncated: Int) {
        let context = try core()
        let json = try #require(context.evaluateScript("JSON.stringify(AgottPageCore.compact(\(entries), \(options)))")?.toString())
        struct Out: Decodable { var items: [SafariPage.Entry]; var offscreen: Int; var truncated: Int }
        let out = try JSONDecoder().decode(Out.self, from: Data(json.utf8))
        return (out.items, out.offscreen, out.truncated)
    }

    @Test func keepsWhatIsInViewAndCountsTheRest() throws {
        let result = try compact("""
        [
          {"kind": "heading", "ref": 1, "name": "  Sign   in ", "visible": true},
          {"kind": "text", "ref": 2, "name": "Email", "visible": true},
          {"kind": "control", "ref": 3, "role": "field", "name": "Email", "value": "", "placeholder": "you@example.com", "flags": ["required"], "visible": true},
          {"kind": "control", "ref": 4, "role": "button", "name": "Continue", "flags": [], "visible": true},
          {"kind": "control", "ref": 5, "role": "link", "name": "Far below", "flags": [], "visible": false},
          {"kind": "text", "ref": 6, "name": "Footer words", "visible": false},
          {"kind": "image", "ref": 7, "name": "", "visible": true},
          {"kind": "text", "ref": 8, "name": "\u{E001}\u{E002}", "visible": true}
        ]
        """)
        #expect(result.items.map(\.ref) == [1, 3, 4])
        #expect(result.items[0].label == "Sign in")
        #expect(result.items[0].role == "heading")
        // The <label> text before its field is said once, as the field's name.
        #expect(result.items[1].label == "Email")
        #expect(result.items[1].placeholder == "you@example.com")
        #expect(result.offscreen == 2)
        #expect(result.truncated == 0)
    }

    @Test func linesMatchTheAccessibilityFormat() throws {
        let context = try core()
        let line = context.evaluateScript("""
            AgottPageCore.line({ ref: 12, role: "field", label: "Name", value: "Moizes", flags: ["focused"] })
            """)?.toString()
        #expect(line == "[12] field \"Name\" =\"Moizes\" focused")
        let text = context.evaluateScript("AgottPageCore.line({ ref: 3, role: \"text\", label: \"Hello\", value: null, flags: [] })")?.toString()
        #expect(text == "[3] \"Hello\"")
        let empty = context.evaluateScript("""
            AgottPageCore.line({ ref: 4, role: "search", label: "", value: null, placeholder: "Search", flags: [] })
            """)?.toString()
        #expect(empty == "[4] search (Search)")
    }

    @Test func sectionsWrapTheirElementsAndEmptyOnesGo() throws {
        let result = try compact("""
        [
          {"kind": "section", "name": "Navigation"},
          {"kind": "control", "ref": 1, "role": "link", "name": "Home", "flags": [], "visible": true},
          {"kind": "end"},
          {"kind": "section", "name": "Sidebar"},
          {"kind": "control", "ref": 2, "role": "link", "name": "Hidden", "flags": [], "visible": false},
          {"kind": "end"},
          {"kind": "control", "ref": 3, "role": "button", "name": "Home", "flags": [], "visible": true}
        ]
        """)
        #expect(result.items.map(\.label) == ["Navigation", "Home", "Home"])
        #expect(result.items[0].header == true)
        #expect(result.items[1].section == "Navigation")
        #expect(result.items[2].section == "")
    }

    @Test func longValuesAreCutAndKeptWhole() throws {
        let long = String(repeating: "word ", count: 60)
        let result = try compact("""
        [{"kind": "control", "ref": 1, "role": "textarea", "name": "Message", "value": "\(long)", "flags": ["focused"], "visible": true}]
        """)
        let item = try #require(result.items.first)
        #expect(item.value?.hasSuffix("(\(long.count) characters)") == true)
        #expect(item.full?.count == long.count)
    }

    @Test func capDropsTextFirstAndNeverTheFocusedField() throws {
        var entries: [String] = []
        for index in 1...40 {
            entries.append(#"{"kind": "text", "ref": \#(index), "name": "Paragraph number \#(index) with some words in it", "visible": true}"#)
        }
        entries.append(#"{"kind": "control", "ref": 100, "role": "field", "name": "Search", "value": "", "flags": ["focused"], "visible": true}"#)
        entries.append(#"{"kind": "control", "ref": 101, "role": "button", "name": "Go", "flags": [], "visible": true}"#)
        let result = try compact("[\(entries.joined(separator: ","))]", options: #"{"maxCharacters": 600}"#)
        let refs = result.items.map(\.ref)
        #expect(refs.contains(100))
        #expect(refs.contains(101))
        #expect(result.truncated > 0)
        // The paragraphs that stay are the first ones, in order.
        #expect(Array(refs.prefix(3)) == [1, 2, 3])
        let total = result.items.reduce(0) { $0 + "[\($1.ref)] \($1.role) \"\($1.label)\"".count + 1 }
        #expect(total <= 660)
    }
}

// MARK: The page in the numbered list

@MainActor
struct SafariPageTests {
    private func page(_ entries: String, title: String = "Shop") throws -> SafariPage {
        let json = #"{"url": "https://example.com/", "title": "\#(title)", "offscreen": 0, "truncated": 0, "items": [\#(entries)]}"#
        return try JSONDecoder().decode(SafariPage.self, from: Data(json.utf8))
    }

    private let navigation = #"""
        {"ref": 0, "role": "section", "label": "Navigation", "flags": [], "section": "", "header": true},
        {"ref": 1, "role": "link", "label": "Home", "flags": [], "section": "Navigation"},
        {"ref": 2, "role": "link", "label": "Cart", "flags": [], "section": "Navigation"}
        """#

    @Test func pageElementsShareTheWindowsIDsWithoutClashing() throws {
        var ids = AXCompactor.IDs()
        // The window's own controls were numbered first.
        _ = ids.id(for: "AXButton|Back|")
        _ = ids.id(for: "AXTextField|Address|")
        let items = try page(navigation + #", {"ref": 9, "role": "field", "label": "Search", "value": "shoes", "flags": ["focused"], "section": ""}"#)
            .items(ids: &ids)
        #expect(items.first?.isHeader == true)
        #expect(items.first?.line == "— Web page \"Shop\" · https://example.com/")
        let elements = items.filter { !$0.isHeader }
        #expect(elements.map(\.id) == [3, 4, 5])
        #expect(elements.map(\.web) == [1, 2, 9])
        #expect(elements.last?.line == "[5] field \"Search\" =\"shoes\" focused")
    }

    @Test func idsStayTheSameAndTheDiffSaysWhatChanged() throws {
        var ids = AXCompactor.IDs()
        let before = try page(navigation + #"""
            , {"ref": 5, "role": "button", "label": "Add to cart", "flags": [], "section": ""},
            {"ref": 6, "role": "text", "label": "Cart is empty", "flags": [], "section": ""}
            """#).items(ids: &ids)
        // After pressing: the page re-rendered (new refs), the cart has one.
        let after = try page(navigation + #"""
            , {"ref": 15, "role": "button", "label": "Add to cart", "flags": ["disabled"], "section": ""},
            {"ref": 16, "role": "text", "label": "1 item in your cart", "flags": [], "section": ""}
            """#).items(ids: &ids)
        let id = { (items: [AXItem], label: String) in items.first { $0.label == label }?.id }
        #expect(id(before, "Home") == id(after, "Home"))
        #expect(id(before, "Add to cart") == id(after, "Add to cart"))
        #expect(after.first { $0.label == "Add to cart" }?.web == 15)

        let diff = AXDiff(before: before, after: after)
        #expect(diff.added.map(\.label) == ["1 item in your cart"])
        #expect(diff.removed.map(\.label) == ["Cart is empty"])
        #expect(diff.changed.map(\.after.label) == ["Add to cart"])
        let rendered = diff.rendered()
        #expect(rendered.contains("+ [\(id(after, "1 item in your cart")!)] \"1 item in your cart\""))
        #expect(rendered.contains("~ [\(id(after, "Add to cart")!)] button \"Add to cart\" disabled (was plain)"))
    }

    @Test func twinsKeepTheirOwnIDs() throws {
        var ids = AXCompactor.IDs()
        let items = try page(#"""
            {"ref": 1, "role": "button", "label": "Reply", "flags": [], "section": ""},
            {"ref": 2, "role": "button", "label": "Reply", "flags": [], "section": ""}
            """#).items(ids: &ids).filter { !$0.isHeader }
        #expect(Set(items.map(\.id)).count == 2)
    }

    @Test func pageElementsAreFoundByWords() throws {
        var ids = AXCompactor.IDs()
        let items = try page(#"""
            {"ref": 1, "role": "select", "label": "Color", "value": "Blue", "flags": [], "section": "", "full": "Options: Red · Blue · Green"}
            """#).items(ids: &ids)
        let found = AXCompactor.filter(items, matching: "color")
        #expect(found.count == 1)
        #expect(found.first?.fullValue == "Options: Red · Blue · Green")
    }
}

// MARK: Live, in Safari (with the extension on)

/// Opens a test page in Safari and lists and clicks it through the extension.
/// Needs the extension turned on and allowed on localhost, so it only runs
/// with TEST_RUNNER_AGOTT_SAFARI=1. Leaves the test tab open.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["AGOTT_SAFARI"] == "1"))
struct LiveSafariTests {
    static let html = """
    <!doctype html><html><head><title>Agott test page</title></head><body>
    <nav aria-label="Main"><a href="#one">One</a> <a href="#two">Two</a></nav>
    <h1>Agott test page</h1>
    <p id="count">Clicked 0 times</p>
    <button id="add" onclick="document.getElementById('count').textContent = 'Clicked ' + (++window.clicks) + ' times'">Add one</button>
    <label>Name <input id="name" placeholder="Your name"></label>
    <p id="hello"></p>
    <label>Color <select id="color"><option>Red</option><option>Blue</option><option>Green</option></select></label>
    <p id="chosen"></p>
    <form id="form" onsubmit="event.preventDefault(); document.getElementById('sent').textContent = 'Sent'">
      <input id="message" aria-label="Message"><button>Send</button></form>
    <p id="sent"></p>
    <script>
      window.clicks = 0;
      document.getElementById('name').addEventListener('input', e => document.getElementById('hello').textContent = 'Hello, ' + e.target.value);
      document.getElementById('color').addEventListener('change', e => document.getElementById('chosen').textContent = 'Chose ' + e.target.value);
    </script>
    </body></html>
    """

    @Test func listsAndClicksATestPage() async throws {
        #expect(await SafariBridge.isEnabled())
        let folder = FileManager.default.temporaryDirectory.appending(path: "agott-safari-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.html.write(to: folder.appending(path: "index.html"), atomically: true, encoding: .utf8)
        let port = Int.random(in: 20000...40000)
        let server = Process()
        server.executableURL = URL(filePath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", folder.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }
        try await Task.sleep(for: .milliseconds(600))

        let safari = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari"))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([URL(string: "http://127.0.0.1:\(port)/")!], withApplicationAt: safari,
                                              configuration: configuration)

        // Wait for the page to load and the content script to come up.
        var page: SafariPage?
        for _ in 0..<40 where page?.title != "Agott test page" {
            try await Task.sleep(for: .milliseconds(250))
            page = await SafariBridge.shared.snapshot()
        }
        let first = try #require(page)
        #expect(first.title == "Agott test page")
        let labels = first.items.map { "\($0.role) \($0.label)" }
        print(first.items.map { "[\($0.ref)] \($0.role) \"\($0.label)\" \($0.value ?? "")" }.joined(separator: "\n"))
        #expect(labels.contains("link One"))
        #expect(labels.contains("button Add one"))
        #expect(labels.contains("field Name"))
        #expect(labels.contains("select Color"))
        #expect(labels.contains("text Clicked 0 times"))

        // Through ScreenReader and ComputerControl, as the tools do it.
        let snapshot = await ScreenReader.shared.capture(pixels: .never)
        #expect(snapshot.page != nil)
        let rendered = snapshot.rendered()
        print(rendered)
        #expect(rendered.contains("— Web page \"Agott test page\""))
        let add = try #require(snapshot.items.first { $0.web != nil && $0.label == "Add one" })
        let pressed = try await ComputerControl.act(.press, on: add.id)
        print(pressed)
        #expect(pressed.contains("Pressed [\(add.id)] Add one on the page."))
        #expect(pressed.contains("\"Clicked 1 times\""))

        let name = try #require(ScreenReader.shared.latest?.items.first { $0.web != nil && $0.label == "Name" })
        let typed = try await ComputerControl.type("Moizes", into: name.id, replace: true, submit: false)
        print(typed)
        #expect(typed.contains("=\"Moizes\""))
        #expect(typed.contains("Hello, Moizes"))

        let color = try #require(ScreenReader.shared.latest?.items.first { $0.web != nil && $0.label == "Color" })
        let chose = try await ComputerControl.type("green", into: color.id, replace: true, submit: false)
        print(chose)
        #expect(chose.contains("Chose \"Green\""))
        #expect(chose.contains("Chose Green"))

        let message = try #require(ScreenReader.shared.latest?.items.first { $0.web != nil && $0.label == "Message" })
        let sent = try await ComputerControl.type("Hi", into: message.id, replace: true, submit: true)
        print(sent)
        #expect(sent.contains("\"Sent\""))
    }
}
#endif
