import SwiftUI

/// The graph as a family tree you can open branch by branch:
///
///     Intercâmbio ── Miguel ── Joga ── Doors
///                          └─ Namora ── Ana
///
/// People: the groups you are in, the people in each, then what Agott knows
/// about each person by kind of thing (what they play, where they study…)
/// and who they are linked to. Projects: each project, the people working on
/// it, and what they do in it. Everything loads when its branch opens, and
/// every person is a link to their card.
struct GraphTree: View {
    enum Roots: String, CaseIterable, Identifiable {
        case people, projects
        var id: String { rawValue }
    }

    var roots: Roots
    @State private var groups: [TreeNode] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if loading && groups.isEmpty {
                    ProgressView().controlSize(.small).padding(20)
                } else if groups.isEmpty {
                    Text(roots == .people ? "No groups or people learned yet." : "No projects learned yet.")
                        .font(.callout).foregroundStyle(Ink.muted).padding(20)
                }
                ForEach(groups) { node in
                    TreeBranch(node: node, depth: 0, last: node.id == groups.last?.id)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .task(id: roots) { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        groups = await TreeNode.roots(roots)
    }
}

/// One node of the tree, with its children fetched on first open.
struct TreeNode: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case group(PersonRef)
        case person(PersonRef)
        case project(String)
        /// A kind of thing known about someone: "Joga", "Estuda em".
        case category(String, [MemoryFact])
        /// One thing: "Doors", with its odds.
        case item(MemoryFact)
        /// A link to another person: "namora" → Ana.
        case link(phrase: String, person: PersonRef, odds: Double)
        /// Somebody's facts about a project, grouped under them.
        case worker(String, [MemoryFact])
    }

    var id: String
    var kind: Kind

    var title: String {
        switch kind {
        case .group(let ref), .person(let ref): ref.name
        case .project(let name): name
        case .category(let predicate, _): predicate.prefix(1).uppercased() + predicate.dropFirst()
        case .item(let fact): fact.object
        case .link(let phrase, let person, _): "\(phrase) \(person.name)"
        case .worker(let name, _): name
        }
    }

    var symbol: String {
        switch kind {
        case .group: "person.3"
        case .person, .worker: "person"
        case .project: "hammer"
        case .category: "folder"
        case .item: "smallcircle.filled.circle"
        case .link: "link"
        }
    }

    var opens: Bool {
        switch kind {
        case .item, .link: false
        default: true
        }
    }

    /// The person to open when this node is clicked, if it names one.
    var personName: String? {
        switch kind {
        case .person(let ref): ref.name
        case .link(_, let person, _): person.name
        case .worker(let name, _): name
        default: nil
        }
    }

    // MARK: Loading

    static func roots(_ roots: GraphTree.Roots) async -> [TreeNode] {
        let store = MemoryStore.shared
        switch roots {
        case .people:
            let groups = (try? await store.topGroups(limit: 24)) ?? []
            return groups.map { TreeNode(id: "g\($0.id)", kind: .group($0)) }
        case .projects:
            let projects = (try? await store.entities(limit: 40, kinds: [.project])) ?? []
            return projects.filter { !GraphView.isPhoneOnly($0.name) }
                .map { TreeNode(id: "p\($0.id)", kind: .project($0.name)) }
        }
    }

    func children() async -> [TreeNode] {
        let store = MemoryStore.shared
        switch kind {
        case .group(let group):
            let members = (try? await store.connections(of: group, limit: 40))?.others ?? []
            return members.map { TreeNode(id: "\(id)/m\($0.id)", kind: .person($0)) }
        case .person(let person):
            let facts = (try? await store.profile(of: person, limit: 60)) ?? []
            var byPredicate: [(String, [MemoryFact])] = []
            // Grouped by what each fact is about, so "joga" and "plays" share a branch.
            for fact in facts {
                let label = fact.displayPredicate
                if let index = byPredicate.firstIndex(where: { $0.0.folded == label.folded }) {
                    byPredicate[index].1.append(fact)
                } else {
                    byPredicate.append((label, [fact]))
                }
            }
            var nodes = byPredicate.map { TreeNode(id: "\(id)/c\($0.0)", kind: .category($0.0, $0.1)) }
            let links = (try? await store.links(of: person.id, limit: 12)) ?? []
            nodes += links.map { link in
                TreeNode(id: "\(id)/l\(link.other.id)\(link.kind.rawValue)",
                         kind: .link(phrase: link.kind.phrase(outgoing: link.outgoing), person: link.other, odds: link.confidence))
            }
            return nodes
        case .category(_, let facts):
            return facts.map { TreeNode(id: "\(id)/i\($0.id)", kind: .item($0)) }
        case .project(let name):
            let facts = (try? await store.facts(matching: name, limit: 80)) ?? []
            var bySubject: [(String, [MemoryFact])] = []
            for fact in facts where fact.object.folded.contains(name.folded) || fact.subject.folded.contains(name.folded) {
                if let index = bySubject.firstIndex(where: { $0.0 == fact.subject }) {
                    bySubject[index].1.append(fact)
                } else {
                    bySubject.append((fact.subject, [fact]))
                }
            }
            return bySubject.map { TreeNode(id: "\(id)/w\($0.0)", kind: .worker($0.0, $0.1)) }
        case .worker(_, let facts):
            return facts.map { TreeNode(id: "\(id)/i\($0.id)", kind: .item($0)) }
        case .item, .link:
            return []
        }
    }
}

/// A node and, once opened, its children, hung off a connector line.
private struct TreeBranch: View {
    var node: TreeNode
    var depth: Int
    var last: Bool
    @State private var open = false
    @State private var children: [TreeNode]?

    static let indent: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if open, let children {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(children) { child in
                        TreeBranch(node: child, depth: depth + 1, last: child.id == children.last?.id)
                    }
                    if children.isEmpty {
                        Text("Nothing here yet.")
                            .font(.caption).foregroundStyle(Ink.muted)
                            .padding(.leading, Self.indent + 8).padding(.vertical, 4)
                    }
                }
                // The trunk: a line down the left of the children.
                .overlay(alignment: .topLeading) {
                    Rectangle().fill(Ink.hairline).frame(width: 1)
                        .padding(.leading, Self.indent / 2 - 0.5)
                        .padding(.bottom, 14)
                }
                .padding(.leading, Self.indent)
                .transition(.opacity)
            }
        }
        .animation(Motion.settle, value: open)
    }

    private var row: some View {
        HStack(spacing: 8) {
            if depth > 0 {
                // The branch: a short line from the trunk to this node.
                Rectangle().fill(Ink.hairline).frame(width: 10, height: 1)
                    .padding(.leading, -Self.indent / 2)
            }
            if node.opens {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Ink.muted)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 10)
            }
            Image(systemName: node.symbol)
                .font(.caption)
                .foregroundStyle(Ink.muted)
                .frame(width: 16)
            label
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
    }

    @ViewBuilder
    private var label: some View {
        switch node.kind {
        case .item(let fact):
            HStack(spacing: 6) {
                Text(fact.object).font(.callout).foregroundStyle(Ink.text)
                Text("\(Int((fact.confidence * 100).rounded()))%")
                    .font(.caption2).monospacedDigit().foregroundStyle(Ink.muted)
            }
        case .link(let phrase, let person, let odds):
            HStack(spacing: 4) {
                Text(phrase).font(.callout).foregroundStyle(Ink.muted)
                Text(person.name).font(.callout.weight(.medium)).foregroundStyle(Ink.text)
                    .personHover(person.name)
                Text("\(Int((odds * 100).rounded()))%")
                    .font(.caption2).monospacedDigit().foregroundStyle(Ink.muted)
            }
        case .person(let ref):
            HStack(spacing: 8) {
                InitialsAvatar(text: ref.name, size: 20)
                Text(ref.name).font(.callout.weight(.medium)).foregroundStyle(Ink.text)
                    .personHover(ref.name)
            }
        case .worker(let name, _):
            Text(name).font(.callout.weight(.medium)).foregroundStyle(Ink.text).personHover(name)
        case .group(let ref):
            HStack(spacing: 8) {
                InitialsAvatar(text: ref.name, size: 20)
                Text(ref.name).font(.callout.weight(.semibold)).foregroundStyle(Ink.text)
            }
        default:
            Text(node.title).font(.callout).foregroundStyle(Ink.text)
        }
    }

    private func toggle() {
        guard node.opens else { return }
        open.toggle()
        if open && children == nil {
            Task { children = await node.children() }
        }
    }
}

extension MemoryStore {
    /// The groups you are in, busiest first.
    func topGroups(limit: Int) throws -> [PersonRef] {
        let db = try open()
        var groups: [PersonRef] = []
        try db.rows("""
            SELECT p.id, p.name, MAX(c.msg_count) AS size FROM people p
            JOIN chat_people cp ON cp.person_id = p.id AND cp.role = 'is'
            JOIN chats c ON c.source = cp.source AND c.chat_id = cp.chat_id
            WHERE p.kind = 'group'
            GROUP BY p.id ORDER BY size DESC LIMIT ?
            """, [.int(Int64(limit))]) { row in
            groups.append(PersonRef(id: Int64(row.int(0)), kind: .group, name: row.text(1) ?? ""))
        }
        return groups.filter { !GraphView.isPhoneOnly($0.name) }
    }
}
