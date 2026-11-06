import SwiftUI

/// Talking to Agott.
///
/// No title bar: the conversation is the screen. Empty, it is a greeting and
/// a composer in the middle of the page, with a few things worth asking
/// that come from your own life. Once you talk, the composer settles at the
/// bottom and the conversation reads like a chat with a friend.
struct ChatView: View {
    /// One column for messages and the composer, so every left and right
    /// edge in the conversation lines up.
    static let column: CGFloat = 720
    static let gutter: CGFloat = 24
    /// Where text starts inside the composer, and where its send button ends.
    /// Messages line up with both: replies start where you type, your
    /// bubbles end where the send button does.
    static let textInset: CGFloat = 18
    static let trailingInset: CGFloat = 8
    #if os(macOS)
    static let topInset: CGFloat = 36
    #else
    static let topInset: CGFloat = 64
    #endif

    @State private var agent = Agent.shared
    @State private var dictation = Dictation.shared
    @State private var draft = ""
    @State private var lookAtScreen = false
    @FocusState private var focused: Bool

    var body: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            // Like a messenger: your chats on the left, the open one beside them.
            ConversationSidebar()
                .frame(width: 270)
                .overlay(alignment: .trailing) { Rectangle().fill(Ink.hairline).frame(width: 1) }
            chat
            if let key = agent.openArtifactKey {
                ArtifactPanel(key: key)
                    .frame(minWidth: 380, idealWidth: 560, maxWidth: 760)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.vertical, 12)
                    .padding(.trailing, 12)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Motion.settle, value: agent.openArtifactKey)
        #else
        chat
            .sheet(isPresented: Binding(
                get: { agent.openArtifactKey != nil },
                set: { if !$0 { agent.openArtifactKey = nil } })) {
                if let key = agent.openArtifactKey { ArtifactPanel(key: key) }
            }
        #endif
    }

    private var chat: some View {
        ZStack(alignment: .topTrailing) {
            if agent.turns.isEmpty {
                ChatHome(composer: composer(centered: true)) { send($0) }
                    .transition(.opacity)
            } else {
                conversation
                    .transition(.opacity)
            }
            #if os(iOS)
            HStack(spacing: 8) {
                if !agent.conversations.isEmpty { ConversationsButton() }
                if !agent.turns.isEmpty {
                    CandyIconButton(symbol: "square.and.pencil") {
                        withAnimation(Motion.settle) { agent.newConversation() }
                    }
                    .help(Text("New conversation"))
                }
            }
            .padding(.top, 18)
            .padding(.trailing, 22)
            #endif
        }
        .animation(Motion.settle, value: agent.turns.isEmpty)
        .onAppear { focused = true }
        #if os(iOS)
        .background(Ink.canvas)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(agent.turns.enumerated()), id: \.element.id) { index, turn in
                        if let label = Self.timeLabel(before: index, in: agent.turns) {
                            Text(label)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Ink.muted)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 6)
                        }
                        TurnRow(turn: turn).id(turn.id)
                            .transition(.asymmetric(insertion: .offset(y: 12).combined(with: .opacity), removal: .opacity))
                    }
                    Color.clear.frame(height: 12).id("bottom")
                }
                .padding(.leading, Self.textInset)
                .padding(.trailing, Self.trailingInset)
                .frame(maxWidth: Self.column)
                .padding(.horizontal, Self.gutter)
                .padding(.top, 8)
                .frame(maxWidth: .infinity)
                .animation(Motion.settle, value: agent.turns.count)
            }
            .scrollIndicators(.never)
            // The buttons above and the composer below keep their own space;
            // the conversation fades softly under both.
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: Self.topInset) }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer(centered: false)
                    .padding(.horizontal, Self.gutter)
                    .padding(.bottom, 20)
                    .padding(.top, 8)
            }
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .onChange(of: agent.turns.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: agent.turns.last?.steps.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: agent.turns.last?.cards.count) { _, _ in
                withAnimation(Motion.settle) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: agent.turns.count) { _, _ in
                withAnimation(Motion.settle) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    /// A quiet time label when the conversation picks up after a pause.
    static func timeLabel(before index: Int, in turns: [Turn]) -> String? {
        let turn = turns[index]
        guard turn.role == .user else { return nil }
        if index == 0 || turn.date.timeIntervalSince(turns[index - 1].date) > 3600 {
            return turn.date.formatted(Calendar.current.isDateInToday(turn.date)
                ? .dateTime.hour().minute()
                : .dateTime.weekday(.wide).day().month().hour().minute())
        }
        return nil
    }

    /// One quiet line: what you write, then the screen, the mic and send.
    /// The model is chosen in Settings, not here.
    private func composer(centered: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField(
                dictation.isRunning ? String(localized: "Listening…") : String(localized: "Talk to me…"),
                text: dictation.isRunning ? .constant(dictation.transcript) : $draft,
                axis: .vertical)
                .textFieldStyle(.plain)
                .font(centered ? .title3 : .body)
                .foregroundStyle(Ink.text)
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit { send(draft) }
                .padding(.leading, Self.textInset - 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)

            #if os(macOS)
            CandyIconButton(symbol: lookAtScreen ? "eye.fill" : "eye", filled: lookAtScreen, size: 32) { lookAtScreen.toggle() }
                .help(Text("Let Agott see the app you were just using"))
            #endif
            HoldToTalkButton { text in send(text) }
            if agent.isBusy {
                CandyIconButton(symbol: "stop.fill", size: 34) { agent.cancel() }
                    .help(Text("Stop"))
            } else {
                CandyIconButton(symbol: "arrow.up", filled: true, size: 34) { send(draft) }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(Text("Send"))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .frame(maxWidth: Self.column)
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        agent.send(trimmed, lookAtScreen: lookAtScreen)
        draft = ""
    }
}

/// The empty conversation: a greeting, the composer, and a few things worth
/// asking that come from your own memory.
private struct ChatHome<Composer: View>: View {
    var composer: Composer
    var pick: (String) -> Void
    @State private var suggestions: [(symbol: String, text: String)] = []
    @State private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 40)
            MascotFace(mood: .happy, size: 64)
            VStack(spacing: 6) {
                Text(greeting)
                    .font(Lettering.display(32, relativeTo: .largeTitle))
                    .foregroundStyle(Ink.text)
                Text("What's on your mind?").foregroundStyle(Ink.muted)
            }
            #if os(macOS)
            NowPlayingLine()
            #endif
            composer
            FlowLayout(spacing: 8) {
                ForEach(suggestions, id: \.text) { item in
                    Button {
                        pick(item.text)
                    } label: {
                        Label(item.text, systemImage: item.symbol)
                            .font(.callout)
                            .foregroundStyle(Ink.text)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressScale())
                }
            }
            .frame(maxWidth: ChatView.column)
            Spacer(minLength: 80)
        }
        .padding(.horizontal, ChatView.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { suggestions = await Self.suggestions() }
    }

    private var greeting: String {
        let first = settings.myName.split(separator: " ").first.map(String.init) ?? settings.myName
        let hour = Calendar.current.component(.hour, from: .now)
        switch hour {
        case 5..<12: return String(localized: "Good morning, \(first)")
        case 12..<18: return String(localized: "Good afternoon, \(first)")
        default: return String(localized: "Good evening, \(first)")
        }
    }

    /// Someone waiting on you first, then the general ones.
    static func suggestions() async -> [(symbol: String, text: String)] {
        var result: [(String, String)] = []
        let recent = (try? await MemoryStore.shared.chats(limit: 40, includeGroups: false,
                                                          since: Date().addingTimeInterval(-3 * 86400))) ?? []
        for chat in recent where !chat.lastFromMe && !GraphView.isPhoneOnly(chat.name) {
            result.append(("arrowshape.turn.up.left", String(localized: "How should I answer \(chat.name)?")))
            if result.count == 2 { break }
        }
        result += [
            ("sun.max", String(localized: "How was my day?")),
            ("person.2", String(localized: "Who's waiting for a reply from me?")),
            ("music.note", String(localized: "What does my music say about my mood?")),
            ("calendar", String(localized: "What's on my calendar tomorrow?")),
        ]
        return Array(result.prefix(5))
    }
}

private struct TurnRow: View {
    var turn: Turn

    var body: some View {
        if turn.role == .user {
            HStack {
                Spacer(minLength: 100)
                Text(turn.text)
                    .textSelection(.enabled)
                    .foregroundStyle(Ink.onSpot)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Ink.spot))
            }
        } else {
            AssistantTurnView(turn: turn)
        }
    }
}

struct HoldToTalkButton: View {
    var onText: (String) -> Void
    @State private var held = false
    @State private var dictation = Dictation.shared

    var body: some View {
        Image(systemName: held ? "waveform" : "mic.fill")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(held ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.text))
            .frame(width: 34, height: 34)
            .glassEffect(held ? .regular.tint(Ink.spot).interactive() : .regular.interactive(), in: .circle)
            .scaleEffect(held ? 1.1 + CGFloat(dictation.level) * 0.25 : 1)
            .animation(Motion.bouncy, value: held)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !held else { return }
                        held = true
                        Agent.shared.setMood(.listening)
                        dictation.start()
                    }
                    .onEnded { _ in
                        held = false
                        Task {
                            let text = await dictation.stop()
                            if text.isEmpty { Agent.shared.setMood(.idle) } else { onText(text) }
                        }
                    })
            .help(Text("Hold to talk"))
            .accessibilityLabel(Text("Hold to talk"))
    }
}
