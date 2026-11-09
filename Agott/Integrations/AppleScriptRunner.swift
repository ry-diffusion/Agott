#if os(macOS)
import AppKit
import Foundation
import FoundationModels

/// Runs AppleScript (or JavaScript for Automation) against the user's apps.
///
/// This is the precise half of computer use. Clicking is how a person uses an
/// app; Apple Events are how an app wants to be used by another program. "Play
/// my liked songs", "make a note", "what tabs are open in Safari", "rename
/// these files": each is one script instead of a dozen clicks that break
/// when a window moves.
nonisolated enum AppleScriptRunner {
    enum Language: String, Sendable { case appleScript, javaScript }

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// In-process for AppleScript, so the Automation prompts name Agott.
    /// JXA goes through `osascript`, which is where it is supported.
    static func run(_ source: String, language: Language = .appleScript, timeout: TimeInterval = 30) async throws -> String {
        switch language {
        case .appleScript:
            return try await MainActor.run {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error {
                    let message = error[NSAppleScript.errorMessage] as? String ?? "AppleScript failed"
                    let number = error[NSAppleScript.errorNumber] as? Int
                    if number == -1743 {
                        throw Failure(message: String(localized: "macOS blocked Agott from controlling that app. Allow it in System Settings → Privacy & Security → Automation."))
                    }
                    throw Failure(message: message)
                }
                return describe(result)
            }
        case .javaScript:
            return try await osascript(source, arguments: ["-l", "JavaScript"], timeout: timeout)
        }
    }

    /// AppleScript through `osascript`, off the main thread and really
    /// bounded by `timeout`: for quick commands to an app that may be slow to
    /// launch or not answering (in-process, NSAppleScript holds the main
    /// thread for as long as the app takes, up to two minutes).
    static func runOutOfProcess(_ source: String, timeout: TimeInterval) async throws -> String {
        try await osascript(source, arguments: [], timeout: timeout)
    }

    private static func osascript(_ source: String, arguments: [String], timeout: TimeInterval) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = arguments + ["-e", source]
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning { process.terminate(); throw Failure(message: "The script timed out.") }
            let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if process.terminationStatus != 0, err.contains("-1743") {
                throw Failure(message: String(localized: "macOS blocked Agott from controlling that app. Allow it in System Settings → Privacy & Security → Automation."))
            }
            guard process.terminationStatus == 0 else { throw Failure(message: err.isEmpty ? "osascript failed" : err) }
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    /// Turns an Apple Event descriptor into text a model can read: lists
    /// become lines, records become key: value pairs.
    @MainActor
    private static func describe(_ descriptor: NSAppleEventDescriptor?) -> String {
        guard let descriptor else { return "" }
        switch descriptor.descriptorType {
        case typeAEList:
            guard descriptor.numberOfItems > 0 else { return "{}" }
            return (1...descriptor.numberOfItems).map { describe(descriptor.atIndex($0)) }.joined(separator: "\n")
        case typeAERecord:
            guard descriptor.numberOfItems > 0 else { return "{}" }
            return (1...descriptor.numberOfItems).map { index in
                let keyword = descriptor.keywordForDescriptor(at: index)
                return "\(fourCC(keyword)): \(describe(descriptor.atIndex(index)))"
            }.joined(separator: ", ")
        case typeTrue: return "true"
        case typeFalse: return "false"
        default:
            return descriptor.stringValue ?? (descriptor.descriptorType == typeNull ? "" : "(\(fourCC(descriptor.descriptorType)))")
        }
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Apps that answer Apple Events, for the model to know what it can drive.
    @MainActor
    static func scriptableRunningApps() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> String? in
                guard let url = app.bundleURL, let bundle = Bundle(url: url),
                      bundle.object(forInfoDictionaryKey: "NSAppleScriptEnabled") as? Bool == true
                        || bundle.object(forInfoDictionaryKey: "OSAScriptingDefinition") != nil
                else { return nil }
                return app.localizedName
            }
    }
}

nonisolated struct AppleScriptTool: Tool {
    let name = "run_applescript"
    let description = """
    Run AppleScript (or JavaScript for Automation) to control the user's Mac apps directly: Music, Finder, \
    Safari, Notes, Messages, Mail, Calendar, Reminders, Shortcuts ("tell application \\"Shortcuts Events\\" to run \
    shortcut \\"Name\\""), System Events, and any scriptable app. Prefer this over clicking whenever an app is \
    scriptable. The script's result is returned. Keep scripts short; read state before changing it.
    """

    @Generable
    struct Arguments {
        @Guide(description: "The complete script")
        var script: String
        @Guide(description: "Use JavaScript for Automation instead of AppleScript")
        var javascript: Bool
        @Guide(description: "What the script does, in plain words, for the user to approve")
        var intent: String
        @Guide(description: "True if the script only reads information and changes nothing")
        var readOnly: Bool
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        // Reading is low-risk but still runs code: the user sees the script either way.
        let title = arguments.readOnly ? String(localized: "Read from your apps") : String(localized: "Run a script")
        guard await Approvals.ask(title, detail: "\(arguments.intent)\n\n\(arguments.script)") else {
            return "The user declined."
        }
        await CardBus.status(String(localized: "Running a script…"))
        do {
            let output = try await AppleScriptRunner.run(
                arguments.script, language: arguments.javascript ? .javaScript : .appleScript)
            return output.isEmpty ? "Done (no result)." : String(output.prefix(8000))
        } catch {
            return "Script error: \(error.localizedDescription)"
        }
    }
}

nonisolated struct ScriptableAppsTool: Tool {
    let name = "scriptable_apps"
    let description = "List the running apps that can be controlled with run_applescript."

    @Generable
    struct Arguments {
        @Guide(description: "Why you need the list")
        var reason: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        let apps = await AppleScriptRunner.scriptableRunningApps()
        return apps.isEmpty ? "No scriptable apps are running." : apps.joined(separator: ", ")
    }
}
#endif
