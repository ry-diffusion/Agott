import SwiftUI

/// Settings → Sync: the Worker, its token and the passphrase. The same on
/// the Mac and the iPhone; the Watch gets it from the iPhone.
struct SyncSettings: View {
    @State private var sync = RoutineSync.shared
    @State private var address = ""
    @State private var token = ""
    @State private var passphrase = ""
    @State private var connecting = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let account = sync.account {
                HStack(alignment: .firstTextBaseline) {
                    Label(account.url.host() ?? account.url.absoluteString, systemImage: "lock.icloud.fill")
                        .foregroundStyle(Ink.text)
                    Spacer()
                    if sync.isSyncing {
                        ProgressView().controlSize(.small)
                    } else if let lastSync = sync.lastSync {
                        Text("Synced \(lastSync.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(Ink.muted)
                    }
                }
                Text("Routines, the days you did them and your API keys are encrypted on this device with your passphrase. The Worker only stores what it cannot read.")
                    .font(.caption).foregroundStyle(Ink.muted)
                if let problem = sync.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button("Sync now") { Task { await sync.sync() } }.disabled(sync.isSyncing)
                    Button("Disconnect", role: .destructive) { sync.disconnect() }
                }
                .controlSize(.small)
            } else {
                TextField("Worker address (https://…workers.dev)", text: $address)
                    .textContentType(.URL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                SecureField("Token", text: $token)
                SecureField("Passphrase", text: $passphrase)
                Text("Deploy the Worker in sync-worker (see the README), then type its address, your token and a passphrase. Use the same passphrase on every device; it never leaves them.")
                    .font(.caption).foregroundStyle(Ink.muted)
                if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button(connecting ? String(localized: "Connecting…") : String(localized: "Connect")) { Task { await connect() } }
                        .disabled(connecting || !canConnect)
                    if connecting { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    private var url: URL? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text.contains("://") ? text : "https://" + text), url.scheme == "https" || url.host() == "localhost" else {
            return nil
        }
        return url
    }

    private var canConnect: Bool {
        url != nil && token.trimmingCharacters(in: .whitespaces).count >= 32 && passphrase.count >= 8
    }

    private func connect() async {
        guard let url else { return }
        connecting = true
        failure = nil
        defer { connecting = false }
        do {
            try await sync.connect(url: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines), passphrase: passphrase)
            passphrase = ""
            token = ""
            AppSync.connected()
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// The app's side of sync: which keys travel, and what to do when they arrive.
enum AppSync {
    static func configure() {
        let sync = RoutineSync.shared
        #if os(macOS)
        sync.deviceName = "Mac"
        #else
        sync.deviceName = "iPhone"
        #endif
        sync.localKeys = {
            var values: [String: String] = [:]
            for account in KeysRecord.accounts {
                if let value = Keychain.get(account), !value.isEmpty { values[account] = value }
            }
            return values
        }
        sync.applyKeys = { values in
            for (account, value) in values where KeysRecord.accounts.contains(account) && !value.isEmpty {
                guard Keychain.get(account) != value else { continue }
                if account == "opencode-api-key" { AppSettings.shared.apiKey = value } else { Keychain.set(value, for: account) }
            }
        }
    }

    /// Just connected: what this device has goes up.
    static func connected() {
        #if os(macOS)
        Nudges.shared.publishAll()
        // The Mac is where keys are typed: they win the first time.
        RoutineSync.shared.keysChanged()
        #endif
    }
}
