import SwiftUI

/// Agott on the wrist: today's routines from sync, done by counting reps
/// from the wrist's motion. Works without the iPhone nearby once the iPhone
/// has handed over the sync account.
@main
struct AgottWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        RoutineSync.shared.deviceName = "Watch"
        WatchLink.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            RoutineList()
                .task { await RoutineSync.shared.sync() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await RoutineSync.shared.sync() } }
        }
    }
}
