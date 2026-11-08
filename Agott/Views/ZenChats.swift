import SwiftUI

// Two working directions for talking to Agott, both driven by the real
// Agent: what you send is answered, remembered, and saved like in the main
// window. They live in the Design Lab until one is chosen.

// MARK: - Shared

/// The conversation's lines, oldest first, and whether Agott is still writing.
private struct LiveTurns {
    var agent: Agent

    var turns: [Turn] { agent.turns }

    static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The input every direction ends with. `glass` melts it into Liquid Glass
/// pieces; otherwise it is a squared field on the page.
private struct LiveComposer: View {
    var glass: Bool
    var large = false
    @State private var agent = Agent.shared
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var hasText: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Group {
            if glass {
                GlassEffectContainer(spacing: 6) {
                    HStack(alignment: .bottom, spacing: 6) {
                        field
                            .padding(.leading, 20)
                            .padding(.vertical, large ? 15 : 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassEffect(.regular, in: .rect(cornerRadius: 26))
                        action
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    field
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Ink.text.opacity(0.06)))
                    action
                }
            }
        }
        .onAppear { focused = true }
    }

    private var field: some View {
        TextField(String(localized: "Message"), text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(large ? .title3 : .body)
            .lineLimit(1...6)
            .focused($focused)
            .onSubmit(send)
    }

    @ViewBuilder
    private var action: some View {
        let size: CGFloat = large ? 52 : 44
        if hasText {
            Button(action: send) {
                Image(systemName: agent.isBusy ? "clock" : "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background {
                        if !glass { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Ink.spot) }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .modifier(GlassIf(glass, tint: Ink.spot, shape: .circle))
            .keyboardShortcut(.return, modifiers: .command)
            .transition(.scale.combined(with: .opacity))
        } else if agent.isBusy {
            Button { agent.cancel() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: size, height: size)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .modifier(GlassIf(glass, tint: nil, shape: .circle))
        } else {
            HoldToTalkButton { text in agent.send(text) }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        agent.send(text)
        draft = ""
    }
}

private struct GlassIf: ViewModifier {
    var on: Bool
    var tint: Color?
    var shape: Circle

    init(_ on: Bool, tint: Color?, shape: Circle) {
        self.on = on
        self.tint = tint
        self.shape = shape
    }

    func body(content: Content) -> some View {
        if on {
            content.glassEffect(tint.map { .regular.tint($0).interactive() } ?? .regular.interactive(), in: shape)
        } else {
            content
        }
    }
}

/// The greeting when nothing has been said yet.
private struct ZenGreeting: View {
    var body: some View {
        let name = AppSettings.shared.myName.split(separator: " ").first.map(String.init) ?? AppSettings.shared.myName
        let hour = Calendar.current.component(.hour, from: .now)
        let hello = hour < 12 ? String(localized: "Good morning, \(name)")
            : hour < 18 ? String(localized: "Good afternoon, \(name)") : String(localized: "Good evening, \(name)")
        VStack(spacing: 8) {
            Text(hello).font(Lettering.display(26, relativeTo: .title))
            Text("What's on your mind?").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
    }
}

// MARK: - Moon (Liquid Glass)

/// The Moon sky: a slow gradient, plum and indigo at night, peach and lilac
/// by day, drifting so the glass on top always has light to bend.
struct MoonSky: View {
    var night: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            LinearGradient(
                colors: night
                    ? [Color(.sRGB, red: 0.10, green: 0.07, blue: 0.20), Color(.sRGB, red: 0.27, green: 0.09, blue: 0.25), Color(.sRGB, red: 0.06, green: 0.05, blue: 0.11)]
                    : [Color(.sRGB, red: 1.00, green: 0.86, blue: 0.85), Color(.sRGB, red: 1.00, green: 0.96, blue: 0.90), Color(.sRGB, red: 0.90, green: 0.88, blue: 1.00)],
                startPoint: UnitPoint(x: 0.5 + 0.35 * sin(t / 9), y: 0),
                endPoint: UnitPoint(x: 0.5 - 0.35 * sin(t / 9), y: 1))
                .ignoresSafeArea()
        }
        .allowsHitTesting(false)
    }
}

/// The Moon direction, working: a drifting sky, the mascot in a glass bubble
/// that breathes while Agott thinks, answers on glass, your words in pink.
struct MoonChat: View {
    var night: Bool
    @State private var agent = Agent.shared
    @State private var zen = LaunchOptions.arguments.contains("-AgottLabZen")

    var body: some View {
        ZStack {
            MoonSky(night: night)

            // Out of zen, the app's own glass panels float on the sky: folders
            // with the window buttons, and your chats. In zen, only the talk.
            HStack(spacing: 10) {
                #if os(macOS)
                if !zen {
                    Sidebar()
                        .frame(width: Sidebar.width)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    ListPanel()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                #endif
                conversation
            }
            .padding(.leading, zen ? 0 : 10)
            .padding(.vertical, zen ? 0 : 10)
        }
        .animation(.easeInOut(duration: 0.4), value: zen)
        .background {
            Button("") { zen = false }.keyboardShortcut(.cancelAction).hidden()
        }
        .overlay(alignment: .topTrailing) {
            Button {
                zen.toggle()
            } label: {
                Label(zen ? "Leave zen" : "Zen", systemImage: zen ? "arrow.down.right.and.arrow.up.left" : "moon.zzz")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .padding(16)
            .tip(zen ? "Back to folders and chats (Esc)" : "Only the conversation")
        }
    }

    private var conversation: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 18) {
                        MascotFace(mood: agent.mood, size: 64)
                            .padding(10)
                            .glassEffect(.regular, in: .circle)
                            .padding(.top, 34)
                        if agent.turns.isEmpty { ZenGreeting() }
                        ForEach(agent.turns) { turn in
                            if turn.role == .user {
                                Text(turn.text)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Ink.spot)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .textSelection(.enabled)
                            } else {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(turn.cards) { card in
                                        CardView(card: card).environment(\.inChat, true).environment(\.chatPanelStyle, .glass)
                                    }
                                    if !LiveTurns.trimmed(turn.text).isEmpty {
                                        MarkdownView(text: turn.text, size: .zen)
                                            .padding(20)
                                            .glassEffect(.regular, in: .rect(cornerRadius: 26))
                                    } else if turn.isStreaming {
                                        TypingDots()
                                            .glassEffect(.regular, in: .capsule)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Color.clear.frame(height: 4).id("end")
                    }
                    .frame(maxWidth: 600)
                    .padding(.horizontal, 40)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.never)
                .scrollEdgeEffectStyle(.soft, for: .all)
                .onChange(of: agent.turns.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: agent.turns.count) { _, _ in withAnimation(Motion.settle) { proxy.scrollTo("end", anchor: .bottom) } }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .safeAreaInset(edge: .bottom) {
                    LiveComposer(glass: true, large: true)
                        .frame(maxWidth: 600)
                        .padding(.horizontal, 40)
                        .padding(.bottom, 18)
                }
            }
    }
}

// MARK: - Page (squared, with and without zen)

/// The Page direction, working: paper, straight corners, Agott's words set
/// on the page, yours on small pink tags. Out of zen, a column of folders and
/// your chats sit on the left like a notebook's margin; in zen, only the page.
struct PageChat: View {
    var night: Bool
    @State private var agent = Agent.shared
    @State private var zen = LaunchOptions.arguments.contains("-AgottLabZen")

    private var paper: Color { night ? Color(.sRGB, red: 0.075, green: 0.07, blue: 0.085) : Color(.sRGB, red: 0.975, green: 0.965, blue: 0.945) }
    private var margin: Color { night ? Color(.sRGB, red: 0.10, green: 0.095, blue: 0.11) : Color(.sRGB, red: 0.95, green: 0.94, blue: 0.915) }

    var body: some View {
        HStack(spacing: 0) {
            if !zen {
                folders
                    .transition(.move(edge: .leading).combined(with: .opacity))
                chats
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            page
        }
        .background(paper.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.35), value: zen)
        .background {
            Button("") { zen = false }.keyboardShortcut(.cancelAction).hidden()
        }
    }

    // Out of zen: folders, square, icon over name.
    private var folders: some View {
        VStack(spacing: 6) {
            // Room for the window buttons.
            Color.clear.frame(height: 44)
            ForEach(AppSection.allCases) { item in
                VStack(spacing: 3) {
                    Image(systemName: item.symbol).font(.system(size: 18, weight: .medium))
                    Text(item.title).font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(item == .chat ? Ink.spot : Ink.muted)
                .frame(width: 64, height: 50)
                .background(RoundedRectangle(cornerRadius: 4).fill(item == .chat ? Ink.spot.opacity(0.12) : .clear))
            }
            Spacer()
        }
        .frame(width: 80)
        .background(margin)
        .overlay(alignment: .trailing) { Rectangle().fill(Ink.hairline).frame(width: 1) }
    }

    // Out of zen: your chats, square rows.
    private var chats: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Chats").font(Lettering.display(16, relativeTo: .headline))
                Spacer()
                Button {
                    withAnimation(Motion.settle) { agent.newConversation() }
                } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(HoverIconStyle(size: 28))
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .padding(.top, 20)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(agent.conversations) { item in
                        let selected = item.id == agent.currentID
                        Button {
                            withAnimation(Motion.settle) { agent.open(item.id) }
                        } label: {
                            HStack(spacing: 10) {
                                PeopleAvatar(people: item.people ?? [], size: 36, title: item.subject ?? item.title)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    Text(item.preview).font(.system(size: 12)).opacity(0.7).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.text))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(Rectangle().fill(selected ? AnyShapeStyle(Ink.spot) : AnyShapeStyle(Color.clear)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .frame(width: 270)
        .background(margin.opacity(0.6))
        .overlay(alignment: .trailing) { Rectangle().fill(Ink.hairline).frame(width: 1) }
    }

    private var page: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(spacing: 8) {
                        MascotFace(mood: agent.mood, size: 44)
                        Text(night ? "Tonight" : "Today")
                            .font(Lettering.display(13, relativeTo: .caption))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                    if agent.turns.isEmpty { ZenGreeting() }
                    ForEach(agent.turns) { turn in
                        if turn.role == .user {
                            HStack {
                                Spacer(minLength: 120)
                                Text(turn.text)
                                    .font(.system(size: 15))
                                    .foregroundStyle(Ink.onSpot)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Ink.spot))
                                    .textSelection(.enabled)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(turn.cards) { card in
                                    CardView(card: card).environment(\.inChat, true).environment(\.chatPanelStyle, .square)
                                }
                                if !LiveTurns.trimmed(turn.text).isEmpty {
                                    MarkdownView(text: turn.text, size: .zen)
                                } else if turn.isStreaming {
                                    TypingDots()
                                }
                            }
                        }
                    }
                    Color.clear.frame(height: 4).id("end")
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, 44)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .background(alignment: .bottom) {
                Screentone(color: Ink.text.opacity(0.05), spacing: 7, from: 0, to: 0.7)
                    .frame(height: 220)
                    .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
                    .allowsHitTesting(false)
            }
            .onChange(of: agent.turns.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: agent.turns.count) { _, _ in withAnimation(Motion.settle) { proxy.scrollTo("end", anchor: .bottom) } }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .safeAreaInset(edge: .bottom) {
                LiveComposer(glass: false)
                    .frame(maxWidth: 640)
                    .padding(.horizontal, 44)
                    .padding(.bottom, 18)
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    zen.toggle()
                } label: {
                    Label(zen ? "Leave zen" : "Zen", systemImage: zen ? "arrow.down.right.and.arrow.up.left" : "moon.zzz")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Ink.text.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .padding(16)
                .tip(zen ? "Back to folders and chats (Esc)" : "Only the conversation")
            }
        }
    }
}
