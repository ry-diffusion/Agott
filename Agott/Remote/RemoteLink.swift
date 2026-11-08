import CryptoKit
import Foundation
import Network
import Observation
import OSLog

/// iPhone ↔ Mac, over the local network.
///
/// The Mac is where Agott's memory, screen and hands are, so the iPhone does
/// not try to be a second Agott: it is a remote for the one on the Mac. Ask
/// from the phone, and the Mac answers with everything it knows, streaming the
/// reply, cards and approval requests back as they happen.
///
/// Discovery is Bonjour (`_agott._tcp`). The channel is TLS with a pre-shared
/// key derived from a six-digit pairing code shown on the Mac, so nothing on
/// the network can listen in or impersonate either side without the code.
nonisolated enum RemoteMessage: Codable, Sendable {
    // Phone → Mac
    case hello(device: String)
    case ask(text: String, lookAtScreen: Bool)
    case cancel
    case approve(id: UUID, allow: Bool)
    case newConversation
    // Mac → Phone
    case welcome(macName: String)
    case state(turns: [Turn], mood: Mood, status: String?, busy: Bool)
}

nonisolated enum RemoteWire {
    static let serviceType = "_agott._tcp"

    /// TLS 1.2 PSK, keyed from the pairing code.
    static func parameters(code: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = SymmetricKey(data: Data(code.utf8))
        let derived = HMAC<SHA256>.authenticationCode(for: Data("agott-remote-v1".utf8), using: key)
        let keyData = Data(derived).withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("agott".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions, keyData as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    /// Length-prefixed JSON frames.
    static func send(_ message: RemoteMessage, on connection: NWConnection) {
        guard let body = try? JSONEncoder().encode(message) else { return }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    static func receive(on connection: NWConnection, _ handler: @escaping @Sendable (RemoteMessage) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, done, error in
            guard error == nil, !done, let header, header.count == 4 else { return }
            let length = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
            guard length > 0, length < 32_000_000 else { connection.cancel(); return }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                guard error == nil, let body else { return }
                if let message = try? JSONDecoder().decode(RemoteMessage.self, from: body) { handler(message) }
                receive(on: connection, handler)
            }
        }
    }
}

#if os(macOS)
import AppKit

/// The Mac side: advertises itself and serves paired phones.
@Observable
final class RemoteHost {
    static let shared = RemoteHost()

    private(set) var isRunning = false
    private(set) var connectedDevices: [String] = []
    private(set) var problem: String?

    /// Six digits, kept until you ask for a new one.
    private(set) var pairingCode: String

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [ObjectIdentifier: (NWConnection, String)] = [:]
    @ObservationIgnored private var pushPending = false
    @ObservationIgnored private let log = Logger(subsystem: "br.com.zesmoi.Agott", category: "remote")

    private init() {
        if let saved = Keychain.get("remote-pairing-code"), saved.count == 6 {
            pairingCode = saved
        } else {
            pairingCode = Self.newCode()
            Keychain.set(pairingCode, for: "remote-pairing-code")
        }
    }

    private static func newCode() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }

    func regenerateCode() {
        pairingCode = Self.newCode()
        Keychain.set(pairingCode, for: "remote-pairing-code")
        stop()
        start()
    }

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: RemoteWire.parameters(code: pairingCode))
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: RemoteWire.serviceType)
            listener.stateUpdateHandler = { state in
                Task { @MainActor in
                    switch state {
                    case .ready: RemoteHost.shared.isRunning = true; RemoteHost.shared.problem = nil
                    case .failed(let error): RemoteHost.shared.problem = error.localizedDescription; RemoteHost.shared.isRunning = false
                    case .cancelled: RemoteHost.shared.isRunning = false
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { connection in
                Task { @MainActor in RemoteHost.shared.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
            observeAgent()
        } catch {
            problem = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for (connection, _) in connections.values { connection.cancel() }
        connections = [:]
        connectedDevices = []
        isRunning = false
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = (connection, "iPhone")
        connection.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .ready:
                    RemoteWire.send(.welcome(macName: Host.current().localizedName ?? "Mac"), on: connection)
                    RemoteHost.shared.push(to: connection)
                case .failed, .cancelled:
                    RemoteHost.shared.connections.removeValue(forKey: key)
                    RemoteHost.shared.refreshDevices()
                default: break
                }
            }
        }
        RemoteWire.receive(on: connection) { message in
            Task { @MainActor in RemoteHost.shared.handle(message, from: key) }
        }
        connection.start(queue: .main)
    }

    private func handle(_ message: RemoteMessage, from key: ObjectIdentifier) {
        switch message {
        case .hello(let device):
            if let (connection, _) = connections[key] { connections[key] = (connection, device) }
            refreshDevices()
        case .ask(let text, let look):
            Agent.shared.send(text, lookAtScreen: look)
        case .cancel:
            Agent.shared.cancel()
        case .approve(let id, let allow):
            Approvals.shared.answer(id, allow: allow)
        case .newConversation:
            Agent.shared.newConversation()
        case .welcome, .state:
            break
        }
    }

    private func refreshDevices() {
        connectedDevices = connections.values.map(\.1)
    }

    /// Pushes state whenever the conversation changes, at most ~12 times a
    /// second while a reply streams.
    private func observeAgent() {
        withObservationTracking {
            let agent = Agent.shared
            _ = agent.turns
            _ = agent.mood
            _ = agent.status
            _ = agent.isBusy
        } onChange: {
            Task { @MainActor in
                RemoteHost.shared.schedulePush()
                RemoteHost.shared.observeAgent()
            }
        }
    }

    private func schedulePush() {
        guard !pushPending, !connections.isEmpty else { return }
        pushPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            pushPending = false
            for (connection, _) in connections.values { push(to: connection) }
        }
    }

    private func push(to connection: NWConnection) {
        let agent = Agent.shared
        // The phone has no people directory: names are filled in here (or
        // hidden as "Person 12"), so it never shows a raw <e id=…/> tag.
        let hidden = AppSettings.shared.hideNames
        let turns = agent.turns.suffix(40).map { turn -> Turn in
            var turn = turn
            turn.text = EntityText.plain(turn.text, hidden: hidden)
            return turn
        }
        RemoteWire.send(
            .state(turns: turns, mood: agent.mood, status: agent.status, busy: agent.isBusy),
            on: connection)
    }
}
#endif

/// The phone side: finds Macs running Agott and talks to one.
@Observable
final class RemoteMac {
    static let shared = RemoteMac()

    struct Found: Identifiable, Hashable {
        var name: String
        var endpoint: NWEndpoint
        var id: String { name }
    }

    enum Link: Equatable { case idle, connecting, connected, failed(String) }

    private(set) var found: [Found] = []
    private(set) var link: Link = .idle
    private(set) var macName: String?
    private(set) var turns: [Turn] = []
    private(set) var mood: Mood = .idle
    private(set) var status: String?
    private(set) var isBusy = false

    var pairingCode: String {
        get { Keychain.get("remote-client-code") ?? "" }
        set { Keychain.set(newValue, for: "remote-client-code") }
    }

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var connection: NWConnection?

    private init() {}

    func browse() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: RemoteWire.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { results, _ in
            let found = results.compactMap { result -> Found? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return Found(name: name, endpoint: result.endpoint)
            }
            Task { @MainActor in
                RemoteMac.shared.found = found
                // Reconnect to the last Mac automatically.
                if RemoteMac.shared.link == .idle,
                   let last = UserDefaults.standard.string(forKey: "remote-last-mac"),
                   let match = found.first(where: { $0.name == last }),
                   !RemoteMac.shared.pairingCode.isEmpty
                {
                    RemoteMac.shared.connect(to: match)
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func connect(to mac: Found, code: String? = nil) {
        if let code { pairingCode = code }
        guard pairingCode.count == 6 else { link = .failed(String(localized: "Enter the six-digit code shown on your Mac.")); return }
        connection?.cancel()
        link = .connecting
        let connection = NWConnection(to: mac.endpoint, using: RemoteWire.parameters(code: pairingCode))
        connection.stateUpdateHandler = { state in
            Task { @MainActor in
                let remote = RemoteMac.shared
                switch state {
                case .ready:
                    remote.link = .connected
                    UserDefaults.standard.set(mac.name, forKey: "remote-last-mac")
                    RemoteWire.send(.hello(device: Self.deviceName), on: connection)
                case .failed(let error):
                    remote.link = .failed(error.localizedDescription)
                case .waiting(let error):
                    // A wrong code shows up as a TLS handshake failure here.
                    remote.link = .failed(String(localized: "Could not connect: \(error.localizedDescription). Check the code."))
                case .cancelled:
                    if remote.link == .connected { remote.link = .idle }
                default:
                    break
                }
            }
        }
        RemoteWire.receive(on: connection) { message in
            Task { @MainActor in RemoteMac.shared.handle(message) }
        }
        connection.start(queue: .main)
        self.connection = connection
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        link = .idle
    }

    private func handle(_ message: RemoteMessage) {
        switch message {
        case .welcome(let name):
            macName = name
        case .state(let turns, let mood, let status, let busy):
            self.turns = turns
            self.mood = mood
            self.status = status
            self.isBusy = busy
        default:
            break
        }
    }

    func send(_ message: RemoteMessage) {
        guard let connection, link == .connected else { return }
        RemoteWire.send(message, on: connection)
    }

    nonisolated static var deviceName: String {
        #if os(iOS)
        "iPhone"
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }
}
