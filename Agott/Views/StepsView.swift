import SwiftUI

/// What Agott did on the way to a reply, the way the best assistants show it.
///
/// While it works, the activity is open: a timeline of what it is doing, its
/// thinking streaming in as it thinks, and what each memory search found.
/// When the reply lands, it folds into one quiet line ("Thought for 6s ·
/// remembered 10 things") that opens again with a click.
struct StepsView: View {
    var steps: [Step]
    var isStreaming: Bool
    @State private var expanded = false

    var body: some View {
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                header
                if isStreaming || expanded {
                    Timeline(steps: steps)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
            .animation(Motion.settle, value: expanded)
            .animation(Motion.settle, value: isStreaming)
        }
    }

    private var header: some View {
        Button {
            if !isStreaming { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                MascotFace(mood: isStreaming ? .thinking : .idle, size: 20)
                    .frame(width: Timeline.rail, height: Timeline.rail)
                Text(headerText)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(isStreaming ? Ink.text : Ink.muted)
                    .lineLimit(1)
                    .modifier(Shimmer(active: isStreaming))
                if !isStreaming {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Ink.muted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 8, inset: -4)
        }
        .buttonStyle(.plain)
        .help(Text(expanded ? "Hide steps" : "Show steps"))
    }

    /// While working: what it is doing now. Afterwards: what it did.
    private var headerText: String {
        if isStreaming {
            return steps.last(where: { $0.state == .running })?.title ?? String(localized: "Working")
        }
        let thought = steps.filter { $0.kind == .thinking }.compactMap(\.seconds).reduce(0, +)
        let remembered = steps.compactMap(\.items).map(\.count).reduce(0, +)
        let tools = steps.filter { $0.kind == .tool }.count
        var parts: [String] = []
        if thought > 0 { parts.append(String(localized: "Thought for \(thought)s")) }
        if remembered > 0 { parts.append(String(localized: "Remembered \(remembered) things")) }
        if tools > 0 { parts.append(String(localized: "\(tools) steps")) }
        return parts.isEmpty ? String(localized: "Steps") : parts.joined(separator: " · ")
    }
}

/// The steps as a vertical timeline: one icon rail, each step's content
/// beside its icon.
private struct Timeline: View {
    static let rail: CGFloat = 18
    var steps: [Step]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                StepRow(step: step, last: index == steps.count - 1)
            }
        }
    }
}

private struct StepRow: View {
    var step: Step
    var last: Bool
    @State private var open = false
    @State private var showAll = false

    private var hasDetail: Bool { !(step.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var items: [Step.Item] { step.items ?? [] }
    private var opens: Bool { hasDetail || !items.isEmpty }
    /// Thinking streams in view while it happens; everything else opens on demand.
    private var showsBody: Bool {
        (step.kind == .thinking && step.state == .running && hasDetail) || open
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            icon
                .frame(width: Timeline.rail, height: 20)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(alignment: .top) {
                    if !last {
                        Rectangle()
                            .fill(Ink.hairline)
                            .frame(width: 1)
                            .padding(.top, 22)
                    }
                }
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    if opens { open.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(step.title)
                            .font(.callout)
                            .foregroundStyle(step.state == .running ? Ink.text : Ink.muted)
                            .lineLimit(1)
                        if let seconds = step.seconds, step.kind == .thinking || seconds >= 2 {
                            Text("\(seconds)s").font(.caption).monospacedDigit().foregroundStyle(Ink.muted)
                        }
                        if opens {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Ink.muted)
                                .rotationEffect(.degrees(open ? 90 : 0))
                        }
                    }
                    .frame(minHeight: 20)
                    .contentShape(Rectangle())
                    .modifier(OptionalHover(active: opens))
                }
                .buttonStyle(.plain)

                if showsBody {
                    if !items.isEmpty {
                        FoundList(items: items, showAll: $showAll)
                    } else if let detail = step.detail {
                        DetailText(text: detail, thinking: step.kind == .thinking, live: step.state == .running)
                    }
                }
            }
            .padding(.bottom, last ? 0 : 10)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(step.state == .running ? "in progress" : step.state == .done ? "done" : "declined"))
    }

    @ViewBuilder
    private var icon: some View {
        switch step.state {
        case .running:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        case .done:
            Image(systemName: step.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Ink.muted)
        case .failed:
            Image(systemName: "xmark.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Ink.muted)
        }
    }
}

/// Highlights a row under the pointer only when clicking it does something.
private struct OptionalHover: ViewModifier {
    var active: Bool
    func body(content: Content) -> some View {
        if active { content.hoverHighlight(cornerRadius: 8, inset: -4) } else { content }
    }
}

/// Reasoning or tool output. Live thinking shows its latest lines, the way
/// you would watch someone think; finished, it is all there to scroll.
private struct DetailText: View {
    var text: String
    var thinking: Bool
    var live: Bool

    var body: some View {
        let shown = live ? Self.tail(text) : text
        Group {
            if live || shown.count < 900 {
                label(shown)
            } else {
                ScrollView { label(shown) }.frame(maxHeight: 260)
            }
        }
        .padding(.vertical, 2)
    }

    /// The last few hundred characters, starting at a line or word boundary.
    static func tail(_ text: String) -> String {
        guard text.count > 420 else { return text }
        let tail = text.suffix(420)
        if let line = tail.firstIndex(of: "\n") { return String(tail[tail.index(after: line)...]) }
        if let space = tail.firstIndex(of: " ") { return "…" + tail[tail.index(after: space)...] }
        return String(tail)
    }

    private func label(_ text: String) -> some View {
        Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(thinking ? .callout : .caption)
            .foregroundStyle(Ink.muted)
            .lineSpacing(2)
            .textSelection(.enabled)
            .lineLimit(live ? 4 : nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What a memory search found: the chat, where and when, and the words.
private struct FoundList: View {
    var items: [Step.Item]
    @Binding var showAll: Bool

    var body: some View {
        let shown = showAll ? items : Array(items.prefix(4))
        VStack(alignment: .leading, spacing: 4) {
            ForEach(shown) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.symbol)
                        .font(.caption)
                        .foregroundStyle(Ink.muted)
                        .frame(width: 16)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.title).font(.callout.weight(.semibold)).foregroundStyle(Ink.text).lineLimit(1)
                            if let subtitle = item.subtitle {
                                Text(subtitle).font(.caption).foregroundStyle(Ink.muted).lineLimit(1)
                            }
                        }
                        if let snippet = item.snippet {
                            Text(snippet)
                                .font(.caption)
                                .foregroundStyle(Ink.muted)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.surface))
            }
            if items.count > 4 {
                Button(showAll ? String(localized: "Show less") : String(localized: "Show \(items.count - 4) more")) {
                    withAnimation(Motion.settle) { showAll.toggle() }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Ink.muted)
                .padding(.leading, 10)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}

/// A light sweep across text that is still in progress.
struct Shimmer: ViewModifier {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1 / 20)) { context in
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                content.overlay {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, Ink.spot.opacity(0.55), .clear],
                            startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.5)
                            .offset(x: proxy.size.width * (CGFloat(t) * 1.6 - 0.5))
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
        } else {
            content
        }
    }
}
