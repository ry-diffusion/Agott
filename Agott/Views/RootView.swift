import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case chat, people, memory, graph, you

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .chat: "Chat"
        case .people: "People"
        case .memory: "Memory"
        case .graph: "Graph"
        case .you: "You"
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right.fill"
        case .people: "heart.fill"
        case .memory: "brain.head.profile.fill"
        case .graph: "point.3.filled.connected.trianglepath.dotted"
        case .you: "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .chat: Ink.pink
        case .people: Color(.sRGB, red: 1.0, green: 0.38, blue: 0.48)
        case .memory: Ink.violet
        case .graph: Ink.sky
        case .you: Ink.mint
        }
    }
}

struct RootView: View {
    @State private var settings = AppSettings.shared
    @State private var section: AppSection = LaunchOptions.section ?? .chat

    var body: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            CandySidebar(section: $section)
            Group {
                switch section {
                case .chat: ChatView()
                case .people: PeopleView()
                case .memory: MemoryView()
                case .graph: GraphView()
                case .you: YouView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            .id(section)
            .overlay(alignment: .top) {
                IndexingPill { section = .memory }
                    .padding(.top, 10)
            }
        }
        .background(Ink.canvas)
        .tint(Ink.spot)
        .animation(Motion.settle, value: section)
        .sheet(isPresented: Binding(get: { LaunchOptions.isDemo ? LaunchOptions.showOnboarding : !settings.hasOnboarded }, set: { _ in })) {
            OnboardingView()
        }
        #else
        TabView {
            Tab("Mac", systemImage: "laptopcomputer") {
                NavigationStack { RemoteChatView() }
            }
            Tab("Chat", systemImage: "bubble.left.and.bubble.right.fill") {
                NavigationStack { ChatView() }
            }
            Tab("Settings", systemImage: "gearshape.fill") {
                NavigationStack { SettingsView().navigationTitle(Text("Settings")) }
            }
        }
        .tint(Ink.spot)
        #endif
    }
}

#if os(macOS)
/// A floating column of sweets: one per screen, the mascot on top.
private struct CandySidebar: View {
    @Binding var section: AppSection
    @State private var agent = Agent.shared
    @State private var indexer = Indexer.shared

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                MascotAvatar(size: 52)
                MuseFace(mood: agent.mood, size: 22)
                    .offset(x: 6, y: 4)
            }
            .padding(.bottom, 10)
            .help(Text(agent.mood.accessibilityName))

            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    ForEach(AppSection.allCases) { item in
                        SidebarTile(item: item, selected: section == item) { section = item }
                    }
                }
            }

            Spacer()

            if indexer.isRunning {
                ProgressView().controlSize(.small).help(Text("Updating memory…"))
            }
            SettingsLink {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Ink.text)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(PressScale())
            .help(Text("Settings"))
        }
        .padding(.vertical, 16)
        .frame(width: 76)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(.leading, 10)
        .padding(.vertical, 10)
        .padding(.top, 28)
    }
}

private struct SidebarTile: View {
    var item: AppSection
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: item.symbol)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.text))
                    .frame(width: 46, height: 46)
                    .glassEffect(
                        selected ? .regular.tint(Ink.spot).interactive() : (hovering ? .regular.interactive() : .clear.interactive()),
                        in: .rect(cornerRadius: 14))
                Text(item.title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(selected ? Ink.text : Ink.muted)
            }

        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .animation(Motion.bouncy, value: selected)
        .animation(.spring(duration: 0.2), value: hovering)
    }
}
#endif

/// What memory is doing, visible from every screen. Tap to open Memory.
struct IndexingPill: View {
    var open: () -> Void
    @State private var indexer = Indexer.shared

    var body: some View {
        if indexer.isRunning || indexer.isLearning {
            Button(action: open) {
                HStack(spacing: 8) {
                    if let progress = indexer.progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(Ink.spot)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(indexer.statusText)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Ink.text)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(PressScale())
            .help(Text("Open Memory"))
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(Motion.settle, value: indexer.statusText)
        }
    }
}

/// First run: who Agott is, the key, and the permissions it needs.
struct OnboardingView: View {
    @State private var settings = AppSettings.shared
    @State private var tick = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                Ink.paper
                Screentone(color: Ink.spot.opacity(0.7), spacing: 7, from: 0.95, to: 0)
                Image("Mascot")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(.horizontal, 6)
                VStack {
                    SpeechBubble(text: "Oi!")
                        .padding(.top, 40)
                    Spacer()
                }
            }
            .frame(width: 250)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Meet Agott").font(Lettering.display(34, relativeTo: .largeTitle)).foregroundStyle(Ink.text)
                    Text("Your self-hosted muse. It remembers your conversations, sees your screen and uses your Mac — all on your machine, with the model you choose.")
                        .foregroundStyle(Ink.muted)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Picker("Model", selection: $settings.provider) {
                        ForEach(ModelProvider.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if settings.provider == .openCode {
                        APIKeyField()
                    }
                    TextField("Your name", text: $settings.myName)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.raised))
                }
                .panel(padding: 14)

                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Permissions.Kind.relevant) { PermissionRow(kind: $0, tick: tick) }
                    }
                }
                .frame(minHeight: 200, maxHeight: .infinity)

                Text("Agott reads your WhatsApp, iMessage and Claude history into a private database on this Mac. Only the passages a question needs are sent to the model you picked.")
                    .font(.caption).foregroundStyle(Ink.muted)

                HStack {
                    Button("Check again") { tick += 1 }
                        .buttonStyle(.candy(.soft))
                    Spacer()
                    Button {
                        settings.hasOnboarded = true
                        Indexer.shared.run()
                        #if os(macOS)
                        Copilot.shared.start()
                        #endif
                        dismiss()
                    } label: {
                        Label("Start remembering", systemImage: "sparkles")
                    }
                    .buttonStyle(.candy)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(26)
        }
        .frame(width: 820, height: 680)
        .background(Ink.canvas)
        .tint(Ink.spot)
    }
}

/// Where you type your OpenCode Go key. It goes straight to the Keychain.
struct APIKeyField: View {
    @State private var settings = AppSettings.shared
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").foregroundStyle(Ink.text)
                Group {
                    if revealed {
                        TextField("OpenCode Go API key", text: $settings.apiKey)
                    } else {
                        SecureField("OpenCode Go API key", text: $settings.apiKey)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash.fill" : "eye.fill").foregroundStyle(Ink.muted)
                }
                .buttonStyle(.plain)
                .help(Text("Show or hide the key"))
                if settings.hasAPIKey {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Ink.spot)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.raised))
            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                Text("Saved in your Keychain. Never leaves this Mac except to talk to OpenCode.")
                Spacer()
                if let url = URL(string: "https://opencode.ai/zen") {
                    Link("Get your key", destination: url).fontWeight(.semibold)
                }
            }
            .font(.caption)
            .foregroundStyle(Ink.muted)
        }
    }
}

/// A speech balloon with lettering, for the mascot.
struct SpeechBubble: View {
    var text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(Lettering.display(20, relativeTo: .title3))
            .foregroundStyle(Ink.faceInk)
            .balloon(.bottom, fill: Ink.paper, padding: EdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18))
    }
}
