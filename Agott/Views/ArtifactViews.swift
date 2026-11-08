import SwiftUI
import WebKit
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// An artifact in the conversation: a compact card that opens it.
struct ArtifactCard: View {
    var artifact: Card.Artifact
    @State private var agent = Agent.shared
    @State private var sheet = false
    @State private var hovering = false

    private var isOpen: Bool { agent.openArtifactKey == artifact.key }

    var body: some View {
        Button {
            #if os(macOS)
            withAnimation(Motion.settle) { agent.openArtifactKey = isOpen ? nil : artifact.key }
            #else
            // On iPhone the card may come from the Mac, so it opens what it carries.
            sheet = true
            #endif
        } label: {
            // A document in the conversation, the way Telegram shows a file.
            MessageBubble(outgoing: false) {
                DocumentRow(symbol: artifact.kind.symbol, title: artifact.title, detail: detail,
                            highlighted: hovering)
            }
            .frame(maxWidth: 420, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        #if os(macOS)
        .pointerStyle(.link)
        #endif
        .animation(.easeOut(duration: 0.12), value: hovering)
        .sheet(isPresented: $sheet) { ArtifactPanel(key: artifact.key, fallback: artifact) }
    }

    /// Kind, version, and how long it takes to read.
    private var detail: String {
        let words = artifact.content.split(whereSeparator: \.isWhitespace).count
        var parts = [subtitle]
        if artifact.kind == .document || artifact.kind == .table {
            parts.append(String(localized: "\(max(1, words / 200)) min read"))
        }
        if isOpen { parts.append(String(localized: "Open")) }
        return parts.joined(separator: " · ")
    }

    private var badge: String {
        switch artifact.kind {
        case .document: "DOC"
        case .table: "TAB"
        case .html: "WEB"
        case .code: String((artifact.language ?? "code").uppercased().prefix(4))
        }
    }

    private var subtitle: String {
        let kind = switch artifact.kind {
        case .document: String(localized: "Document")
        case .code: artifact.language?.capitalized ?? String(localized: "Code")
        case .html: String(localized: "Web page")
        case .table: String(localized: "Table")
        }
        return artifact.version > 1 ? String(localized: "\(kind) · version \(artifact.version)") : kind
    }
}

/// The open artifact, beside the chat on the Mac and as a sheet on iPhone.
struct ArtifactPanel: View {
    var key: String
    /// Shown when this conversation does not hold the artifact (it came from the Mac).
    var fallback: Card.Artifact?
    @State private var agent = Agent.shared
    @Environment(\.dismiss) private var dismiss
    @State private var version: Int?
    @State private var showSource = false
    @State private var copied = false

    private var versions: [Card.Artifact] {
        let local = agent.versions(of: key)
        return local.isEmpty ? (fallback.map { [$0] } ?? []) : local
    }
    private var artifact: Card.Artifact? {
        if let version, let match = versions.first(where: { $0.version == version }) { return match }
        return versions.last
    }

    var body: some View {
        if let artifact {
            VStack(spacing: 0) {
                toolbar(artifact)
                Divider().opacity(0.5)
                content(artifact)
            }
            .background(Ink.surface)
            .onChange(of: versions.count) { _, _ in version = nil }
        }
    }

    private func toolbar(_ artifact: Card.Artifact) -> some View {
        HStack(spacing: 4) {
            Image(systemName: artifact.kind.symbol).foregroundStyle(Ink.spot)
            Text(artifact.title)
                .font(.headline)
                .foregroundStyle(Ink.text)
                .lineLimit(1)
                .padding(.leading, 6)
            if versions.count > 1 {
                Menu {
                    ForEach(versions.reversed(), id: \.id) { item in
                        Button(String(localized: "Version \(item.version)")) { version = item.version }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("v\(artifact.version)")
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .font(.caption.weight(.semibold))
                }
                .menuStyle(.button)
                .buttonStyle(.hoverIcon)
                .menuIndicator(.hidden)
                .fixedSize()
                .tip("Versions")
            }
            Spacer(minLength: 8)
            if artifact.kind == .html || artifact.kind == .document {
                Button {
                    showSource.toggle()
                } label: {
                    Image(systemName: showSource ? "eye" : "chevron.left.forwardslash.chevron.right")
                }
                .tip(showSource ? "Preview" : "Source")
            }
            Button {
                Clipboard.copy(artifact.exportText)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .tip("Copy")
            #if os(macOS)
            Button { save(artifact) } label: { Image(systemName: "square.and.arrow.down") }
                .tip("Save…")
            PublishButton(artifact: artifact)
            #else
            ShareLink(item: artifact.content) { Image(systemName: "square.and.arrow.up") }
            #endif
            Button {
                withAnimation(Motion.settle) { agent.openArtifactKey = nil }
                #if os(iOS)
                dismiss()
                #endif
            } label: {
                Image(systemName: "xmark")
            }
            .keyboardShortcut(.cancelAction)
            .tip("Close")
        }
        .buttonStyle(.hoverIcon)
        .font(.system(size: 14, weight: .semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func content(_ artifact: Card.Artifact) -> some View {
        switch (artifact.kind, showSource) {
        case (.html, false):
            HTMLPreview(html: artifact.content)
        case (.code, _), (.html, true), (.document, true):
            ScrollView([.vertical, .horizontal]) {
                Text(artifact.content)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Ink.text)
                    .textSelection(.enabled)
                    .padding(20)
                    .fixedSize(horizontal: artifact.kind == .code, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case (.document, false), (.table, _):
            ScrollView {
                MarkdownView(text: artifact.content, size: .document)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    #if os(macOS)
    private func save(_ artifact: Card.Artifact) {
        let panel = NSSavePanel()
        let safe = artifact.title.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(safe).\(artifact.kind.fileExtension)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? artifact.exportText.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    #endif
}

/// A web page artifact, rendered.
private struct HTMLPreview: View {
    var html: String
    @State private var page = WebPage()

    var body: some View {
        WebView(page)
            .task(id: html) {
                do { for try await _ in page.load(html: html) {} } catch {}
            }
    }
}

#if os(macOS)
/// Publishes the artifact to your site, or shows where it lives.
private struct PublishButton: View {
    var artifact: Card.Artifact
    @State private var publisher = ArtifactPublisher.shared
    @State private var confirming = false
    @State private var error: String?

    private var entry: ArtifactPublisher.Entry? { publisher.entry(for: artifact.key) }
    private var busy: Bool { publisher.publishing == artifact.key }
    private var upToDate: Bool { entry?.version == artifact.version }

    var body: some View {
        Group {
            if busy {
                ProgressView().controlSize(.small).frame(width: 28, height: 28)
                    .help(Text("Publishing…"))
            } else if let entry {
                Menu {
                    if let url = publisher.url(for: entry) {
                        Button("Open", systemImage: "safari") { NSWorkspace.shared.open(url) }
                        Button("Copy link", systemImage: "link") { Clipboard.copy(url.absoluteString) }
                    }
                    if !upToDate {
                        Button("Publish version \(artifact.version)", systemImage: "arrow.up.circle") { publish() }
                    }
                    if let all = URL(string: "https://\(publisher.domain)/") {
                        Button("All artifacts", systemImage: "square.grid.2x2") { NSWorkspace.shared.open(all) }
                    }
                    Divider()
                    Button("Unpublish", systemImage: "eye.slash", role: .destructive) { unpublish() }
                } label: {
                    Image(systemName: upToDate ? "globe" : "globe.badge.chevron.backward")
                        .foregroundStyle(Ink.spot)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .tip(upToDate ? "Published" : "Published, with a newer version here")
            } else {
                Button { confirming = true } label: { Image(systemName: "globe") }
                    .tip("Publish to \(publisher.domain)")
            }
        }
        .confirmationDialog(
            Text("Publish “\(artifact.title)”?"),
            isPresented: $confirming
        ) {
            Button("Publish") { publish() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It goes to \(publisher.domain), where anyone with the link can open it. Check it holds nothing private about you or others.")
        }
        .alert(Text("Could not publish"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func publish() {
        Task {
            do {
                let url = try await publisher.publish(artifact)
                Clipboard.copy(url.absoluteString)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func unpublish() {
        Task {
            do { try await publisher.unpublish(artifact.key) } catch { self.error = error.localizedDescription }
        }
    }
}
#endif
