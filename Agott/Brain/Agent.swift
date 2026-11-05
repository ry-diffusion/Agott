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

        // Context: the screen, then memory.
        var context: [String] = []
        #if os(macOS)
        if lookAtScreen && AppSettings.shared.useScreenContext {
            status = String(localized: "Looking at your screen…")
            let snapshot = await ScreenReader.shared.capture(ocr: true)
            if !snapshot.text.isEmpty || !snapshot.elements.isEmpty {
                context.append("What is on the user's screen right now:\n" + snapshot.rendered(maxElements: 80, maxText: 5000))
                user.screenApp = snapshot.appName
            }
        }
        #endif
        status = String(localized: "Remembering…")
        let recall = await Retriever().recall(text, limit: 6)
        if !recall.isEmpty {
            context.append(recall.rendered(characterBudget: 7000))
            user.memoryCount = recall.hits.count + recall.facts.count
        }
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
