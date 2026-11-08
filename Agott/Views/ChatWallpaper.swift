import SwiftUI

/// The chat's paper: manga screentone, not doodles. A wash of halftone dots
/// rises from the bottom like a printed panel, and a corner of pink tone
/// sits up top, the spot colour. Faint enough to read over.
struct ChatWallpaper: View {
    var body: some View {
        ZStack {
            VStack {
                Spacer()
                Screentone(color: Ink.text.opacity(0.06), spacing: 7, from: 0, to: 0.75)
                    .frame(height: 260)
                    .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
            }
            VStack {
                HStack {
                    Spacer()
                    Screentone(color: Ink.spot.opacity(0.10), spacing: 8, from: 0.8, to: 0, axis: .horizontal)
                        .frame(width: 320, height: 200)
                        .mask(RadialGradient(colors: [.black, .clear], center: .topTrailing, startRadius: 20, endRadius: 300))
                }
                Spacer()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
