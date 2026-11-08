import SwiftUI

#if os(macOS)

/// Settings inside the window, like a notebook app's: the sidebar turns into
/// the list of pages under your name, and each page is a serif title over
/// quiet cards of rows, each with what it does and its switch.
enum SettingsPage: String, CaseIterable, Identifiable {
    case preferences, models, learning, voice, connections, permissions

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .preferences: "Preferences"
        case .models: "Models"
        case .learning: "Memory"
        case .voice: "Voice and keys"
        case .connections: "Connections"
        case .permissions: "Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .preferences: "slider.horizontal.3"
        case .models: "cpu"
        case .learning: "brain.head.profile"
        case .voice: "keyboard"
        case .connections: "square.grid.2x2"
        case .permissions: "lock.shield"
        }
    }
}

/// The sidebar while Settings is open: back, who you are, the pages.
struct SettingsSidebar: View {
    @State private var navigator = Navigator.shared
    @State private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Spacer().frame(width: WindowBar.afterButtons)
                Button { navigator.settingsPage = nil } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(HoverIconStyle(size: 28))
                .keyboardShortcut(.cancelAction)
                .tip("Back", edge: .bottom)
                Spacer()
            }
            .font(.system(size: 14))
            .frame(height: WindowBar.height)

            VStack(spacing: 6) {
                InitialsAvatar(text: settings.myName.isEmpty ? "?" : settings.myName, size: 48)
                Text(settings.myName.isEmpty ? String(localized: "You") : settings.myName)
                    .font(Lettering.display(20, relativeTo: .title3))
                    .foregroundStyle(Ink.text)
                Text(ModelHub.resolved().title)
                    .font(.caption)
                    .foregroundStyle(Ink.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 1) {
                ForEach(SettingsPage.allCases) { page in
                    Button { navigator.settingsPage = page } label: {
                        HStack(spacing: 9) {
                            Image(systemName: page.symbol).font(.system(size: 13)).frame(width: 18)
                                .foregroundStyle(navigator.settingsPage == page ? Ink.text : Ink.muted)
                            Text(page.title).font(.system(size: 13.5)).foregroundStyle(Ink.text)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Ink.text.opacity(navigator.settingsPage == page ? 0.09 : 0)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            Spacer()
        }
        .background { SidebarMaterial().ignoresSafeArea() }
    }
}

/// One page of Settings.
struct SettingsPageView: View {
    var page: SettingsPage
    @State private var settings = AppSettings.shared
    @State private var testing = false
    @State private var testResult: String?
    @State private var tick = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(page.title)
                    .font(Lettering.display(34, relativeTo: .largeTitle))
                    .foregroundStyle(Ink.text)
                    .padding(.top, 8)
                content
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, WindowBar.height)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .background(Ink.canvas)
        .toggleStyle(.switch)
        .tint(Ink.spot)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .preferences:
            SettingsCard {
                SettingsRow(symbol: "person", title: "Your name", detail: "How Agott calls you and finds you in your chats.") {
                    TextField("", text: $settings.myName).textFieldStyle(.roundedBorder).frame(width: 200)
                }
                SettingsRow(symbol: "list.bullet.indent", title: "Show the steps", detail: "What Agott did and thought on the way to each reply.") {
                    Toggle("", isOn: $settings.showSteps).labelsHidden()
                }
                SettingsRow(symbol: "eye.slash", title: "Hide names", detail: "People and groups show as Person 12, for screenshots and screen sharing.") {
                    Toggle("", isOn: $settings.hideNames).labelsHidden()
                }
            }
            SettingsSection(title: "Using your Mac")
            SettingsCard {
                SettingsRow(symbol: "rectangle.on.rectangle", title: "Look at the screen", detail: "When you ask from the overlay, Agott sees the app you were using.") {
                    Toggle("", isOn: $settings.useScreenContext).labelsHidden()
                }
                SettingsRow(symbol: "music.note", title: "Notice your music", detail: "What you play on Spotify or Apple Music, to sense your mood.") {
                    Toggle("", isOn: $settings.listenToMusic).labelsHidden()
                }
                SettingsRow(symbol: "bolt", title: "Autopilot", detail: "Click, type, run scripts and send without asking first.") {
                    Toggle("", isOn: $settings.autopilot).labelsHidden()
                }
                SettingsRow(symbol: "bell", title: "Set reminders for me", detail: "When a message sets up a call, a plan or a deadline, Agott adds it to Reminders with an alert.") {
                    Toggle("", isOn: $settings.autoReminders).labelsHidden()
                }
            }
        case .models:
            SettingsCard {
                SettingsRow(symbol: "bubble.left", title: "Chat model", verbatim: settings.provider.detail) {
                    ModelPickerRow(title: "", provider: $settings.provider, model: $settings.modelName, allowsSame: false)
                        .labelsHidden()
                }
                SettingsRow(symbol: "checkmark.seal", title: "Try it", verbatim: testResult ?? String(localized: "Sends a tiny message to the chat model.")) {
                    Button(testing ? "Testing…" : "Test") { Task { await test() } }
                        .buttonStyle(.candy(.soft, compact: true))
                        .disabled(testing)
                }
            }
            if settings.provider == .openCode || settings.learningProvider == .openCode {
                SettingsSection(title: "OpenCode Go")
                SettingsCard { APIKeyField().padding(14) }
            }
            SettingsSection(title: "TypeSafe")
            SettingsCard { TypeSafeKeyField().padding(14) }
        case .learning:
            SettingsCard {
                SettingsRow(symbol: "sparkles", title: "Learn after each reading", detail: "Agott reads new moments and learns about you and your people.") {
                    Toggle("", isOn: $settings.autoLearn).labelsHidden()
                }
                SettingsRow(symbol: "cpu", title: "Model that reads your messages", detail: "Used only for learning, never for chat.") {
                    ModelPickerRow(title: "", provider: $settings.learningProvider, model: $settings.learningModelName, allowsSame: true)
                        .labelsHidden()
                }
                SettingsRow(symbol: "waveform", title: "Listen to voice notes", detail: "WhatsApp voice notes are transcribed on this Mac and remembered with the conversation.") {
                    Toggle("", isOn: $settings.transcribeVoiceNotes).labelsHidden()
                }
                SettingsRow(symbol: "photo", title: "Look at photos", detail: "What is in WhatsApp photos and any text in them, read on this Mac.") {
                    Toggle("", isOn: $settings.describePhotos).labelsHidden()
                }
                if settings.learningProvider == .openCode {
                    SettingsRow(symbol: "text.word.spacing", title: "Context window",
                                detail: "\(settings.contextTokens.formatted()) tokens, \(Int(settings.batchFill * 100))% per batch") {
                        Stepper("", value: $settings.contextTokens, in: 16_000...1_000_000, step: 16_000).labelsHidden()
                    }
                }
            }
        case .voice:
            SettingsCard {
                SettingsRow(symbol: "waveform", title: "Hold to ask", detail: "Hold, speak, let go: Agott answers over what you are doing. Tap it to type and send screenshots instead.") {
                    Picker("", selection: $settings.askKey) { ForEach(HoldKey.allCases) { Text($0.title).tag($0) } }
                        .labelsHidden().fixedSize()
                }
                SettingsRow(symbol: "text.cursor", title: "Shortcut to type", detail: "Opens Agott over any app: type a question, send a screenshot of a window or part of the screen.") {
                    Picker("", selection: $settings.textShortcut) {
                        ForEach(TextShortcut.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow(symbol: "keyboard", title: "Hold to dictate", detail: "What you say is cleaned up and typed where your cursor is.") {
                    Picker("", selection: $settings.dictateKey) { ForEach(HoldKey.allCases) { Text($0.title).tag($0) } }
                        .labelsHidden().fixedSize()
                }
                SettingsRow(symbol: "waveform.badge.mic", title: "Speech engine",
                            detail: "Parakeet is much faster and better with Portuguese and English mixed. Voice notes are only read with it; until it is downloaded, dictation uses Apple's engine.") {
                    HStack(spacing: 8) {
                        if settings.speechEngine == SpeechEngine.parakeet.rawValue {
                            ParakeetStatus()
                        }
                        Picker("", selection: $settings.speechEngine) {
                            ForEach(SpeechEngine.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                SettingsRow(symbol: "wand.and.stars", title: "Clean up dictation",
                            detail: "Removes filler words and false starts and applies your own corrections before typing. Off types exactly what was heard.") {
                    Picker("", selection: $settings.dictationCleanup) {
                        Text("Off").tag("off")
                        Text("On this Mac").tag("apple")
                        let models = ModelCatalog.shared.models.filter(\.isSupported).sorted { $0.name < $1.name }
                        if !models.isEmpty {
                            Divider()
                            ForEach(models) { Text(verbatim: $0.name).tag($0.id) }
                        }
                        // A model chosen before the catalog loaded stays selectable.
                        if !["off", "apple"].contains(settings.dictationCleanup),
                           !models.contains(where: { $0.id == settings.dictationCleanup }) {
                            Text(verbatim: settings.dictationCleanup).tag(settings.dictationCleanup)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow(symbol: "globe", title: "Speech language",
                            detail: "The main language you speak in, for dictation and voice notes. Automatic lets Parakeet tell; Portuguese with English words mixed in works either way.") {
                    Picker("", selection: $settings.speechLocale) {
                        ForEach(AppSettings.speechLanguages, id: \.self) { code in
                            Text(verbatim: AppSettings.speechLanguageName(code)).tag(code)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        case .connections:
            SettingsSection(title: "Spotify")
            SettingsCard { SpotifyConnect().padding(14) }
            SettingsSection(title: "iPhone")
            SettingsCard { VStack(alignment: .leading, spacing: 8) { IPhonePairingSection() }.padding(14) }
            SettingsSection(title: "Hooks")
            SettingsCard { HooksEditor().padding(14) }
            SettingsSection(title: "Publishing")
            SettingsCard {
                SettingsRow(symbol: "globe", title: "Site address", detail: "Where published documents go, on your Cloudflare account.") {
                    TextField("", text: $settings.publishDomain).textFieldStyle(.roundedBorder).frame(width: 200)
                }
                SettingsRow(symbol: "server.rack", title: "Worker name", detail: "Uses wrangler's own login (run “npx wrangler login” once).") {
                    TextField("", text: $settings.publishWorker).textFieldStyle(.roundedBorder).frame(width: 200)
                }
            }
        case .permissions:
            SettingsCard {
                ForEach(Permissions.Kind.relevant) { kind in
                    PermissionRow(kind: kind, tick: tick).padding(.horizontal, 14).padding(.vertical, 10)
                    if kind != Permissions.Kind.relevant.last { Divider().overlay(Ink.hairline) }
                }
            }
            Button("Check again") { tick += 1 }.buttonStyle(.candy(.soft, compact: true))
        }
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

/// A small heading between cards.
private struct SettingsSection: View {
    var title: LocalizedStringKey
    var body: some View { SectionHeading(title: title) }
}
#endif

/// A small heading between cards, the same on every page.
struct SectionHeading: View {
    var title: LocalizedStringKey
    var body: some View {
        Text(title).font(.headline).foregroundStyle(Ink.text).padding(.top, 6)
    }
}

/// Rows in a quiet card, separated by hairlines.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    row
                    if index < rows.count - 1 {
                        Rectangle().fill(Ink.hairline).frame(height: 1).padding(.leading, 56)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .quietSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// An icon in a tile, what the setting is and does, and its control.
struct SettingsRow<Control: View>: View {
    var symbol: String
    var title: LocalizedStringKey
    var detail: Text
    var control: Control

    init(symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey, @ViewBuilder control: () -> Control) {
        self.symbol = symbol
        self.title = title
        self.detail = Text(detail)
        self.control = control()
    }

    /// For text that is already words, not a key to translate (a model's description).
    init(symbol: String, title: LocalizedStringKey, verbatim detail: String, @ViewBuilder control: () -> Control) {
        self.symbol = symbol
        self.title = title
        self.detail = Text(verbatim: detail)
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Ink.muted)
                .frame(width: 30, height: 30)
                .quietSurface(RoundedRectangle(cornerRadius: 8, style: .continuous), fill: Ink.raised)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(Ink.text)
                detail.font(.callout).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

#if os(macOS)
/// Where the Parakeet download stands: a progress ring while it comes in,
/// a way to try again when it failed.
private struct ParakeetStatus: View {
    @State private var setup = ParakeetSetup.shared

    var body: some View {
        switch setup.state {
        case .ready:
            EmptyView()
        case .downloading(let fraction):
            HStack(spacing: 6) {
                ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small)
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.callout).monospacedDigit().foregroundStyle(Ink.muted)
            }
            .help(Text(setup.notice ?? ""))
        case .missing, .failed:
            Button("Download") { setup.start() }
                .buttonStyle(.candy(.soft, compact: true))
                .help({ if case .failed(let reason) = setup.state { Text(reason) } else { Text("Downloads Parakeet from Hugging Face, once.") } }())
        }
    }
}
#endif
