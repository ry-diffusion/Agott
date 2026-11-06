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
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            RootView()
                .tint(Ink.accent)
                .frame(minWidth: 860, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Ask Agott…") { Copilot.shared.beginTyping() }
                    .keyboardShortcut(.space, modifiers: [.option, .command])
                Button("Update Memory") { Indexer.shared.run() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }

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
            return
        }
        if AppSettings.shared.hasOnboarded { Copilot.shared.start() }
        // Repair what older versions wrote, then keep indexing.
        MusicListener.shared.start()
        Task(priority: .utility) { await ModelCatalog.shared.refresh() }
        Task(priority: .utility) {
            await MemoryRepair.shared.runIfNeeded()
            Indexer.shared.startAutomatic()
        }
        RemoteHost.shared.start()
        // New messages within seconds: hooks, follow-ups, what to remember.
        Notifier.start()
        MessageWatcher.shared.start()
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
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Agott") { NSApp.terminate(nil) }
    }
}
#endif
