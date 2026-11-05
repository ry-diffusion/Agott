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
    func applicationDidFinishLaunching(_ notification: Notification) {
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
        Indexer.shared.startAutomatic()
        RemoteHost.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
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
        Button(indexer.isRunning ? "Stop indexing" : "Update Memory") {
            if indexer.isRunning { indexer.stop() } else { indexer.run() }
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
