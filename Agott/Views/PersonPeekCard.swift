import SwiftUI

/// Who someone is, at a glance: what they are called, who they are linked
/// to, and what Agott knows about them, each with its odds. Shown on hover
/// over people in lists, and when a name in the chat is clicked.
struct PersonPeekCard: View {
    struct Info: Sendable {
        var ref: PersonRef
        var otherNames: [String]
        var direct: [ChatSummary]
        var groups: [PersonRef]
        var links: [MemoryStore.PersonLink]
        var facts: [MemoryFact]
    }

    /// By id (a tag in the chat) or by name (a row in a list).
    var id: Int64?
    var name: String?
    @State private var info: Info?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let info {
                header(info)
                if !info.links.isEmpty {
                    section("Linked to", symbol: "point.3.connected.trianglepath.dotted") {
                        ForEach(Array(info.links.prefix(5).enumerated()), id: \.offset) { _, link in
                            line(Text("\(link.kind.phrase(outgoing: link.outgoing)) \(Text(label(link.other)).bold())"),
                                 odds: link.confidence)
                                // The other person is a link too: click to open them.
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let url = URL(string: "agott://person/\(link.other.id)") { _ = EntityText.open(url) }
                                }
                                .hoverHighlight(cornerRadius: 6, inset: -3)
                        }
                    }
                }
                if !info.facts.isEmpty {
                    section("What Agott knows", symbol: "pin") {
                        ForEach(info.facts.prefix(5)) { fact in
                            line(Text("\(fact.displayPredicate) \(Text(fact.object).foregroundStyle(Ink.spot))"), odds: fact.confidence)
                        }
                    }
                }
                if info.links.isEmpty && info.facts.isEmpty {
                    Text("Nothing learned about them yet.").font(.callout).foregroundStyle(Ink.muted)
                }
                Button {
                    if let url = URL(string: "agott://person/\(info.ref.id)") { _ = EntityText.open(url) }
                } label: {
                    Label("Open in People", systemImage: "arrow.up.right")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Ink.spot)
                }
                .buttonStyle(.plain)
            } else if loaded {
                Text("Agott doesn't know who this is yet.").font(.callout).foregroundStyle(Ink.muted)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .task(id: "\(id ?? 0)|\(name ?? "")") {
            info = await Self.load(id: id, name: name)
            loaded = true
        }
    }

    private var hidden: Bool { AppSettings.shared.hideNames }

    private func label(_ ref: PersonRef) -> String { PeopleDirectory.shared.label(ref.id, hidden: hidden) }

    private func header(_ info: Info) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(name: hidden ? "?" : info.ref.name, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(label(info.ref)).font(Lettering.display(17, relativeTo: .headline)).foregroundStyle(Ink.text)
                Text(subtitle(info)).font(.caption).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func subtitle(_ info: Info) -> String {
        var parts: [String] = []
        if info.ref.kind == .group {
            parts.append(String(localized: "Group chat"))
        } else if !hidden, !info.otherNames.isEmpty {
            parts.append(String(localized: "Also called \(info.otherNames.prefix(4).joined(separator: ", "))"))
        }
        let messages = info.direct.map(\.messageCount).reduce(0, +)
        if messages > 0 { parts.append(String(localized: "\(messages.formatted()) messages")) }
        if !info.groups.isEmpty {
            parts.append(info.ref.kind == .group
                         ? String(localized: "\(info.groups.count) people")
                         : String(localized: "in \(info.groups.count) groups"))
        }
        return parts.joined(separator: " · ")
    }

    private func section<Content: View>(_ title: LocalizedStringKey, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol).font(.caption.weight(.bold)).foregroundStyle(Ink.muted)
            content()
        }
    }

    private func line(_ text: Text, odds: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            text.font(.callout).foregroundStyle(Ink.text).lineLimit(2)
            Spacer(minLength: 4)
            Text("\(Int((odds * 100).rounded()))%").font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(Ink.muted)
        }
    }

    static func load(id: Int64?, name: String?) async -> Info? {
        let store = MemoryStore.shared
        var ref: PersonRef?
        if let id { ref = try? await store.person(id: id) }
        if ref == nil, let name {
            let found = (try? await store.resolvePeople(name)) ?? []
            ref = found.first { $0.name.folded == name.folded } ?? found.first
        }
        guard let ref else { return nil }
        let connections = (try? await store.connections(of: ref, limit: 40)) ?? (direct: [], others: [])
        return Info(
            ref: ref,
            otherNames: ((try? await store.otherNames(of: ref.id)) ?? []).filter { $0.folded != ref.name.folded },
            direct: connections.direct.filter { !$0.isGroup },
            groups: connections.others,
            links: ref.kind == .person ? ((try? await store.links(of: ref.id, limit: 6)) ?? []) : [],
            facts: ref.kind == .person ? ((try? await store.profile(of: ref, limit: 6)) ?? []) : [])
    }
}

/// Hovering a person shows their card; clicking opens them in People.
struct PersonHover: ViewModifier {
    var name: String
    @State private var hovering = false
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Ink.text.opacity(hovering ? 0.06 : 0))
                    .padding(-5))
            .onHover { inside in
                hovering = inside
                if inside {
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        if hovering { shown = true }
                    }
                } else {
                    shown = false
                }
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .popover(isPresented: $shown, arrowEdge: .trailing) {
                PersonPeekCard(name: name)
            }
            .onTapGesture {
                shown = false
                Task {
                    if let ref = (try? await MemoryStore.shared.resolvePeople(name))?.first,
                       let url = URL(string: "agott://person/\(ref.id)") { _ = EntityText.open(url) }
                }
            }
    }
}

extension View {
    func personHover(_ name: String) -> some View { modifier(PersonHover(name: name)) }
}

/// A person picked from a name in the chat.
struct PersonPeek: Identifiable, Hashable {
    var id: Int64

    /// The person a chat link points at, if it is one.
    static func from(_ url: URL) -> PersonPeek? {
        guard url.scheme == "agott", url.host() == "person", let id = Int64(url.lastPathComponent) else { return nil }
        return PersonPeek(id: id)
    }
}
