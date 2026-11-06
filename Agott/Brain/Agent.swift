import Foundation
import FoundationModels
import Observation
import OSLog

/// How Agott looks right now. The face reads this.
nonisolated enum Mood: String, Codable, Sendable, CaseIterable {
    case idle, listening, thinking, working, talking, happy, confused, sleepy, love, surprised
}

nonisolated struct Turn: Identifiable, Codable, Hashable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }

    var id = UUID()
    var role: Role
    var text: String
    var cards: [Card] = []
    var date = Date()
    /// The app on screen when this was asked, if the screen was read.
    var screenApp: String?
    var memoryCount = 0
    var error: String?
    var isStreaming = false
    /// What Agott did to write this reply: thinking, context, tool calls.
    var steps: [Step] = []

    init(id: UUID = UUID(), role: Role, text: String, cards: [Card] = [], date: Date = Date(),
         screenApp: String? = nil, memoryCount: Int = 0, error: String? = nil, isStreaming: Bool = false,
         steps: [Step] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.cards = cards
        self.date = date
        self.screenApp = screenApp
        self.memoryCount = memoryCount
        self.error = error
        self.isStreaming = isStreaming
        self.steps = steps
    }

    // Conversations saved before steps existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        cards = try c.decodeIfPresent([Card].self, forKey: .cards) ?? []
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        screenApp = try c.decodeIfPresent(String.self, forKey: .screenApp)
        memoryCount = try c.decodeIfPresent(Int.self, forKey: .memoryCount) ?? 0
        error = try c.decodeIfPresent(String.self, forKey: .error)
        isStreaming = try c.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
    }
}

/// One conversation with Agott, and the loop that runs it.
///
/// Each message goes out with context attached: what is on screen (when asked
/// from the overlay) and what memory recalls for it. The model can then dig
/// further with tools. Cards and approvals arrive through `CardBus` and land on
/// the reply being written.
@Observable
final class Agent {
    static let shared = Agent()

    private(set) var turns: [Turn] = []
    private(set) var mood: Mood = .idle
    private(set) var status: String?
    private(set) var isBusy = false

    @ObservationIgnored private var session: LanguageModelSession?
    @ObservationIgnored private var sessionProvider: ModelProvider?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "br.com.zesmoi.Agott", category: "agent")

    private init() {
        if LaunchOptions.isDemo {
            turns = DemoData.turns()
        } else {
            conversations = Self.loadIndex()
            if let latest = conversations.first {
                currentID = latest.id
                turns = Self.load(latest.id)
            }
        }
        CardBus.statusSink = { [weak self] text in
            self?.status = text
            self?.mood = .working
        }
    }

    var provider: ModelProvider { ModelHub.resolved() }

    func setMood(_ mood: Mood) { self.mood = mood }

    /// Sends a message. `lookAtScreen` attaches what is on screen.
    func send(_ text: String, lookAtScreen: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        task = Task { await run(trimmed, lookAtScreen: lookAtScreen) }
    }

    func cancel() {
        task?.cancel()
        Approvals.shared.denyAll()
        finish(mood: .idle)
        if let index = turns.indices.last, turns[index].isStreaming { turns[index].isStreaming = false }
    }

    // MARK: Artifacts

    /// The artifact open beside the chat, by its stable key.
    var openArtifactKey: String?

    /// Every version of every artifact in this conversation, oldest first.
    var artifacts: [Card.Artifact] {
        turns.flatMap(\.cards).compactMap { card in
            if case .artifact(let artifact) = card { artifact } else { nil }
        }
    }

    func versions(of key: String) -> [Card.Artifact] {
        artifacts.filter { $0.key == key }
    }

    // MARK: Conversations

    /// Every conversation, newest first.
    private(set) var conversations: [ConversationInfo] = []
    private(set) var currentID = UUID()

    /// Recall, or nil when the store does not answer in time.
    private static func recall(_ text: String, within limit: Duration) async -> Retriever.Recall? {
        final class Once { var done = false }
        let once = Once()
        return await withCheckedContinuation { continuation in
            Task {
                let recall = await Retriever().recall(text, limit: 6)
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: recall)
            }
            Task {
                try? await Task.sleep(for: limit)
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: nil)
            }
        }
    }

    /// Starts a fresh conversation; the current one stays in the list.
    func newConversation() {
        openArtifactKey = nil
        cancel()
        save()
        turns = []
        currentID = UUID()
        session = nil
    }

    func open(_ id: UUID) {
        guard id != currentID else { return }
        openArtifactKey = nil
        cancel()
        save()
        currentID = id
        turns = Self.load(id)
        // The model gets this conversation's history back on the next message.
        session = nil
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.fileURL(id))
        Self.saveIndex(conversations)
        if id == currentID {
            turns = []
            currentID = UUID()
            session = nil
        }
    }

    private func run(_ text: String, lookAtScreen: Bool) async {
        isBusy = true
        mood = .thinking
        status = nil
        var user = Turn(role: .user, text: text)
        turns.append(user)
        turns.append(Turn(role: .assistant, text: "", isStreaming: true))
        let replyIndex = turns.count - 1
        let replyID = turns[replyIndex].id

        CardBus.shared.sink = { [weak self] card in
            guard let self, let index = self.turns.firstIndex(where: { $0.id == replyID }) else { return }
            var card = card
            if case .artifact(var artifact) = card {
                // Same title as an earlier one: this is its next version.
                artifact.version = (self.versions(of: artifact.key).map(\.version).max() ?? 0) + 1
                card = .artifact(artifact)
                self.openArtifactKey = artifact.key
            }
            self.turns[index].cards.append(card)
            if case .approval = card { self.mood = .surprised }
        }
        CardBus.shared.update = { [weak self] card in
            guard let self, case .approval(let update) = card,
                  let index = self.turns.firstIndex(where: { $0.id == replyID }),
                  let cardIndex = self.turns[index].cards.firstIndex(where: { $0.id == update.id }),
                  case .approval(var existing) = self.turns[index].cards[cardIndex]
            else { return }
            existing.state = update.state
            self.turns[index].cards[cardIndex] = .approval(existing)
            self.mood = .working
        }

        // Context: the screen, then memory. Each shows as a step.
        var context: [String] = []
        var contextSteps: [Step] = []
        func show(_ step: Step) {
            if let i = contextSteps.firstIndex(where: { $0.id == step.id }) { contextSteps[i] = step } else { contextSteps.append(step) }
            if let index = turns.firstIndex(where: { $0.id == replyID }) { turns[index].steps = contextSteps }
        }
        #if os(macOS)
        if lookAtScreen && AppSettings.shared.useScreenContext {
            status = String(localized: "Looking at your screen…")
            var step = Step(id: "screen", kind: .context, title: String(localized: "Looking at your screen"), symbol: "eye",
                            state: .running, started: .now)
            show(step)
            let snapshot = await ScreenReader.shared.capture(ocr: true)
            if !snapshot.text.isEmpty || !snapshot.elements.isEmpty {
                context.append("What is on the user's screen right now:\n" + snapshot.rendered(maxElements: 80, maxText: 5000))
                user.screenApp = snapshot.appName
                step.title = String(localized: "Looked at \(snapshot.appName)")
                step.detail = String(snapshot.text.prefix(600))
            }
            step.state = .done
            step.ended = .now
            show(step)
        }
        #endif
        status = String(localized: "Searching your memories…")
        var memoryStep = Step(id: "memory", kind: .context, title: String(localized: "Searching your memories"), symbol: "brain.head.profile",
                              state: .running, started: .now)
        show(memoryStep)
        // While a big read holds the store, memory may answer slowly; the
        // reply should not wait on it for long.
        let recall = await Self.recall(text, within: .seconds(10))
        if let recall, !recall.isEmpty {
            context.append(recall.rendered(characterBudget: 7000))
            user.memoryCount = recall.hits.count + recall.facts.count
            memoryStep.title = String(localized: "Remembered \(user.memoryCount) things")
            memoryStep.items = recall.facts.prefix(4).map {
                Step.Item(title: $0.sentence, subtitle: String(localized: "Something I know"), symbol: "pin")
            } + recall.hits.prefix(8).map { hit in
                Step.Item(
                    title: hit.chunk.chatName,
                    subtitle: hit.chunk.source.displayName + " · " + hit.chunk.start.formatted(date: .abbreviated, time: .shortened),
                    snippet: String(hit.chunk.text.split(separator: "\n").suffix(3).joined(separator: "\n").prefix(220)),
                    symbol: hit.chunk.source.symbol)
            }
        } else if recall == nil {
            memoryStep.title = String(localized: "Memory is busy reading; answering without it")
        } else {
            memoryStep.title = String(localized: "Nothing in memory about this")
        }
        memoryStep.state = .done
        memoryStep.ended = .now
        show(memoryStep)
        self.contextSteps = contextSteps
        #if os(macOS)
        // What is playing is part of the moment.
        if let play = MusicListener.shared.nowPlaying {
            let mood = MusicListener.shared.nowMood.map { " (feels \($0.mood), energy \($0.energy)/100)" } ?? ""
            context.append("The user is listening to \"\(play.track)\" by \(play.artist) on \(play.app)\(mood).")
        }
        #endif
        if let index = turns.firstIndex(where: { $0.id == user.id }) { turns[index] = user }

        let prompt = context.isEmpty
            ? text
            : "<context>\n\(context.joined(separator: "\n\n"))\n</context>\n\n\(text)"

        status = nil
        mood = .thinking
        await respond(to: prompt, replyID: replyID, retry: true)
        CardBus.shared.sink = nil
        CardBus.shared.update = nil
        save()
        nameConversation()
    }

    /// Gives the conversation a subject and its people after the first reply,
    /// and again once it has grown (subjects drift).
    private func nameConversation() {
        guard !LaunchOptions.isDemo else { return }
        let id = currentID
        let count = turns.count
        let written = conversations.first { $0.id == id }?.subjectTurns ?? 0
        guard written == 0 || (written < 8 && count >= 8) else { return }
        let transcript = turns.suffix(12).map {
            ($0.role == .user ? "User: " : "Agott: ") + String($0.text.prefix(400))
        }.joined(separator: "\n")
        Task {
            guard let subject = try? await ModelHub.generate(
                ConversationSubject.self, prompt: transcript,
                instructions: "Name this chat between the user and their assistant. Write the title in \(Persona.languageName).",
                provider: ModelHub.bulkProvider) else { return }
            guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
            let me = AppSettings.shared.myName.folded
            conversations[index].subject = subject.title.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            conversations[index].people = subject.people.filter { !$0.isEmpty && $0.folded != me && $0.folded != "agott" }
            conversations[index].subjectTurns = count
            let snapshot = conversations
            Task.detached(priority: .utility) { Self.saveIndex(snapshot) }
        }
    }

    private func respond(to prompt: String, replyID: UUID, retry: Bool) async {
        let provider = ModelHub.resolved()
        if session == nil || sessionProvider != provider {
            // Earlier turns of this conversation come back as history, so a
            // reopened chat carries on instead of starting from nothing.
            let earlier = turns.filter { !$0.isStreaming && $0.id != replyID }.dropLast()
            session = ModelHub.session(
                provider: provider, tools: Persona.tools(for: provider),
                instructions: Persona.instructions(provider: provider),
                thinking: true,
                history: Array(earlier.suffix(30)))
            sessionProvider = provider
        }
        guard let session else { return }

        // Watch the transcript while the model works, so thinking and every
        // tool call appear as they happen, not after.
        let baseline = session.transcript.count
        let clock = StepTracker.Clock()
        let watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.updateSteps(replyID: replyID, session: session, baseline: baseline, clock: clock, busy: true)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer {
            watcher.cancel()
            updateSteps(replyID: replyID, session: session, baseline: baseline, clock: clock, busy: false)
        }

        do {
            let stream = session.streamResponse(to: prompt)
            for try await snapshot in stream {
                try Task.checkCancellation()
                guard let index = turns.firstIndex(where: { $0.id == replyID }) else { break }
                turns[index].text = snapshot.content
                if !snapshot.content.isEmpty { mood = .talking; status = nil }
            }
            if let index = turns.firstIndex(where: { $0.id == replyID }) {
                turns[index].isStreaming = false
                let hasCards = !turns[index].cards.isEmpty
                finish(mood: hasCards ? .happy : .idle)
            }
        } catch is CancellationError {
            finish(mood: .idle)
        } catch let error as LanguageModelError {
            if case .contextSizeExceeded = error, retry {
                // Start over with a clean session; the conversation so far is
                // already summarised in the turns the user can see.
                self.session = nil
                await respond(to: prompt, replyID: replyID, retry: false)
                return
            }
            fail(replyID, error)
        } catch {
            fail(replyID, error)
        }
    }

    @ObservationIgnored private var contextSteps: [Step] = []

    private func updateSteps(replyID: UUID, session: LanguageModelSession, baseline: Int, clock: StepTracker.Clock, busy: Bool) {
        guard let index = turns.firstIndex(where: { $0.id == replyID }) else { return }
        let derived = StepTracker.steps(from: session.transcript, after: baseline, busy: busy, clock: clock)
        let steps = contextSteps + derived
        if turns[index].steps != steps { turns[index].steps = steps }
        if busy, let running = derived.last(where: { $0.state == .running }) {
            status = running.title + "…"
            mood = running.kind == .thinking ? .thinking : .working
        }
    }

    private func fail(_ id: UUID, _ error: Error) {
        log.error("Turn failed: \(error.localizedDescription, privacy: .public)")
        if let index = turns.firstIndex(where: { $0.id == id }) {
            turns[index].isStreaming = false
            turns[index].error = error.localizedDescription
        }
        // A broken session (bad key, network) should not poison the next try.
        session = nil
        finish(mood: .confused)
    }

    private func finish(mood: Mood) {
        isBusy = false
        status = nil
        self.mood = mood
        guard mood == .happy || mood == .confused else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if !self.isBusy { self.mood = .idle }
        }
    }

    // MARK: Persistence

    nonisolated private static var folder: URL {
        let folder = URL.applicationSupportDirectory.appending(path: "Agott/Conversations", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    nonisolated private static func fileURL(_ id: UUID) -> URL { folder.appending(path: "\(id.uuidString).json") }
    nonisolated private static var indexURL: URL { folder.appending(path: "index.json") }

    private func save() {
        guard !LaunchOptions.isDemo, !turns.isEmpty else { return }
        let recent = Array(turns.suffix(400))
        let id = currentID
        let title = turns.first(where: { $0.role == .user })?.text ?? String(localized: "New conversation")
        let previous = conversations.first { $0.id == id }
        var info = ConversationInfo(
            id: id, title: String(title.prefix(70)),
            preview: String((turns.last { $0.role == .assistant }?.text ?? "").prefix(90)),
            updated: turns.last?.date ?? .now)
        info.subject = previous?.subject
        info.people = previous?.people
        info.subjectTurns = previous?.subjectTurns
        conversations.removeAll { $0.id == id }
        conversations.insert(info, at: 0)
        conversations.sort { $0.updated > $1.updated }
        let index = conversations
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(recent) { try? data.write(to: Self.fileURL(id), options: .atomic) }
            Self.saveIndex(index)
        }
    }

    nonisolated private static func saveIndex(_ index: [ConversationInfo]) {
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: indexURL, options: .atomic) }
    }

    nonisolated private static func loadIndex() -> [ConversationInfo] {
        if let data = try? Data(contentsOf: indexURL),
           let index = try? JSONDecoder().decode([ConversationInfo].self, from: data) {
            return index.sorted { $0.updated > $1.updated }
        }
        // The single conversation from before becomes the first in the list.
        let old = URL.applicationSupportDirectory.appending(path: "Agott/conversation.json")
        guard let data = try? Data(contentsOf: old),
              let turns = try? JSONDecoder().decode([Turn].self, from: data), !turns.isEmpty else { return [] }
        let id = UUID()
        try? data.write(to: fileURL(id), options: .atomic)
        let info = ConversationInfo(
            id: id, title: String((turns.first { $0.role == .user }?.text ?? "Agott").prefix(70)),
            preview: String((turns.last { $0.role == .assistant }?.text ?? "").prefix(90)),
            updated: turns.last?.date ?? .now)
        saveIndex([info])
        try? FileManager.default.removeItem(at: old)
        return [info]
    }

    nonisolated private static func load(_ id: UUID) -> [Turn] {
        guard let data = try? Data(contentsOf: fileURL(id)),
              var turns = try? JSONDecoder().decode([Turn].self, from: data)
        else { return [] }
        for index in turns.indices { turns[index].isStreaming = false }
        return turns
    }
}

nonisolated struct ConversationInfo: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var preview: String
    var updated: Date
    /// What it is about, in a few words, written by Agott.
    var subject: String?
    /// The people it is about, by name.
    var people: [String]?
    /// How many turns the subject was written from.
    var subjectTurns: Int?

    var displayTitle: String { subject ?? title }
}

/// A conversation's subject and the people in it, written after it starts.
@Generable
struct ConversationSubject {
    @Guide(description: "What the conversation is about, two to five words, like a chat title. No quotes, no emoji.")
    var title: String
    @Guide(description: "Real people the conversation is about, by the names used in it. Not the user, not Agott. Empty if none.", .maximumCount(4))
    var people: [String]
}
