#if os(macOS)
import AppKit
import Carbon.HIToolbox

/// The shortcut that opens quick entry to type, from any app.
nonisolated enum TextShortcut: String, CaseIterable, Identifiable, Codable, Sendable {
    case optionSpace, controlSpace, commandShiftSpace, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optionSpace: "⌥ Space"
        case .controlSpace: "⌃ Space"
        case .commandShiftSpace: "⌘ ⇧ Space"
        case .off: String(localized: "Off")
        }
    }

    /// Carbon modifier flags for the key.
    var modifiers: UInt32? {
        switch self {
        case .optionSpace: UInt32(optionKey)
        case .controlSpace: UInt32(controlKey)
        case .commandShiftSpace: UInt32(cmdKey | shiftKey)
        case .off: nil
        }
    }
}

/// A system-wide key combination, registered with the system so the press
/// goes to Agott and not to the app in front (it would type a space).
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    /// Registers the shortcut (replacing any earlier one); `.off` removes it.
    func register(_ shortcut: TextShortcut, action: @escaping () -> Void) {
        unregister()
        guard let modifiers = shortcut.modifiers else { return }
        self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { GlobalHotKey.shared.action?() }
            return noErr
        }, 1, &type, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x41474F54), id: 1) // "AGOT"
        RegisterEventHotKey(UInt32(kVK_Space), modifiers, id, GetApplicationEventTarget(), 0, &reference)
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
    }
}
#endif
