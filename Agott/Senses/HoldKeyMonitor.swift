#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Observation
import OSLog

/// Watches the hold-to-talk keys from any app.
///
/// Adapted from Shirusu's Globe monitor, widened to the right-hand modifiers
/// so Agott can live beside Shirusu without the two fighting over 🌐. A
/// modifier is also a modifier, though: if another key goes down while it is
/// held (right-⌥ + e for é), that was typing, not talking, and the press is
/// cancelled.
@Observable
final class HoldKeyMonitor {
    enum Purpose { case ask, dictate }

    private(set) var isActive = false
    var onPress: ((Purpose) -> Void)?
    var onRelease: ((Purpose, TimeInterval) -> Void)?
    var onCancel: ((Purpose) -> Void)?

    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var held: (Purpose, Date)?
    @ObservationIgnored private var state: [HoldKey: Bool] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "br.com.zesmoi.Agott", category: "hotkey")

    var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @discardableResult
    func enable() -> Bool {
        guard tap == nil else { return true }
        guard hasAccessibilityPermission else { return false }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HoldKeyMonitor>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            log.error("Could not create the event tap")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        isActive = true
        return true
    }

    func disable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isActive = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            if let (purpose, _) = held { held = nil; onCancel?(purpose) }
            return
        }
        if type == .keyDown {
            if let (purpose, _) = held {
                held = nil
                onCancel?(purpose)
            }
            return
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let settings = AppSettings.shared

        for key in [HoldKey.rightOption, .rightCommand, .globe] {
            let isDown: Bool
            switch key {
            case .rightOption:
                guard code == 61 else { continue }
                isDown = flags.contains(.maskAlternate)
            case .rightCommand:
                guard code == 54 else { continue }
                isDown = flags.contains(.maskCommand)
            case .globe:
                guard code == 63 || code == 179 else { continue }
                isDown = flags.contains(.maskSecondaryFn)
            case .off:
                continue
            }
            guard state[key, default: false] != isDown else { continue }
            state[key] = isDown

            let purpose: Purpose? = settings.askKey == key ? .ask : settings.dictateKey == key ? .dictate : nil
            guard let purpose else { continue }
            if isDown {
                // Another modifier already down means a shortcut, not a hold.
                let others: CGEventFlags = [.maskShift, .maskControl]
                guard flags.intersection(others).isEmpty else { continue }
                held = (purpose, Date())
                onPress?(purpose)
            } else if let (heldPurpose, since) = held, heldPurpose == purpose {
                held = nil
                onRelease?(purpose, Date().timeIntervalSince(since))
            }
        }
    }
}
#endif
