import SwiftUI

/// Your life as a graph, laid out by a small force simulation.
///
/// You are pinned at the centre. People, groups, places and projects settle
/// around you, pulled closer by the weight of what connects you and pushed
/// apart from each other so names stay readable.
struct GraphView: View {
    @State private var nodes: [Node] = []
    @State private var edges: [GraphEdge] = []
    @State private var selected: Int64?
    @State private var neighbors: [(GraphEntity, GraphEdge)] = []
    @State private var kinds: Set<EntityKind> = [.me, .person, .group, .place, .organization, .project, .topic]
    @State private var size = 120
    @State private var drag: CGSize = .zero
    @State private var offset: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @State private var settling = false
    @State private var generation = 0
    @State private var lastReload = Date.distantPast

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
                    Picker("Size", selection: $size) {
                        Text(verbatim: "60").tag(60)
                        Text(verbatim: "120").tag(120)
                        Text(verbatim: "250").tag(250)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .labelsHidden()
                    CandyIconButton(symbol: "arrow.clockwise") { Task { await load() } }
                }
            }
            HStack(spacing: 14) {
                canvas
                    .clipShape(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
                if let selected, let node = nodes.first(where: { $0.id == selected }) {
                    inspector(node.entity)
                        .frame(width: 280)
                        .panel(padding: 0)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(Motion.settle, value: selected)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 24)
        .task(id: size) { await load() }
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

    private var canvas: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !settling && drag == .zero)) { _ in
            // Drawn off the main thread, so a busy graph never blocks clicks.
            Canvas(rendersAsynchronously: true) { context, _ in
                let center = self.center
                let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
                // Text is the expensive part of each frame: label the forty
                // most-mentioned only.
                let labelled = Set(nodes.sorted { $0.entity.mentions > $1.entity.mentions }.prefix(40).map(\.id))
                func point(_ p: CGPoint) -> CGPoint { CGPoint(x: center.x + p.x * zoom, y: center.y + p.y * zoom) }

                for edge in edges {
                    guard let a = byID[edge.source], let b = byID[edge.target] else { continue }
                    var path = Path()
                    path.move(to: point(a.position))
                    path.addLine(to: point(b.position))
                    let highlighted = selected == edge.source || selected == edge.target
                    context.stroke(path, with: .color(highlighted ? Ink.spot : Ink.text.opacity(0.18)),
                                   lineWidth: highlighted ? 1.6 : min(3, 0.4 + log2(edge.weight + 1) * 0.3))
                }
                for node in nodes {
                    let radius = Self.radius(node.entity)
                    let p = point(node.position)
                    let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
                    // Kinds differ by mark, like a legend in print: solid,
                    // ringed, dotted, squared.
                    let shape = Self.mark(node.entity.kind, in: rect)
                    switch node.entity.kind {
                    case .me:
                        context.fill(shape, with: .color(Ink.spot))
                        context.stroke(shape, with: .color(Ink.text), lineWidth: Ink.line)
                    case .person:
                        context.fill(shape, with: .color(Ink.text))
                    case .group, .project:
                        context.fill(shape, with: .color(Ink.surface))
                        context.stroke(shape, with: .color(Ink.text), lineWidth: Ink.line)
                        context.fill(Circle().path(in: rect.insetBy(dx: rect.width * 0.32, dy: rect.height * 0.32)), with: .color(Ink.text))
                    default:
                        context.fill(shape, with: .color(Ink.surface))
                        context.stroke(shape, with: .color(Ink.text), lineWidth: Ink.line)
                    }
                    if selected == node.id {
                        context.stroke(Circle().path(in: rect.insetBy(dx: -3, dy: -3)), with: .color(Ink.accent), lineWidth: 2)
                    }
                    if (radius > 9 && labelled.contains(node.id)) || selected == node.id || node.entity.kind == .me {
                        context.draw(
                            Text(node.entity.name).font(.system(size: node.entity.kind == .me ? 14 : 10, weight: node.entity.kind == .me ? .heavy : .semibold, design: .rounded)).foregroundStyle(Ink.text),
                            at: CGPoint(x: p.x, y: p.y + radius + 8))
                    }
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

    @State private var canvasSize: CGSize = .zero

    private func pick(at location: CGPoint) {
        let nearest = nodes.min { distance($0, location) < distance($1, location) }
        if let nearest, distance(nearest, location) < max(14, Self.radius(nearest.entity) + 8) {
            selected = nearest.id
            Task { neighbors = (try? await MemoryStore.shared.neighbors(of: nearest.id, limit: 30)) ?? [] }
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
        .glassEffect(.regular, in: .capsule)
    }

    private func inspector(_ entity: GraphEntity) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(entity.name, systemImage: entity.kind.symbol).font(Lettering.display(17, relativeTo: .title3)).foregroundStyle(Ink.text)
                Text("\(entity.kind.label) · seen \(entity.mentions) times").font(.caption).foregroundStyle(Ink.muted)
                Divider()
                ForEach(Array(neighbors.enumerated()), id: \.offset) { _, pair in
                    let (other, edge) = pair
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: other.kind.symbol).foregroundStyle(Ink.text)
                        VStack(alignment: .leading) {
                            Text(other.name).font(.callout)
                            Text(edge.relation).font(.caption).foregroundStyle(Ink.muted)
                        }
                        Spacer()
                        Text("×\(Int(edge.weight))").font(.caption).monospacedDigit().foregroundStyle(Ink.muted)
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: Layout

    private func load() async {
        lastReload = .now
        let entities = (try? await MemoryStore.shared.entities(limit: size, kinds: kinds)) ?? []
        edges = (try? await MemoryStore.shared.edges(among: entities.map(\.id))) ?? []
        // Keep nodes that were already placed where they are, so a refresh
        // grows the graph instead of reshuffling it.
        let placed = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        nodes = entities.enumerated().map { index, entity in
            if var existing = placed[entity.id] {
                existing.entity = entity
                return existing
            }
            let angle = Double(index) * 2.399963
            let r = entity.kind == .me ? 0 : 60 + sqrt(Double(index)) * 40
            return Node(entity: entity, position: CGPoint(x: cos(angle) * r, y: sin(angle) * r))
        }
        generation += 1
    }

    /// Runs the layout until it settles, then stops redrawing.
    private func simulate() async {
        guard !nodes.isEmpty else { return }
        settling = true
        defer { settling = false }
        for _ in 0..<300 {
            guard !Task.isCancelled else { return }
            step()
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private func step() {
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        var forces = [CGVector](repeating: .zero, count: nodes.count)
        for i in nodes.indices {
            for j in nodes.indices where j > i {
                let dx = nodes[i].position.x - nodes[j].position.x
                let dy = nodes[i].position.y - nodes[j].position.y
                let d2 = max(dx * dx + dy * dy, 25)
                let f = 900 / d2
                forces[i].dx += dx * f / sqrt(d2); forces[i].dy += dy * f / sqrt(d2)
                forces[j].dx -= dx * f / sqrt(d2); forces[j].dy -= dy * f / sqrt(d2)
            }
        }
        for edge in edges {
            guard let a = index[edge.source], let b = index[edge.target] else { continue }
            let dx = nodes[b].position.x - nodes[a].position.x
            let dy = nodes[b].position.y - nodes[a].position.y
            let d = max(sqrt(dx * dx + dy * dy), 1)
            let target = 90 / (1 + log2(edge.weight + 1) * 0.3)
            let f = (d - target) * 0.02
            forces[a].dx += dx / d * f; forces[a].dy += dy / d * f
            forces[b].dx -= dx / d * f; forces[b].dy -= dy / d * f
        }
        for i in nodes.indices {
            if nodes[i].entity.kind == .me { nodes[i].position = .zero; continue }
            forces[i].dx -= nodes[i].position.x * 0.004
            forces[i].dy -= nodes[i].position.y * 0.004
            nodes[i].velocity.dx = (nodes[i].velocity.dx + forces[i].dx) * 0.82
            nodes[i].velocity.dy = (nodes[i].velocity.dy + forces[i].dy) * 0.82
            nodes[i].position.x += max(-8, min(8, nodes[i].velocity.dx))
            nodes[i].position.y += max(-8, min(8, nodes[i].velocity.dy))
        }
    }

    static func radius(_ entity: GraphEntity) -> CGFloat {
        entity.kind == .me ? 16 : min(14, 3 + log2(Double(entity.mentions) + 1) * 1.4)
    }

    static func color(_ kind: EntityKind) -> Color {
        switch kind {
        case .me: Ink.pink
        case .person: Color(.sRGB, red: 1.0, green: 0.50, blue: 0.62)
        case .group: Ink.violet
        case .place: Ink.mint
        case .organization: Ink.peach
        case .project: Ink.sky
        case .topic: Color(.sRGB, red: 0.40, green: 0.80, blue: 0.85)
        case .thing: Ink.muted
        }
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
