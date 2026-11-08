import SwiftUI

/// A list of things with their pictures: a numbered ranking with covers, or
/// a grid of posters. Each item opens its link when it has one.
struct CollectionCardView: View {
    var card: Card.Collection
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).font(.headline).foregroundStyle(Ink.text)
                if let subtitle = card.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(Ink.muted)
                }
            }
            switch card.style {
            case .ranking: ranking
            case .grid: grid
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .quietSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(card.title))
    }

    private var ranking: some View {
        VStack(spacing: 0) {
            ForEach(Array(card.items.enumerated()), id: \.offset) { index, item in
                Button { open(item) } label: {
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(Lettering.display(17, relativeTo: .body))
                            .monospacedDigit()
                            .foregroundStyle(index < 3 ? Ink.text : Ink.muted)
                            .frame(width: 26, alignment: .trailing)
                        Artwork(url: item.image, kind: card.kind, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.callout.weight(.semibold)).foregroundStyle(Ink.text).lineLimit(1)
                            if let subtitle = item.subtitle, !subtitle.isEmpty {
                                Text(subtitle).font(.caption).foregroundStyle(Ink.muted).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail).font(.caption).monospacedDigit().foregroundStyle(Ink.muted)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: 10, inset: 0)
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 170), spacing: 14)], alignment: .leading, spacing: 16) {
            ForEach(Array(card.items.enumerated()), id: \.offset) { _, item in
                Button { open(item) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Artwork(url: item.image, kind: card.kind, size: nil)
                        Text(item.title).font(.callout.weight(.semibold)).foregroundStyle(Ink.text).lineLimit(2)
                        if let subtitle = item.subtitle, !subtitle.isEmpty {
                            Text(subtitle).font(.caption).foregroundStyle(Ink.muted).lineLimit(1)
                        }
                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail).font(.caption).foregroundStyle(Ink.muted).lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The item's own link, or a search for it where it can be played or seen.
    private func open(_ item: Card.Collection.Item) {
        if let link = item.link { openURL(link); return }
        let media = MediaTag(kind: card.kind, title: item.title, by: item.subtitle)
        if let place = media.destinations.first { openURL(place.url) }
    }
}

/// A cover or poster; a quiet tile with the kind's symbol until it loads,
/// or when there is none. `size` nil fills the width (posters in a grid).
struct Artwork: View {
    var url: URL?
    var kind: String
    var size: CGFloat?

    private var ratio: CGFloat { ["movie", "show", "book"].contains(kind) ? 2 / 3 : 1 }
    private var corner: CGFloat { (size ?? 120) < 60 ? 6 : 10 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        Group {
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size.map { $0 / ratio })
        .aspectRatio(ratio, contentMode: .fit)
        .frame(maxWidth: size == nil ? .infinity : nil)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Ink.hairline, lineWidth: 1))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            Ink.raised
            Image(systemName: Self.symbol(for: kind))
                .font(.system(size: (size ?? 120) * 0.32))
                .foregroundStyle(Ink.muted)
        }
    }

    static func symbol(for kind: String) -> String {
        switch kind {
        case "song": "music.note"
        case "album": "square.stack"
        case "artist": "music.mic"
        case "movie": "film"
        case "show": "tv"
        case "book": "book.closed"
        case "app": "app"
        case "podcast": "mic"
        case "place": "mappin.and.ellipse"
        default: "square.grid.2x2"
        }
    }
}
