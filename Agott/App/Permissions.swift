import Foundation
#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
#endif
import AVFoundation
import Contacts
import EventKit

/// Everything Agott has to be allowed to do, checked in one place.
enum Permissions {
    enum Kind: String, CaseIterable, Identifiable {
        case fullDiskAccess, accessibility, screenRecording, microphone, contacts, calendar, reminders

        var id: String { rawValue }

        var title: String {
            switch self {
            case .fullDiskAccess: String(localized: "Full Disk Access")
            case .accessibility: String(localized: "Accessibility")
            case .screenRecording: String(localized: "Screen Recording")
            case .microphone: String(localized: "Microphone")
            case .contacts: String(localized: "Contacts")
            case .calendar: String(localized: "Calendar")
            case .reminders: String(localized: "Reminders")
            }
        }

        var reason: String {
            switch self {
            case .fullDiskAccess: String(localized: "To read your WhatsApp and iMessage history.")
            case .accessibility: String(localized: "To hear the talk key anywhere and use your apps.")
            case .screenRecording: String(localized: "To read what's on your screen.")
            case .microphone: String(localized: "To hear you while you hold the key.")
            case .contacts: String(localized: "To put names to phone numbers.")
            case .calendar: String(localized: "To see and add events.")
            case .reminders: String(localized: "To see and add tasks.")
            }
        }

        var symbol: String {
            switch self {
            case .fullDiskAccess: "externaldrive.fill"
            case .accessibility: "accessibility"
            case .screenRecording: "rectangle.dashed.badge.record"
            case .microphone: "mic.fill"
            case .contacts: "person.crop.circle"
            case .calendar: "calendar"
            case .reminders: "checklist"
            }
        }

        static var relevant: [Kind] {
            #if os(macOS)
            allCases
            #else
            [.microphone, .calendar, .reminders]
            #endif
        }
    }

    static func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .fullDiskAccess:
            #if os(macOS)
            // Opening chat.db is the only honest test; the API does not say.
            return (try? SQLiteDB(path: IMessageSource.path, readOnly: true))
                .flatMap { try? $0.scalarInt("SELECT 1 FROM message LIMIT 1") } != nil
            #else
            return true
            #endif
        case .accessibility:
            #if os(macOS)
            return AXIsProcessTrusted()
            #else
            return true
            #endif
        case .screenRecording:
            #if os(macOS)
            return CGPreflightScreenCaptureAccess()
            #else
            return true
            #endif
        case .microphone:
            return AVAudioApplication.shared.recordPermission == .granted
        case .contacts:
            return CNContactStore.authorizationStatus(for: .contacts) == .authorized
        case .calendar:
            return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        case .reminders:
            return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        }
    }

    static func request(_ kind: Kind) async {
        switch kind {
        case .fullDiskAccess:
            openFullDiskAccess()
        case .accessibility:
            #if os(macOS)
            Copilot.shared.keys.requestAccessibility()
            #endif
        case .screenRecording:
            #if os(macOS)
            if !CGRequestScreenCaptureAccess() { openPane("Privacy_ScreenCapture") }
            #endif
        case .microphone:
            _ = await AVAudioApplication.requestRecordPermission()
        case .contacts:
            _ = await ContactBook.requestAccess()
        case .calendar, .reminders:
            _ = await Organizer.shared.requestAccess()
        }
    }

    static func openFullDiskAccess() {
        openPane("Privacy_AllFiles")
    }

    static func openPane(_ anchor: String) {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
