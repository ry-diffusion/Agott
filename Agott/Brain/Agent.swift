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
        turns = LaunchOptions.isDemo ? DemoData.turns() : Self.load()
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

    func newConversation() {
        cancel()
        turns = []
        session = nil
        save()
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
        status = String(localized: "Remembering…")
        var memoryStep = Step(id: "memory", kind: .context, title: String(localized: "Remembering"), symbol: "brain.head.profile",
                              state: .running, started: .now)
        show(memoryStep)
        let recall = await Retriever().recall(text, limit: 6)
        if !recall.isEmpty {
            context.append(recall.rendered(characterBudget: 7000))
            user.memoryCount = recall.hits.count + recall.facts.count
            memoryStep.title = String(localized: "Remembered \(user.memoryCount) things")
            memoryStep.detail = recall.hits.prefix(5).map { "· \($0.chunk.chatName)" }.joined(separator: "\n")
        } else {
            memoryStep.title = String(localized: "Nothing in memory about this")
        }
        memoryStep.state = .done
        memoryStep.ended = .now
        show(memoryStep)
        self.contextSteps = contextSteps
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
    }

    private func respond(to prompt: String, replyID: UUID, retry: Bool) async {
        let provider = ModelHub.resolved()
        if session == nil || sessionProvider != provider {
            session = ModelHub.session(
                provider: provider, tools: Persona.tools(for: provider),
                instructions: Persona.instructions(provider: provider))
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

    nonisolated private static var fileURL: URL {
        let folder = URL.applicationSupportDirectory.appending(path: "Agott", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "conversation.json")
    }

    private func save() {
        guard !LaunchOptions.isDemo else { return }
        let recent = Array(turns.suffix(200))
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(recent) { try? data.write(to: Self.fileURL, options: .atomic) }
        }
    }

    private static func load() -> [Turn] {
        guard let data = try? Data(contentsOf: fileURL),
              var turns = try? JSONDecoder().decode([Turn].self, from: data)
        else { return [] }
        for index in turns.indices { turns[index].isStreaming = false }
        return turns
    }
}
