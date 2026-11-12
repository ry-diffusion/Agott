#if os(iOS) || os(watchOS)
import Foundation
import WatchConnectivity

/// The iPhone hands the Watch what it needs to sync on its own (the Worker,
/// the token and the key, never the passphrase), over the paired devices'
/// own encrypted link. After that the Watch talks to the Worker by itself.
@MainActor
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()

    private var activated = false

    func activate() {
        guard WCSession.isSupported(), !activated else { return }
        activated = true
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    #if os(iOS)
    /// Sends the current account (or that there is none) to the Watch.
    func sendAccount() {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let data = RoutineSync.shared.account.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        try? session.updateApplicationContext(["account": data])
    }
    #endif

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        guard state == .activated else { return }
        #if os(iOS)
        Task { @MainActor in self.sendAccount() }
        #else
        let data = session.receivedApplicationContext["account"] as? Data
        Task { @MainActor in self.receive(data) }
        #endif
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.sendAccount() }
    }
    #else
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let data = context["account"] as? Data
        Task { @MainActor in self.receive(data) }
    }

    private func receive(_ data: Data?) {
        guard let data else { return }
        if data.isEmpty {
            if RoutineSync.shared.isConnected { RoutineSync.shared.disconnect() }
        } else if let account = try? JSONDecoder().decode(SyncAccount.self, from: data) {
            RoutineSync.shared.use(account)
        }
    }
    #endif
}
#endif
