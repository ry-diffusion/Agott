import SwiftUI

/// Agott's live face, drawn like the mascot: ink on paper.
///
/// Manga does not show feeling with colour; it uses marks. A sweat drop for
/// effort, a question mark for confusion, sparkles for joy, sound lines for
/// listening, hatched lines across the cheeks for a blush. The face is built
/// from those, so each mood reads at a glance, at any size, in either mode.
/// It blinks on its own, follows your voice while listening, and talks while
/// words stream in.
struct MuseFace: View {
    var mood: Mood
    var size: CGFloat = 64
    /// 0…1 microphone level, for listening.
    var level: Float = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            face(t: context.date.timeIntervalSinceReferenceDate)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(Text("Agott"))
        .accessibilityValue(Text(mood.accessibilityName))
    }

    private func face(t: Double) -> some View {
        let look = expression
        let blink = isBlinking(t) && look.eyes == .round
        let talk = mood == .talking ? (0.25 + 0.4 * abs(sin(t * 13)) * abs(cos(t * 5.3))) : 0
        let bob = mood == .listening ? CGFloat(level) * 0.06 : (reduceMotion ? 0 : CGFloat(sin(t * 1.6)) * 0.01)
        let line = max(1.2, size * 0.035)
        let corner = size * 0.34

        return ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Ink.paper)
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Ink.faceInk, lineWidth: line * 1.1)

            // Blush: hatched lines, the way the mascot blushes.
            HStack(spacing: size * 0.4) {
                Hatch(count: 3).stroke(Ink.spot, style: StrokeStyle(lineWidth: max(1, line * 0.7), lineCap: .round))
                Hatch(count: 3).stroke(Ink.spot, style: StrokeStyle(lineWidth: max(1, line * 0.7), lineCap: .round))
            }
            .frame(width: size * 0.74, height: size * 0.09)
            .opacity(look.blush)
            .offset(y: size * 0.1)

            HStack(spacing: size * 0.2) {
                Eye(style: look.eyes, open: blink ? 0.08 : look.eyeOpen * look.leftScale, size: size)
                Eye(style: look.eyes, open: blink ? 0.08 : look.eyeOpen, size: size)
            }
            .offset(x: look.gaze.width * size, y: -size * 0.06 + look.gaze.height * size)

            Mouth(smile: look.smile, open: max(look.mouthOpen, talk))
                .fill(Ink.faceInk)
                .overlay(Mouth(smile: look.smile, open: max(look.mouthOpen, talk))
                    .stroke(Ink.faceInk, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round)))
                .frame(width: size * look.mouthWidth, height: size * 0.2)
                .offset(y: size * 0.2)

            mark(t: t, line: line)
        }
        .scaleEffect(1 + bob)
        .rotationEffect(.degrees(look.tilt + (mood == .thinking ? sin(t * 1.2) * 3 : 0)))
        .animation(Motion.bouncy, value: mood)
    }

    /// The manga emotion mark for this mood.
    @ViewBuilder
    private func mark(t: Double, line: CGFloat) -> some View {
        let corner = CGSize(width: size * 0.44, height: -size * 0.44)
        switch mood {
        case .thinking:
            HStack(spacing: size * 0.04) {
                ForEach(0..<3) { index in
                    Circle().fill(Ink.text)
                        .frame(width: size * 0.065, height: size * 0.065)
                        .opacity(0.3 + 0.7 * max(0, sin(t * 5 - Double(index) * 0.9)))
                }
            }
            .offset(x: size * 0.36, y: -size * 0.5)
        case .working:
            SweatDrop()
                .fill(Ink.surface)
                .overlay(SweatDrop().stroke(Ink.text, lineWidth: line * 0.8))
                .frame(width: size * 0.13, height: size * 0.19)
                .offset(x: corner.width, y: corner.height + CGFloat(sin(t * 3)) * size * 0.02)
        case .confused:
            Text(verbatim: "?")
                .font(Lettering.display(size * 0.3))
                .foregroundStyle(Ink.text)
                .offset(x: corner.width, y: corner.height)
        case .surprised:
            Text(verbatim: "!")
                .font(Lettering.display(size * 0.32))
                .foregroundStyle(Ink.spot)
                .offset(x: corner.width, y: corner.height)
        case .sleepy:
            Text(verbatim: "z")
                .font(Lettering.display(size * 0.22))
                .foregroundStyle(Ink.text)
                .offset(x: corner.width, y: corner.height - CGFloat(sin(t * 2)) * size * 0.04)
        case .happy, .love:
            Image(systemName: mood == .love ? "heart.fill" : "sparkle")
                .font(.system(size: size * 0.2, weight: .black))
                .foregroundStyle(Ink.spot)
                .scaleEffect(1 + 0.12 * CGFloat(sin(t * 4)))
                .offset(x: corner.width, y: corner.height)
        case .listening:
            SoundLines()
                .stroke(Ink.text, style: StrokeStyle(lineWidth: line * 0.9, lineCap: .round))
                .frame(width: size * 0.16, height: size * 0.36)
                .scaleEffect(0.85 + CGFloat(level) * 0.5, anchor: .leading)
                .offset(x: size * 0.6, y: 0)
        case .idle, .talking:
            EmptyView()
        }
    }

    private func isBlinking(_ t: Double) -> Bool {
        guard !reduceMotion else { return false }
        let a = t.truncatingRemainder(dividingBy: 4.3)
        let b = t.truncatingRemainder(dividingBy: 7.1)
        return a < 0.12 || (b > 3.0 && b < 3.1)
    }

    struct Expression {
        var eyes: Eye.Style = .round
        var eyeOpen: CGFloat = 1
        var leftScale: CGFloat = 1
        var gaze: CGSize = .zero
        var smile: CGFloat = 0.5
        var mouthOpen: CGFloat = 0
        var mouthWidth: CGFloat = 0.26
        var blush: Double = 0.7
        var tilt: Double = 0
    }

    private var expression: Expression {
        switch mood {
        case .idle: Expression()
        case .listening: Expression(eyeOpen: 1.15, smile: 0.2, mouthOpen: 0.35, mouthWidth: 0.15, blush: 0.4)
        case .thinking: Expression(eyeOpen: 0.85, gaze: CGSize(width: 0.06, height: -0.06), smile: 0.1, mouthWidth: 0.13, tilt: -4)
        case .working: Expression(eyeOpen: 0.55, gaze: CGSize(width: 0, height: 0.03), smile: 0.2, mouthWidth: 0.15)
        case .talking: Expression(smile: 0.4, mouthWidth: 0.22)
        case .happy: Expression(eyes: .happy, smile: 1, mouthOpen: 0.45, mouthWidth: 0.32, blush: 1)
        case .confused: Expression(leftScale: 0.65, gaze: CGSize(width: -0.03, height: 0), smile: -0.35, mouthWidth: 0.2, blush: 0.2, tilt: 8)
        case .sleepy: Expression(eyes: .closed, smile: 0.15, mouthWidth: 0.12, blush: 0.3, tilt: 6)
        case .love: Expression(eyes: .heart, smile: 0.9, mouthOpen: 0.2, mouthWidth: 0.26, blush: 1)
        case .surprised: Expression(eyeOpen: 1.3, smile: 0, mouthOpen: 0.8, mouthWidth: 0.12, blush: 0.5)
        }
    }
}

struct Eye: View {
    enum Style { case round, happy, closed, heart }

    var style: Style
    var open: CGFloat
    var size: CGFloat

    var body: some View {
        let width = size * 0.11
        let height = size * 0.16
        Group {
            switch style {
            case .round:
                ZStack(alignment: .topTrailing) {
                    Capsule().fill(Ink.faceInk)
                    Circle().fill(Ink.paper)
                        .frame(width: width * 0.4, height: width * 0.4)
                        .offset(x: -width * 0.12, y: height * 0.12)
                        .opacity(open > 0.4 ? 1 : 0)
                }
                .frame(width: width, height: max(width * 0.3, height * open))
            case .happy:
                HappyArc()
                    .stroke(Ink.faceInk, style: StrokeStyle(lineWidth: max(1.5, size * 0.04), lineCap: .round))
                    .frame(width: width * 1.6, height: height * 0.5)
            case .closed:
                Capsule().fill(Ink.faceInk).frame(width: width * 1.6, height: max(1.5, size * 0.035))
            case .heart:
                Image(systemName: "heart.fill")
                    .font(.system(size: size * 0.17))
                    .foregroundStyle(Ink.spot)
            }
        }
        .frame(width: width * 1.8, height: height * 1.3)
    }
}

struct HappyArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.6))
        return path
    }
}

/// Diagonal blush strokes.
struct Hatch: Shape {
    var count: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step = rect.width / CGFloat(count)
        for index in 0..<count {
            let x = rect.minX + step * (CGFloat(index) + 0.5)
            path.move(to: CGPoint(x: x - step * 0.25, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + step * 0.25, y: rect.minY))
        }
        return path
    }
}

struct SweatDrop: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.width / 2), control: CGPoint(x: rect.maxX, y: rect.midY))
        path.addArc(center: CGPoint(x: rect.midX, y: rect.maxY - rect.width / 2), radius: rect.width / 2,
                    startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.midY))
        return path
    }
}

/// Curved lines beside the face: the sound of being heard.
struct SoundLines: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0..<3 {
            let inset = CGFloat(index) * rect.width * 0.45
            let r = CGRect(x: rect.minX + inset - rect.width, y: rect.minY + rect.height * (0.25 - CGFloat(index) * 0.12),
                           width: rect.width * 1.6, height: rect.height * (0.5 + CGFloat(index) * 0.24))
            path.addArc(center: CGPoint(x: r.minX, y: r.midY), radius: r.width / 2 + inset,
                        startAngle: .degrees(-30), endAngle: .degrees(30), clockwise: false)
        }
        return path
    }
}

/// A mouth that can smile, frown and open, and animate between all three.
struct Mouth: Shape {
    var smile: CGFloat
    var open: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(smile, open) }
        set { smile = newValue.first; open = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let mid = rect.midY - rect.height * 0.15
        let cornerY = mid - smile * rect.height * 0.22
        let lower = mid + smile * rect.height * 0.45 + open * rect.height * 0.75
        let upper = mid + smile * rect.height * 0.12 - open * rect.height * 0.15
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: cornerY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: cornerY), control: CGPoint(x: rect.midX, y: lower))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: cornerY), control: CGPoint(x: rect.midX, y: upper))
        path.closeSubpath()
        return path
    }
}

extension Mood {
    var accessibilityName: String {
        switch self {
        case .idle: String(localized: "Calm")
        case .listening: String(localized: "Listening")
        case .thinking: String(localized: "Thinking")
        case .working: String(localized: "Working")
        case .talking: String(localized: "Talking")
        case .happy: String(localized: "Happy")
        case .confused: String(localized: "Confused")
        case .sleepy: String(localized: "Sleepy")
        case .love: String(localized: "Delighted")
        case .surprised: String(localized: "Surprised")
        }
    }
}

#Preview("Moods") {
    FlowLayout(spacing: 20) {
        ForEach(Mood.allCases, id: \.self) { mood in
            VStack {
                MuseFace(mood: mood, size: 72)
                Text(mood.accessibilityName).font(.caption)
            }
        }
    }
    .padding(30)
    .frame(width: 520)
}
