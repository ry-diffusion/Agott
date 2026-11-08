import SwiftUI

/// A message the way Telegram for Mac draws one.
///
/// Corners are 17 pt, except on the sender's side where a message joins its
/// neighbours from the same author (sent within ten minutes): there they
/// tighten to 5 pt, so a run of messages reads as one block. The time sits
/// inside the bubble, on the last line when it fits.
struct MessageBubble<Content: View>: View {
    static var bigRadius: CGFloat { 17 }
    static var smallRadius: CGFloat { 5 }
    /// Room on the sender's side for the tail; every bubble keeps it so a
    /// group's edges line up.
    static var tailWidth: CGFloat { 6 }
    /// The visible ink line around Agott's balloons.
    static var inkLine: CGFloat { 1.25 }
    /// Same author within this window joins the group (Telegram's `simpleDif`).
    static var mergeWindow: TimeInterval { 10 * 60 }

    var outgoing: Bool
    var time: Date?
    var joinsAbove = false
    var joinsBelow = false
    @ViewBuilder var content: Content

    var body: some View {
        let shape = BubbleShape(outgoing: outgoing, joinsAbove: joinsAbove, joinsBelow: joinsBelow)
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .padding(outgoing ? .trailing : .leading, Self.tailWidth)
            .foregroundStyle(outgoing ? AnyShapeStyle(Ink.onSpot) : AnyShapeStyle(Ink.text))
            .background {
                let fill = outgoing ? AnyShapeStyle(Ink.spot) : AnyShapeStyle(Ink.bubble)
                ZStack {
                    shape.fill(fill)
                    if !joinsBelow { BubbleTail(outgoing: outgoing).fill(fill) }
                }
                // Lifted off the page by a soft shadow, not outlined.
                .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
            }
            .contentShape(shape)
            // Keep the tail's room outside the column edge, like Telegram.
            .padding(outgoing ? .trailing : .leading, -Self.tailWidth)
    }
}

/// Telegram's bubble: rounded body, tightened corners where the group
/// continues, and on the last message of a group a small curved tail at the
/// bottom on the sender's side.
struct BubbleShape: Shape {
    var outgoing: Bool
    var joinsAbove: Bool
    var joinsBelow: Bool

    func path(in rect: CGRect) -> Path {
        let tail = MessageBubble<EmptyView>.tailWidth
        let big = MessageBubble<EmptyView>.bigRadius, small = MessageBubble<EmptyView>.smallRadius
        var body = rect
        if outgoing { body.size.width -= tail } else { body.origin.x += tail; body.size.width -= tail }
        let hasTail = !joinsBelow
        // The sender's bottom corner: tight when the group goes on, and
        // tight under the tail so the two flow into each other.
        let senderBottom = hasTail || joinsBelow ? small : big
        let senderTop = joinsAbove ? small : big
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: outgoing ? big : senderTop,
            bottomLeadingRadius: outgoing ? big : senderBottom,
            bottomTrailingRadius: outgoing ? senderBottom : big,
            topTrailingRadius: outgoing ? senderTop : big,
            style: .continuous)
        // The tail is filled as its own shape (see `BubbleTail`): drawn in one
        // path its winding would cut a hole where it meets the body.
        return shape.path(in: body)
    }
}

/// The small curved tail under the last bubble of a group.
struct BubbleTail: Shape {
    var outgoing: Bool

    func path(in rect: CGRect) -> Path {
        let tail = MessageBubble<EmptyView>.tailWidth
        var body = rect
        if outgoing { body.size.width -= tail } else { body.origin.x += tail; body.size.width -= tail }
        var tailPath = Path()
        if outgoing {
            tailPath.move(to: CGPoint(x: body.maxX - 12, y: body.maxY))
            tailPath.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            tailPath.addQuadCurve(to: CGPoint(x: body.maxX, y: body.maxY - 13),
                                  control: CGPoint(x: body.maxX + 0.5, y: body.maxY - 3))
            tailPath.addLine(to: CGPoint(x: body.maxX - 12, y: body.maxY - 13))
        } else {
            tailPath.move(to: CGPoint(x: body.minX + 12, y: body.maxY))
            tailPath.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            tailPath.addQuadCurve(to: CGPoint(x: body.minX, y: body.maxY - 13),
                                  control: CGPoint(x: body.minX - 0.5, y: body.maxY - 3))
            tailPath.addLine(to: CGPoint(x: body.minX + 12, y: body.maxY - 13))
        }
        tailPath.closeSubpath()
        return tailPath
    }
}

/// The time inside a bubble: after the text when the line has room, under it
/// on the right when it does not.
struct TextWithTime: View {
    var text: AttributedString
    var time: Date
    var outgoing: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(text).fixedSize()
                stamp
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(text).frame(maxWidth: .infinity, alignment: .leading)
                stamp
            }
        }
        .textSelection(.enabled)
    }

    private var stamp: some View {
        Text(time, format: .dateTime.hour().minute())
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(outgoing ? AnyShapeStyle(Ink.onSpot.opacity(0.75)) : AnyShapeStyle(Ink.muted))
    }
}

extension Turn {
    /// Whether this turn joins `other` in one visual group.
    func joins(_ other: Turn?) -> Bool {
        guard let other, other.role == role else { return false }
        return abs(date.timeIntervalSince(other.date)) < MessageBubble<EmptyView>.mergeWindow
    }
}
