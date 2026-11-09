import SwiftUI

/// Your life as a graph, laid out by a small force simulation.
///
/// You are pinned at the centre. People, groups, places and projects settle
/// around you. A raw graph of everyone you have ever texted is a hairball, so
/// this one is edited: contacts known only by a phone number stay out, each
/// node keeps only its strongest few connections, labels never collide, and
/// the view fits itself to what is there. Click anything to focus on it: its
/// connections light up, everything else steps back, and the side panel says
/// what Agott knows about it.
struct GraphView: View {
    @State private var nodes: [Node] = []
    @State private var edges: [GraphEdge] = []
    @State private var selected: Int64?
    @State private var neighbors: [(GraphEntity, GraphEdge)] = []
    @State private var facts: [MemoryFact] = []
    @State private var kinds: Set<EntityKind> = [.me, .person, .group, .place, .organization, .project, .topic]
    @State private var size = 80
    @State private var drag: CGSize = .zero
    @State private var offset: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @State private var settling = false
    @State private var generation = 0
    @State private var lastReload = Date.distantPast
    @State private var canvasSize: CGSize = .zero
    @State private var mode: Mode = .map
    @State private var filter: Filter = .all
    @State private var treeRoots: GraphTree.Roots = .people

    enum Mode: String, CaseIterable, Identifiable { case map, tree; var id: String { rawValue } }

    /// What the map shows: everything, or one kind of thing (and you).
    enum Filter: String, CaseIterable, Identifiable {
        case all, people, projects, places, topics
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .all: "Everything"
            case .people: "People"
            case .projects: "Projects"
            case .places: "Places"
            case .topics: "Topics"
            }
        }

        var kinds: Set<EntityKind> {
            switch self {
            case .all: [.me, .person, .group, .place, .organization, .project, .topic]
            case .people: [.me, .person, .group]
            case .projects: [.me, .project, .organization, .person]
            case .places: [.me, .place, .person]
            case .topics: [.me, .topic, .person]
            }
        }
    }

    struct Node: Identifiable {
        var entity: GraphEntity
        var position: CGPoint
        var velocity: CGVector = .zero
        var id: Int64 { entity.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScreenHeader(title: "Graph", subtitle: "The people and things in your life, and how they connect.", symbol: "point.3.connected.trianglepath.dotted") {
                HStack(spacing: 8) {
                    Picker("View", selection: $mode) {
                        Text("Map").tag(Mode.map)
                        Text("Tree").tag(Mode.tree)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .labelsHidden()
                    if mode == .map {
                    Picker("Size", selection: $size) {
                        Text(verbatim: "40").tag(40)
                        Text(verbatim: "80").tag(80)
                        Text(verbatim: "150").tag(150)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .labelsHidden()
                    CandyIconButton(symbol: "arrow.up.left.and.down.right.magnifyingglass") { fit(animated: true) }
                        .help(Text("Fit to view"))
                    CandyIconButton(symbol: "arrow.clockwise") { Task { await load() } }
                        .help(Text("Refresh"))
                    }
                }
            }
            // What to show: everything or one kind (map), people or projects (tree).
            HStack(spacing: 6) {
                if mode == .map {
                    ForEach(Filter.allCases) { item in
                        FilterChip(title: item.title, selected: filter == item) { filter = item }
                    }
                } else {
                    FilterChip(title: "People", selected: treeRoots == .people) { treeRoots = .people }
                    FilterChip(title: "Projects", selected: treeRoots == .projects) { treeRoots = .projects }
                }
            }
            if mode == .map {
                HStack(spacing: 14) {
                    canvas
                        .clipShape(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
                    if let selected, let node = nodes.first(where: { $0.id == selected }) {
                        inspector(node.entity)
                            .frame(width: 300)
                            .panel(padding: 0)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(Motion.settle, value: selected)
            } else {
                GraphTree(roots: treeRoots)
                    .quietSurface(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 24)
        .task(id: size) { await load() }
        .onChange(of: filter) { _, new in
            kinds = new.kinds
            selected = nil
            Task { await load() }
        }
        // While indexing, the graph grows in front of you.
        .onChange(of: Indexer.shared.totals.entities) { _, _ in
            guard Date().timeIntervalSince(lastReload) > 10 else { return }
            lastReload = .now
            Task { await load() }
        }
    }

    private var center: CGPoint {
        CGPoint(x: canvasSize.width / 2 + offset.width + drag.width,
                y: canvasSize.height / 2 + offset.height + drag.height)
    }

    /// Ids within one hop of the selection.
    private var focus: Set<Int64>? {
        guard let selected else { return nil }
        var ids: Set<Int64> = [selected]
        for edge in edges where edge.source == selected || edge.target == selected {
            ids.insert(edge.source)
            ids.insert(edge.target)
        }
        return ids
    }

    private var canvas: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !settling && drag == .zero)) { _ in
            // Drawn off the main thread, so a busy graph never blocks clicks.
            Canvas(rendersAsynchronously: true) { context, size in
                let center = self.center
                let focus = self.focus
                let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
                func point(_ p: CGPoint) -> CGPoint { CGPoint(x: center.x + p.x * zoom, y: center.y + p.y * zoom) }
                func dimmed(_ id: Int64) -> Bool { focus.map { !$0.contains(id) } ?? false }

                for edge in edges {
                    guard let a = byID[edge.source], let b = byID[edge.target] else { continue }
                    var path = Path()
                    path.move(to: point(a.position))
                    path.addLine(to: point(b.position))
                    let lit = selected == edge.source || selected == edge.target
                    let faded = focus != nil && !lit
                    context.stroke(
                        path,
                        with: .color(lit ? Ink.spot : Ink.text.opacity(faded ? 0.04 : 0.14)),
                        lineWidth: lit ? 1.8 : min(2.2, 0.5 + log2(edge.weight + 1) * 0.2))
                }

                // Labels: the selection and its neighbours first, then by
                // importance, skipping any that would overlap one already drawn.
                var placed: [CGRect] = []
                let order = nodes.sorted { a, b in
                    let fa = focus?.contains(a.id) ?? false, fb = focus?.contains(b.id) ?? false
                    if fa != fb { return fa }
                    if (a.entity.kind == .me) != (b.entity.kind == .me) { return a.entity.kind == .me }
                    return a.entity.mentions > b.entity.mentions
                }
                var labels: [(Node, CGPoint)] = []

                for node in nodes {
                    let radius = Self.radius(node.entity) * min(1.4, max(0.7, zoom))
                    let p = point(node.position)
                    guard p.x > -20, p.y > -20, p.x < size.width + 20, p.y < size.height + 20 else { continue }
                    let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
                    var layer = context
                    layer.opacity = dimmed(node.id) ? 0.18 : 1
                    let shape = Self.mark(node.entity.kind, in: rect)
                    switch node.entity.kind {
                    case .me:
                        layer.fill(shape, with: .color(Ink.spot))
                    case .person:
                        layer.fill(shape, with: .color(Ink.text.opacity(0.85)))
                    case .group, .project:
                        layer.fill(shape, with: .color(Ink.surface))
                        layer.stroke(shape, with: .color(Ink.text.opacity(0.8)), lineWidth: 1.2)
                        layer.fill(Circle().path(in: rect.insetBy(dx: rect.width * 0.34, dy: rect.height * 0.34)), with: .color(Ink.text))
                    default:
                        layer.fill(shape, with: .color(Ink.surface))
                        layer.stroke(shape, with: .color(Ink.text.opacity(0.8)), lineWidth: 1.2)
                    }
                    if selected == node.id {
                        layer.stroke(Circle().path(in: rect.insetBy(dx: -4, dy: -4)), with: .color(Ink.spot), lineWidth: 2)
                    }
                }
                for node in order.prefix(focus == nil ? 45 : 60) {
                    let radius = Self.radius(node.entity) * min(1.4, max(0.7, zoom))
                    let p = point(node.position)
                    labels.append((node, CGPoint(x: p.x, y: p.y + radius + 9)))
                }
                for (node, at) in labels {
                    let isMe = node.entity.kind == .me
                    let text = Text(node.entity.name.count > 22 ? String(node.entity.name.prefix(21)) + "…" : node.entity.name)
                        .font(.system(size: isMe ? 13 : 10.5, weight: isMe ? .heavy : .semibold, design: .rounded))
                        .foregroundStyle(Ink.text)
                    let resolved = context.resolve(text)
                    let measured = resolved.measure(in: CGSize(width: 200, height: 40))
                    let box = CGRect(x: at.x - measured.width / 2 - 3, y: at.y - measured.height / 2 - 1,
                                     width: measured.width + 6, height: measured.height + 2)
                    guard isMe || node.id == selected || !placed.contains(where: { $0.intersects(box) }) else { continue }
                    placed.append(box)
                    var layer = context
                    layer.opacity = dimmed(node.id) ? 0.25 : 1
                    layer.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(Ink.surface.opacity(0.85)))
                    layer.draw(resolved, at: at)
                }
            }
        }
        .task(id: generation) { await simulate() }
        .onGeometryChange(for: CGSize.self, of: \.size) { canvasSize = $0 }
        .background(Ink.surface)
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { drag = $0.translation }
                .onEnded { value in
                    offset.width += value.translation.width
                    offset.height += value.translation.height
                    drag = .zero
                })
        .simultaneousGesture(MagnifyGesture().onChanged { zoom = max(0.3, min(3, $0.magnification)) })
        .onTapGesture(coordinateSpace: .local) { location in pick(at: location) }
        .overlay(alignment: .bottomLeading) { legend.padding(12) }
        .overlay {
            if nodes.isEmpty {
                ContentUnavailableView("The graph is empty", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("Update memory and Agott will connect the people and things in your life."))
            }
        }
    }

    private func pick(at location: CGPoint) {
        let nearest = nodes.min { distance($0, location) < distance($1, location) }
        if let nearest, distance(nearest, location) < max(16, Self.radius(nearest.entity) + 10) {
            selected = nearest.id
            let entity = nearest.entity
            Task {
                neighbors = (try? await MemoryStore.shared.neighbors(of: entity.id, limit: 40)) ?? []
                facts = (try? await MemoryStore.shared.facts(matching: entity.kind == .me ? nil : entity.name, limit: 30)) ?? []
                if entity.kind == .person {
                    // Their profile first: facts about them, however their name was written.
                    let profile = (try? await MemoryStore.shared.profile(of: entity.name, limit: 30)) ?? []
                    let ids = Set(profile.map(\.id))
                    facts = profile + facts.filter { !ids.contains($0.id) }
                }
                if entity.kind == .me {
                    facts = (try? await MemoryStore.shared.facts(about: entity.name, limit: 30)) ?? []
                }
            }
        } else {
            selected = nil
        }
    }

    private func distance(_ node: Node, _ location: CGPoint) -> CGFloat {
        let p = CGPoint(x: center.x + node.position.x * zoom, y: center.y + node.position.y * zoom)
        return hypot(p.x - location.x, p.y - location.y)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach([EntityKind.person, .group, .place, .organization, .project, .topic], id: \.self) { kind in
                HStack(spacing: 4) {
                    LegendMark(kind: kind).frame(width: 9, height: 9)
                    Text(kind.label).font(.caption2)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .quietSurface(Capsule(), fill: Ink.surface)
    }

    private func inspector(_ entity: GraphEntity) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(entity.name, systemImage: entity.kind.symbol)
                        .font(Lettering.display(17, relativeTo: .title3)).foregroundStyle(Ink.text)
                    Spacer()
                    Button { selected = nil } label: { Image(systemName: "xmark").foregroundStyle(Ink.muted) }
                        .buttonStyle(.plain)
                }
                Text("\(entity.kind.label) · seen \(entity.mentions) times").font(.caption).foregroundStyle(Ink.muted)

                if entity.kind == .person {
                    PersonPanel(name: entity.name).id(entity.id)
                }

                if !facts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        PanelTitle(title: "What Agott knows", symbol: "pin")
                        ForEach(facts.prefix(12)) { fact in FactRow(fact: fact) }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    PanelTitle(title: "Connections", symbol: "point.3.connected.trianglepath.dotted")
                    ForEach(Array(neighbors.filter { !Self.isPhoneOnly($0.0.name) }.enumerated()), id: \.offset) { _, pair in
                        let (other, edge) = pair
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: other.kind.symbol).foregroundStyle(Ink.muted).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(other.name).font(.callout).foregroundStyle(Ink.text)
                                Text(Self.relationLabel(edge.relation)).font(.caption).foregroundStyle(Ink.muted)
                            }
                            Spacer()
                            Text("×\(Int(edge.weight))").font(.caption).monospacedDigit().foregroundStyle(Ink.muted)
                        }
                        // Every person is a link: hover for their card, click to open them.
                        .modifier(PersonLinkIf(name: other.kind == .person || other.kind == .me ? other.name : nil))
                    }
                }
            }
            .padding(16)
        }
    }

    /// A graph relation in the reader's language: the graph's own words
    /// ("knows", "member of") and fact verbs alike.
    static func relationLabel(_ relation: String) -> String {
        if let known = GraphRelation(rawValue: relation) { return known.label }
        guard Persona.prefersPortuguese else { return relation }
        return FactWords.portuguese[relation.lowercased()] ?? relation
    }

    // MARK: Data

    /// A contact known only by a number tells you nothing on a map.
    nonisolated static func isPhoneOnly(_ name: String) -> Bool {
        let digits = name.filter(\.isNumber).count
        return digits >= 7 && !name.contains(where: \.isLetter)
    }

    private func load() async {
        lastReload = .now
        let candidates = (try? await MemoryStore.shared.entities(limit: size * 3, kinds: kinds)) ?? []
        let entities = Array(candidates.filter { $0.kind == .me || !Self.isPhoneOnly($0.name) }.prefix(size))
        let all = (try? await MemoryStore.shared.edges(among: entities.map(\.id))) ?? []
        edges = Self.prune(all, keep: 3)

        // Keep nodes that were already placed where they are, so a refresh
        // grows the graph instead of reshuffling it.
        let placed = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        nodes = entities.enumerated().map { index, entity in
            if var existing = placed[entity.id] {
                existing.entity = entity
                return existing
            }
            let angle = Double(index) * 2.399963
            let r = entity.kind == .me ? 0 : 80 + sqrt(Double(index)) * 55
            return Node(entity: entity, position: CGPoint(x: cos(angle) * r, y: sin(angle) * r))
        }
        generation += 1
    }

    /// Each node keeps only its strongest `keep` connections (an edge stays
    /// if either end ranks it highly), which turns a hairball into a map.
    static func prune(_ edges: [GraphEdge], keep: Int) -> [GraphEdge] {
        var byNode: [Int64: [GraphEdge]] = [:]
        for edge in edges {
            byNode[edge.source, default: []].append(edge)
            byNode[edge.target, default: []].append(edge)
        }
        var kept = Set<String>()
        for (_, list) in byNode {
            for edge in list.sorted(by: { $0.weight > $1.weight }).prefix(keep) {
                kept.insert("\(edge.source)-\(edge.target)-\(edge.relation)")
            }
        }
        return edges.filter { kept.contains("\($0.source)-\($0.target)-\($0.relation)") }
    }

    /// Runs the layout until it settles, fits it to the view, then stops
    /// redrawing.
    private func simulate() async {
        guard !nodes.isEmpty else { return }
        settling = true
        defer { settling = false }
        for tick in 0..<320 {
            guard !Task.isCancelled else { return }
            step(cooling: max(0.15, 1 - Double(tick) / 320))
            if tick == 60 || tick == 319 { fit(animated: tick == 319) }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    /// Zooms and centres so everything is visible with a margin.
    private func fit(animated: Bool) {
        guard !nodes.isEmpty, canvasSize.width > 0 else { return }
        let xs = nodes.map(\.position.x), ys = nodes.map(\.position.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: max(1, xs.max()! - xs.min()!), height: max(1, ys.max()! - ys.min()!))
        let scale = min(1.8, max(0.3, min((canvasSize.width - 140) / bounds.width, (canvasSize.height - 120) / bounds.height)))
        let change = {
            zoom = scale
            offset = CGSize(width: -bounds.midX * scale, height: -bounds.midY * scale)
        }
        if animated { withAnimation(Motion.settle, change) } else { change() }
    }

    private func step(cooling: Double) {
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        var forces = [CGVector](repeating: .zero, count: nodes.count)
        // Repulsion: everyone pushes everyone, so names get room.
        for i in nodes.indices {
            for j in nodes.indices where j > i {
                let dx = nodes[i].position.x - nodes[j].position.x
                let dy = nodes[i].position.y - nodes[j].position.y
                let d2 = max(dx * dx + dy * dy, 100)
                let d = sqrt(d2)
                let f = 4200 / d2
                forces[i].dx += dx / d * f; forces[i].dy += dy / d * f
                forces[j].dx -= dx / d * f; forces[j].dy -= dy / d * f
            }
        }
        // Springs: strong connections sit closer.
        for edge in edges {
            guard let a = index[edge.source], let b = index[edge.target] else { continue }
            let dx = nodes[b].position.x - nodes[a].position.x
            let dy = nodes[b].position.y - nodes[a].position.y
            let d = max(sqrt(dx * dx + dy * dy), 1)
            let target = 150 / (1 + log2(edge.weight + 1) * 0.15)
            let f = (d - target) * 0.012
            forces[a].dx += dx / d * f; forces[a].dy += dy / d * f
            forces[b].dx -= dx / d * f; forces[b].dy -= dy / d * f
        }
        let limit = 10 * cooling
        for i in nodes.indices {
            if nodes[i].entity.kind == .me { nodes[i].position = .zero; continue }
            forces[i].dx -= nodes[i].position.x * 0.0015
            forces[i].dy -= nodes[i].position.y * 0.0015
            nodes[i].velocity.dx = (nodes[i].velocity.dx + forces[i].dx) * 0.8
            nodes[i].velocity.dy = (nodes[i].velocity.dy + forces[i].dy) * 0.8
            nodes[i].position.x += max(-limit, min(limit, nodes[i].velocity.dx))
            nodes[i].position.y += max(-limit, min(limit, nodes[i].velocity.dy))
        }
    }

    static func radius(_ entity: GraphEntity) -> CGFloat {
        entity.kind == .me ? 13 : min(9, 3.5 + log2(Double(entity.mentions) + 1) * 0.7)
    }
}

extension GraphView {
    static func mark(_ kind: EntityKind, in rect: CGRect) -> Path {
        switch kind {
        case .organization, .project: Path(roundedRect: rect, cornerRadius: rect.width * 0.2)
        case .place:
            Path { p in
                p.move(to: CGPoint(x: rect.midX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
                p.closeSubpath()
            }
        default: Circle().path(in: rect)
        }
    }
}

private struct LegendMark: View {
    var kind: EntityKind

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            let shape = GraphView.mark(kind, in: rect)
            if kind == .person {
                context.fill(shape, with: .color(Ink.text))
            } else {
                context.stroke(shape, with: .color(Ink.text), lineWidth: 1.2)
                if kind == .group || kind == .project {
                    context.fill(Circle().path(in: rect.insetBy(dx: rect.width * 0.3, dy: rect.height * 0.3)), with: .color(Ink.text))
                }
            }
        }
    }
}

extension EntityKind {
    var label: String {
        switch self {
        case .me: String(localized: "You")
        case .person: String(localized: "Person")
        case .group: String(localized: "Group")
        case .place: String(localized: "Place")
        case .organization: String(localized: "Organization")
        case .topic: String(localized: "Topic")
        case .project: String(localized: "Project")
        case .thing: String(localized: "Thing")
        }
    }
}

/// Who someone is, in the graph's side panel: counts right away, then a
/// written portrait (cached after the first time).
private struct PersonPanel: View {
    var name: String
    @State private var trace: MemoryStore.PersonTrace?
    @State private var portrait: PersonPortrait?
    @State private var writing = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let trace, trace.total > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(trace.total.formatted()) messages from them", systemImage: "text.bubble")
                    if let last = trace.lastSeen {
                        Label("Last time: \(last.formatted(.relative(presentation: .named)))", systemImage: "clock")
                    }
                    if !trace.groups.isEmpty {
                        Label(trace.groups.prefix(3).map(\.name).joined(separator: ", "), systemImage: "person.3")
                            .lineLimit(2)
                    }
                }
                .font(.caption)
                .foregroundStyle(Ink.muted)
            }

            if let portrait {
                VStack(alignment: .leading, spacing: 8) {
                    Text(portrait.toYou).font(.callout.weight(.semibold)).foregroundStyle(Ink.text)
                    Text(portrait.summary).font(.callout).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true)
                    if !portrait.vibe.isEmpty {
                        Chip(text: portrait.vibe.capitalized, symbol: "heart", spot: true)
                    }
                    if !portrait.topics.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(portrait.topics, id: \.self) { Chip(text: $0) }
                        }
                    }
                    Button {
                        Task { await write() }
                    } label: {
                        Label("Write again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Ink.muted)
                }
                .panel(padding: 12, toned: true)
            } else if writing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Writing who \(name) is…").font(.callout).foregroundStyle(Ink.muted)
                }
            } else if let error {
                Text(error).font(.caption).foregroundStyle(Ink.muted)
                Button("Try again") { Task { await write() } }.buttonStyle(.candy(.soft, compact: true))
            }
        }
        .task {
            trace = try? await MemoryStore.shared.trace(of: name)
            portrait = await PersonSummary.cached(name)
            if portrait == nil, (trace?.total ?? 0) > 0 || ModelHub.isAvailable(ModelHub.resolved()) {
                await write()
            }
        }
    }

    private func write() async {
        writing = true
        error = nil
        do {
            portrait = try await PersonSummary.write(name)
        } catch {
            self.error = error.localizedDescription
        }
        writing = false
    }
}


/// A fact with its odds and its proof: what was said, by whom, where.
struct FactRow: View {
    var fact: MemoryFact

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Text(fact.subject).bold()) \(fact.displayPredicate) \(Text(fact.object).foregroundStyle(Ink.spot))")
                    .font(.callout).foregroundStyle(Ink.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text("\(Int((fact.confidence * 100).rounded()))%")
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(fact.confidence >= 0.7 ? Ink.text : Ink.muted)
                    .help(Text(fact.selfStated ? "Said by them" : "Inferred"))
            }
            if let evidence = fact.evidence, !evidence.isEmpty {
                Text("“\(evidence)”")
                    .font(.caption).italic()
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let chat = fact.chatName {
                Text(fact.inGroup ? String(localized: "In the group “\(chat)”") : String(localized: "In the direct chat with \(chat)"))
                    .font(.caption2).foregroundStyle(Ink.muted)
            }
        }
    }
}

/// A rounded filter pill: filled when chosen, outlined otherwise.
struct FilterChip: View {
    var title: LocalizedStringKey
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .foregroundStyle(selected ? Ink.canvas : Ink.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(selected ? Ink.text : .clear))
                .overlay(Capsule().strokeBorder(Ink.hairline.opacity(selected ? 0 : 1), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Makes a row a person link when it names a person.
private struct PersonLinkIf: ViewModifier {
    var name: String?
    func body(content: Content) -> some View {
        if let name { content.personHover(name) } else { content }
    }
}

