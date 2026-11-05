import SwiftUI

/// What Agott did on the way to a reply.
///
/// While it works, each step is a live row: a spinner beside what it is
/// doing right now ("Thinking", "Remembering “Floripa”", "Reading your chat
/// with Ana"), a check once it is done. When the reply lands, the rows fold
/// into one quiet line you can open again: the work is there if you want it
/// and out of the way if you do not.
struct StepsView: View {
    var steps: [Step]
    var isStreaming: Bool
    @State private var expanded = false

    var body: some View {
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if isStreaming || expanded {
                    if !isStreaming {
                        summary
                    }
                    ForEach(steps) { step in
                        StepRow(step: step)
                            .transition(.opacity.combined(with: .offset(y: -4)))
                    }
                } else {
                    summary
                }
            }
            .animation(Motion.settle, value: steps.map(\.id))
            .animation(Motion.settle, value: expanded)
            .padding(.leading, 4)
        }
    }

    private var summary: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text(summaryText)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(Ink.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(expanded ? "Hide steps" : "Show steps"))
    }

    private var summaryText: String {
        let thought = steps.filter { $0.kind == .thinking }.compactMap(\.seconds).reduce(0, +)
        let tools = steps.filter { $0.kind != .thinking }.count
        switch (thought > 0, tools > 0) {
        case (true, true): return String(localized: "Thought for \(thought)s · \(tools) steps")
        case (true, false): return String(localized: "Thought for \(thought)s")
        case (false, true): return String(localized: "\(tools) steps")
        default: return String(localized: "Steps")
        }
    }
}

private struct StepRow: View {
    var step: Step
    @State private var open = false

    private var hasDetail: Bool { !(step.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if hasDetail { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    icon.frame(width: 16)
                    Text(step.title)
                        .font(.callout.weight(step.state == .running ? .semibold : .regular))
                        .foregroundStyle(step.state == .running ? Ink.text : Ink.muted)
                        .lineLimit(1)
                        .modifier(Shimmer(active: step.state == .running))
                    if let seconds = step.seconds, step.kind == .thinking || seconds >= 2 {
                        Text("\(seconds)s").font(.caption2).monospacedDigit().foregroundStyle(Ink.muted)
                    }
                    if hasDetail {
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Ink.muted)
                            .rotationEffect(.degrees(open ? 0 : -90))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasDetail)

            if open, let detail = step.detail {
                Text(detail)
                    .font(step.kind == .thinking ? .callout.italic() : .caption)
                    .foregroundStyle(Ink.muted)
                    .textSelection(.enabled)
                    .lineLimit(14)
                    .padding(.leading, 24)
                    .padding(.vertical, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(step.state == .running ? "in progress" : step.state == .done ? "done" : "declined"))
    }

    @ViewBuilder
    private var icon: some View {
        switch step.state {
        case .running:
            ProgressView().controlSize(.mini)
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

/// A light sweep across text that is still in progress.
private struct Shimmer: ViewModifier {
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
