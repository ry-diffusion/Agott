import SwiftUI

/// The iPhone talking to Agott on the Mac.
struct RemoteChatView: View {
    @State private var remote = RemoteMac.shared
    @State private var draft = ""
    @State private var code = ""
    @State private var lookAtScreen = false
    @State private var dictation = Dictation.shared

    var body: some View {
        Group {
            if remote.link == .connected {
                conversation
            } else {
                pairing
            }
        }
        .navigationTitle(Text(remote.macName ?? String(localized: "Your Mac")))
        .task { remote.browse() }
    }

    private var pairing: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    MuseFace(mood: remote.link == .connecting ? .thinking : .sleepy, size: 80)
                    Text("Talk to Agott on your Mac").font(.title3.weight(.semibold))
                    Text("Your Mac has your memory, your screen and your apps. Pair once with the code from Agott → Settings → iPhone.")
                        .multilineTextAlignment(.center).foregroundStyle(Ink.muted).font(.callout)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section("Pairing code") {
                TextField("6 digits", text: $code)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .font(.system(.title2, design: .monospaced))
                    .onAppear { code = remote.pairingCode }
            }
            Section("Macs nearby") {
                if remote.found.isEmpty {
                    Label("Looking for Agott on your network…", systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(Ink.muted)
                }
                ForEach(remote.found) { mac in
                    Button {
                        remote.connect(to: mac, code: code)
                    } label: {
                        Label(mac.name, systemImage: "laptopcomputer")
                    }
                    .disabled(code.count != 6)
                }
            }
            if case .failed(let message) = remote.link {
                Section { Text(message).foregroundStyle(.orange) }
            }
        }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(remote.turns) { turn in
                            if turn.role == .user {
                                HStack {
                                    Spacer(minLength: 50)
                                    Text(turn.text)
                                        .padding(.horizontal, 14).padding(.vertical, 9)
                                        .background(Ink.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                }
                            } else {
                                RemoteTurnView(turn: turn)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .onChange(of: remote.turns.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            HStack(alignment: .bottom, spacing: 8) {
                MuseFace(mood: remote.mood, size: 34, level: dictation.level)
                VStack(alignment: .leading, spacing: 2) {
                    if let status = remote.status { Text(status).font(.caption).foregroundStyle(Ink.muted) }
                    TextField(dictation.isRunning ? String(localized: "Listening…") : String(localized: "Ask your Mac"),
                              text: dictation.isRunning ? .constant(dictation.transcript) : $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(10)
                        .background(Ink.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                Toggle(isOn: $lookAtScreen) { Image(systemName: lookAtScreen ? "eye.fill" : "eye") }
                    .toggleStyle(.button)
                HoldToTalkButton { text in send(text) }
                if remote.isBusy {
                    Button { remote.send(.cancel) } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                } else {
                    Button { send(draft) } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(12)
            .background(.bar)
        }
        .toolbar {
            Menu {
                Button("New conversation") { remote.send(.newConversation) }
                Button("Disconnect", role: .destructive) { remote.disconnect() }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        remote.send(.ask(text: trimmed, lookAtScreen: lookAtScreen))
        draft = ""
    }
}

/// A reply streamed from the Mac. Approvals answer the Mac, not this phone.
private struct RemoteTurnView: View {
    var turn: Turn

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !turn.text.isEmpty {
                Text(AssistantTurnView.markdown(turn.text)).textSelection(.enabled)
            } else if turn.isStreaming && turn.cards.isEmpty {
                TypingDots()
            }
            ForEach(turn.cards) { card in
                if case .approval(let approval) = card {
                    RemoteApprovalCard(card: approval)
                } else {
                    CardView(card: card)
                }
            }
            if let error = turn.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
        }
    }
}

private struct RemoteApprovalCard: View {
    var card: Card.Approval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(card.title, systemImage: "hand.raised.fill").font(.headline).foregroundStyle(.orange)
            Text(card.detail).font(.callout).lineLimit(8)
            if card.state == .pending {
                HStack {
                    Button("Allow") { RemoteMac.shared.send(.approve(id: card.id, allow: true)) }
                        .buttonStyle(.borderedProminent)
                    Button("Don't") { RemoteMac.shared.send(.approve(id: card.id, allow: false)) }
                }
            } else {
                Text(card.state == .approved ? "Allowed" : "Declined").font(.caption).foregroundStyle(Ink.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(padding: 12)
    }
}
