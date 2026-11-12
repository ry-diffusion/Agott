#if os(macOS)
import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import Agott

// MARK: Tree compaction and addressing (no live app)

@MainActor
struct AXCompactorTests {
    private func button(_ title: String, x: CGFloat = 10, y: CGFloat = 10, enabled: Bool = true) -> AXNode {
        AXNode(role: "AXButton", title: title, frame: CGRect(x: x, y: y, width: 60, height: 20), enabled: enabled,
               children: [AXNode(role: "AXStaticText", value: title, frame: CGRect(x: x, y: y, width: 50, height: 16))])
    }

    private func text(_ value: String, y: CGFloat = 40) -> AXNode {
        AXNode(role: "AXStaticText", value: value, frame: CGRect(x: 10, y: y, width: 200, height: 16))
    }

    private func row(_ words: [String], y: CGFloat, selected: Bool = false) -> AXNode {
        AXNode(role: "AXRow", subrole: "AXTableRow", frame: CGRect(x: 0, y: y, width: 400, height: 20), selected: selected,
               children: words.map { word in
                   AXNode(role: "AXCell", frame: CGRect(x: 0, y: y, width: 100, height: 20),
                          children: [AXNode(role: "AXStaticText", value: word, frame: CGRect(x: 0, y: y, width: 90, height: 16))])
               })
    }

    private func window(_ children: [AXNode]) -> AXNode {
        AXNode(role: "AXWindow", title: "Test", frame: CGRect(x: 0, y: 0, width: 800, height: 600), children: [
            AXNode(role: "AXGroup", frame: CGRect(x: 0, y: 0, width: 800, height: 600), children: children),
        ])
    }

    @Test func keepsControlsAndTextDropsScaffolding() {
        var ids = AXCompactor.IDs()
        let tree = window([
            button("Save"),
            AXNode(role: "AXCheckBox", title: "Wrap lines", value: "1", frame: CGRect(x: 10, y: 60, width: 100, height: 20)),
            AXNode(role: "AXTextField", label: "Name", value: "", placeholder: "Your name",
                   frame: CGRect(x: 10, y: 90, width: 200, height: 22), focused: true),
            text("Hello there", y: 120),
            AXNode(role: "AXScrollBar", frame: CGRect(x: 790, y: 0, width: 10, height: 600)),
            AXNode(role: "AXImage", frame: CGRect(x: 10, y: 150, width: 20, height: 20)),  // says nothing: dropped
            button("Delete", y: 180, enabled: false),
            AXNode(role: "AXPopUpButton", title: "Weekly", value: "Weekly", frame: CGRect(x: 10, y: 210, width: 100, height: 20)),
            AXNode(role: "AXButton", subrole: "AXCloseButton", help: "Closes the window", frame: CGRect(x: 2, y: 2, width: 12, height: 12)),
            text("Test", y: 230),  // the window's own title, said already
        ])
        let result = AXCompactor.compact([tree], viewport: tree.frame, ids: &ids)
        let lines = result.items.map(\.line)
        #expect(lines == [
            "[1] button \"Save\"",
            "[2] checkbox \"Wrap lines\" =\"on\"",
            "[3] field \"Name\" (Your name) focused",
            "[4] \"Hello there\"",
            "[5] button \"Delete\" disabled",
            "[6] popup \"Weekly\"",
            "[7] close",
        ])
    }

    @Test func findShowsTheWholeTextOfALongField() {
        var ids = AXCompactor.IDs()
        let body = String(repeating: "Buy bread and milk. ", count: 40)
        let tree = window([AXNode(role: "AXTextArea", value: body, frame: CGRect(x: 0, y: 0, width: 400, height: 300))])
        let items = AXCompactor.compact([tree], viewport: nil, ids: &ids).items
        #expect(items[0].line.hasSuffix("(\(body.count) characters)\""))
        #expect(items[0].fullValue == body)
        let snapshot = ScreenReader.Snapshot(appName: "Notes", bundleID: "", pid: 1, windowTitle: "Test", focused: nil,
                                             items: items, menuBar: [], readable: true)
        #expect(snapshot.rendered(find: "textarea").contains(body))
        #expect(!snapshot.rendered().contains(body))
    }

    @Test func foldsTableRowsIntoOneLine() {
        var ids = AXCompactor.IDs()
        let table = AXNode(role: "AXTable", label: "Files", frame: CGRect(x: 0, y: 0, width: 400, height: 300), children: [
            row(["Report.pdf", "Today", "2 MB"], y: 20, selected: true),
            row(["Notes.txt", "Yesterday", "4 KB"], y: 40),
        ])
        let result = AXCompactor.compact([window([table])], viewport: CGRect(x: 0, y: 0, width: 800, height: 600), ids: &ids)
        #expect(result.items.map(\.line) == [
            "— Files",
            "[1] row \"Report.pdf · Today · 2 MB\" selected",
            "[2] row \"Notes.txt · Yesterday · 4 KB\"",
        ])
    }

    @Test func leavesOutWhatIsScrolledAway() {
        var ids = AXCompactor.IDs()
        let tree = window([button("Visible", y: 10), button("Far below", y: 2000)])
        let result = AXCompactor.compact([tree], viewport: CGRect(x: 0, y: 0, width: 800, height: 600), ids: &ids)
        #expect(result.items.map(\.label) == ["Visible"])
        #expect(result.offscreen == 1)
    }

    @Test func idsSurviveARereadAndRepeatsStayApart() {
        var ids = AXCompactor.IDs()
        let first = AXCompactor.compact([window([button("Delete"), button("Delete", y: 40), button("Save", y: 70)])],
                                        viewport: nil, ids: &ids).items
        #expect(first.map(\.id) == [1, 2, 3])
        // Something new appears at the top; the old ones keep their ids.
        let second = AXCompactor.compact([window([button("New", y: 0), button("Delete"), button("Delete", y: 40), button("Save", y: 70)])],
                                         viewport: nil, ids: &ids).items
        #expect(second.map(\.label) == ["New", "Delete", "Delete", "Save"])
        #expect(second.map(\.id) == [4, 1, 2, 3])
    }

    @Test func diffSaysWhatChanged() {
        var ids = AXCompactor.IDs()
        let before = AXCompactor.compact([window([
            button("Save"),
            AXNode(role: "AXCheckBox", title: "Wrap", value: "0", frame: CGRect(x: 10, y: 60, width: 80, height: 20)),
        ])], viewport: nil, ids: &ids).items
        let after = AXCompactor.compact([window([
            AXNode(role: "AXCheckBox", title: "Wrap", value: "1", frame: CGRect(x: 10, y: 60, width: 80, height: 20)),
            button("Done", y: 90),
        ])], viewport: nil, ids: &ids).items
        let diff = AXDiff(before: before, after: after)
        #expect(diff.added.map(\.label) == ["Done"])
        #expect(diff.removed.map(\.label) == ["Save"])
        #expect(diff.changed.map(\.after.value) == ["on"])
        #expect(diff.rendered() == """
            + [3] button "Done"
            - [1] button "Save"
            ~ [2] checkbox "Wrap" ="on" (was ="off")
            """)
        #expect(AXDiff(before: after, after: after).isEmpty)
    }

    @Test func capDropsPlainTextBeforeControls() {
        var ids = AXCompactor.IDs()
        var children: [AXNode] = [button("Keep me")]
        for index in 0..<50 { children.append(text("Paragraph number \(index) with some words in it", y: CGFloat(30 + index))) }
        var options = AXCompactor.Options()
        options.maxCharacters = 400
        let result = AXCompactor.compact([window(children)], viewport: nil, ids: &ids, options: options)
        #expect(result.items.first?.label == "Keep me")
        #expect(result.truncated > 0)
        #expect(result.items.reduce(0) { $0 + $1.line.count + 1 } <= 400)
    }

    @Test func findFiltersByWords() {
        var ids = AXCompactor.IDs()
        let items = AXCompactor.compact([window([button("Save draft"), button("Send", y: 40), text("Draft saved", y: 70)])],
                                        viewport: nil, ids: &ids).items
        #expect(AXCompactor.filter(items, matching: "draft").map(\.label) == ["Save draft", "Draft saved"])
        #expect(AXCompactor.filter(items, matching: "button send").map(\.label) == ["Send"])
    }

    @Test func dialogComesFirstAndNamed() {
        var ids = AXCompactor.IDs()
        let sheet = AXNode(role: "AXSheet", label: "Save As", frame: CGRect(x: 100, y: 50, width: 400, height: 200),
                           children: [button("Cancel", x: 120, y: 200), button("Save", x: 300, y: 200)])
        let items = AXCompactor.compact([sheet], viewport: sheet.frame, ids: &ids).items
        #expect(items.map(\.line) == ["— Dialog: Save As", "[1] button \"Cancel\"", "[2] button \"Save\""])
    }

    @Test func screenshotOnlyWhenTheTreeIsNotEnough() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        var ids = AXCompactor.IDs()
        // An ordinary window: no pixels.
        let normal = window([button("Save"), button("Open", y: 40), text("Ready", y: 80)])
        let normalItems = AXCompactor.compact([normal], viewport: frame, ids: &ids).items
        #expect(PixelsReason.check(roots: [normal], items: normalItems, window: frame) == nil)
        // No window at all.
        #expect(PixelsReason.check(roots: [], items: [], window: nil) == .noWindow)
        // A game: one drawn view filling the window.
        let game = AXNode(role: "AXWindow", frame: frame, children: [
            button("Close", x: 5, y: 5), text("Score", y: 5), text("0", y: 5),
            AXNode(role: "AXGroup", frame: CGRect(x: 0, y: 30, width: 800, height: 570)),
        ])
        let gameItems = AXCompactor.compact([game], viewport: frame, ids: &ids).items
        #expect(PixelsReason.check(roots: [game], items: gameItems, window: frame) == .canvas)
        // A web page that exposes nothing.
        let web = AXNode(role: "AXWindow", frame: frame, children: [
            button("Back"), button("Reload", y: 5), text("example.com", y: 5),
            AXNode(role: "AXWebArea", frame: CGRect(x: 0, y: 40, width: 800, height: 560),
                   children: [AXNode(role: "AXGroup", frame: CGRect(x: 0, y: 40, width: 800, height: 560))]),
        ])
        let webItems = AXCompactor.compact([web], viewport: frame, ids: &ids).items
        #expect(PixelsReason.check(roots: [web], items: webItems, window: frame) == .opaqueWeb)
        // Next to nothing readable.
        let empty = window([AXNode(role: "AXGroup", frame: CGRect(x: 0, y: 0, width: 10, height: 10))])
        #expect(PixelsReason.check(roots: [empty], items: [], window: frame) == .sparse)
    }
}

// MARK: Live: reading and acting on a real window, in this process

@MainActor
final class Fixture: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow
    var rows: [[String]] = []
    var columns: [String] = []
    var pressed: [String] = []

    init(title: String, size: NSSize = NSSize(width: 900, height: 620)) {
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        super.init()
    }

    var content: NSView { window.contentView! }

    @discardableResult
    func button(_ title: String, at point: NSPoint, width: CGFloat = 90) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(tap(_:)))
        button.frame = NSRect(origin: point, size: NSSize(width: width, height: 28))
        content.addSubview(button)
        return button
    }

    @objc func tap(_ sender: NSButton) { pressed.append(sender.title) }

    @discardableResult
    func label(_ text: String, at point: NSPoint, width: CGFloat = 300) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(origin: point, size: NSSize(width: width, height: 18))
        content.addSubview(label)
        return label
    }

    @discardableResult
    func field(_ placeholder: String, at point: NSPoint, width: CGFloat = 220) -> NSTextField {
        let field = NSTextField(frame: NSRect(origin: point, size: NSSize(width: width, height: 24)))
        field.placeholderString = placeholder
        content.addSubview(field)
        return field
    }

    @discardableResult
    func checkbox(_ title: String, at point: NSPoint, on: Bool) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        box.state = on ? .on : .off
        box.frame = NSRect(origin: point, size: NSSize(width: 260, height: 22))
        content.addSubview(box)
        return box
    }

    func popup(_ items: [String], at point: NSPoint) {
        let popup = NSPopUpButton(frame: NSRect(origin: point, size: NSSize(width: 180, height: 26)), pullsDown: false)
        popup.addItems(withTitles: items)
        content.addSubview(popup)
    }

    func table(_ columns: [String], rows: [[String]], frame: NSRect) {
        self.columns = columns
        self.rows = rows
        let scroll = NSScrollView(frame: frame)
        let table = NSTableView(frame: scroll.bounds)
        for name in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
            column.title = name
            column.width = frame.width / CGFloat(columns.count) - 4
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        content.addSubview(scroll)
        table.reloadData()
    }

    func textView(_ text: String, frame: NSRect) {
        let scroll = NSScrollView(frame: frame)
        let view = NSTextView(frame: scroll.bounds)
        view.string = text
        scroll.documentView = view
        content.addSubview(scroll)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let index = columns.firstIndex(of: tableColumn.identifier.rawValue) else { return nil }
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: rows[row][index])
        cell.addSubview(text)
        cell.textField = text
        text.frame = NSRect(x: 2, y: 0, width: tableColumn.width - 4, height: 17)
        return cell
    }

    func show() async throws {
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
    }

    func close() { window.close() }
}

@MainActor
enum ScreenFixtures {
    static func finder() -> Fixture {
        let fixture = Fixture(title: "Downloads")
        let names = ["Report", "Invoice", "Photo", "Budget", "Slides", "Notes", "Archive", "Song", "Movie", "Script"]
        let kinds = ["PDF document", "Spreadsheet", "JPEG image", "Folder", "Keynote", "Plain text", "ZIP archive", "MP3 audio"]
        let rows = (0..<300).map { index -> [String] in
            ["\(names[index % names.count]) \(index + 1).\(["pdf", "xlsx", "jpg", "zip"][index % 4])",
             "\((index % 28) + 1) Oct 2026 at \(9 + index % 10):\(10 + index % 50)", "\((index * 37) % 900 + 12) KB",
             kinds[index % kinds.count]]
        }
        fixture.table(["Favorites"], rows: ["AirDrop", "Recents", "Applications", "Desktop", "Documents", "Downloads",
                                             "iCloud Drive", "Shared", "Macintosh HD", "Network", "Red", "Blue"].map { [$0] },
                      frame: NSRect(x: 0, y: 40, width: 180, height: 520))
        // A second table for the files; the fixture's data source serves one,
        // so the files table gets its own fixture data through a child.
        let files = Fixture(title: "unused")
        files.columns = ["Name", "Date Modified", "Size", "Kind"]
        files.rows = rows
        let scroll = NSScrollView(frame: NSRect(x: 190, y: 40, width: 700, height: 520))
        let table = NSTableView(frame: scroll.bounds)
        for name in files.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
            column.title = name
            column.width = 170
            table.addTableColumn(column)
        }
        table.dataSource = files
        table.delegate = files
        scroll.documentView = table
        fixture.content.addSubview(scroll)
        table.reloadData()
        objc_setAssociatedObject(fixture, "files", files, .OBJC_ASSOCIATION_RETAIN)
        fixture.button("Back", at: NSPoint(x: 10, y: 580), width: 60)
        fixture.button("Forward", at: NSPoint(x: 75, y: 580), width: 70)
        fixture.button("Share", at: NSPoint(x: 600, y: 580), width: 60)
        fixture.field("Search", at: NSPoint(x: 680, y: 582), width: 200)
        fixture.label("300 items, 41 GB available", at: NSPoint(x: 350, y: 12))
        return fixture
    }

    static func settings() -> Fixture {
        let fixture = Fixture(title: "General")
        fixture.table(["Settings"], rows: ["Wi-Fi", "Bluetooth", "Network", "Battery", "General", "Appearance",
                                            "Accessibility", "Control Center", "Siri", "Spotlight", "Privacy & Security",
                                            "Desktop & Dock", "Displays", "Wallpaper", "Screen Saver", "Energy",
                                            "Lock Screen", "Login Password", "Users & Groups", "Passwords",
                                            "Internet Accounts", "Game Center", "Wallet", "Keyboard", "Mouse"].map { [$0] },
                      frame: NSRect(x: 0, y: 0, width: 220, height: 620))
        var y: CGFloat = 560
        let rows: [(String, String)] = [
            ("Show scroll bars", "Automatically based on mouse or trackpad"),
            ("Click in the scroll bar to", "Jump to the next page"),
            ("Default web browser", "Safari"),
            ("Ask to keep changes when closing documents", ""),
            ("Close windows when quitting an application", "When selected, open documents and windows will not be restored."),
            ("Recent items", "10 Documents, Apps and Servers"),
            ("Allow Handoff between this Mac and your iCloud devices", ""),
            ("Use font smoothing when available", ""),
        ]
        for (index, (title, detail)) in rows.enumerated() {
            if index % 3 == 1 {
                fixture.label(title, at: NSPoint(x: 240, y: y), width: 300)
                fixture.popup([detail.isEmpty ? "Always" : detail, "Never", "Ask"], at: NSPoint(x: 560, y: y - 4))
            } else {
                fixture.checkbox(title, at: NSPoint(x: 240, y: y), on: index % 2 == 0)
                if !detail.isEmpty { fixture.label(detail, at: NSPoint(x: 260, y: y - 20), width: 600) }
            }
            y -= 60
        }
        fixture.button("Help", at: NSPoint(x: 800, y: 12), width: 60)
        return fixture
    }

    static func notes() -> Fixture {
        let fixture = Fixture(title: "Notes")
        let titles = ["Groceries", "Trip to Floripa", "Book ideas", "Meeting notes", "Recipes", "Gift list",
                      "Workout plan", "Quotes", "Movies to watch", "Packing list"]
        fixture.table(["Note", "Date", "Preview"], rows: (0..<60).map { index in
            [titles[index % titles.count] + (index >= titles.count ? " \(index / titles.count + 1)" : ""),
             "\((index % 28) + 1)/10/2026", "A first line of the note that goes on for a while, number \(index)"]
        }, frame: NSRect(x: 0, y: 0, width: 330, height: 580))
        let body = (0..<14).map { "Paragraph \($0 + 1): remember to buy bread, milk, eggs and coffee; call Ana about the weekend and book the hotel near the beach before prices go up." }
            .joined(separator: "\n\n")
        fixture.textView(body, frame: NSRect(x: 340, y: 0, width: 560, height: 580))
        fixture.button("New Note", at: NSPoint(x: 340, y: 586), width: 90)
        fixture.button("Delete", at: NSPoint(x: 440, y: 586), width: 70)
        fixture.button("Share", at: NSPoint(x: 520, y: 586), width: 70)
        fixture.field("Search", at: NSPoint(x: 680, y: 588), width: 200)
        return fixture
    }
}

@MainActor
@Suite(.serialized)
struct LiveAccessibilityTests {
    @Test func pressesTogglesAndFocusesByID() async throws {
        let fixture = Fixture(title: "Press test", size: NSSize(width: 500, height: 300))
        fixture.button("Save", at: NSPoint(x: 20, y: 240))
        fixture.button("Cancel", at: NSPoint(x: 120, y: 240))
        let box = fixture.checkbox("Remember me", at: NSPoint(x: 20, y: 200), on: false)
        let field = fixture.field("Email", at: NSPoint(x: 20, y: 160))
        try await fixture.show()
        defer { fixture.close() }

        let app = AXUIElementCreateApplication(getpid())
        let window = try #require((AXReader.array(app, kAXWindowsAttribute) ?? []).first {
            AXReader.string($0, kAXTitleAttribute) == "Press test"
        })
        let read = try #require(AXReader.read(pid: getpid(), root: window))
        var ids = AXCompactor.IDs()
        let items = AXCompactor.compact(read.roots, viewport: read.viewport, ids: &ids).items
        func item(_ label: String) throws -> (ScreenReader.Handle, AXItem) {
            let item = try #require(items.first { $0.label == label })
            return (ScreenReader.Handle(element: read.handles[try #require(item.ref)]), item)
        }

        let save = try item("Save")
        #expect(save.1.role == "button")
        _ = await ComputerControl.perform(.press, on: save.0, item: save.1)
        #expect(fixture.pressed == ["Save"])

        let remember = try item("Remember me")
        #expect(remember.1.value == "off")
        _ = await ComputerControl.perform(.press, on: remember.0, item: remember.1)
        #expect(box.state == .on)

        let email = try #require(items.first { $0.placeholder == "Email" })
        let emailHandle = ScreenReader.Handle(element: read.handles[try #require(email.ref)])
        let focused = await ComputerControl.perform(.press, on: emailHandle, item: email)
        #expect(focused.hasPrefix("Focused"))
        #expect(fixture.window.firstResponder === field.currentEditor())

        // A re-read keeps the ids.
        let again = try #require(AXReader.read(pid: getpid(), root: window))
        let reread = AXCompactor.compact(again.roots, viewport: again.viewport, ids: &ids).items
        #expect(reread.first { $0.label == "Save" }?.id == save.1.id)
        #expect(reread.first { $0.label == "Remember me" }?.value == "on")
    }

    /// Before/after cost of reading a window, on Finder-, Settings- and
    /// Notes-like windows built here (never the person's own apps). Run with
    /// TEST_RUNNER_AGOTT_MEASURE=1; prints a table.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGOTT_MEASURE"] == "1"))
    func measureBeforeAndAfter() async throws {
        var report = ["| Window | Before: chars | Before: ms (AX + OCR) | After: chars | After: ms | Diff after a press: chars |",
                      "|---|---|---|---|---|---|"]
        for (name, make) in [("Finder-like", ScreenFixtures.finder), ("Settings-like", ScreenFixtures.settings),
                             ("Notes-like", ScreenFixtures.notes)] {
            let fixture = make()
            try await fixture.show()
            defer { fixture.close() }
            let app = AXUIElementCreateApplication(getpid())
            let window = try #require((AXReader.array(app, kAXWindowsAttribute) ?? []).first {
                AXReader.string($0, kAXTitleAttribute) == fixture.window.title
            })

            // Before: the old reader (every element, each attribute its own
            // call) plus OCR of the window, as look_at_screen did each time.
            let clock = ContinuousClock()
            var start = clock.now
            let legacy = LegacyReader.render(window: window, image: fixture.image())
            let legacyText = await legacy.text()
            let before = legacy.rendered(text: legacyText)
            let beforeTime = clock.now - start

            // After: the new reader and compaction, no pixels.
            var ids = AXCompactor.IDs()
            start = clock.now
            let read = try #require(AXReader.read(pid: getpid(), root: window))
            let compact = AXCompactor.compact(read.roots, viewport: read.viewport, ids: &ids)
            let snapshot = ScreenReader.Snapshot(appName: "Fixture", bundleID: "", pid: getpid(),
                                                 windowTitle: fixture.window.title, focused: nil, items: compact.items,
                                                 menuBar: [], offscreen: read.offscreen + compact.offscreen,
                                                 truncated: compact.truncated, readable: true)
            let after = snapshot.rendered()
            let afterTime = clock.now - start
            #expect(PixelsReason.check(roots: read.roots, items: compact.items, window: read.windowFrame) == nil)

            // One step: press a button, then see the result. Before, the
            // model looked again (the whole screen); now the press returns
            // what changed.
            fixture.label("Saved just now", at: NSPoint(x: 400, y: 30))
            let next = try #require(AXReader.read(pid: getpid(), root: window))
            let changed = AXCompactor.compact(next.roots, viewport: next.viewport, ids: &ids).items
            let diff = AXDiff(before: compact.items, after: changed).rendered()

            func ms(_ duration: Duration) -> String { String(format: "%.0f", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000) }
            report.append("| \(name) | \(before.count) | \(ms(beforeTime)) | \(after.count) | \(ms(afterTime)) | \(diff.count + 40) |")
            print("---- \(name) after:\n\(after)\n---- diff:\n\(diff)")
        }
        // A real app in its own process (so every read pays for real IPC), and
        // one with nothing personal in it: Calculator. Accessibility only;
        // the test host has no Screen Recording permission for OCR.
        let url = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.calculator").isEmpty
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let calculator = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        defer { if !wasRunning { calculator.terminate() } }
        try await Task.sleep(for: .seconds(1.5))
        let pid = calculator.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        if let window = AXReader.array(app, kAXWindowsAttribute)?.first {
            let clock = ContinuousClock()
            var start = clock.now
            let legacy = LegacyReader.render(window: window, image: nil).rendered(text: "")
            let beforeTime = clock.now - start
            var ids = AXCompactor.IDs()
            start = clock.now
            let read = try #require(AXReader.read(pid: pid, root: window))
            let compact = AXCompactor.compact(read.roots, viewport: read.viewport, ids: &ids)
            let after = ScreenReader.Snapshot(appName: "Calculator", bundleID: "", pid: pid, windowTitle: read.windowTitle,
                                              focused: nil, items: compact.items, menuBar: [], readable: true).rendered()
            let afterTime = clock.now - start
            func ms(_ duration: Duration) -> String { String(format: "%.0f", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000) }
            report.append("| Calculator (real app, AX only) | \(legacy.count) | \(ms(beforeTime)) | \(after.count) | \(ms(afterTime)) | — |")
            print("---- Calculator after:\n\(after)")
        }
        print("MEASURE\n" + report.joined(separator: "\n"))
    }
}

extension Fixture {
    /// The window's own pixels (no Screen Recording needed for our own view).
    func image() -> CGImage? {
        let view = window.contentView!.superview ?? window.contentView!
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }
}

/// The reader Agott had before this change, kept here only to measure
/// against: every element, attribute by attribute, plus OCR of the window.
@MainActor
struct LegacyReader {
    var title: String
    var lines: [String]
    var image: CGImage?
    var frame: CGRect

    static let interesting: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXLink", "AXMenuItem", "AXMenuButton", "AXCheckBox",
        "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXTab", "AXSearchField", "AXCell", "AXRow",
        "AXStaticText", "AXImage", "AXDisclosureTriangle", "AXIncrementor", "AXSlider",
    ]

    static func render(window: AXUIElement, image: CGImage?) -> LegacyReader {
        var lines: [String] = []
        var visited = 0
        func label(_ element: AXUIElement) -> String {
            for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute] {
                if let value = AXReader.string(element, key), !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    return value.replacingOccurrences(of: "\n", with: " ")
                }
            }
            return ""
        }
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 18, visited < 3000, lines.count < 300 else { return }
            visited += 1
            let role = AXReader.string(element, kAXRoleAttribute) ?? ""
            if interesting.contains(role), let frame = AXReader.frame(element), frame.width > 2, frame.height > 2 {
                let text = label(element)
                let isStatic = role == "AXStaticText" || role == "AXImage" || role == "AXCell" || role == "AXRow"
                if !(isStatic && text.isEmpty) {
                    lines.append("[\(lines.count + 1)] \(role.replacingOccurrences(of: "AX", with: "")) \"\(text.prefix(80))\" @\(Int(frame.midX)),\(Int(frame.midY))")
                }
            }
            for child in AXReader.array(element, kAXChildrenAttribute) ?? [] { walk(child, depth: depth + 1) }
        }
        walk(window, depth: 0)
        return LegacyReader(title: AXReader.string(window, kAXTitleAttribute) ?? "", lines: lines, image: image,
                            frame: AXReader.frame(window) ?? .zero)
    }

    func text() async -> String {
        guard let image else { return "" }
        // The same recognition the old reader ran, without positions.
        let positioned = await ScreenReader.recognize(image, in: frame)
        return positioned.split(separator: "\n").map { line in
            String(line.drop(while: { $0 == "\"" }).prefix(while: { $0 != "\"" }))
        }.joined(separator: "\n")
    }

    func rendered(text: String) -> String {
        var parts = ["App: Fixture", "Window: \(title)"]
        if !lines.isEmpty { parts.append("Controls (use the number to press one):\n" + lines.prefix(160).joined(separator: "\n")) }
        if !text.isEmpty { parts.append("Visible text (OCR, top to bottom):\n" + String(text.prefix(6000))) }
        return parts.joined(separator: "\n")
    }
}
#endif
