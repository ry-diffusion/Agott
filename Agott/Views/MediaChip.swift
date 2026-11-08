import SwiftUI

/// A song, album, film or book named in a reply: its cover, its title and
/// who made it, a soft button under the pointer, a larger card on click.
struct MediaChip: View {
    var media: MediaTag
    @State private var image: URL?
    @State private var hovering = false
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 5) {
                Artwork(url: image, kind: media.kind, size: 18)
                Text(media.title).fontWeight(.semibold).foregroundStyle(Ink.text)
                if let by = media.by {
                    Text(verbatim: "· \(by)").foregroundStyle(Ink.muted)
                }
            }
            .padding(.leading, 2)
            .padding(.trailing, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Ink.raised.opacity(hovering || showing ? 1 : 0.6)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Ink.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        #if os(macOS)
        .pointerStyle(.link)
        #endif
        .animation(.easeOut(duration: 0.12), value: hovering)
        .popover(isPresented: $showing, arrowEdge: .bottom) { MediaPeekCard(media: media, image: image) }
        .task(id: media) { image = await MediaArtwork.shared.image(for: media) }
        .accessibilityLabel(Text(media.by.map { "\(media.title), \($0)" } ?? media.title))
    }
}

/// The cover large, and where to open it.
private struct MediaPeekCard: View {
    var media: MediaTag
    var image: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Artwork(url: image, kind: media.kind, size: 160)
            VStack(alignment: .leading, spacing: 2) {
                Text(media.title).font(.headline).foregroundStyle(Ink.text)
                if let by = media.by { Text(by).font(.callout).foregroundStyle(Ink.muted) }
            }
            HStack(spacing: 8) {
                ForEach(destinations, id: \.title) { destination in
                    Button(destination.title) { openURL(destination.url) }
                        .buttonStyle(.candy(.soft, compact: true))
                }
            }
        }
        .padding(16)
        .frame(width: 220, alignment: .leading)
    }

    private var destinations: [(title: String, url: URL)] { media.destinations }
}

extension MediaTag {
    /// Where to open it: Spotify and Apple Music for music, IMDb for films
    /// and series, a web search for the rest.
    var destinations: [(title: String, url: URL)] {
        let query = [title, by].compactMap { $0 }.joined(separator: " ")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let path = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        switch kind {
        case "song", "album", "artist", "podcast":
            return [("Spotify", URL(string: "https://open.spotify.com/search/\(path)")!),
                    ("Apple Music", URL(string: "https://music.apple.com/br/search?term=\(encoded)")!)]
        case "movie", "show":
            return [("IMDb", URL(string: "https://www.imdb.com/find/?q=\(encoded)")!)]
        default:
            return [(String(localized: "Search"), URL(string: "https://duckduckgo.com/?q=\(encoded)")!)]
        }
    }
}

/// Covers found once per title and kept for the session, so a reply that
/// redraws while streaming does not ask the catalogue again.
@MainActor
final class MediaArtwork {
    static let shared = MediaArtwork()
    private var found: [MediaTag: URL?] = [:]
    private var pending: [MediaTag: Task<URL?, Never>] = [:]

    func image(for media: MediaTag) async -> URL? {
        if let known = found[media] { return known }
        if let task = pending[media] { return await task.value }
        let task = Task { await ArtworkLookup.image(kind: media.kind, title: media.title, subtitle: media.by) }
        pending[media] = task
        let url = await task.value
        found[media] = url
        pending[media] = nil
        return url
    }
}
