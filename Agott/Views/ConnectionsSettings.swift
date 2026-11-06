import AuthenticationServices
import SwiftUI

/// The TypeSafe key, typed in and kept in the Keychain.
struct TypeSafeKeyField: View {
    @State private var key = Jev.apiKey
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").foregroundStyle(Ink.text)
                Group {
                    if revealed { TextField("TypeSafe API key", text: $key) } else { SecureField("TypeSafe API key", text: $key) }
                }
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .onChange(of: key) { _, value in Keychain.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: Jev.keychainAccount) }
                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash.fill" : "eye.fill").foregroundStyle(Ink.muted)
                }
                .buttonStyle(.plain)
                if !key.isEmpty { Image(systemName: "checkmark.seal.fill").foregroundStyle(Ink.spot) }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.raised))
            HStack(spacing: 4) {
                Text("Jev reads each new message: whether it needs you, what to ask again, and what is worth remembering.")
                Spacer()
                if let url = URL(string: "https://typesafe.ai") { Link("Get a key", destination: url).fontWeight(.semibold) }
            }
            .font(.caption)
            .foregroundStyle(Ink.muted)
        }
    }
}

/// "When someone writes…" rules.
struct HooksEditor: View {
    @State private var store = HookStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.hooks.isEmpty {
                Text("No hooks yet. Add one to hear about the messages that matter, the moment they arrive.")
                    .font(.callout).foregroundStyle(Ink.muted)
            }
            ForEach($store.hooks) { $hook in
                HookRow(hook: $hook) { store.hooks.removeAll { $0.id == hook.id } }
            }
            HStack {
                Button("Add hook", systemImage: "plus") { store.hooks.append(Hook()) }
                if store.hooks.isEmpty {
                    Button("When anyone needs me") {
                        store.hooks.append(Hook(person: "", onlyWhenItMatters: true, action: .draftReplies))
                    }
                }
            }
            .buttonStyle(.candy(.soft, compact: true))
            if !Jev.isConfigured {
                Text("Without a TypeSafe key, “only when it needs me” falls back to messages that ask a question.")
                    .font(.caption).foregroundStyle(Ink.muted)
            }
        }
    }
}

private struct HookRow: View {
    @Binding var hook: Hook
    var remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("", isOn: $hook.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                Text("When").foregroundStyle(Ink.muted)
                TextField(String(localized: "anyone"), text: $hook.person)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ink.raised))
                    .frame(maxWidth: 180)
                Text("writes").foregroundStyle(Ink.muted)
                Spacer()
                Button(action: remove) { Image(systemName: "trash") }
                    .buttonStyle(HoverIconStyle(size: 26))
                    .help(Text("Delete hook"))
            }
            HStack(spacing: 12) {
                Toggle("Only when it needs me", isOn: $hook.onlyWhenItMatters)
                Picker("", selection: $hook.action) {
                    Text("Notify me").tag(Hook.Action.notify)
                    Text("Notify and help me reply").tag(Hook.Action.draftReplies)
                }
                .labelsHidden()
                .fixedSize()
            }
            .font(.callout)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.surface))
        .opacity(hook.enabled ? 1 : 0.6)
    }
}

/// Sign in to Spotify with OAuth2 (PKCE).
struct SpotifyConnect: View {
    @State private var account = SpotifyAccount.shared
    @State private var error: String?
    @State private var working = false
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if account.isConnected {
                HStack {
                    Label(account.displayName.map { String(localized: "Connected as \($0)") } ?? String(localized: "Connected"),
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Ink.text)
                    Spacer()
                    Button("Sign out") { account.signOut() }
                }
                Text("Agott sees what you play on any device and your recent listening.")
                    .font(.caption).foregroundStyle(Ink.muted)
            } else {
                TextField("Spotify Client ID", text: $account.clientID)
                    .font(.system(.body, design: .monospaced))
                HStack {
                    Button(working ? String(localized: "Signing in…") : String(localized: "Sign in with Spotify")) {
                        Task { await signIn() }
                    }
                    .disabled(account.clientID.isEmpty || working)
                    Spacer()
                    if let url = URL(string: "https://developer.spotify.com/dashboard") {
                        Link("Create an app", destination: url).font(.caption.weight(.semibold))
                    }
                }
                Text("In your Spotify app, add the redirect URI \(SpotifyAccount.redirectURI) and paste its Client ID here. No secret is needed.")
                    .font(.caption).foregroundStyle(Ink.muted)
                    .textSelection(.enabled)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func signIn() async {
        guard let url = account.authorizeURL() else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            let callback = try await webAuthenticationSession.authenticate(
                using: url, callbackURLScheme: SpotifyAccount.callbackScheme, preferredBrowserSession: .shared)
            try await account.finish(callback: callback)
        } catch {
            if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                self.error = error.localizedDescription
            }
        }
    }
}
