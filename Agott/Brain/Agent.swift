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
    /// Files sent with this message.
    var attachments: [FileAttachment] = []

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
        attachments = try c.decodeIfPresent([FileAttachment].self, forKey: .attachments) ?? []
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
    /// The conversation a reply is being written in. It keeps going when you
    /// switch to another chat, and lands where it was asked.
    private(set) var runningConversation: UUID?
    /// Busy in the chat on screen (not one you left mid-reply).
    var isBusyHere: Bool { isBusy && runningConversation == currentID }
    /// Chats you left while their reply was still coming, until it lands.
    @ObservationIgnored private var away: [UUID: [Turn]] = [:]

    @ObservationIgnored private var session: LanguageModelSession?
    @ObservationIgnored private var sessionProvider: ModelProvider?
    /// The model the session was made for: picking another starts a new one.
    @ObservationIgnored private var sessionModel: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var taskToken = UUID()
    @ObservationIgnored private let log = Logger(subsystem: "br.com.zesmoi.Agott", category: "agent")

    private init() {
        if LaunchOptions.isDemo {
            turns = DemoData.turns()
            conversations = DemoData.conversations(current: currentID)
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
    /// A message written while Agott was still answering; it goes next.
    struct Queued: Identifiable, Hashable {
        var id = UUID()
        var text: String
        var lookAtScreen: Bool
        var attachments: [FileAttachment]
        var date = Date()
    }

    /// Messages waiting their turn, oldest first.
    private(set) var queue: [Queued] = []

    func send(_ text: String, lookAtScreen: Bool = false, attachments: [FileAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        let message = Queued(text: trimmed, lookAtScreen: lookAtScreen, attachments: attachments)
        // Busy: wait in line instead of being dropped.
        if isBusy || task != nil {
            queue.append(message)
            return
        }
        start(message)
    }

    func unqueue(_ id: UUID) { queue.removeAll { $0.id == id } }

    private func start(_ message: Queued) {
        let token = UUID()
        taskToken = token
        task = Task {
            await run(message.text, lookAtScreen: message.lookAtScreen, attachments: message.attachments)
            // A stopped run must not clear or advance a newer one.
            guard taskToken == token else { return }
            task = nil
            if !queue.isEmpty { start(queue.removeFirst()) }
        }
    }

    func cancel() {
        queue.removeAll()
        task?.cancel()
        task = nil
        taskToken = UUID()
        Approvals.shared.denyAll()
        finish(mood: .idle)
        if let index = turns.indices.last, turns[index].isStreaming { turns[index].isStreaming = false }
    }

    // MARK: Turns, wherever they are

    /// Changes one turn, in the chat on screen or in one you left mid-reply.
    @discardableResult
    private func update(_ id: UUID, _ body: (inout Turn) -> Void) -> Bool {
        if let index = turns.firstIndex(where: { $0.id == id }) {
            body(&turns[index])
            return true
        }
        for key in away.keys {
            if let index = away[key]?.firstIndex(where: { $0.id == id }) {
                body(&away[key]![index])
                return true
            }
        }
        return false
    }

    private func turn(_ id: UUID) -> Turn? {
        turns.first { $0.id == id } ?? away.values.lazy.compactMap { $0.first { $0.id == id } }.first
    }

    private func turns(in conversation: UUID) -> [Turn] {
        conversation == currentID ? turns : (away[conversation] ?? [])
    }

    /// Leaving the chat on screen. A reply still coming keeps coming.
    private func leaveCurrent() {
        if isBusyHere {
            away[currentID] = turns
            // Messages queued here would land in the next chat; drop them.
            queue.removeAll()
        } else if isBusy {
            // A reply in another chat is still coming; leave it be.
            queue.removeAll()
        } else {
            cancel()
        }
        save()
    }

    // MARK: Going back

    /// Back to just before this message: it and everything after it leave
    /// the conversation, and the model forgets them too. Returns the message.
    @discardableResult
    func rewind(to id: UUID) -> Turn? {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return nil }
        let turn = turns[index]
        if isBusyHere { cancel() }
        turns.removeSubrange(index...)
        if let key = openArtifactKey, !artifacts.contains(where: { $0.key == key }) { openArtifactKey = nil }
        // The next message rebuilds the model's history from what is left.
        session = nil
        save(allowEmpty: true)
        return turn
    }

    /// Replaces one of your messages: the answers after it go, and the new
    /// words are asked instead.
    func edit(_ id: UUID, to text: String, attachments: [FileAttachment]) {
        guard let original = rewind(to: id) else { return }
        send(text, lookAtScreen: original.screenApp != nil, attachments: attachments)
    }

    /// Asks again: from a reply, the message before it; from your message, itself.
    func retry(_ id: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        guard let question = turns[...index].last(where: { $0.role == .user }), let original = rewind(to: question.id) else { return }
        send(original.text, lookAtScreen: original.screenApp != nil, attachments: original.attachments)
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
    private static func recall(_ text: String, near: Set<Int64> = [], within limit: Duration) async -> Retriever.Recall? {
        final class Once { var done = false }
        let once = Once()
        return await withCheckedContinuation { continuation in
            Task {
                let recall = await Retriever().recall(text, limit: 6, near: near)
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
        leaveCurrent()
        turns = []
        currentID = UUID()
        session = nil
    }

    func open(_ id: UUID) {
        guard id != currentID else { return }
        openArtifactKey = nil
        leaveCurrent()
        currentID = id
        // Back to a chat whose reply is still coming: pick it up live.
        turns = away.removeValue(forKey: id) ?? Self.load(id)
        // The model gets this conversation's history back on the next message.
        session = nil
    }

    func delete(_ id: UUID) {
        if runningConversation == id { cancel() }
        away[id] = nil
        conversations.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.fileURL(id))
        Self.saveIndex(conversations)
        if id == currentID {
            turns = []
            currentID = UUID()
            session = nil
        }
    }

    private func run(_ text: String, lookAtScreen: Bool, attachments: [FileAttachment] = []) async {
        // A newer fix for next time; this message uses the one already known.
        Whereabouts.shared.refresh()
        // Which run this is: Stop, Edit and Ask again start a new one, and
        // this one must not touch its state when it wakes up late.
        let runToken = taskToken
        isBusy = true
        let conversation = currentID
        runningConversation = conversation
        mood = .thinking
        status = nil
        // What was said just before, so "and her?" can be resolved.
        let earlier = turns.suffix(4).map { ($0.role == .user ? "User: " : "Agott: ") + String($0.text.prefix(300)) }
        var user = Turn(role: .user, text: text)
        user.attachments = attachments
        turns.append(user)
        turns.append(Turn(role: .assistant, text: "", isStreaming: true))
        let replyIndex = turns.count - 1
        let replyID = turns[replyIndex].id

        CardBus.shared.sink = { [weak self] card in
            guard let self else { return }
            var card = card
            if case .artifact(var artifact) = card {
                // Same title as an earlier one: this is its next version.
                let earlier = self.turns(in: conversation).flatMap(\.cards).compactMap { card -> Card.Artifact? in
                    if case .artifact(let a) = card { a } else { nil }
                }
                artifact.version = (earlier.filter { $0.key == artifact.key }.map(\.version).max() ?? 0) + 1
                card = .artifact(artifact)
                if conversation == self.currentID { self.openArtifactKey = artifact.key }
            }
            self.update(replyID) { turn in
                // The same list twice in one reply (a model that shows the
                // ranking spotify_top already drew): keep the first.
                if case .collection(let list) = card,
                   turn.cards.contains(where: { if case .collection(let other) = $0 { other.repeats(list) } else { false } }) {
                    return
                }
                turn.cards.append(card)
            }
            if case .approval = card { self.mood = .surprised }
        }
        CardBus.shared.update = { [weak self] card in
            guard let self, case .approval(let approval) = card else { return }
            self.update(replyID) { turn in
                guard let cardIndex = turn.cards.firstIndex(where: { $0.id == approval.id }),
                      case .approval(var existing) = turn.cards[cardIndex] else { return }
                existing.state = approval.state
                turn.cards[cardIndex] = .approval(existing)
            }
            self.mood = .working
        }

        // Context: the screen, then memory. Each shows as a step.
        var context: [String] = []
        var contextSteps: [Step] = []
        func show(_ step: Step) {
            if let i = contextSteps.firstIndex(where: { $0.id == step.id }) { contextSteps[i] = step } else { contextSteps.append(step) }
            update(replyID) { $0.steps = contextSteps }
        }
        #if os(macOS)
        if lookAtScreen && AppSettings.shared.useScreenContext {
            status = String(localized: "Looking at your screen…")
            var step = Step(id: "screen", kind: .context, title: String(localized: "Looking at your screen"), symbol: "eye",
                            state: .running, started: .now)
            show(step)
            let snapshot = await ScreenReader.shared.capture()
            if !snapshot.isEmpty {
                let screen = snapshot.rendered(maxCharacters: 4000)
                context.append("What is on the user's screen right now (act on elements by their [id]):\n" + screen)
                user.screenApp = snapshot.appName
                step.title = String(localized: "Looked at \(snapshot.appName)")
                step.detail = String((snapshot.text.isEmpty ? screen : snapshot.text).prefix(600))
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
        // Jev plans everything this message needs (who, when, the chat, the
        // relationship, the calendar) while the general recall runs, and it
        // is all fetched at once: one wait instead of a tool call per need.
        let planned = Task { () -> [RecallPlanner.Gathered] in
            guard let plan = await RecallPlanner.plan(for: text, earlier: earlier), !plan.isEmpty else { return [] }
            return await RecallPlanner.gather(plan, query: text)
        }
        // Who the conversation is already about: "a Ana" after talking
        // about one Ana is that Ana.
        let near = Set(turns.suffix(6).flatMap { PeopleDirectory.tags(in: $0.text) })
        let recall = await Self.recall(text, near: near, within: .seconds(10))
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
        let gathered = await planned.value
        for (index, item) in gathered.enumerated() {
            show(Step(id: "plan-\(index)", kind: .context, title: item.title, symbol: item.symbol, state: .done,
                      detail: String(item.text.prefix(600)), started: .now, ended: .now))
        }
        if !gathered.isEmpty {
            context.append(
                "Gathered for this message before you answer. Use it first; call a tool only for something "
                + "specific that is still missing.\n\n"
                + gathered.map { "## \($0.title)\n\($0.text)" }.joined(separator: "\n\n"))
        }
        self.contextSteps = contextSteps
        #if os(macOS)
        // What is playing is part of the moment.
        if let play = MusicListener.shared.nowPlaying {
            let mood = MusicListener.shared.nowMood.map { " (feels \($0.mood), energy \($0.energy)/100)" } ?? ""
            context.append("The user is listening to \"\(play.track)\" by \(play.artist) on \(play.app)\(mood).")
        }
        #endif
        update(user.id) { $0 = user }

        // Files: their words go in the context; images go as images when the
        // model can see.
        var images: [URL] = []
        if !attachments.isEmpty {
            let files = await AttachmentStore.context(for: attachments, modelSeesImages: Self.chatSeesImages)
            if !files.text.isEmpty { context.append("Files the user sent with this message:\n" + files.text) }
            images = files.images
        }
        let ask = text.isEmpty ? String(localized: "Take a look at this.") : text
        let prompt = context.isEmpty
            ? ask
            : "<context>\n\(context.joined(separator: "\n\n"))\n</context>\n\n\(ask)"

        // Stopped while remembering or planning: no answer, nothing to clean
        // up that a newer run now owns.
        guard taskToken == runToken, !Task.isCancelled else { return }
        status = nil
        mood = .thinking
        await respond(to: prompt, images: images, replyID: replyID, conversation: conversation, retry: true)
        // Names the model wrote plainly become tags too, for the people it was
        // told about, so hiding names hides them all.
        let told = PeopleDirectory.tags(in: prompt).compactMap { PeopleDirectory.shared.name($0) }
        if !told.isEmpty { update(replyID) { $0.text = PeopleDirectory.tagNames($0.text, people: told) } }
        save(conversation)
        nameConversation(conversation)
        // What they said in passing is kept without them asking: who someone
        // is, a nickname, that something ended. It runs after the reply, so
        // it never makes them wait, and says what it kept.
        if !text.isEmpty {
            Task { [weak self] in
                let heard = await Listening.hear(text, earlier: earlier)
                guard !heard.isEmpty, let self else { return }
                let kept = heard.facts + heard.nicknames + heard.ties
                let step = Step(id: "heard", kind: .context,
                                title: kept == 1 ? String(localized: "Kept one thing you told me")
                                    : String(localized: "Kept \(kept) things you told me"),
                                symbol: "pin", state: .done, started: .now, ended: .now)
                if self.update(replyID, { $0.steps.append(step) }) { self.save(conversation) }
            }
        }
        // Only the run that still owns them lets go of the card channel and
        // of a chat you left (its reply has landed and is saved).
        guard taskToken == runToken else { return }
        CardBus.shared.sink = nil
        CardBus.shared.update = nil
        if conversation != currentID { away[conversation] = nil }
    }

    /// Gives the conversation a subject and its people after the first reply,
    /// and again once it has grown (subjects drift).
    private func nameConversation(_ id: UUID) {
        guard !LaunchOptions.isDemo else { return }
        let turns = turns(in: id)
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

    /// Whether the chat model takes images.
    static var chatSeesImages: Bool {
        ModelHub.resolved() == .openCode && (ModelCatalog.shared.model(AppSettings.shared.modelName)?.vision ?? false)
    }

    private func respond(to prompt: String, images: [URL] = [], replyID: UUID, conversation: UUID, retry: Bool) async {
        let provider = ModelHub.resolved()
        // The chat's own session; a chat you left gets one of its own, so
        // the one on screen never inherits another chat's history.
        let model = AppSettings.shared.modelName
        var active = conversation == currentID && sessionProvider == provider && sessionModel == model ? session : nil
        if active == nil {
            // Earlier turns of this conversation come back as history, so a
            // reopened chat carries on instead of starting from nothing.
            let earlier = turns(in: conversation).filter { !$0.isStreaming && $0.id != replyID }.dropLast()
            active = ModelHub.session(
                provider: provider, tools: Persona.tools(for: provider),
                instructions: Persona.instructions(provider: provider),
                // The chat model itself sees images when it can.
                vision: Self.chatSeesImages,
                modelName: Self.chatSeesImages ? AppSettings.shared.modelName : nil,
                thinking: true,
                history: Array(earlier.suffix(30)))
            if conversation == currentID {
                session = active
                sessionProvider = provider
                sessionModel = model
            }
        }
        guard let session = active else { return }

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
            let stream = session.streamResponse(to: Prompt {
                prompt
                images.map { FoundationModels.Attachment(imageURL: $0) }
            })
            for try await snapshot in stream {
                try Task.checkCancellation()
                guard update(replyID, { $0.text = snapshot.content }) else { break }
                if !snapshot.content.isEmpty { mood = .talking; status = nil }
            }
            var hasCards = false
            if update(replyID, { $0.isStreaming = false; hasCards = !$0.cards.isEmpty }) {
                finish(mood: hasCards ? .happy : .idle)
            }
        } catch is CancellationError {
            // `cancel()` already settled things; a newer run may be going.
        } catch let error as LanguageModelError {
            if case .contextSizeExceeded = error, retry {
                // Start over with a clean session; the conversation so far is
                // already summarised in the turns the user can see.
                if conversation == currentID { self.session = nil }
                await respond(to: prompt, images: images, replyID: replyID, conversation: conversation, retry: false)
                return
            }
            fail(replyID, error)
        } catch {
            fail(replyID, error)
        }
    }

    @ObservationIgnored private var contextSteps: [Step] = []

    private func updateSteps(replyID: UUID, session: LanguageModelSession, baseline: Int, clock: StepTracker.Clock, busy: Bool) {
        guard let current = turn(replyID) else { return }
        let derived = StepTracker.steps(from: session.transcript, after: baseline, busy: busy, clock: clock)
        let steps = contextSteps + derived
        if current.steps != steps { update(replyID) { $0.steps = steps } }
        if busy, let running = derived.last(where: { $0.state == .running }) {
            status = running.title + "…"
            mood = running.kind == .thinking ? .thinking : .working
        }
    }

    private func fail(_ id: UUID, _ error: Error) {
        // Stopped on purpose (stop, edit, try again): not a failure.
        guard !Task.isCancelled else { return }
        log.error("Turn failed: \(error.localizedDescription, privacy: .public)")
        update(id) {
            $0.isStreaming = false
            $0.error = error.localizedDescription
        }
        // A broken session (bad key, network) should not poison the next try.
        session = nil
        finish(mood: .confused)
    }

    private func finish(mood: Mood) {
        isBusy = false
        runningConversation = nil
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

    private func save(_ conversation: UUID? = nil, allowEmpty: Bool = false) {
        let id = conversation ?? currentID
        let turns = turns(in: id)
        guard !LaunchOptions.isDemo, allowEmpty || !turns.isEmpty else { return }
        let recent = Array(turns.suffix(400))
        let title = turns.first(where: { $0.role == .user })?.text ?? String(localized: "New conversation")
        let previous = conversations.first { $0.id == id }
        var info = ConversationInfo(
            id: id, title: String(title.prefix(70)),
            preview: String((turns.last { $0.role == .assistant }?.text ?? "").markdownStripped.prefix(90)),
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
            preview: String((turns.last { $0.role == .assistant }?.text ?? "").markdownStripped.prefix(90)),
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

// MARK: - Artifact library

/// One artifact in the library: its newest version and where it was made.
nonisolated struct LibraryItem: Identifiable, Hashable, Sendable {
    var artifact: Card.Artifact
    var versions: Int
    var conversation: UUID
    var conversationTitle: String
    var date: Date
    var id: String { "\(conversation.uuidString)|\(artifact.key)" }
}

extension Agent {
    /// Every artifact from every saved conversation, newest first: the
    /// latest version of each, read off the main thread.
    nonisolated static func library(of conversations: [ConversationInfo]) async -> [LibraryItem] {
        var items: [LibraryItem] = []
        for info in conversations {
            let turns = load(info.id)
            var latest: [String: (Card.Artifact, Date, Int)] = [:]
            for turn in turns {
                for card in turn.cards {
                    guard case .artifact(let artifact) = card else { continue }
                    let count = (latest[artifact.key]?.2 ?? 0) + 1
                    latest[artifact.key] = (artifact, turn.date, count)
                }
            }
            for (_, entry) in latest {
                items.append(LibraryItem(artifact: entry.0, versions: entry.2, conversation: info.id,
                                         conversationTitle: info.displayTitle, date: entry.1))
            }
        }
        return items.sorted { $0.date > $1.date }
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
