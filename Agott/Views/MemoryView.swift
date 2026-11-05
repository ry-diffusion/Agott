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
                        Button { indexer.run() } label: { Label("Update memory", systemImage: "arrow.triangle.2.circlepath") }
                            .buttonStyle(.candy)
                    }
                }
                totals
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

    private var totals: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                MuseFace(mood: indexer.isRunning ? .working : .happy, size: 56)
                VStack(alignment: .leading, spacing: 6) {
                    Text(indexer.statusText).font(Lettering.display(18, relativeTo: .title3)).foregroundStyle(Ink.text)
                    if indexer.isRunning {
                        if let progress = indexer.progress {
                            HStack(spacing: 10) {
                                ProgressView(value: progress).tint(Ink.spot)
                                Text(progress, format: .percent.precision(.fractionLength(0)))
                                    .font(.callout.weight(.bold)).monospacedDigit().foregroundStyle(Ink.text)
                            }
                        } else {
                            ProgressView().progressViewStyle(.linear).tint(Ink.spot)
                        }
                    }
                    Text("\(indexer.totals.messages) messages · \(indexer.totals.chunks) moments · \(indexer.totals.vectors) understood · \(indexer.totals.entities) things in the graph · \(indexer.totals.facts) facts")
                        .font(.callout).monospacedDigit().foregroundStyle(Ink.muted)
                    if let error = indexer.lastError { Text(error).font(.caption).foregroundStyle(Ink.text) }
                }
                Spacer()
            }
            if indexer.totals.messages == 0 && !indexer.isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Agott hasn't read anything yet. Start indexing to let it remember your WhatsApp, iMessage and Claude history. It runs in the background; you can keep using the app.")
                        .foregroundStyle(Ink.text)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button { indexer.run() } label: { Label("Start indexing", systemImage: "play.fill") }
                            .buttonStyle(.candy)
                        if !Permissions.isGranted(.fullDiskAccess) {
                            Button("Grant Full Disk Access") { Permissions.openFullDiskAccess() }
                                .buttonStyle(.candy(.soft))
                        }
                    }
                }
            }
        }
        .panel(toned: indexer.isRunning)
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle(title: "Sources", symbol: "tray.and.arrow.down")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach([MemorySource.whatsapp, .imessage, .claude], id: \.self) { source in
                    SourceTile(source: source)
                }
            }
            #if os(macOS)
            HStack {
                Button { importing = true } label: {
                    Label("Import a claude.ai export…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.candy(.soft, compact: true))
                Text("conversations.json from Settings → Privacy → Export data").font(.caption).foregroundStyle(Ink.muted)
            }
            #endif
        }
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle(title: "Search your memory", symbol: "magnifyingglass")
            HStack {
                CandyField(placeholder: "Anything: a name, a plan, a feeling…", text: $query, symbol: "magnifyingglass") {
                    Task { await runSearch() }
                }
                Button("Search") { Task { await runSearch() } }
                    .buttonStyle(.candy)
                    .disabled(query.isEmpty || searching)
            }
            ForEach(hits) { hit in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: hit.chunk.source.symbol).foregroundStyle(Ink.violet)
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
                PanelTitle(title: "Recent memories", symbol: "clock.arrow.circlepath")
                Spacer()
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        feedChip(nil, title: String(localized: "All"), symbol: "tray.full")
                        ForEach([MemorySource.whatsapp, .imessage, .claude], id: \.self) { source in
                            feedChip(source, title: source.displayName, symbol: source.symbol)
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
                .buttonStyle(.candy(.soft))
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func feedChip(_ source: MemorySource?, title: String, symbol: String) -> some View {
        let selected = feedSource == source
        return Button {
            feedLimit = 30
            feedSource = source
        } label: {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.text))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassEffect(selected ? .regular.tint(Ink.spot).interactive() : .regular.interactive(), in: .capsule)
        }
        .buttonStyle(PressScale())
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

private struct SourceTile: View {
    var source: MemorySource
    @State private var settings = AppSettings.shared
    @State private var indexer = Indexer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: source.symbol)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Ink.text)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Ink.raised))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { settings.enabledSources.contains(source) },
                    set: { on in
                        if on { settings.enabledSources.insert(source) } else { settings.enabledSources.remove(source) }
                    }))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Ink.spot)
            }
            Text(source.displayName).font(Lettering.display(15, relativeTo: .headline)).foregroundStyle(Ink.text)
            Text(detail).font(.caption).foregroundStyle(Ink.muted).lineLimit(2)
            HStack {
                if indexer.states[source] == .needsPermission {
                Text("Add Agott in System Settings → Full Disk Access, then come back. If it still can't read, quit and reopen Agott.")
                    .font(.caption).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
            }
            if indexer.states[source] == .needsPermission {
                    Button("Grant Full Disk Access") { Permissions.openFullDiskAccess() }
                        .buttonStyle(.candy(.primary, compact: true))
                }
                Spacer()
                Menu {
                    Button("Forget everything from \(source.displayName)", role: .destructive) {
                        Task { await indexer.forget(source) }
                    }
                } label: { Image(systemName: "ellipsis.circle.fill").foregroundStyle(Ink.muted) }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .panel(padding: 14, toned: settings.enabledSources.contains(source))
    }

    private var detail: String {
        let count = indexer.counts[source] ?? 0
        switch indexer.states[source] {
        case .needsPermission: return String(localized: "Needs Full Disk Access to read")
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
