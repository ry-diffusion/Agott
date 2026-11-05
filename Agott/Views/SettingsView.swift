import SwiftUI

struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var testResult: String?
    @State private var testing = false
    @State private var tick = 0

    var body: some View {
        Form {
            Section("Brain") {
                Picker("Model", selection: $settings.provider) {
                    ForEach(ModelProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                Text(settings.provider.detail).font(.caption).foregroundStyle(Ink.muted)
                if settings.provider == .openCode {
                    APIKeyField()
                    TextField("Endpoint", text: $settings.baseURL)
                    TextField("Model", text: $settings.modelName)
                }
                if !ModelHub.isAvailable(settings.provider) {
                    Label("Not available right now. Agott will use \(ModelHub.resolved().title).", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.caption)
                }
                HStack {
                    Button(testing ? "Testing…" : "Test") { Task { await test() } }.disabled(testing)
                    if let testResult { Text(testResult).font(.caption).foregroundStyle(Ink.muted).lineLimit(2) }
                }
            }

            Section("Learning about you") {
                Picker("Model that reads your messages", selection: $settings.learningProvider) {
                    ForEach(ModelProvider.allCases) { Text($0.title).tag($0) }
                }
                if settings.learningProvider == .openCode {
                    Stepper(value: $settings.contextTokens, in: 16_000...1_000_000, step: 16_000) {
                        Text("Context window: \(settings.contextTokens.formatted()) tokens")
                    }
                    VStack(alignment: .leading) {
                        Text("Fill per batch: \(Int(settings.batchFill * 100))%")
                        Slider(value: $settings.batchFill, in: 0.1...0.8, step: 0.05)
                    }
                    Text("Moments are packed into one request until they fill this share of the context. About \(Int(Double(settings.contextTokens) * settings.batchFill * 3.3 / 1000))k characters per batch.")
                        .font(.caption).foregroundStyle(Ink.muted)
                } else {
                    Text("Apple's models have small windows, so batches stay small. On this device, nothing leaves your Mac.")
                        .font(.caption).foregroundStyle(Ink.muted)
                }
            }

            Section("You") {
                TextField("Your name", text: $settings.myName)
                Picker("Speech language", selection: $settings.speechLocale) {
                    Text("Português (Brasil)").tag("pt-BR")
                    Text("English (US)").tag("en-US")
                }
            }

            #if os(macOS)
            Section("Keys") {
                Picker("Hold to ask Agott", selection: $settings.askKey) {
                    ForEach(HoldKey.allCases) { Text($0.title).tag($0) }
                }
                Picker("Hold to dictate", selection: $settings.dictateKey) {
                    ForEach(HoldKey.allCases) { Text($0.title).tag($0) }
                }
                Text("Tap the ask key to type instead of talking. Dictation is cleaned up and typed where your cursor is.")
                    .font(.caption).foregroundStyle(Ink.muted)
            }

            Section("Using your Mac") {
                Toggle("Look at the screen when I ask from the overlay", isOn: $settings.useScreenContext)
                Toggle("Autopilot: act without asking first", isOn: $settings.autopilot)
                if settings.autopilot {
                    Label("Agott will click, type, run scripts and send without confirmation.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                }
            }

            Section("iPhone") {
                IPhonePairingSection()
            }
            #endif

            Section("Permissions") {
                ForEach(Permissions.Kind.relevant) { kind in
                    PermissionRow(kind: kind, tick: tick)
                }
                Button("Check again") { tick += 1 }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Ink.canvas)
        .tint(Ink.spot)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 600)
        #endif
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let answer = try await ModelHub.text("Say hi in five words.", instructions: "You are Agott.")
            testResult = "✓ \(answer)"
        } catch {
            testResult = error.localizedDescription
        }
    }
}

struct PermissionRow: View {
    var kind: Permissions.Kind
    var tick: Int
    @State private var granted = false

    var body: some View {
        HStack {
            Image(systemName: kind.symbol).frame(width: 22)
            VStack(alignment: .leading) {
                Text(kind.title)
                Text(kind.reason).font(.caption).foregroundStyle(Ink.muted)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Allow") {
                    Task {
                        await Permissions.request(kind)
                        granted = Permissions.isGranted(kind)
                    }
                }
            }
        }
        .task(id: tick) { granted = Permissions.isGranted(kind) }
    }
}

#if os(macOS)
private struct IPhonePairingSection: View {
    @State private var host = RemoteHost.shared

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pairing code").font(.caption).foregroundStyle(Ink.muted)
                Text(host.pairingCode.map { String($0) }.joined(separator: " "))
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Label(host.isRunning ? "Visible on your network" : "Off",
                      systemImage: host.isRunning ? "dot.radiowaves.left.and.right" : "wifi.slash")
                    .foregroundStyle(host.isRunning ? .green : .secondary)
                if !host.connectedDevices.isEmpty {
                    Text("Connected: \(host.connectedDevices.joined(separator: ", "))").font(.caption)
                }
                Button("New code") { host.regenerateCode() }.controlSize(.small)
            }
        }
        Text("Open Agott on your iPhone, pick this Mac and enter the code. Your phone talks to Agott here, with all your memory and apps.")
            .font(.caption).foregroundStyle(Ink.muted)
        if let problem = host.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
    }
}
#endif
