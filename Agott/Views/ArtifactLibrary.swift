import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// Everything Agott has written to keep, from every conversation: documents,
/// code, pages and tables. Open one where it was made, copy it, or save it as
/// a file.
struct ArtifactLibraryView: View {
    @State private var agent = Agent.shared
    @State private var navigator = Navigator.shared
    @State private var items: [LibraryItem] = []
    @State private var loading = true
    @State private var kind: Card.Artifact.Kind?
    @State private var query = ""

    private var shown: [LibraryItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return items.filter { item in
            (kind == nil || item.artifact.kind == kind)
                && (q.isEmpty || item.artifact.title.localizedStandardContains(q)
                    || item.artifact.content.localizedStandardContains(q)
                    || item.conversationTitle.localizedStandardContains(q))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center) {
                    Text("Artifacts")
                        .font(Lettering.display(34, relativeTo: .largeTitle))
                        .foregroundStyle(Ink.text)
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Ink.muted)
                        TextField(String(localized: "Search artifacts"), text: $query).textFieldStyle(.plain)
                    }
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .quietSurface(Capsule(), fill: Ink.raised)
                    .frame(width: 240)
                }
                HStack(spacing: 6) {
                    FilterChip(title: "Everything", selected: kind == nil) { kind = nil }
                    ForEach(Card.Artifact.Kind.allCases, id: \.self) { item in
                        FilterChip(title: item.libraryTitle, selected: kind == item) { kind = item }
                    }
                }

                if loading && items.isEmpty {
                    ProgressView().controlSize(.small).padding(.top, 30).frame(maxWidth: .infinity)
                } else if shown.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.on.doc").font(.system(size: 26)).foregroundStyle(Ink.muted)
                        Text(items.isEmpty ? "Documents, code and pages Agott writes for you show up here."
                                           : "Nothing matches.")
                            .font(.callout).foregroundStyle(Ink.muted)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                        ForEach(shown) { item in
                            ArtifactTile(item: item) { open(item) }
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, WindowBar.height + 8)
            .padding(.bottom, 40)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .background(Ink.canvas)
        .task(id: agent.conversations.count) { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        items = await Agent.library(of: agent.conversations)
    }

    /// Back to the conversation it was made in, with it open beside the chat.
    private func open(_ item: LibraryItem) {
        navigator.section = .chat
        agent.open(item.conversation)
        withAnimation(Motion.settle) { agent.openArtifactKey = item.artifact.key }
    }
}

/// An artifact as a card: what kind, its title, how it starts, where from.
private struct ArtifactTile: View {
    var item: LibraryItem
    var open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: item.artifact.kind.symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(Ink.muted)
                        .frame(width: 30, height: 30)
                        .quietSurface(RoundedRectangle(cornerRadius: 8, style: .continuous), fill: Ink.raised)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.artifact.title).font(.body.weight(.medium)).foregroundStyle(Ink.text).lineLimit(1)
                        Text(item.artifact.kind.libraryTitle).font(.caption).foregroundStyle(Ink.muted)
                    }
                    Spacer(minLength: 0)
                }
                Text(Self.preview(item.artifact))
                    .font(.callout)
                    .foregroundStyle(Ink.muted)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                HStack(spacing: 6) {
                    Text(EntityText.plain(item.conversationTitle, hidden: AppSettings.shared.hideNames)).lineLimit(1)
                    Text(verbatim: "·")
                    Text(item.date, format: .dateTime.day().month(.abbreviated))
                    if item.versions > 1 {
                        Text(verbatim: "·")
                        Text("v\(item.versions)")
                    }
                }
                .font(.caption)
                .foregroundStyle(Ink.muted)
            }
            .padding(16)
            .quietSurface(RoundedRectangle(cornerRadius: 16, style: .continuous),
                          fill: hovering ? Ink.raised : Ink.surface)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            Button("Open", systemImage: "arrow.up.forward.square", action: open)
            Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(item.artifact.exportText) }
            #if os(macOS)
            Button("Save as File…", systemImage: "square.and.arrow.down") { Self.save(item.artifact) }
            #endif
        }
    }

    /// The first words, without Markdown marks.
    static func preview(_ artifact: Card.Artifact) -> String {
        let shown = artifact.shownText(hidden: AppSettings.shared.hideNames)
        let text = artifact.kind == .code || artifact.kind == .html ? shown : shown.markdownStripped
        return String(text.prefix(280))
    }

    #if os(macOS)
    static func save(_ artifact: Card.Artifact) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(artifact.title).\(artifact.kind.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? artifact.exportText.write(to: url, atomically: true, encoding: .utf8)
    }
    #endif
}

extension Card.Artifact.Kind {
    var libraryTitle: LocalizedStringKey {
        switch self {
        case .document: "Documents"
        case .code: "Code"
        case .html: "Pages"
        case .table: "Tables"
        }
    }
}
