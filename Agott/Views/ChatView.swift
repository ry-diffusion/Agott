import SwiftUI
import UniformTypeIdentifiers

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
    static let chatMinWidth: CGFloat = 440
    static let panelMinWidth: CGFloat = 360


    static let gutter: CGFloat = 24
    /// Where text starts inside the composer, and where its send button ends.
    /// Messages line up with both: replies start where you type, your
    /// bubbles end where the send button does.
    static let textInset: CGFloat = 0
    static let trailingInset: CGFloat = 0
    #if os(macOS)
    static let topInset: CGFloat = 58
    #else
    static let topInset: CGFloat = 64
    #endif

    @State private var agent = Agent.shared
    private var currentInfo: ConversationInfo? { agent.conversations.first { $0.id == agent.currentID } }
    @State private var dictation = Dictation.shared
    @State private var draft = ""
    @State private var lookAtScreen = false
    @State private var pending: [FileAttachment] = []
    @State private var importing = false
    @State private var dropping = false
    /// The message of yours being rewritten, if any.
    @State private var editing: Turn?
    @FocusState private var focused: Bool

    var body: some View {
        #if os(macOS)
        HStack(spacing: 8) {
            chat
                .frame(minWidth: Self.chatMinWidth)
                .layoutPriority(1)
            if let key = agent.openArtifactKey {
                ArtifactPanel(key: key)
                    .frame(minWidth: Self.panelMinWidth, idealWidth: 520, maxWidth: 720)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.vertical, 8)
                    .padding(.trailing, 8)
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
                // Keyed by the chat, so "New conversation" on a chat that is
                // already empty still visibly starts over instead of doing
                // nothing.
                ChatHome(composer: composer(centered: true)) { send($0) }
                    .id(agent.currentID)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96)),
                                            removal: .opacity))
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
        // Drop files anywhere on the conversation to attach them.
        .dropDestination(for: URL.self) { urls, _ in
            attach(urls.filter(\.isFileURL))
            return !urls.isEmpty
        } isTargeted: { dropping = $0 }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Ink.spot, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Ink.spot.opacity(0.06)))
                    .overlay(Label("Drop to attach", systemImage: "paperclip").font(.headline).foregroundStyle(Ink.spot))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .animation(Motion.settle, value: agent.turns.isEmpty)
        // A person's name in the chat opens them in People.
        .environment(\.openURL, OpenURLAction { EntityText.open($0) })
        .onAppear { focused = true }
        // Another chat, or a new one: ready to type, and an edit of a
        // message from the chat you left is dropped.
        .onChange(of: agent.currentID) {
            if editing != nil { stopEditing() }
            focused = true
        }
        #if os(iOS)
        .background(Ink.canvas)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Rows carry everything they need, worked out once from
                    // the same turns: a row SwiftUI keeps around for a moment
                    // after the chat changes never indexes into the new list.
                    ForEach(Self.rows(agent.turns)) { row in
                        let turn = row.turn
                        if let label = row.label {
                            // The day, quietly, centred.
                            Text(label)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Ink.muted)
                                .frame(maxWidth: .infinity)
                                // The first day sits right under the bar.
                                .padding(.top, row.isFirst ? 4 : 18)
                                .padding(.bottom, 8)
                        }
                        TurnRow(turn: turn, joinsAbove: row.joinsAbove, joinsBelow: row.joinsBelow,
                                isEditing: editing?.id == turn.id) { startEditing(turn) }
                            .id(turn.id)
                            // Grouped messages sit close; a new speaker gets air.
                            .padding(.top, row.isFirst ? (row.label == nil ? 8 : 4) : (row.joinsAbove ? 10 : 28))
                            .transition(.asymmetric(insertion: .offset(y: 12).combined(with: .opacity), removal: .opacity))
                    }
                    // After a finished answer, a nudge to keep going.
                    if let last = agent.turns.last, last.role == .assistant, !last.isStreaming, last.error == nil,
                       !agent.isBusyHere, agent.queue.isEmpty {
                        Button(String(localized: "Say more")) { send(String(localized: "Say more")) }
                            .buttonStyle(.candy(.soft, compact: true))
                            .padding(.top, 14)
                            .transition(.opacity)
                    }
                    // Written while Agott was answering: waiting their turn.
                    ForEach(agent.queue) { message in
                        HStack(spacing: 6) {
                            Spacer(minLength: 120)
                            Image(systemName: "clock").font(.caption).foregroundStyle(Ink.muted)
                            VStack(alignment: .trailing, spacing: 6) {
                                if !message.attachments.isEmpty {
                                    AttachmentsView(attachments: message.attachments, outgoing: false)
                                }
                                if !message.text.isEmpty {
                                    UserText(text: message.text)
                                        .font(.system(size: 15))
                                        .foregroundStyle(Ink.text)
                                        .textSelection(.enabled)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 9)
                                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Ink.bubble))
                                }
                            }
                            .opacity(0.55)
                            .contextMenu {
                                Button("Don't send", systemImage: "xmark", role: .destructive) { agent.unqueue(message.id) }
                            }
                        }
                        .padding(.top, 3)
                        .help(Text("Sends when Agott finishes this answer"))
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
            // Open at the newest message, laid out from the bottom. Jumping
            // there with scrollTo before the lazy rows are measured left the
            // window blank on launch until a chat was picked.
            // Short chats read from the top down; long ones open at the
            // newest message and follow it as a reply grows.
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            // A different chat is a fresh scroll view, opened at its bottom.
            .id(agent.currentID)
            // The buttons above and the composer below keep their own space;
            // the conversation fades softly under both.
            #if os(macOS)
            // The title, music and Zen sit in a real bar: messages scroll
            // under it and fade there, and it keeps clear of the window
            // buttons, in Zen too.
            .safeAreaBar(edge: .top, spacing: 0) { ChatTopBar() }
            #else
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: Self.topInset) }
            #endif
            .safeAreaBar(edge: .bottom, spacing: 0) {
                composer(centered: false)
                    .padding(.horizontal, Self.gutter)
                    .padding(.bottom, 10)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity)
            }
            // Messages slide under the bars and blur softly, like Claude.
            .scrollEdgeEffectStyle(.soft, for: .all)
            // While a reply streams in, the bottom anchor keeps it in view;
            // a scroll per token was more than once a frame.
            .onChange(of: agent.turns.last?.cards.count) { _, _ in
                withAnimation(Motion.settle) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: agent.queue.count) { _, _ in
                withAnimation(Motion.settle) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: agent.turns.count) { _, _ in
                withAnimation(Motion.settle) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// A quiet time label when the conversation picks up after a pause.
    /// The day when it changes ("Today", "Yesterday", a date), and the hour
    /// when a conversation picks up after a long pause the same day.
    struct Row: Identifiable {
        var turn: Turn
        var label: String?
        var joinsAbove: Bool
        var joinsBelow: Bool
        var isFirst: Bool
        var id: UUID { turn.id }
    }

    static func rows(_ turns: [Turn]) -> [Row] {
        turns.indices.map { index in
            let turn = turns[index]
            let above = index > 0 ? turns[index - 1] : nil
            let below = index + 1 < turns.count ? turns[index + 1] : nil
            return Row(turn: turn, label: timeLabel(before: index, in: turns),
                       joinsAbove: turn.joins(above), joinsBelow: turn.joins(below), isFirst: index == 0)
        }
    }

    static func timeLabel(before index: Int, in turns: [Turn]) -> String? {
        guard turns.indices.contains(index) else { return nil }
        let turn = turns[index]
        let calendar = Calendar.current
        let previous = index > 0 ? turns[index - 1].date : nil
        if previous.map({ !calendar.isDate($0, inSameDayAs: turn.date) }) ?? true {
            if calendar.isDateInToday(turn.date) { return String(localized: "Today") }
            if calendar.isDateInYesterday(turn.date) { return String(localized: "Yesterday") }
            return turn.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        if turn.role == .user, let previous, turn.date.timeIntervalSince(previous) > 3 * 3600 {
            return turn.date.formatted(.dateTime.hour().minute())
        }
        return nil
    }

    /// One quiet box to write in: the editing strip and attachments on top,
    /// then the field, the screen toggle, a paperclip, and a round button
    /// that is the mic while empty, send once there is something to send,
    /// and stop while Agott answers with nothing typed.
    private func composer(centered: Bool) -> some View {
        let hasContent = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pending.isEmpty
        return VStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                if let editing {
                    HStack(spacing: 8) {
                        Image(systemName: "pencil").foregroundStyle(Ink.spot)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Editing").font(.caption.weight(.semibold)).foregroundStyle(Ink.spot)
                            Text(editing.text).font(.caption).foregroundStyle(Ink.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Button { stopEditing() } label: { Image(systemName: "xmark") }
                            .buttonStyle(HoverIconStyle(size: 24))
                            .keyboardShortcut(.cancelAction)
                            .tip("Cancel editing", edge: .top)
                    }
                    .padding(.top, 10)
                    .padding(.leading, 18)
                    .padding(.trailing, 8)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if !pending.isEmpty {
                    PendingAttachments(attachments: $pending)
                        .padding(.top, 8)
                        .padding(.horizontal, 12)
                }
                HStack(alignment: .bottom, spacing: 4) {
                    TextField(
                        dictation.isRunning ? dictation.hint : String(localized: "Ask anything"),
                        text: dictation.isRunning ? .constant(dictation.transcript) : $draft,
                        axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.text)
                        .lineLimit(1...8)
                        .focused($focused)
                        .onSubmit { send(draft) }
                        .padding(.leading, 18)
                        .padding(.vertical, 15)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // The controls sit centred on one line, whatever their size.
                    HStack(alignment: .center, spacing: 2) {
                        ModelButton()
                        #if os(macOS)
                        Button { lookAtScreen.toggle() } label: {
                            Image(systemName: lookAtScreen ? "eye.fill" : "eye")
                                .foregroundStyle(lookAtScreen ? AnyShapeStyle(Ink.spot) : AnyShapeStyle(Ink.muted))
                        }
                        .buttonStyle(HoverIconStyle(size: 30))
                        .tip("Let Agott see the app you were just using", edge: .top)
                        #endif
                        Button { importing = true } label: { Image(systemName: "paperclip") }
                            .buttonStyle(HoverIconStyle(size: 30))
                            .tip("Attach a photo, PDF or file", edge: .top)
                        // Stop stays reachable while you type a correction.
                        if agent.isBusyHere && hasContent && !dictation.isRunning {
                            CircleGlassButton(symbol: "stop.fill", size: Self.inputHeight) { agent.cancel() }
                                .tip("Stop", edge: .top)
                        }
                        ZStack {
                            // While the mic is on it stays put: swapping it
                            // out mid-press would leave it listening forever.
                            if hasContent && !dictation.isRunning {
                                CircleGlassButton(symbol: "arrow.up", size: Self.inputHeight, tinted: true) { send(draft) }
                                    .keyboardShortcut(.return, modifiers: .command)
                                    .tip(agent.isBusy ? "Send after this answer" : "Send", edge: .top)
                            } else if agent.isBusyHere && !dictation.isRunning {
                                CircleGlassButton(symbol: "stop.fill", size: Self.inputHeight) { agent.cancel() }
                                    .tip("Stop", edge: .top)
                            } else {
                                HoldToTalkButton { text in send(text) }
                            }
                        }
                        .transition(.opacity)
                        .animation(.easeOut(duration: 0.15), value: hasContent)
                    }
                    .padding(.bottom, 8)
                }
                .padding(.trailing, 8)
            }
            .quietSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
            if !centered {
                Text("Agott uses AI and can make mistakes.")
                    .font(.caption)
                    .foregroundStyle(Ink.muted)
            }
        }
        .frame(maxWidth: Self.column)
        .animation(Motion.settle, value: editing?.id)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attach(urls) }
        }
    }

    private func attach(_ urls: [URL]) {
        for url in urls {
            if let attachment = try? AttachmentStore.add(url) { pending.append(attachment) }
        }
    }

    static let inputHeight: CGFloat = 34

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !pending.isEmpty else { return }
        if let editing {
            withAnimation(Motion.settle) { agent.edit(editing.id, to: trimmed, attachments: pending) }
            self.editing = nil
        } else {
            agent.send(trimmed, lookAtScreen: lookAtScreen, attachments: pending)
        }
        draft = ""
        pending = []
    }

    /// Your message goes back into the composer; sending replaces it and
    /// whatever came after. Until then nothing changes.
    private func startEditing(_ turn: Turn) {
        editing = turn
        draft = turn.text
        pending = turn.attachments
        focused = true
    }

    private func stopEditing() {
        editing = nil
        draft = ""
        pending = []
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
        VStack(spacing: 18) {
            Spacer(minLength: 40)
            VStack(spacing: 6) {
                Text(greeting)
                    .font(Lettering.display(34, relativeTo: .largeTitle))
                    .foregroundStyle(Ink.text)
                Text("What's on your mind?").foregroundStyle(Ink.muted)
            }
            composer
            FlowLayout(spacing: 6) {
                ForEach(suggestions, id: \.text) { item in
                    Button {
                        pick(item.text)
                    } label: {
                        Label(item.text, systemImage: item.symbol)
                            .font(.callout)
                            .foregroundStyle(Ink.muted)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .quietSurface(Capsule(), fill: .clear)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: ChatView.column)
            Spacer(minLength: 80)
        }
        .padding(.horizontal, ChatView.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { suggestions = await ChatSuggestions.load() }
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
}

private struct TurnRow: View {
    var turn: Turn
    var joinsAbove = false
    var joinsBelow = false
    var isEditing = false
    var onEdit: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        if turn.role == .user {
            // Your words on the right, with edit and ask-again beside them
            // under the pointer.
            HStack(alignment: .top, spacing: 10) {
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    Button(action: onEdit) { Image(systemName: "pencil") }
                        .buttonStyle(HoverIconStyle(size: 26))
                        .tip("Edit")
                    Button { withAnimation(Motion.settle) { Agent.shared.retry(turn.id) } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(HoverIconStyle(size: 26))
                    .tip("Ask again")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Ink.muted)
                .opacity(hovering && !isEditing ? 1 : 0)
                .allowsHitTesting(hovering && !isEditing)
                message
            }
            .padding(.leading, 60)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .opacity(isEditing ? 0.45 : 1)
            // Its tips hang below; keep them over the next message.
            .zIndex(hovering ? 1 : 0)
            .contextMenu {
                Button("Edit", systemImage: "pencil", action: onEdit)
                Button("Ask again", systemImage: "arrow.clockwise") { Agent.shared.retry(turn.id) }
                Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(EntityText.plain(turn.text, hidden: AppSettings.shared.hideNames)) }
                Divider()
                Button("Go back to before this", systemImage: "arrow.uturn.backward", role: .destructive) {
                    withAnimation(Motion.settle) { _ = Agent.shared.rewind(to: turn.id) }
                }
            }
        } else {
            AssistantTurnView(turn: turn, joinsAbove: joinsAbove, joinsBelow: joinsBelow)
        }
    }

    private var message: some View {
            VStack(alignment: .trailing, spacing: 6) {
                if !turn.attachments.isEmpty {
                    AttachmentsView(attachments: turn.attachments, outgoing: false)
                }
                if !turn.text.isEmpty {
                    // Your words in a soft grey pill on the right.
                    UserText(text: turn.text)
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Ink.bubble))
                }
            }
            .layoutPriority(1)
    }
}

#if os(macOS)
/// The bar over a conversation: back to Home and your History on the left,
/// the chat's documents and New conversation on the right.
private struct ChatTopBar: View {
    @State private var agent = Agent.shared
    @State private var navigator = Navigator.shared

    var body: some View {
        HStack(spacing: 6) {
            if navigator.zen { SidebarToggle() }
            Button { navigator.section = .home } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Image(systemName: "bubble.left")
                }
                .padding(.horizontal, 6)
            }
            .buttonStyle(HoverIconStyle(size: 30))
            .quietSurface(Capsule(), fill: .clear)
            .tip("Back to Home", edge: .bottom)

            Menu {
                ForEach(agent.conversations.prefix(20)) { item in
                    Button(EntityText.plain(item.displayTitle, hidden: AppSettings.shared.hideNames)) {
                        withAnimation(Motion.settle) { agent.open(item.id) }
                    }
                }
                if agent.conversations.isEmpty {
                    Text("No conversations yet")
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("History")
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(.callout)
                .foregroundStyle(Ink.text)
            }
            .menuStyle(.button)
            .buttonStyle(HoverIconStyle(size: 30))
            .menuIndicator(.hidden)
            .fixedSize()

            if agent.isBusyHere {
                Text("typing…").font(.caption).foregroundStyle(Ink.muted).padding(.leading, 4)
            }
            Spacer()
            let documents = Dictionary(grouping: agent.artifacts, by: \.key).compactMap { $0.value.last }
            if !documents.isEmpty {
                Menu {
                    ForEach(documents, id: \.key) { document in
                        Button(document.title, systemImage: document.kind.symbol) {
                            withAnimation(Motion.settle) { agent.openArtifactKey = document.key }
                        }
                    }
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 14))
                }
                .menuStyle(.button)
                .buttonStyle(HoverIconStyle(size: 30))
                .menuIndicator(.hidden)
                .fixedSize()
                .tip("Documents in this chat", edge: .bottom)
            }
            Button {
                withAnimation(Motion.settle) { agent.newConversation() }
            } label: {
                Label("New conversation", systemImage: "square.and.pencil")
            }
            .buttonStyle(.candy(.soft, compact: true))
        }
        .padding(.horizontal, 14)
        .frame(height: WindowBar.height)
        .titleBar()
        .animation(.easeOut(duration: 0.2), value: agent.isBusyHere)
    }
}
#endif

/// A round piece of glass with one symbol: send, stop.
private struct CircleGlassButton: View {
    var symbol: String
    var size: CGFloat
    var tinted = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(tinted ? AnyShapeStyle(Ink.canvas) : AnyShapeStyle(Ink.text))
                .frame(width: size, height: size)
                .background(Circle().fill(tinted ? Ink.text : Ink.raised))
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
    }
}

/// The mic. Hold it and talk, let go to send; or tap it once to talk
/// hands-free and tap again to send.
struct HoldToTalkButton: View {
    var onText: (String) -> Void
    @State private var pressedAt: Date?
    @State private var handsFree = false
    @State private var dictation = Dictation.shared

    /// A press shorter than this is a tap.
    static let tapLimit: TimeInterval = 0.35

    private var live: Bool { dictation.isRunning }

    var body: some View {
        Image(systemName: live ? "waveform" : "mic.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(live ? AnyShapeStyle(Ink.onSpot) : AnyShapeStyle(Ink.text))
            .frame(width: ChatView.inputHeight, height: ChatView.inputHeight)
            .background(Circle().fill(live ? Ink.spot : Ink.raised))
            .scaleEffect(live ? 1.05 + CGFloat(dictation.level) * 0.2 : 1)
            .animation(Motion.bouncy, value: live)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard pressedAt == nil else { return }
                        pressedAt = .now
                        if !live {
                            Agent.shared.setMood(.listening)
                            dictation.start()
                        }
                    }
                    .onEnded { _ in
                        let held = pressedAt.map { Date().timeIntervalSince($0) } ?? 0
                        pressedAt = nil
                        // A tap on a quiet mic keeps it listening until the next tap.
                        if held < Self.tapLimit && !handsFree && live {
                            handsFree = true
                            return
                        }
                        finish()
                    })
            // The run ended on its own (it could not start): back to rest.
            .onChange(of: live) { _, isLive in
                if !isLive { handsFree = false }
            }
            // Leaving with the mic on keeps what was said instead of
            // recording forever.
            .onDisappear { if live { finish() } }
            .tip(live ? (handsFree ? "Tap to send" : "Release to send") : "Hold to talk, or tap to talk hands-free", edge: .top)
            .accessibilityLabel(Text(live ? "Stop listening and send" : "Talk"))
    }

    private func finish() {
        handsFree = false
        Task {
            let text = await dictation.stop()
            if text.isEmpty { Agent.shared.setMood(.idle) } else { onText(text) }
        }
    }
}


/// Your words: as typed, or with the names of people and groups hidden.
private struct UserText: View {
    var text: String

    var body: some View {
        if AppSettings.shared.hideNames {
            Text(MarkdownView.inline(text))
        } else {
            Text(text)
        }
    }
}
