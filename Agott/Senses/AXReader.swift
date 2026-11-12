#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Reads another app's accessibility tree into `AXNode`s: the focused window
/// (or the dialog over it), any open menu, and the menu bar's titles.
///
/// Fast on purpose, after fazm's macos-use: one IPC round trip per element
/// for all its attributes (`AXUIElementCopyMultipleAttributeValues`), only
/// the visible rows of tables and outlines, nothing scrolled out of view, a
/// short timeout on every element so a busy app cannot stall Agott, and caps
/// on depth, count and time. Off the main thread.
nonisolated enum AXReader {
    struct Limits: Sendable {
        var maxNodes = 3000
        var maxDepth = 40
        var maxChildren = 300
        var budget: Duration = .seconds(2)
        /// Per element, so one stuck app cannot hold up the read.
        var timeout: Float = 0.5
        /// Leave out what is inside web areas: Safari's extension reads the
        /// page from the DOM instead.
        var skipWebContent = false
    }

    /// One read. Handles are kept so the model can act on what it saw.
    struct Read: @unchecked Sendable {
        var pid: pid_t
        var windowTitle = ""
        var windowFrame: CGRect?
        /// The area that counts as on screen: the dialog when one is up.
        var viewport: CGRect?
        var roots: [AXNode] = []
        var menuBar: AXNode?
        var focused: AXNode?
        var handles: [AXUIElement] = []
        var visited = 0
        var offscreen = 0
        var duration: Duration = .zero
        var hitLimit = false
    }

    private static let attributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        kAXHelpAttribute, kAXPlaceholderValueAttribute, kAXEnabledAttribute, kAXFocusedAttribute,
        kAXSelectedAttribute, kAXExpandedAttribute, kAXPositionAttribute, kAXSizeAttribute,
    ]

    /// `root` reads that window instead of the focused one.
    static func read(pid: pid_t, root: AXUIElement? = nil, limits: Limits = Limits()) -> Read? {
        guard AXIsProcessTrusted() else { return nil }
        let clock = ContinuousClock()
        let start = clock.now
        var read = Read(pid: pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, limits.timeout)

        let window: AXUIElement? = root ?? element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
            ?? (array(app, kAXWindowsAttribute)?.first)
        var walker = Walker(read: read, limits: limits, deadline: start + limits.budget)

        // Menus opened by the user or by Agott: a context menu hangs off the
        // app; a menu-bar menu off its title.
        var menus: [AXNode] = []
        for child in array(app, kAXChildrenAttribute) ?? [] where string(child, kAXRoleAttribute) == kAXMenuRole {
            if let node = walker.walk(child, depth: 0, clip: nil) { menus.append(node) }
        }

        if let bar: AXUIElement = element(app, kAXMenuBarAttribute) {
            var titles: [AXNode] = []
            for item in (array(bar, kAXChildrenAttribute) ?? []).dropFirst() {  // not the Apple menu
                AXUIElementSetMessagingTimeout(item, limits.timeout)
                let values = walker.values(of: item)
                guard let title = values.string(2), !title.isEmpty else { continue }
                var node = AXNode(role: kAXMenuBarItemRole, title: title, enabled: values.bool(7) ?? true,
                                  selected: values.bool(9) ?? false, ref: walker.keep(item))
                if node.selected, let menu = array(item, kAXChildrenAttribute)?.first,
                   let open = walker.walk(menu, depth: 0, clip: nil) {
                    node.selected = false
                    var opened = open
                    opened.title = title
                    menus.append(opened)
                }
                titles.append(node)
            }
            walker.read.menuBar = AXNode(role: kAXMenuBarRole, children: titles)
        }

        if let window {
            AXUIElementSetMessagingTimeout(window, limits.timeout)
            walker.read.windowTitle = string(window, kAXTitleAttribute) ?? ""
            walker.read.windowFrame = frame(window)
            // A dialog over the window is all that can be used until it goes.
            let sheet = (array(window, kAXChildrenAttribute) ?? []).first { string($0, kAXRoleAttribute) == "AXSheet" }
            let root = sheet ?? window
            let clip = sheet.flatMap(frame) ?? walker.read.windowFrame
            walker.read.viewport = clip
            if let node = walker.walk(root, depth: 0, clip: clip) { walker.read.roots.append(node) }
        }
        walker.read.roots = menus + walker.read.roots

        if let focused: AXUIElement = element(app, kAXFocusedUIElementAttribute) {
            AXUIElementSetMessagingTimeout(focused, limits.timeout)
            let values = walker.values(of: focused)
            walker.read.focused = AXNode(role: values.string(0) ?? "", subrole: values.string(1), title: values.string(2),
                                         label: values.string(3), value: values.string(4), placeholder: values.string(6),
                                         focused: true)
        }
        read = walker.read
        read.duration = clock.now - start
        return read
    }

    /// A cheap signature of the app's state, to tell when the UI has settled.
    static func fingerprint(pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var parts = [String(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)]
        if let window: AXUIElement = element(app, kAXFocusedWindowAttribute) {
            AXUIElementSetMessagingTimeout(window, 0.3)
            parts.append(string(window, kAXTitleAttribute) ?? "")
            var count: CFIndex = 0
            AXUIElementGetAttributeValueCount(window, kAXChildrenAttribute as CFString, &count)
            parts.append(String(count))
            if let frame = frame(window) { parts.append("\(Int(frame.width))x\(Int(frame.height))") }
        }
        if let focused: AXUIElement = element(app, kAXFocusedUIElementAttribute) {
            AXUIElementSetMessagingTimeout(focused, 0.3)
            parts.append(string(focused, kAXRoleAttribute) ?? "")
            parts.append(String((string(focused, kAXValueAttribute) ?? "").suffix(40)))
            var count: CFIndex = 0
            AXUIElementGetAttributeValueCount(focused, kAXChildrenAttribute as CFString, &count)
            parts.append(String(count))
        }
        return parts.joined(separator: "|")
    }

    // MARK: Walking

    private struct Values {
        var raw: [CFTypeRef?]

        func string(_ index: Int) -> String? {
            guard let value = raw[index] else { return nil }
            if let text = value as? String { return text }
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
            if let number = value as? NSNumber { return number.stringValue }
            if let url = value as? URL { return url.absoluteString }
            if let text = value as? NSAttributedString { return text.string }
            return nil
        }

        func bool(_ index: Int) -> Bool? {
            guard let value = raw[index], let number = value as? NSNumber else { return nil }
            return number.boolValue
        }

        func point(_ index: Int) -> CGPoint? {
            guard let value = raw[index], CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero
            return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
        }

        func size(_ index: Int) -> CGSize? {
            guard let value = raw[index], CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            var size = CGSize.zero
            return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
        }
    }

    private struct Walker {
        var read: Read
        let limits: Limits
        let deadline: ContinuousClock.Instant
        private var seen = Set<AXUIElementHash>()

        init(read: Read, limits: Limits, deadline: ContinuousClock.Instant) {
            self.read = read
            self.limits = limits
            self.deadline = deadline
        }

        mutating func keep(_ element: AXUIElement) -> Int {
            read.handles.append(element)
            return read.handles.count - 1
        }

        func values(of element: AXUIElement) -> Values {
            var array: CFArray?
            let result = AXUIElementCopyMultipleAttributeValues(
                element, AXReader.attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &array)
            var raw = [CFTypeRef?](repeating: nil, count: AXReader.attributes.count)
            guard result == .success, let list = array as? [AnyObject] else { return Values(raw: raw) }
            for (index, value) in list.prefix(raw.count).enumerated() {
                if value is NSNull { continue }
                if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { continue }
                raw[index] = value
            }
            return Values(raw: raw)
        }

        mutating func walk(_ element: AXUIElement, depth: Int, clip: CGRect?) -> AXNode? {
            guard depth <= limits.maxDepth, read.visited < limits.maxNodes, ContinuousClock.now < deadline else {
                read.hitLimit = true
                return nil
            }
            guard seen.insert(AXUIElementHash(element)).inserted else { return nil }
            read.visited += 1
            AXUIElementSetMessagingTimeout(element, limits.timeout)
            let values = values(of: element)
            let role = values.string(0) ?? ""
            if role.isEmpty && depth > 0 { return nil }
            if role == "AXScrollBar" { return nil }

            var frame: CGRect?
            if let origin = values.point(11), let size = values.size(12) { frame = CGRect(origin: origin, size: size) }
            // Scrolled out of view: neither it nor anything inside it shows.
            if let frame, let clip, frame.width > 0, frame.height > 0, !frame.intersects(clip),
               values.bool(8) != true {
                read.offscreen += 1
                return nil
            }

            var node = AXNode(
                role: role, subrole: values.string(1), title: values.string(2), label: values.string(3),
                value: values.string(4), help: values.string(5), placeholder: values.string(6), frame: frame,
                enabled: values.bool(7) ?? true, focused: values.bool(8) ?? false, selected: values.bool(9) ?? false,
                expanded: role == "AXDisclosureTriangle" || role == "AXRow" ? values.bool(10) : nil)
            node.ref = keep(element)

            if role == "AXWebArea", limits.skipWebContent { return node }

            // A scroll area or a list clips what is inside it.
            var inner = clip
            if role == "AXScrollArea" || role == "AXWebArea", let frame, frame.width > 0, frame.height > 0 {
                inner = clip.map { $0.intersection(frame) } ?? frame
                if inner?.isNull == true { inner = frame }
            }
            for child in children(of: element, role: role) {
                if let childNode = walk(child, depth: depth + 1, clip: inner) { node.children.append(childNode) }
            }
            return node
        }

        /// Tables and outlines can hold thousands of rows; only the visible
        /// ones matter. Everything else: the first few hundred children.
        func children(of element: AXUIElement, role: String) -> [AXUIElement] {
            if role == "AXTable" || role == "AXOutline" {
                var rows: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXVisibleRowsAttribute as CFString, &rows) == .success,
                   let rows = rows as? [AXUIElement] {
                    // The header (column titles) is a child, not a row.
                    let header: [AXUIElement] = AXReader.element(element, kAXHeaderAttribute).map { [$0] } ?? []
                    return header + Array(rows.prefix(limits.maxChildren))
                }
            }
            var count: CFIndex = 0
            guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success,
                  count > 0 else { return [] }
            var list: CFArray?
            guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0,
                                                 min(count, CFIndex(limits.maxChildren)), &list) == .success,
                  let children = list as? [AXUIElement] else { return [] }
            return children
        }
    }

    /// AXUIElements compare by the element they stand for; this lets them go
    /// in a set without the set retaining Core Foundation semantics by hand.
    private struct AXUIElementHash: Hashable {
        let element: AXUIElement
        init(_ element: AXUIElement) { self.element = element }
        static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    // MARK: Single attributes

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func array(_ element: AXUIElement, _ name: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }
}
#endif
