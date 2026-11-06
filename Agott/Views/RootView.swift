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
    @State private var navigator = Navigator.shared
    private var section: AppSection { navigator.section }

    var body: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            CandySidebar(section: $navigator.section)
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
/// A slim column: Agott on top, one icon per screen, and at the bottom
/// only what is happening now (music, memory) and Settings.
private struct CandySidebar: View {
    @Binding var section: AppSection
    @State private var agent = Agent.shared

    var body: some View {
        VStack(spacing: 6) {
            MascotFace(mood: agent.mood, size: 40)
                .padding(.bottom, 12)
                .help(Text(agent.mood.accessibilityName))

            GlassEffectContainer(spacing: 6) {
                VStack(spacing: 6) {
                    ForEach(AppSection.allCases) { item in
                        SidebarTile(item: item, selected: section == item) { section = item }
                    }
                }
            }

            Spacer()

            VStack(spacing: 10) {
                NowPlayingButton()
                ActivityButton { section = .memory }
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(HoverIconStyle(size: 36))
                .help(Text("Settings"))
            }
        }
        .padding(.vertical, 14)
        .frame(width: 60)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
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
            Image(systemName: item.symbol)
                .font(.system(size: 16, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(hovering ? Ink.text : Ink.muted))
                .frame(width: 40, height: 40)
                // Not interactive glass: it handles presses itself and
                // could swallow the first click on a tab.
                .glassEffect(
                    selected ? .regular.tint(Ink.spot) : (hovering ? .regular : .clear),
                    in: .rect(cornerRadius: 12))
                .frame(width: 52, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .help(Text(item.title))
        .accessibilityLabel(Text(item.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering = $0 }
        .animation(Motion.bouncy, value: selected)
        .animation(.spring(duration: 0.2), value: hovering)
    }
}

/// Memory at work, as a small ring. Open it for what and how far, and to pause.
private struct ActivityButton: View {
    var openMemory: () -> Void
    @State private var indexer = Indexer.shared
    @State private var repair = MemoryRepair.shared
    @State private var showing = false

    private var active: Bool { indexer.isRunning || indexer.isLearning || repair.note != nil }

    var body: some View {
        if active || indexer.isPaused {
            Button { showing.toggle() } label: {
                ZStack {
                    Circle().stroke(Ink.muted.opacity(0.25), lineWidth: 2.5)
                    if indexer.isPaused && !active {
                        Image(systemName: "pause.fill").font(.system(size: 10, weight: .bold))
                    } else if let progress = indexer.progress {
                        Circle()
                            .trim(from: 0, to: max(0.03, progress))
                            .stroke(Ink.spot, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(Motion.settle, value: progress)
                    } else {
                        Spinner()
                    }
                }
                .frame(width: 20, height: 20)
                .frame(width: 36, height: 36)
            }
            .buttonStyle(HoverIconStyle(size: 36))
            .help(Text(repair.note ?? indexer.statusText))
            .popover(isPresented: $showing, arrowEdge: .trailing) { details }
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(repair.note ?? indexer.statusText)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Ink.text)
                .monospacedDigit()
            if let progress = indexer.progress {
                ProgressView(value: progress).tint(Ink.spot)
            }
            HStack {
                if indexer.isPaused {
                    Button("Resume", systemImage: "play.fill") { indexer.resume() }
                } else if indexer.isRunning || indexer.isLearning {
                    Button("Pause", systemImage: "pause.fill") { indexer.pause() }
                }
                Spacer()
                Button("Open Memory") { showing = false; openMemory() }
            }
            .buttonStyle(.candy(.soft, compact: true))
        }
        .padding(14)
        .frame(width: 280)
    }
}

/// An open arc that turns, for work that cannot say how far along it is.
private struct Spinner: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(Ink.spot, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 1) * 360))
        }
    }
}

/// What is playing on Spotify or Apple Music: the cover, and the song on hover.
private struct NowPlayingButton: View {
    @State private var listener = MusicListener.shared
    @State private var showing = false

    var body: some View {
        if let play = listener.nowPlaying {
            Button { showing.toggle() } label: {
                NowPlayingArt(url: listener.artwork, size: 30)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(HoverIconStyle(size: 36))
            .help(Text("Listening to \(play.track) · \(play.artist)"))
            .popover(isPresented: $showing, arrowEdge: .trailing) {
                NowPlayingCard(play: play, artwork: listener.artwork, mood: listener.nowMood)
                    .padding(14)
                    .frame(width: 300)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }
}

#endif

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
