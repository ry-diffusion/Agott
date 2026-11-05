import SwiftUI
import UniformTypeIdentifiers

/// What Agott remembers, where it came from, and a way to search it yourself.
struct MemoryView: View {
    @State private var indexer = Indexer.shared
    @State private var query = ""
    @State private var hits: [MemoryHit] = []
    @State private var searching = false
    @State private var importing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ScreenHeader(title: "Memory", subtitle: "Everything Agott remembers, and where it came from.", symbol: "brain") {
                    if indexer.isRunning {
                        Button { indexer.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                            .buttonStyle(.candy(.soft))
                    } else {
                        Button { indexer.run() } label: { Label("Update memory", systemImage: "arrow.triangle.2.circlepath") }
                            .buttonStyle(.candy)
                    }
                }
                totals
                sources
                search
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 30)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .task { await indexer.refreshTotals() }
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
                    Text(phaseText).font(Lettering.display(18, relativeTo: .title3)).foregroundStyle(Ink.text)
                    Text("\(indexer.totals.messages) messages · \(indexer.totals.chunks) moments · \(indexer.totals.vectors) understood · \(indexer.totals.entities) things in the graph · \(indexer.totals.facts) facts")
                        .font(.callout).monospacedDigit().foregroundStyle(Ink.muted)
                    if let error = indexer.lastError { Text(error).font(.caption).foregroundStyle(Ink.text) }
                }
                Spacer()
            }
        }
        .panel(toned: indexer.isRunning)
    }

    private var phaseText: String {
        switch indexer.phase {
        case .idle:
            if let last = indexer.lastRun {
                return String(localized: "Up to date, \(last.formatted(.relative(presentation: .named)))")
            }
            return String(localized: "All caught up")
        case .reading(let source): return String(localized: "Reading \(source.displayName)…")
        case .linking: return String(localized: "Connecting the dots…")
        case .embedding(let done, let total): return String(localized: "Understanding moments \(done) of \(total)…")
        case .learning(let done, let total): return String(localized: "Learning about you \(done) of \(total)…")
        }
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
