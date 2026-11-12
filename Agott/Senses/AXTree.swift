#if os(macOS)
import CoreGraphics
import Foundation

/// One element of another app's accessibility tree, read once and kept as a
/// plain value so the compaction below can be tested without a live app.
/// `ref` is the index of its `AXUIElement` in the read's handle table.
nonisolated struct AXNode: Sendable, Hashable {
    var role: String
    var subrole: String? = nil
    var title: String? = nil
    var label: String? = nil
    var value: String? = nil
    var help: String? = nil
    var placeholder: String? = nil
    var frame: CGRect? = nil
    var enabled = true
    var focused = false
    var selected = false
    var expanded: Bool? = nil
    var children: [AXNode] = []
    var ref: Int? = nil
}

/// What the model sees of one element: a short id it can act on, a short
/// role, its words and its state. Everything else stays here.
nonisolated struct AXItem: Sendable, Hashable {
    var id: Int
    var role: String
    var label: String
    var value: String?
    var placeholder: String?
    var flags: [String]
    /// A field's whole text when `value` had to be cut, for find.
    var fullValue: String? = nil
    var frame: CGRect?
    var ref: Int?
    /// Identity across reads: the same control in the next read keeps its id.
    var key: String
    /// A section line (dialog, sidebar, menu) rather than an element.
    var isHeader = false

    var line: String {
        if isHeader { return "— \(label)" }
        var parts = ["[\(id)]"]
        if role != "text" { parts.append(role) }
        if !label.isEmpty { parts.append("\"\(label)\"") }
        if let value, value != label { parts.append("=\"\(value)\"") }
        else if let placeholder { parts.append("(\(placeholder))") }
        parts += flags
        return parts.joined(separator: " ")
    }

    var isText: Bool { role == "text" || role == "heading" }
}

/// Turns an accessibility tree into a short numbered list for the model, the
/// way fazm's macos-use does it, re-done for Agott: keep what can be pressed
/// or read, drop the scaffolding, fold table rows into one line, skip what is
/// scrolled out of view, and cap the size. Ids stay the same across reads, so
/// "[12]" means the same button before and after an action.
nonisolated enum AXCompactor {
    struct Options: Sendable {
        var maxItems = 220
        var maxCharacters = 7000
        var labelLength = 70
        var valueLength = 120
        var textLength = 160
    }

    struct Result: Sendable {
        var items: [AXItem]
        /// Elements left out because they are scrolled out of view.
        var offscreen: Int
        /// Elements left out to stay within the size cap.
        var truncated: Int
    }

    /// Ids handed out so far, by element key, so they survive a re-read.
    struct IDs: Sendable {
        var byKey: [String: Int] = [:]
        var next = 1

        mutating func id(for key: String) -> Int {
            if let id = byKey[key] { return id }
            let id = next
            next += 1
            byKey[key] = id
            return id
        }
    }

    static let roleNames: [String: String] = [
        "AXButton": "button", "AXCheckBox": "checkbox", "AXRadioButton": "radio", "AXPopUpButton": "popup",
        "AXMenuButton": "menubutton", "AXComboBox": "combobox", "AXTextField": "field", "AXTextArea": "textarea",
        "AXSlider": "slider", "AXIncrementor": "stepper", "AXLink": "link", "AXMenuItem": "menuitem",
        "AXMenuBarItem": "menu", "AXDisclosureTriangle": "disclosure", "AXRow": "row", "AXCell": "cell",
        "AXColorWell": "colorwell", "AXDateField": "datefield", "AXTimeField": "timefield",
        "AXStaticText": "text", "AXHeading": "heading", "AXImage": "image", "AXTab": "tab",
        "AXSegmentedControl": "segmented", "AXLevelIndicator": "level", "AXProgressIndicator": "progress",
        "AXValueIndicator": "indicator", "AXDockItem": "dockitem",
    ]

    static let subroleNames: [String: String] = [
        "AXSearchField": "search", "AXSecureTextField": "password", "AXSwitch": "switch", "AXToggle": "toggle",
        "AXTabButton": "tab", "AXOutlineRow": "row", "AXSortButton": "sortbutton", "AXCloseButton": "close",
        "AXMinimizeButton": "minimize", "AXZoomButton": "zoom", "AXFullScreenButton": "fullscreen",
    ]

    /// Roles a person can act on.
    static let actionable: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXTextField",
        "AXTextArea", "AXSlider", "AXIncrementor", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXDisclosureTriangle",
        "AXRow", "AXCell", "AXColorWell", "AXDateField", "AXTimeField", "AXTab", "AXSegmentedControl", "AXDockItem",
    ]

    /// Containers worth a section line when they have a name.
    static let sections: Set<String> = [
        "AXSheet", "AXPopover", "AXTabGroup", "AXTable", "AXOutline", "AXList", "AXToolbar", "AXGroup",
        "AXSplitGroup", "AXScrollArea", "AXWebArea", "AXMenu", "AXDrawer", "AXBrowser",
    ]

    /// Never useful to the model: the window's own chrome and scroll bars.
    static let skipped: Set<String> = ["AXScrollBar", "AXGrowArea", "AXSplitter", "AXRuler", "AXHelpTag"]

    /// Value roles whose value is the point (a field's text, a box's state).
    static let showsValue: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXCheckBox", "AXRadioButton", "AXSlider", "AXIncrementor",
        "AXPopUpButton", "AXDateField", "AXTimeField", "AXColorWell", "AXLevelIndicator", "AXProgressIndicator",
        "AXValueIndicator",
    ]

    static func shortRole(_ node: AXNode) -> String {
        if let subrole = node.subrole, let name = subroleNames[subrole] {
            // An outline row reads as a row, a tab button as a tab.
            return name
        }
        return roleNames[node.role] ?? node.role.replacingOccurrences(of: "AX", with: "").lowercased()
    }

    static func clean(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return nil }
        // Private-use glyphs (SF Symbols drawn as text) read as nothing.
        if flat.unicodeScalars.allSatisfy({ (0xE000...0xF8FF).contains($0.value) || (0xF0000...0x10FFFF).contains($0.value) }) {
            return nil
        }
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }

    /// The words that name an element, in the order apps fill them in.
    static func name(of node: AXNode, limit: Int) -> String? {
        if node.role == "AXStaticText" || node.role == "AXHeading" {
            return clean(node.value, limit: limit) ?? clean(node.title, limit: limit) ?? clean(node.label, limit: limit)
        }
        if let subrole = node.subrole, chrome.contains(subrole) { return nil }
        return clean(node.title, limit: limit) ?? clean(node.label, limit: limit) ?? clean(node.help, limit: limit)
    }

    /// The window's own buttons: their role says it all; their help text is noise.
    static let chrome: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]

    /// All the words under a node, for rows and unnamed buttons.
    static func words(under node: AXNode, limit: Int) -> String? {
        var parts: [String] = []
        func collect(_ node: AXNode) {
            guard parts.count < 6 else { return }
            if let text = name(of: node, limit: limit), !parts.contains(text),
               node.role == "AXStaticText" || node.role == "AXHeading" || node.role == "AXImage" || node.role == "AXTextField" {
                parts.append(text)
            }
            for child in node.children { collect(child) }
        }
        for child in node.children { collect(child) }
        return clean(parts.joined(separator: " · "), limit: limit)
    }

    static func flags(of node: AXNode) -> [String] {
        var flags: [String] = []
        if !node.enabled { flags.append("disabled") }
        if node.focused { flags.append("focused") }
        if node.selected { flags.append("selected") }
        if let expanded = node.expanded { flags.append(expanded ? "expanded" : "collapsed") }
        return flags
    }

    static func value(of node: AXNode, options: Options) -> String? {
        guard showsValue.contains(node.role), let raw = node.value else { return nil }
        switch node.role {
        case "AXCheckBox", "AXRadioButton":
            switch raw {
            case "1": return "on"
            case "0": return "off"
            case "2": return "mixed"
            default: return clean(raw, limit: options.labelLength)
            }
        case "AXTextArea":
            guard let text = clean(raw, limit: options.valueLength) else { return nil }
            return raw.count > options.valueLength ? "\(text) (\(raw.count) characters)" : text
        default:
            return clean(raw, limit: options.valueLength)
        }
    }

    /// Whether an element lies at least partly inside the visible area.
    static func visible(_ frame: CGRect?, in viewport: CGRect?) -> Bool {
        guard let frame else { return true }
        guard frame.width > 0 || frame.height > 0 else { return false }
        guard let viewport else { return true }
        return frame.insetBy(dx: -1, dy: -1).intersects(viewport)
    }

    /// Compacts `roots` (a window, a dialog, an open menu…) into items.
    static func compact(_ roots: [AXNode], viewport: CGRect?, ids: inout IDs, options: Options = Options()) -> Result {
        var items: [AXItem] = []
        var offscreen = 0
        // Repeats of the same role and words get a running count, so two
        // "Delete" buttons stay two different keys.
        var seen: [String: Int] = [:]

        func key(_ role: String, _ label: String, _ section: String) -> String {
            let base = "\(role)|\(label)|\(section)"
            let count = seen[base, default: 0]
            seen[base] = count + 1
            return count == 0 ? base : "\(base)#\(count)"
        }

        func add(_ node: AXNode, role: String, label: String, section: String, header: Bool = false) {
            let itemKey = key(role, label, section)
            let shown = header ? nil : value(of: node, options: options)
            let whole = node.value.map { String($0.prefix(4000)) }
            items.append(AXItem(
                id: header ? 0 : ids.id(for: itemKey), role: role, label: label, value: shown,
                placeholder: header ? nil : clean(node.placeholder, limit: options.labelLength),
                flags: header ? [] : flags(of: node),
                fullValue: shown != nil && (whole?.count ?? 0) > options.valueLength ? whole : nil,
                frame: node.frame, ref: node.ref, key: itemKey, isHeader: header))
        }

        /// `owner` is the label of the nearest element already listed, so its
        /// own caption is not listed twice.
        func walk(_ node: AXNode, section: String, owner: String?) {
            if skipped.contains(node.role) { return }
            if !visible(node.frame, in: viewport) {
                if node.focused { /* the focused field is always worth knowing */ } else {
                    offscreen += actionable.contains(node.role) || node.role == "AXStaticText" ? 1 : 0
                    return
                }
            }

            let role = node.role
            if role == "AXRow" || (role == "AXCell" && node.children.allSatisfy { !actionable.contains($0.role) }) {
                // A row is one line: its words joined, its own controls after.
                let label = name(of: node, limit: options.labelLength) ?? words(under: node, limit: options.textLength) ?? ""
                add(node, role: shortRole(node), label: label, section: section)
                for child in node.children { walkControls(child, section: section) }
                return
            }

            if actionable.contains(role) {
                var label = name(of: node, limit: options.labelLength)
                    ?? (role == "AXTextField" || role == "AXTextArea" ? nil : words(under: node, limit: options.labelLength))
                    ?? ""
                if role == "AXPopUpButton" || role == "AXMenuButton", label.isEmpty, let shown = clean(node.value, limit: options.labelLength) {
                    label = shown
                }
                // A menu's separators are items with nothing to say.
                if role == "AXMenuItem", label.isEmpty { return }
                add(node, role: shortRole(node), label: label, section: section)
                // Buttons hold their own caption as text; skip it.
                for child in node.children { walk(child, section: section, owner: label) }
                return
            }

            if role == "AXStaticText" || role == "AXHeading" {
                if let text = name(of: node, limit: options.textLength), text != owner, text != items.last?.label {
                    add(node, role: shortRole(node), label: text, section: section)
                }
                return
            }

            if role == "AXImage" {
                // Pictures only count when they say something.
                if let text = clean(node.label, limit: options.labelLength) ?? clean(node.title, limit: options.labelLength),
                   text != owner {
                    add(node, role: "image", label: text, section: section)
                }
                return
            }

            var inner = section
            if sections.contains(role), let title = clean(node.title, limit: options.labelLength) ?? clean(node.label, limit: options.labelLength) {
                let header = role == "AXSheet" ? "Dialog: \(title)" : title
                add(node, role: "section", label: header, section: section, header: true)
                inner = title
            } else if role == "AXSheet" {
                add(node, role: "section", label: "Dialog", section: section, header: true)
                inner = "Dialog"
            }
            for child in node.children { walk(child, section: inner, owner: owner) }
        }

        /// Inside a folded row: only what can be pressed.
        func walkControls(_ node: AXNode, section: String) {
            if actionable.contains(node.role), node.role != "AXCell", node.role != "AXRow", visible(node.frame, in: viewport) {
                let label = name(of: node, limit: options.labelLength) ?? words(under: node, limit: options.labelLength) ?? ""
                add(node, role: shortRole(node), label: label, section: section)
                return
            }
            for child in node.children { walkControls(child, section: section) }
        }

        // The window's title shows as text inside it too; it is said once already.
        for root in roots { walk(root, section: "", owner: clean(root.title, limit: options.textLength)) }

        // Empty section lines (a header whose contents were all dropped).
        items = items.enumerated().filter { index, item in
            guard item.isHeader else { return true }
            let next = items.index(after: index)
            return next < items.endIndex && !items[next].isHeader
        }.map(\.element)

        // The cap: drop plain text from the end first, then controls.
        var truncated = 0
        func size() -> Int { items.reduce(0) { $0 + $1.line.count + 1 } }
        var total = size()
        while items.count > options.maxItems || total > options.maxCharacters {
            let victim = items.lastIndex(where: { $0.isText && !$0.flags.contains("focused") })
                ?? items.lastIndex(where: { !$0.flags.contains("focused") })
            guard let victim else { break }
            total -= items[victim].line.count + 1
            items.remove(at: victim)
            truncated += 1
        }
        return Result(items: items, offscreen: offscreen, truncated: truncated)
    }

    /// Items whose words match `query`, for "find the Save button".
    static func filter(_ items: [AXItem], matching query: String) -> [AXItem] {
        let words = query.folded.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            guard !item.isHeader else { return false }
            let haystack = "\(item.role) \(item.label) \(item.fullValue ?? item.value ?? "") \(item.placeholder ?? "")".folded
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}

/// What changed between two reads of the same app, by id.
nonisolated struct AXDiff: Sendable {
    var added: [AXItem]
    var removed: [AXItem]
    var changed: [(before: AXItem, after: AXItem)]

    var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }
    var count: Int { added.count + removed.count + changed.count }

    init(before: [AXItem], after: [AXItem]) {
        let old = Dictionary(before.filter { !$0.isHeader }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let new = Dictionary(after.filter { !$0.isHeader }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        added = after.filter { !$0.isHeader && old[$0.id] == nil }
        removed = before.filter { !$0.isHeader && new[$0.id] == nil }
        changed = after.compactMap { item in
            guard !item.isHeader, let previous = old[item.id],
                  previous.value != item.value || previous.flags != item.flags || previous.label != item.label
            else { return nil }
            return (previous, item)
        }
    }

    func rendered(limit: Int = 40) -> String {
        var lines: [String] = []
        for item in added.prefix(limit) { lines.append("+ \(item.line)") }
        for item in removed.prefix(max(0, limit - lines.count)) { lines.append("- \(item.line)") }
        for (before, after) in changed.prefix(max(0, limit - lines.count)) {
            let was = [before.value.map { "=\"\($0)\"" }, before.flags.isEmpty ? nil : before.flags.joined(separator: " ")]
                .compactMap { $0 }.joined(separator: " ")
            lines.append("~ \(after.line) (was \(was.isEmpty ? "plain" : was))")
        }
        if count > lines.count { lines.append("… and \(count - lines.count) more changes") }
        return lines.joined(separator: "\n")
    }
}

/// When the accessibility tree is not enough and a picture is needed.
nonisolated enum PixelsReason: String, Sendable {
    case asked = "you asked for it"
    case noWindow = "the app has no window Agott can read"
    case sparse = "the app shows almost nothing to Accessibility"
    case canvas = "most of the window is drawn (a canvas, video, game or image)"
    case opaqueWeb = "the web page in it has no accessibility"

    /// Decides from the read: `roots` the window (or dialog), `items` what
    /// compaction kept, `window` its frame.
    static func check(roots: [AXNode], items: [AXItem], window: CGRect?) -> PixelsReason? {
        guard !roots.isEmpty, let window, window.width > 0, window.height > 0 else { return .noWindow }
        let readable = items.filter { !$0.isHeader && ($0.isText || !$0.label.isEmpty || $0.value != nil) }
        if readable.count < 3 { return .sparse }

        let area = window.width * window.height
        var reason: PixelsReason?
        func scan(_ node: AXNode) {
            guard reason == nil else { return }
            if let frame = node.frame?.intersection(window), !frame.isNull, frame.width * frame.height > area * 0.4 {
                if node.role == "AXWebArea" && countReadable(node) < 3 { reason = .opaqueWeb; return }
                let drawn: Set<String> = ["AXImage", "AXLayoutArea", "AXUnknown", "AXGroup", "AXScrollArea", "AXSplitGroup"]
                if drawn.contains(node.role) && countReadable(node) < 3 && node.children.count < 3 { reason = .canvas; return }
            }
            node.children.forEach(scan)
        }
        roots.forEach(scan)
        return reason
    }

    private static func countReadable(_ node: AXNode) -> Int {
        var count = 0
        func walk(_ node: AXNode) {
            guard count < 3 else { return }
            // A text area or a long run of text is plenty to read.
            if node.role == "AXTextArea" || (node.value?.count ?? 0) > 80 { count = 3; return }
            if AXCompactor.actionable.contains(node.role) || AXCompactor.name(of: node, limit: 40) != nil { count += 1 }
            node.children.forEach(walk)
        }
        node.children.forEach(walk)
        return count
    }
}
#endif
