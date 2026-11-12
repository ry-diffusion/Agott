//
//  AgottApp.swift
//  Agott
//
//  Created by Moizes Sousa on 05/11/26.
//

import SwiftUI

@main
struct AgottApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #endif

    init() {
        Lettering.register()
        AppSync.configure()
        #if os(iOS)
        PhoneRoutines.register()
        #endif
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            Group {
                if LaunchOptions.arguments.contains("-AgottLab") { DesignLab() } else { RootView() }
            }
            .tint(Ink.accent)
            .frame(minWidth: 860, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.presented)
        .commands {
            // ⌘N starts a conversation (not a second window), and ⌘, opens
            // Settings inside the window.
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") {
                    Navigator.shared.settingsPage = nil
                    Navigator.shared.section = .chat
                    Agent.shared.newConversation()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { Navigator.shared.settingsPage = .preferences }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Ask Agott…") { Copilot.shared.beginTyping() }
                    .keyboardShortcut(.space, modifiers: [.option, .command])
                Button("Update Memory") { Indexer.shared.run() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(after: .windowArrangement) {
                OpenDesignLab()
            }
        }

        // Three zen directions to compare, live.
        Window("Design Lab", id: "design-lab") {
            DesignLab()
                .tint(Ink.accent)
                .frame(minWidth: 820, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MenuBarContent()
        } label: {
            Image(systemName: "face.smiling.inverse")
        }
        .menuBarExtraStyle(.menu)
        #else
        WindowGroup {
            RootView()
                .tint(Ink.accent)
        }
        #endif
    }
}

#if os(macOS)
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// True when the app is only the host for unit tests. It must not index
    /// or listen, or tests would write into your real memory.
    static var isTestHost: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isTestHost else { return }
        // Claude history progress is now saved only after storing; read it
        // once more from the start so nothing from before is missing.
        if !UserDefaults.standard.bool(forKey: "claudeProgressV2") {
            ClaudeHistorySource.resetProgress()
            UserDefaults.standard.set(true, forKey: "claudeProgressV2")
        }
        _ = ScreenReader.shared
        if let appearance = LaunchOptions.value("-AgottAppearance") {
            NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        if LaunchOptions.isDemo {
            // Made-up data only; nothing from this Mac is read.
            Task {
                await DemoData.seed()
                if LaunchOptions.showOverlay { Copilot.shared.showDemoOverlay() }
            }
            MusicListener.shared.showDemo(
                Play(date: .now, track: "Desleixado", artist: "KARNIVAL", album: "", app: "Spotify"),
                mood: TrackMood(mood: "playful", energy: 70, valence: 65, genre: "pop rock"))
            if LaunchOptions.arguments.contains("-AgottOffscreen") { Self.showOffscreen() }
            return
        }
        if AppSettings.shared.hasOnboarded { Copilot.shared.start() }
        // Apple's models are checked in the background, never on the main thread.
        ModelAvailability.warm()
        #if os(macOS)
        // The fast transcription model, fetched once in the background;
        // Apple's engine stands in until it is here.
        ParakeetSetup.shared.start()
        VoiceSetup.shared.start()
        // Reminders Agott brings up in its pop-up.
        if !LaunchOptions.isDemo { Nudges.shared.start() }
        #endif
        // Repair what older versions wrote, then keep indexing.
        MusicListener.shared.start()
        Task(priority: .utility) { await ModelCatalog.shared.refresh() }
        Task(priority: .utility) {
            await MemoryRepair.shared.runIfNeeded()
            // Facts learned with English verbs, rewritten in Portuguese once:
            // after the repair, which redraws the graph from the facts.
            await FactWords.migrate()
            // Every fact gets a kind, once; new ones come with theirs.
            _ = try? await MemoryStore.shared.backfillFactKinds()
            Indexer.shared.startAutomatic()
        }
        RemoteHost.shared.start()
        // Where the Mac is, so "here" means here. Asks for permission once.
        Whereabouts.shared.refresh()
        // New messages within seconds: hooks, follow-ups, what to remember.
        Notifier.start()
        // Who is who, by id, before the first question.
        Task {
            _ = try? await MemoryStore.shared.syncPeople()
            await PeopleDirectory.shared.refresh()
            await ContactPhotos.shared.refresh()
        }
        MessageWatcher.shared.start()
    }

    /// Demo screenshots without taking your focus: the window is put on
    /// screen far outside the visible area, never activated, so it can be
    /// captured by its window number.
    private static func showOffscreen() {
        Task { @MainActor in
            for _ in 0..<40 {
                if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                    window.setContentSize(NSSize(width: 1320, height: 820))
                    window.setFrameOrigin(NSPoint(x: -6000, y: 200))
                    window.orderFrontRegardless()
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !Self.isTestHost else { return }
        // Accessibility is granted outside the app; pick it up when we return.
        if !LaunchOptions.isDemo, AppSettings.shared.hasOnboarded, !Copilot.shared.keys.isActive { Copilot.shared.start() }
        // Coming back from System Settings with Full Disk Access granted:
        // read the sources that were locked out, without waiting ten minutes.
        if !LaunchOptions.isDemo, AppSettings.shared.hasOnboarded, !Indexer.shared.isRunning,
           Indexer.shared.states.values.contains(.needsPermission), Permissions.isGranted(.fullDiskAccess)
        {
            Indexer.shared.run()
        }
    }
}

private struct OpenDesignLab: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Design Lab") { openWindow(id: "design-lab") }
            .keyboardShortcut("l", modifiers: [.command, .option])
    }
}

private struct MenuBarContent: View {
    @State private var indexer = Indexer.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Ask Agott…") { Copilot.shared.beginTyping() }
        Text(indexer.statusText)
        if indexer.isPaused {
            Button("Resume indexing") { indexer.resume() }
        } else if indexer.isRunning || indexer.isLearning {
            Button("Pause indexing") { indexer.pause() }
        } else {
            Button("Update Memory") { indexer.run() }
        }
        Divider()
        Button("Open Agott") {
            NSApp.activate()
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        Button("Settings…") {
            NSApp.activate()
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            Navigator.shared.settingsPage = .preferences
        }
        Divider()
        Button("Quit Agott") { NSApp.terminate(nil) }
    }
}
#endif
