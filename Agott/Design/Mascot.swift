import SwiftUI

/// Agott's face: the mascot from the app icon.
///
/// It stays the same drawing in every mood; what changes is quiet. While it
/// thinks, a soft ring breathes around it. While it listens, the ring follows
/// your voice. Asleep, it dims a little.
struct MascotFace: View {
    var mood: Mood
    var size: CGFloat = 36
    /// 0…1 microphone level, for listening.
    var level: Float = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var busy: Bool { [.thinking, .working, .talking].contains(mood) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !(busy || mood == .listening) || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breath = busy && !reduceMotion ? (sin(t * 3) + 1) / 2 : 0
            let ring = mood == .listening ? CGFloat(level) : CGFloat(breath)
            Image("MascotHead")
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: size, height: size)
                .background(Circle().fill(Ink.paper))
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Ink.spot.opacity(busy || mood == .listening ? 0.35 + 0.65 * ring : 0),
                                      lineWidth: max(1.5, size * 0.06)))
                .scaleEffect(mood == .listening ? 1 + ring * 0.06 : 1)
                .saturation(mood == .sleepy ? 0.4 : 1)
                .opacity(mood == .sleepy ? 0.7 : 1)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(Text("Agott"))
        .accessibilityValue(Text(mood.accessibilityName))
    }
}
