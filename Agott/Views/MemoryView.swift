import SwiftUI
import UniformTypeIdentifiers

/// What Agott remembers, where it came from, and a way to search it yourself.
struct MemoryView: View {
    @State private var indexer = Indexer.shared
    @State private var query = ""
    @State private var hits: [MemoryHit] = []
    @State private var searching = false
    @State private var importing = false
    @State private var recent: [MemoryChunk] = []
    @State private var feedSource: MemorySource?
    @State private var feedLimit = 30
    @State private var lastFeed = Date.distantPast
    @State private var confirmReread = false
    @State private var estimate: (moments: Int, tokens: Int, dollars: Double?)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ScreenHeader(title: "Memory", subtitle: "Everything Agott remembers, and where it came from.", symbol: "brain") {
                    if indexer.isPaused {
                        Button { indexer.resume() } label: { Label("Resume indexing", systemImage: "play.fill") }
                            .buttonStyle(.candy)
                    } else if indexer.isRunning || indexer.isLearning {
                        Button { indexer.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                            .buttonStyle(.candy(.soft))
                    } else {
                        HStack(spacing: 8) {
                            Button {
                                Task {
                                    estimate = await indexer.peopleRelearnEstimate()
                                    confirmReread = true
                                }
                            } label: { Label("Read again", systemImage: "arrow.counterclockwise") }
                                .buttonStyle(.candy(.soft))
                                .help(Text("Learn again from your conversations: who is who, nicknames, links between people"))
                            Button { indexer.run() } label: { Label("Update memory", systemImage: "arrow.triangle.2.circlepath") }
                                .buttonStyle(.candy)
                        }
                    }
                }
                totals
                    .confirmationDialog(Text("Read your conversations again?"), isPresented: $confirmReread) {
                        Button("Reread people") { indexer.rereadPeople() }
                        Button("Read everything, Claude too") { indexer.reread() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(rereadMessage)
                    }
                MemoryDigest()
                DeepMoments()
                sources
                search
                if query.isEmpty || hits.isEmpty {
                    feed
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 30)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .task { await indexer.refreshTotals() }
        .task(id: "\(feedSource?.rawValue ?? "all")-\(feedLimit)") { await loadFeed() }
        // New memories arrive while indexing; refresh the feed now and then.
        .onChange(of: indexer.totals.chunks) { _, _ in
            guard Date().timeIntervalSince(lastFeed) > 10 else { return }
            Task { await loadFeed() }
        }
        #if os(macOS)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { Task { await indexer.importClaudeExport(url) } }
        }
        #endif
    }

    /// What a people re-read reads and roughly costs.
    private var rereadMessage: String {
        var text = String(localized: "Agott reads your WhatsApp and iMessage conversations again, groups you only read included, starting with the people you talk to most. It learns facts with proof, nicknames, who is linked to whom, and rewrites the conversations that mattered. What it already knows stays.")
        if let estimate {
            let tokens = estimate.tokens.formatted(.number.notation(.compactName))
            text += "\n\n" + String(localized: "\(estimate.moments) moments, about \(tokens) tokens")
            if let dollars = estimate.dollars {
                text += " · " + String(localized: "about \(dollars.formatted(.currency(code: "USD")))")
            }
            text += ". " + String(localized: "It runs in the background; you can pause it.")
        }
        return text
    }

    /// Where memory stands: one quiet line, the orb while it reads.
    private var totals: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                if indexer.isRunning || indexer.isLearning {
                    ThinkingOrb(mode: .globe, size: 22)
                } else {
                    Image(systemName: "checkmark.circle").font(.system(size: 18)).foregroundStyle(Ink.muted)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(indexer.statusText).font(.body.weight(.medium)).foregroundStyle(Ink.text)
                    Text("\(indexer.totals.messages) messages · \(indexer.totals.chunks) moments · \(indexer.totals.vectors) understood · \(indexer.totals.entities) things in the graph · \(indexer.totals.facts) facts")
                        .font(.callout).monospacedDigit().foregroundStyle(Ink.muted)
                }
                Spacer()
                if indexer.isRunning, let progress = indexer.progress {
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .font(.callout).monospacedDigit().foregroundStyle(Ink.text)
                }
            }
            if indexer.isRunning {
                ProgressView(value: indexer.progress ?? 0)
                    .progressViewStyle(.linear)
                    .tint(Ink.spot)
                    .opacity(indexer.progress == nil ? 0 : 1)
            }
            if let error = indexer.lastError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Ink.text)
            }
            if !indexer.findings.isEmpty {
                RunFindingsView(findings: indexer.findings)
            }
            if indexer.totals.messages == 0 && !indexer.isRunning {
                Text("Agott hasn't read anything yet. Start indexing to let it remember your WhatsApp, iMessage and Claude history. It runs in the background; you can keep using the app.")
                    .font(.callout)
                    .foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { indexer.run() } label: { Label("Start indexing", systemImage: "play.fill") }
                        .buttonStyle(.candy(.primary, compact: true))
                    if !Permissions.isGranted(.fullDiskAccess) {
                        Button("Grant Full Disk Access") { Permissions.openFullDiskAccess() }
                            .buttonStyle(.candy(.soft, compact: true))
                    }
                }
            }
        }
        .padding(16)
        .quietSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Where memories come from, as rows like Settings.
    private var sources: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Sources")
            SettingsCard {
                ForEach([MemorySource.whatsapp, .imessage, .claude], id: \.self) { source in
                    SourceRow(source: source)
                }
                #if os(macOS)
                SettingsRow(symbol: "square.and.arrow.down", title: "Import a claude.ai export…",
                            detail: "conversations.json from Settings → Privacy → Export data") {
                    Button("Import") { importing = true }
                        .buttonStyle(.candy(.soft, compact: true))
                }
                #endif
            }
        }
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Search your memory")
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Ink.muted)
                TextField(String(localized: "Anything: a name, a plan, a feeling…"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .onSubmit { Task { await runSearch() } }
                if searching { ProgressView().controlSize(.small) }
                Button("Search") { Task { await runSearch() } }
                    .buttonStyle(.candy(.soft, compact: true))
                    .disabled(query.isEmpty || searching)
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(minHeight: 50)
            .quietSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
            ForEach(hits) { hit in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: hit.chunk.source.symbol).foregroundStyle(Ink.muted)
                        Text(hit.chunk.chatName).font(.headline).foregroundStyle(Ink.text).lineLimit(1)
                        Spacer()
                        ForEach(Array(hit.matchedBy).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { signal in
                            Chip(text: signal.label, spot: signal == .meaning)
                        }
                        Text(hit.chunk.start, format: .dateTime.day().month().year()).font(.caption).foregroundStyle(Ink.muted)
                    }
                    Text(hit.chunk.text).font(.callout).foregroundStyle(Ink.text).lineLimit(8).textSelection(.enabled)
                }
                .panel(padding: 14)
            }
        }
    }

    /// The newest moments, so memory is something you can look through, not
    /// only search.
    private var feed: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeading(title: "Recent memories")
                Spacer()
                HStack(spacing: 6) {
                    FilterChip(title: "All", selected: feedSource == nil) { feedLimit = 30; feedSource = nil }
                    ForEach([MemorySource.whatsapp, .imessage, .claude], id: \.self) { source in
                        FilterChip(title: LocalizedStringKey(source.displayName), selected: feedSource == source) {
                            feedLimit = 30
                            feedSource = source
                        }
                    }
                }
            }
            if recent.isEmpty {
                Text(indexer.totals.chunks == 0 ? "Nothing indexed yet" : "No memories from this source yet.")
                    .foregroundStyle(Ink.muted)
                    .padding(.vertical, 8)
            }
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(recent) { chunk in
                    MemoryMoment(chunk: chunk)
                }
            }
            if recent.count >= feedLimit {
                Button {
                    feedLimit += 30
                } label: {
                    Label("Show more", systemImage: "arrow.down")
                }
                .buttonStyle(.candy(.soft, compact: true))
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func loadFeed() async {
        lastFeed = .now
        var filter = MemoryStore.Filter()
        if let feedSource { filter.sources = [feedSource] }
        let ids = (try? await MemoryStore.shared.recentChunkIDs(filter: filter, limit: feedLimit)) ?? []
        recent = (try? await MemoryStore.shared.chunks(ids: ids)) ?? []
    }

    private func runSearch() async {
        searching = true
        hits = await Retriever().recall(query, limit: 12).hits
        searching = false
    }
}

extension MemoryHit.Signal {
    var label: String {
        switch self {
        case .keyword: String(localized: "words")
        case .meaning: String(localized: "meaning")
        case .graph: String(localized: "graph")
        }
    }

}

/// A source as a settings row: what it is, how much is remembered, on/off.
private struct SourceRow: View {
    var source: MemorySource
    @State private var settings = AppSettings.shared
    @State private var indexer = Indexer.shared

    var body: some View {
        SettingsRow(symbol: source.symbol, title: LocalizedStringKey(source.displayName), verbatim: detail) {
            HStack(spacing: 8) {
                if indexer.states[source] == .needsPermission {
                    Button("Grant Full Disk Access") { Permissions.openFullDiskAccess() }
                        .buttonStyle(.candy(.soft, compact: true))
                }
                Toggle("", isOn: Binding(
                    get: { settings.enabledSources.contains(source) },
                    set: { on in
                        if on { settings.enabledSources.insert(source) } else { settings.enabledSources.remove(source) }
                    }))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Ink.spot)
                Menu {
                    Button("Forget everything from \(source.displayName)", role: .destructive) {
                        Task { await indexer.forget(source) }
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button)
                .buttonStyle(HoverIconStyle(size: 28))
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private var detail: String {
        let count = indexer.counts[source] ?? 0
        switch indexer.states[source] {
        case .needsPermission: return String(localized: "Add Agott in System Settings → Full Disk Access, then come back. If it still can't read, quit and reopen Agott.")
        case .missing: return String(localized: "Not found on this Mac")
        case .failed(let message): return message
        default: return String(localized: "\(count) messages remembered")
        }
    }
}

/// One moment of conversation, as it was said.
private struct MemoryMoment: View {
    var chunk: MemoryChunk
    @State private var open = false

    private var lines: [Substring] { chunk.text.split(separator: "\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: chunk.source.symbol).font(.caption.weight(.bold)).foregroundStyle(Ink.muted)
                Text(chunk.chatName).font(.headline).foregroundStyle(Ink.text).lineLimit(1)
                Spacer()
                Text(chunk.end, format: .relative(presentation: .named)).font(.caption).foregroundStyle(Ink.muted)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.prefix(open ? 40 : 4).enumerated()), id: \.offset) { _, line in
                    MomentLine(line: String(line))
                }
            }
            if lines.count > 4 {
                Button(open ? "Show less" : "Show \(lines.count - 4) more") { open.toggle() }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Ink.spot)
            }
        }
        .panel(padding: 14)
    }
}

/// "[2026-11-05 14:02] Ana: texto" drawn as sender and words.
private struct MomentLine: View {
    var line: String

    var body: some View {
        let body = line.split(separator: "] ", maxSplits: 1).last.map(String.init) ?? line
        let parts = body.split(separator: ":", maxSplits: 1)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if parts.count == 2 {
                Text(parts[0]).font(.callout.weight(.semibold)).foregroundStyle(Ink.text).lineLimit(1)
                Text(parts[1].trimmingCharacters(in: .whitespaces)).font(.callout).foregroundStyle(Ink.text).lineLimit(3)
            } else {
                Text(body).font(.callout).foregroundStyle(Ink.text).lineLimit(3)
            }
        }
        .textSelection(.enabled)
    }
}

/// What Agott understood, not what it read: the people you are closest to,
/// what it learned about you, what you work on, and your circles.
private struct MemoryDigest: View {
    @State private var people: [(GraphEntity, Double)] = []
    @State private var facts: [MemoryFact] = []
    @State private var projects: [GraphEntity] = []
    @State private var subjects: [GraphEntity] = []
    @State private var circles: [PeopleCircle] = []
    @State private var indexer = Indexer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle(title: "What I understood", symbol: "sparkles")
            if people.isEmpty && facts.isEmpty && projects.isEmpty {
                Text("Agott is still reading. What it learns shows up here.")
                    .foregroundStyle(Ink.muted)
            } else {
                // Rows share their tallest card's height and every card starts
                // at the top, so the two columns line up.
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow(alignment: .top) {
                    section("Closest to you", symbol: "heart") {
                        ForEach(Array(people.enumerated()), id: \.offset) { _, pair in
                            HStack(spacing: 10) {
                                Avatar(name: pair.0.name, size: 28)
                                Text(pair.0.name).font(.callout.weight(.semibold)).foregroundStyle(Ink.text).lineLimit(1)
                                Spacer()
                                Text("\(Int(pair.1).formatted()) msgs").font(.caption).monospacedDigit().foregroundStyle(Ink.muted)
                            }
                            .personHover(pair.0.name)
                        }
                    }
                    section("About you", symbol: "person.text.rectangle") {
                        ForEach(facts) { fact in
                            Text("\(fact.predicate) \(Text(fact.object).foregroundStyle(Ink.spot).bold())")
                                .font(.callout).foregroundStyle(Ink.text).lineLimit(2)
                        }
                    }
                    }
                    GridRow(alignment: .top) {
                    section("What you work on", symbol: "hammer") {
                        FlowLayout(spacing: 6) {
                            ForEach(projects) { Chip(text: $0.name, symbol: "folder") }
                        }
                    }
                    section("What you talk about", symbol: "bubble.left.and.bubble.right") {
                        FlowLayout(spacing: 6) {
                            ForEach(subjects) { Chip(text: $0.name, symbol: $0.kind.symbol) }
                            ForEach(uniqueCircles) { Chip(text: $0.name, symbol: $0.kind.symbol, spot: true) }
                        }
                    }
                    }
                }
            }
        }
        .task { await load() }
        .onChange(of: indexer.isLearning) { _, learning in if !learning { Task { await load() } } }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption.weight(.bold)).foregroundStyle(Ink.muted)
            content()
        }
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity, alignment: .topLeading)
        .panel(padding: 14)
    }

    /// Circles that share a name show once.
    private var uniqueCircles: [PeopleCircle] {
        var seen = Set<String>()
        return circles.filter { seen.insert($0.name.folded).inserted }
    }

    private func load() async {
        let store = MemoryStore.shared
        let me = AppSettings.shared.myName
        if let meID = try? await KnowledgeGraph.meID() {
            let neighbors = (try? await store.neighbors(of: meID, limit: 80)) ?? []
            people = neighbors
                .filter { $0.1.relation == GraphRelation.talksWith.rawValue && $0.0.kind == .person && !GraphView.isPhoneOnly($0.0.name) }
                .prefix(7)
                .map { ($0.0, $0.1.weight) }
        }
        facts = Array(((try? await store.facts(about: me, limit: 40)) ?? []).prefix(7))
        projects = ((try? await store.entities(limit: 40, kinds: [.project])) ?? [])
            .filter { $0.mentions >= 2 }.prefix(10).map { $0 }
        subjects = ((try? await store.entities(limit: 120, kinds: [.topic, .organization, .place])) ?? [])
            .filter { $0.mentions >= 5 && KnowledgeGraph.isPlausibleName($0.name) }.prefix(10).map { $0 }
        circles = await Circles.cached()
    }
}

/// Conversations that mattered, condensed: a diary, newest first.
private struct DeepMoments: View {
    @State private var reflections: [Reflection] = []
    @State private var indexer = Indexer.shared
    @State private var showAll = false

    var body: some View {
        // Always present, so it loads even while empty.
        VStack(alignment: .leading, spacing: 12) {
            if !reflections.isEmpty {
                PanelTitle(title: "Conversations that mattered", symbol: "heart.text.square")
                ForEach(showAll ? reflections : Array(reflections.prefix(4))) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.title).font(.headline).foregroundStyle(Ink.text)
                            Spacer(minLength: 8)
                            Text(item.date, format: .dateTime.day().month().year())
                                .font(.caption).foregroundStyle(Ink.muted)
                        }
                        Text(item.summary)
                            .foregroundStyle(Ink.text)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        HStack(spacing: 6) {
                            Chip(text: item.feeling, symbol: "heart", spot: true)
                            ForEach(item.people.prefix(4), id: \.self) { Chip(text: $0, symbol: "person") }
                            Spacer()
                            Text(item.chat).font(.caption).foregroundStyle(Ink.muted).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel(padding: 14)
                }
                if reflections.count > 4 {
                    Button(showAll ? String(localized: "Show less") : String(localized: "Show \(reflections.count - 4) more")) {
                        withAnimation(Motion.settle) { showAll.toggle() }
                    }
                    .buttonStyle(.candy(.soft, compact: true))
                }
            }
        }
        .task { await load() }
            .onChange(of: indexer.isLearning) { _, learning in if !learning { Task { await load() } } }
    }

    private func load() async {
        reflections = (try? await MemoryStore.shared.reflections(limit: 24)) ?? []
    }
}

/// What the latest indexing run found: one line of counts, then a few of the
/// facts it learned, as examples.
struct RunFindingsView: View {
    var findings: Indexer.Findings
    var examples = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(Ink.hairline).frame(height: 1).padding(.bottom, 4)
            Text("Last run found")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Ink.muted)
            Text(findings.summary)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(Ink.text)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(findings.examples.prefix(examples)) { fact in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(Ink.spot).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0.height + 1 }
                    Text("\(Text(EntityText.plain(fact.subject, hidden: AppSettings.shared.hideNames)).fontWeight(.medium)) \(fact.displayPredicate) \(Text(fact.object).foregroundStyle(Ink.spot))")
                        .font(.callout)
                        .foregroundStyle(Ink.text)
                        .lineLimit(2)
                }
            }
        }
    }
}
