import SwiftUI

/// A paragraph that names people, laid out word by word so each person can
/// be a real control: their avatar and name, a button under the pointer,
/// and their card opening right above the name when clicked.
///
/// A SwiftUI `Text` can carry links but not hover, avatars or a popover per
/// word, so paragraphs without mentions stay plain (selectable) text and only
/// these are rebuilt from tokens.
struct MentionParagraph: View {
    var text: String
    var lineSpacing: CGFloat = 3

    enum Token {
        case words(AttributedString)
        case mention(Int64)
        case media(MediaTag)
    }

    var body: some View {
        let lines = Self.lines(MarkdownView.inline(text))
        VStack(alignment: .leading, spacing: lineSpacing) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                InlineFlow(lineSpacing: lineSpacing) {
                    ForEach(Array(line.enumerated()), id: \.offset) { _, token in
                        switch token {
                        case .words(let words): Text(words)
                        case .mention(let id): MentionChip(id: id)
                        case .media(let media): MediaChip(media: media)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The paragraph as lines of tokens: a word with its trailing space, or
    /// a person. Styled runs (bold, code) keep their attributes.
    static func lines(_ attributed: AttributedString) -> [[Token]] {
        var lines: [[Token]] = [[]]
        for run in attributed.runs {
            if let url = run.link, url.scheme == "agott", url.host() == "person",
               let id = Int64(url.lastPathComponent) {
                lines[lines.count - 1].append(.mention(id))
                continue
            }
            if let url = run.link, let media = MediaTag(link: url) {
                lines[lines.count - 1].append(.media(media))
                continue
            }
            let slice = attributed[run.range]
            var start = slice.startIndex
            for index in slice.characters.indices {
                let character = slice.characters[index]
                let next = slice.characters.index(after: index)
                if character == "\n" {
                    if start < index { lines[lines.count - 1].append(.words(AttributedString(slice[start..<index]))) }
                    lines.append([])
                    start = next
                } else if character.isWhitespace {
                    lines[lines.count - 1].append(.words(AttributedString(slice[start..<next])))
                    start = next
                }
            }
            if start < slice.endIndex {
                lines[lines.count - 1].append(.words(AttributedString(slice[start..<slice.endIndex])))
            }
        }
        return lines
    }
}

/// A person named in a reply: avatar and name, a soft button under the
/// pointer, their card above it on click.
struct MentionChip: View {
    var id: Int64
    @State private var hovering = false
    @State private var showing = false

    var body: some View {
        let hidden = AppSettings.shared.hideNames
        let label = PeopleDirectory.shared.label(id, hidden: hidden)
        let name = PeopleDirectory.shared.name(id)?.name ?? label
        Button { showing = true } label: {
            HStack(spacing: 4) {
                InitialsAvatar(text: hidden ? "?" : name, size: 16)
                Text(label)
                    .fontWeight(.semibold)
                    .foregroundStyle(Ink.spot)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Ink.spot.opacity(hovering || showing ? 0.14 : 0)))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Ink.spot.opacity(hovering || showing ? 0.35 : 0), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        #if os(macOS)
        .pointerStyle(.link)
        #endif
        .animation(.easeOut(duration: 0.12), value: hovering)
        // Above the name, its arrow pointing down at it.
        .popover(isPresented: $showing, arrowEdge: .bottom) { PersonPeekCard(id: id) }
        .accessibilityLabel(Text(label))
        .accessibilityHint(Text("Shows who this is"))
    }
}

/// Lays children out like words in a line of text: left to right, wrapping,
/// each line aligned on the text baseline so chips sit level with words.
struct InlineFlow: Layout {
    var lineSpacing: CGFloat = 3

    private struct Line {
        var items: [(index: Int, size: CGSize, baseline: CGFloat)] = []
        var width: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
    }

    private func lines(for width: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = [Line()]
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let baseline = view.dimensions(in: .unspecified)[VerticalAlignment.firstTextBaseline]
            if lines[lines.count - 1].width + size.width > width, !lines[lines.count - 1].items.isEmpty {
                lines.append(Line())
            }
            lines[lines.count - 1].items.append((index, size, baseline))
            lines[lines.count - 1].width += size.width
            lines[lines.count - 1].ascent = max(lines[lines.count - 1].ascent, baseline)
            lines[lines.count - 1].descent = max(lines[lines.count - 1].descent, size.height - baseline)
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = lines(for: width, subviews: subviews)
        let height = lines.reduce(0) { $0 + $1.ascent + $1.descent } + lineSpacing * CGFloat(max(0, lines.count - 1))
        let widest = lines.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(for: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in line.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y + line.ascent - item.baseline),
                                           proposal: ProposedViewSize(item.size))
                x += item.size.width
            }
            y += line.ascent + line.descent + lineSpacing
        }
    }
}
