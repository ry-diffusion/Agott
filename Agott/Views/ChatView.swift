import SwiftUI

struct ChatView: View {
    @State private var agent = Agent.shared
    @State private var dictation = Dictation.shared
    @State private var draft = ""
    @State private var lookAtScreen = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if agent.turns.isEmpty {
                            EmptyChat { suggestion in send(suggestion) }
                                .padding(.top, 12)
                        }
                        ForEach(agent.turns) { turn in
                            TurnRow(turn: turn).id(turn.id)
                                .transition(.asymmetric(insertion: .offset(y: 12).combined(with: .opacity), removal: .opacity))
                        }
                        Color.clear.frame(height: 110).id("bottom")
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 8)
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity)
                    .animation(Motion.settle, value: agent.turns.count)
                }
                .scrollIndicators(.never)
                .onChange(of: agent.turns.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: agent.turns.last?.cards.count) { _, _ in
                    withAnimation(Motion.settle) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: agent.turns.count) { _, _ in
                    withAnimation(Motion.settle) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottom) { composer }
        }
        #if os(iOS)
        .background(Ink.canvas)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    private var header: some View {
        HStack(spacing: 12) {
            MuseFace(mood: agent.mood, size: 44, level: dictation.level)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "Agott").font(Lettering.display(22, relativeTo: .title2)).foregroundStyle(Ink.text)
                HStack(spacing: 6) {
                    Chip(text: ModelHub.currentModelLabel, symbol: "cpu")
                    // What Agott is doing shows in the reply's steps; the
                    // header only carries its mood.
                    Text(agent.mood.accessibilityName).font(.caption).foregroundStyle(Ink.muted)
                }
            }
            Spacer()
            CandyIconButton(symbol: "square.and.pencil") { agent.newConversation() }
                .disabled(agent.turns.isEmpty)
                .help(Text("New conversation"))
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 12)
        .frame(maxWidth: 836)
        .frame(maxWidth: .infinity)
        .animation(Motion.settle, value: agent.status)
    }

    private var composer: some View {
        HStack(alignment: .center, spacing: 8) {
            TextField(
                dictation.isRunning ? String(localized: "Listening…") : String(localized: "Ask Agott anything"),
                text: dictation.isRunning ? .constant(dictation.transcript) : $draft,
                axis: .vertical)
                .textFieldStyle(.plain)
                .foregroundStyle(Ink.text)
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit { send(draft) }
                .padding(.leading, 8)

            #if os(macOS)
            CandyIconButton(symbol: lookAtScreen ? "eye.fill" : "eye", filled: lookAtScreen) { lookAtScreen.toggle() }
                .help(Text("Let Agott see the app you were just using"))
            #endif

            HoldToTalkButton { text in send(text) }

            if agent.isBusy {
                CandyIconButton(symbol: "stop.fill") { agent.cancel() }
                    .help(Text("Stop"))
            } else {
                CandyIconButton(symbol: "arrow.up", filled: true) { send(draft) }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(Text("Send"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Ink.spot.opacity(agent.isBusy ? 0.7 : 0), lineWidth: 1.5))
        .frame(maxWidth: 760)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .animation(Motion.settle, value: agent.isBusy)
    }

    private func send(_ text: String) {
        agent.send(text, lookAtScreen: lookAtScreen)
        draft = ""
    }
}

private struct TurnRow: View {
    var turn: Turn

    var body: some View {
        if turn.role == .user {
            HStack {
                Spacer(minLength: 100)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(turn.text)
                        .textSelection(.enabled)
                        .foregroundStyle(Ink.onSpot)
                        .balloon(.trailing, fill: Ink.spot)
                    HStack(spacing: 6) {
                        if let app = turn.screenApp { Chip(text: app, symbol: "eye") }
                        if turn.memoryCount > 0 {
                            Chip(text: String(localized: "\(turn.memoryCount) memories"), symbol: "brain")
                        }
                    }
                }
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                MascotAvatar(size: 36)
                AssistantTurnView(turn: turn)
            }
        }
    }
}

private struct EmptyChat: View {
    var pick: (String) -> Void

    private var suggestions: [(String, String)] {
        [
            ("envelope.badge", String(localized: "Who's waiting for a reply from me?")),
            ("calendar", String(localized: "What's on my calendar tomorrow?")),
            ("person.text.rectangle", String(localized: "What do you know about me?")),
            ("person.2", String(localized: "What did I talk about with my friends this week?")),
            ("music.note", String(localized: "Play something chill in Music")),
        ]
    }

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            ZStack(alignment: .topTrailing) {
                ZStack(alignment: .bottom) {
                    Ink.paper
                    Screentone(color: Ink.faceInk.opacity(0.22), spacing: 6, from: 0, to: 0.9)
                    Image("Mascot")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(.top, 34)
                }
                .frame(width: 230, height: 270)
                .clipShape(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))

                Text("Hi, I'm Agott")
                    .font(Lettering.display(17, relativeTo: .headline))
                    .foregroundStyle(Ink.faceInk)
                    .balloon(.bottom, fill: Ink.paper, padding: EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14))
                    .offset(x: 46, y: -22)
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("Your copilot. I remember your chats, see your screen and use your Mac. Hold Right Option anywhere to talk to me.")
                    .foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(suggestions, id: \.1) { symbol, text in
                        Button {
                            pick(text)
                        } label: {
                            Label(text, systemImage: symbol)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Ink.text)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .glassEffect(.regular.interactive(), in: .capsule)
                        }
                        .buttonStyle(PressScale())
                    }
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
    }
}

/// Press and hold to speak; let go to send.
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
