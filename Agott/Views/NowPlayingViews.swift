import SwiftUI

/// The cover of what is playing; a note when there is no cover to show.
struct NowPlayingArt: View {
    var url: URL?
    var size: CGFloat = 30

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high).scaledToFill()
            } else {
                ZStack {
                    Ink.spot.opacity(0.16)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(Ink.spot)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Listening to: the song, the artist, and how it feels.
struct NowPlayingCard: View {
    var play: Play
    var artwork: URL?
    var mood: TrackMood?

    var body: some View {
        HStack(spacing: 12) {
            NowPlayingArt(url: artwork, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("Listening to").font(.caption.weight(.semibold)).foregroundStyle(Ink.muted)
                Text(play.track).font(.headline).foregroundStyle(Ink.text).lineLimit(1)
                Text(play.artist).font(.callout).foregroundStyle(Ink.muted).lineLimit(1)
                if let mood {
                    Text("Feels \(mood.moodName) · \(play.app)").font(.caption).foregroundStyle(Ink.spot).lineLimit(1)
                } else {
                    Text(play.app).font(.caption).foregroundStyle(Ink.muted)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

#if os(macOS)
/// What is playing, in the toolbar beside the title: the cover, the song and
/// the artist. Click for its mood.
struct NowPlayingCapsule: View {
    @State private var listener = MusicListener.shared
    @State private var showing = false

    var body: some View {
        if let play = listener.nowPlaying {
            Button { showing.toggle() } label: {
                HStack(spacing: 8) {
                    NowPlayingArt(url: listener.artwork, size: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(play.track).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(play.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: 180, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: "waveform").font(.caption).foregroundStyle(Ink.spot)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                }
                .padding(.horizontal, 4)
            }
            .buttonStyle(.plain)
            .help(Text("Listening to \(play.track) · \(play.artist)"))
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                NowPlayingCard(play: play, artwork: listener.artwork, mood: listener.nowMood)
                    .padding(14)
                    .frame(width: 300)
            }
        }
    }
}

/// A quiet line on the chat's first screen: what you are listening to.
struct NowPlayingLine: View {
    @State private var listener = MusicListener.shared

    var body: some View {
        if let play = listener.nowPlaying {
            HStack(spacing: 8) {
                NowPlayingArt(url: listener.artwork, size: 22)
                Text("Listening to \(Text(play.track).foregroundStyle(Ink.text)) · \(play.artist)")
                    .font(.callout)
                    .foregroundStyle(Ink.muted)
                    .lineLimit(1)
            }
            .padding(.leading, 4)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
            .transition(.opacity)
        }
    }
}
#endif
