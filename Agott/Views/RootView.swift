import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case home, chat, routines, people, memory, graph, library, you

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .home: "Home"
        case .chat: "Chat"
        case .routines: "Routines"
        case .people: "People"
        case .memory: "Memory"
        case .graph: "Graph"
        case .library: "Artifacts"
        case .you: "You"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .chat: "bubble.left"
        case .routines: "checklist"
        case .people: "person.2"
        case .memory: "brain.head.profile"
        case .graph: "point.3.connected.trianglepath.dotted"
        case .library: "doc.on.doc"
        case .you: "person.crop.circle"
        }
    }

    var tint: Color {
        switch self {
        case .home: Ink.text
        case .chat, .people, .routines: Ink.spot
        case .memory: Ink.violet
        case .graph, .library: Ink.sky
        case .you: Ink.mint
        }
    }
}

struct RootView: View {
    @State private var settings = AppSettings.shared
    @State private var navigator = Navigator.shared
    @State private var agent = Agent.shared
    @Environment(\.colorScheme) private var scheme
    #if os(macOS)
    @State private var windowWidth: CGFloat = 1200
    #endif
    private var section: AppSection { navigator.section }
    /// Every screen is one page now: People is a table, chats are reached
    /// from the sidebar and History. The list column stays for nothing.
    private var hasList: Bool { false }

    var body: some View {
        #if os(macOS)
        // A notebook's layout: a fixed sidebar a shade darker than the page,
        // then the page. People keeps its list beside it.
        HStack(spacing: 0) {
            if let page = navigator.settingsPage {
                SettingsSidebar()
                    .frame(width: Sidebar.width)
                Rectangle().fill(Ink.hairline).frame(width: 1)
                SettingsPageView(page: page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(page)
            } else {
            if !navigator.zen {
                Sidebar()
                    .frame(width: Sidebar.width)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Rectangle().fill(Ink.hairline).frame(width: 1)
            }
            if showsList && !navigator.zen {
                ListPanel()
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Rectangle().fill(Ink.hairline).frame(width: 1)
            }
            Group {
                switch section {
                case .home: HomeView()
                case .chat: ChatView()
                case .routines: RoutinesView()
                case .people: PeopleView()
                case .memory: MemoryView()
                case .graph: GraphView()
                case .library: ArtifactLibraryView()
                case .you: YouView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Ink.canvas)
            // Pages without a top bar of their own still get a title bar strip.
            .overlay(alignment: .top) {
                if section != .home && section != .chat {
                    TitleBarArea(doubleClickOnly: true).frame(height: WindowBar.height)
                }
            }
            .id(section)
            }
        }
        // Sidebar hidden: its two buttons stay beside the window buttons on
        // every screen, so there is always a way back.
        .overlay(alignment: .topLeading) {
            if navigator.zen && navigator.settingsPage == nil {
                CollapsedChrome().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: navigator.zen)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        // Empty space moves the window; double-click zooms it. No page colour
        // behind everything: the sidebar shows the desktop through its material.
        .background { WindowChromeArea() }
        .background {
            // Esc brings the sidebar back; ⌃⌘S shows or hides it, as in Finder.
            Button("") { navigator.zen = false }.keyboardShortcut(.cancelAction).hidden()
            Button("") { withAnimation(.easeInOut(duration: 0.3)) { navigator.zen.toggle() } }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .hidden()
        }
        .ignoresSafeArea(.container, edges: .top)
        .tint(Ink.spot)
        .animation(Motion.settle, value: showsList)
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

    #if os(macOS)
    /// With a document open in a narrow window, the list steps aside so the
    /// conversation keeps its width; it comes back when there is room.
    private var showsList: Bool {
        guard hasList else { return false }
        return agent.openArtifactKey == nil
            || windowWidth >= Sidebar.width + ListPanel.width + ChatView.chatMinWidth + ChatView.panelMinWidth + 40
    }
    #endif
}

#if os(macOS)
/// People's list, as a plain column between the sidebar and the page.
struct ListPanel: View {
    static let width: CGFloat = 320
    @State private var navigator = Navigator.shared
    @State private var agent = Agent.shared

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Text(navigator.section.title)
                    .font(.headline)
                    .foregroundStyle(Ink.text)
                HStack {
                    Spacer()
                    if navigator.section == .chat {
                        Button {
                            withAnimation(Motion.settle) { agent.newConversation() }
                        } label: {
                            Image(systemName: "square.and.pencil").font(.system(size: 16, weight: .medium))
                        }
                        .buttonStyle(HoverIconStyle(size: 30))
                        .tip("New conversation")
                    }
                }
            }
            .frame(height: 30)
            .padding(.horizontal, 12)
            .padding(.top, 12)

            switch navigator.section {
            case .people: PeopleList().padding(.leading, 8)
            default: ConversationSidebar().padding(.leading, 8)
            }
        }
        .frame(width: Self.width)
        .background(Ink.canvas)
    }
}

/// Memory at work, as a small ring. Open it for what and how far, and to pause.
struct ActivityButton: View {
    var openMemory: () -> Void
    @State private var indexer = Indexer.shared
    @State private var repair = MemoryRepair.shared
    @State private var parakeet = ParakeetSetup.shared
    @State private var showing = false

    private var active: Bool { indexer.isRunning || indexer.isLearning || repair.note != nil || parakeet.isDownloading }

    private var downloadFraction: Double? {
        if case .downloading(let fraction) = parakeet.state { return fraction }
        return nil
    }

    /// The line on the ring: a repair, the model download, or memory's status.
    private var line: String { repair.note ?? (indexer.isRunning || indexer.isLearning ? nil : parakeet.notice) ?? indexer.statusText }

    var body: some View {
        if active || indexer.isPaused {
            Button { showing.toggle() } label: {
                ZStack {
                    Circle().stroke(Ink.muted.opacity(0.25), lineWidth: 2.5)
                    if indexer.isPaused && !active {
                        Image(systemName: "pause.fill").font(.system(size: 10, weight: .bold))
                    } else if let progress = indexer.progress ?? downloadFraction {
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
            .help(Text(line))
            .popover(isPresented: $showing, arrowEdge: .trailing) { details }
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(line)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Ink.text)
                .monospacedDigit()
            if let progress = indexer.progress {
                ProgressView(value: progress).tint(Ink.spot)
            }
            // The fast transcription model, while it comes in alongside indexing.
            if let notice = parakeet.notice, line != notice, case .downloading(let fraction) = parakeet.state {
                VStack(alignment: .leading, spacing: 4) {
                    Text(notice).font(.caption).foregroundStyle(Ink.muted)
                    ProgressView(value: fraction).tint(Ink.spot)
                }
            } else if case .downloading(let fraction) = parakeet.state, line == parakeet.notice {
                ProgressView(value: fraction).tint(Ink.spot)
            }
            if !indexer.findings.isEmpty {
                RunFindingsView(findings: indexer.findings, examples: 3)
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
            // The app's character on a plain sidebar-toned panel.
            ZStack(alignment: .bottom) {
                Ink.sidebar
                Image("Mascot")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
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
