import CoreText
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Agott's visual world: a quiet notebook.
///
/// Neutral greys, near-white type, a serif for page headlines and the
/// system face for everything else. Surfaces are a step lighter than the
/// page with a hairline around them; nothing floats, nothing glows. One
/// colour, the system purple, is kept for what is selected or live.
enum Ink {
    // MARK: Colour

    /// The page.
    static let canvas = dynamic(dark: (0.149, 0.149, 0.149), light: (0.988, 0.988, 0.984))
    /// The sidebar: a shade darker than the page.
    static let sidebar = dynamic(dark: (0.118, 0.118, 0.118), light: (0.953, 0.953, 0.945))
    /// Inside a panel or card.
    static let surface = dynamic(dark: (0.180, 0.180, 0.180), light: (1.0, 1.0, 1.0))
    /// A field, a chip, a hovered row.
    static let raised = dynamic(dark: (0.212, 0.212, 0.212), light: (0.945, 0.945, 0.937))
    /// Your messages: a soft grey pill.
    static let bubble = dynamic(dark: (0.235, 0.235, 0.235), light: (0.929, 0.929, 0.922))
    /// Text.
    static let text = dynamic(dark: (0.925, 0.925, 0.910), light: (0.110, 0.110, 0.106))
    static let muted = dynamic(dark: (0.600, 0.600, 0.588), light: (0.455, 0.455, 0.443))
    static let hairline = dynamic(dark: (0.262, 0.262, 0.262), light: (0.878, 0.878, 0.867))
    /// The one colour: the system's purple, for what is selected or live.
    /// It is the purple Liquid Glass is tinted with across macOS, and it
    /// adjusts itself between light and dark.
    #if os(macOS)
    static let spot = Color(nsColor: .systemPurple)
    #else
    static let spot = Color(uiColor: .systemPurple)
    #endif
    /// Text that sits on the spot colour.
    static let onSpot = Color.white
    /// Paper that stays paper in dark mode, under the black-ink mascot.
    static let paper = Color(.sRGB, red: 0.985, green: 0.982, blue: 0.972)
    /// Ink that stays ink in dark mode, on paper.
    static let faceInk = Color(.sRGB, red: 0.078, green: 0.070, blue: 0.098)

    // Names the rest of the app grew up with. In this world every role but
    // the spot is ink; distinction comes from tone and line, not hue.
    static let accent = spot
    static let pink = spot
    static let violet = text
    static let sky = text
    static let mint = text
    static let peach = text
    static let butter = text
    static let shadow = text
    static let candy = spot
    static let intelligence: [Color] = [spot]

    static func intelligenceRing(angle: Double) -> Color { spot }

    static func dynamic(dark: (Double, Double, Double), light: (Double, Double, Double)) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #endif
    }

    // MARK: Line

    static let line: CGFloat = 1.5
    static let heavyLine: CGFloat = 2.25
}

/// The strip across the top of the window: as tall as the line the window
/// buttons sit on, so every top bar lines up with them.
enum WindowBar {
    static let height: CGFloat = 40
    /// How far the window buttons sit from the window's left edge.
    static let buttonsInset: CGFloat = 16
    /// Where things may start after the window buttons, with room to breathe.
    static let afterButtons: CGFloat = 92
}

enum Radius {
    static let surface: CGFloat = 14
    static let control: CGFloat = 10
}

enum Motion {
    static let settle = Animation.spring(duration: 0.38, bounce: 0)
    static let arrive = Animation.spring(duration: 0.28, bounce: 0)
    static let bouncy = Animation.spring(duration: 0.45, bounce: 0.3)
}

// MARK: - Lettering

enum Lettering {
    static let family = "MochiyPopOne-Regular"

    /// Registers the bundled face once, before any view asks for it.
    static func register() {
        guard let url = Bundle.main.url(forResource: family, withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    /// Display type. Page headlines (20 pt and up) are set in the system
    /// serif, like a notebook's title; anything smaller is the system face,
    /// semibold, so labels and names stay plain.
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        size >= 20 ? .system(size: size, weight: .regular, design: .serif) : .system(size: size, weight: .semibold)
    }
}

// MARK: - Screentone

/// Halftone dots, the way manga gets its greys. Dots grow along `axis`, so a
/// tone can fade in like a printed gradient.
struct Screentone: View {
    var color: Color = Ink.text
    var spacing: CGFloat = 5
    var from: CGFloat = 0.35
    var to: CGFloat = 0.35
    var axis: Axis = .vertical

    var body: some View {
        Canvas { context, size in
            let maxRadius = spacing * 0.42
            var y: CGFloat = 0
            var row = 0
            while y < size.height + spacing {
                var x: CGFloat = row.isMultiple(of: 2) ? 0 : spacing / 2
                while x < size.width + spacing {
                    let t = axis == .vertical ? y / max(size.height, 1) : x / max(size.width, 1)
                    let r = maxRadius * (from + (to - from) * t)
                    if r > 0.15 {
                        context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(color))
                    }
                    x += spacing
                }
                y += spacing * 0.866
                row += 1
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Panels

extension View {
    /// A content surface: a quiet fill, no border. Glass is reserved for the
    /// floating layer, so content stays plain and readable.
    func surface(padding: CGFloat = 16, tint: Color? = nil) -> some View {
        modifier(Panel(padding: padding, toned: tint != nil && tint != Ink.text))
    }

    func panel(padding: CGFloat = 16, toned: Bool = false) -> some View {
        modifier(Panel(padding: padding, toned: toned))
    }
}

extension EnvironmentValues {
    /// Inside a conversation, panels and titles take the message style:
    /// bubble colour, bubble corners, system type, no ornaments.
    @Entry var inChat = false
    /// How chat panels are drawn: on the bubble's paper, in glass (Moon), or
    /// with straight corners (Page).
    @Entry var chatPanelStyle: ChatPanelStyle = .bubble
}

enum ChatPanelStyle { case bubble, glass, square }

struct Panel: ViewModifier {
    var padding: CGFloat
    var toned: Bool
    @Environment(\.inChat) private var inChat
    @Environment(\.chatPanelStyle) private var panelStyle

    func body(content: Content) -> some View {
        if inChat && panelStyle == .glass {
            framed(content)
        } else if inChat && panelStyle == .square {
            content
                .padding(padding)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Ink.text.opacity(0.06)))
        } else if inChat {
            // In the chat a card sits on the balloon's paper, lifted softly.
            content
                .padding(padding)
                .background(
                    RoundedRectangle(cornerRadius: MessageBubble<EmptyView>.bigRadius, style: .continuous)
                        .fill(Ink.bubble)
                        .shadow(color: .black.opacity(0.14), radius: 6, y: 2))
        } else {
            framed(content)
        }
    }

    private func framed(_ content: Content) -> some View {
        content
            .padding(padding)
            .quietSurface(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
    }
}

extension View {
    /// A card the quiet way: a step lighter than what is under it, with a
    /// hairline around it. What glass used to do, without the glow.
    /// A surface that blurs what scrolls behind it, for the one thing that
    /// floats over content (the question box), instead of blurring a whole
    /// strip of the window.
    func frostedSurface<S: InsettableShape>(_ shape: S) -> some View {
        background(shape.fill(.regularMaterial))
            .background(shape.fill(Ink.surface.opacity(0.55)))
            .overlay(shape.strokeBorder(Ink.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }

    func quietSurface<S: InsettableShape>(_ shape: S, fill: Color = Ink.surface, line: Bool = true) -> some View {
        background(shape.fill(fill))
            .overlay(shape.strokeBorder(Ink.hairline.opacity(line ? 1 : 0), lineWidth: 1))
    }
}

/// The page itself.
struct CandyBackground: View {
    var body: some View {
        Ink.canvas.ignoresSafeArea()
    }
}

// MARK: - Speech balloons

/// A speech balloon with a tail. Agott's tail points back at the mascot;
/// yours points at the edge of the page you speak from.
struct Balloon: InsettableShape {
    enum Tail { case leading, trailing, bottom, none }
    var tail: Tail
    var radius: CGFloat = 18
    var inset: CGFloat = 0
    static let tailSize: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let tailSize = Self.tailSize
        var body = r
        switch tail {
        case .leading: body = r.divided(atDistance: tailSize, from: .minXEdge).remainder
        case .trailing: body = r.divided(atDistance: tailSize, from: .maxXEdge).remainder
        case .bottom: body = r.divided(atDistance: tailSize, from: .maxYEdge).remainder
        case .none: break
        }
        let corner = min(radius, body.height / 2)
        var path = Path(roundedRect: body, cornerRadius: corner, style: .continuous)
        var tailPath = Path()
        switch tail {
        case .leading:
            let y = body.minY + min(22, body.height / 2)
            tailPath.move(to: CGPoint(x: body.minX + 1, y: y - 7))
            tailPath.addQuadCurve(to: CGPoint(x: r.minX, y: y - 9), control: CGPoint(x: body.minX - 3, y: y - 4))
            tailPath.addQuadCurve(to: CGPoint(x: body.minX + 1, y: y + 5), control: CGPoint(x: body.minX - 2, y: y + 2))
        case .trailing:
            let y = body.maxY - min(18, body.height / 2)
            tailPath.move(to: CGPoint(x: body.maxX - 1, y: y - 5))
            tailPath.addQuadCurve(to: CGPoint(x: r.maxX, y: y + 9), control: CGPoint(x: body.maxX + 2, y: y + 1))
            tailPath.addQuadCurve(to: CGPoint(x: body.maxX - 1, y: y + 7), control: CGPoint(x: body.maxX + 1, y: y + 7))
        case .bottom:
            let x = body.midX - 6
            tailPath.move(to: CGPoint(x: x - 6, y: body.maxY - 1))
            tailPath.addQuadCurve(to: CGPoint(x: x - 2, y: r.maxY), control: CGPoint(x: x - 2, y: body.maxY + 4))
            tailPath.addQuadCurve(to: CGPoint(x: x + 8, y: body.maxY - 1), control: CGPoint(x: x + 2, y: body.maxY + 3))
        case .none:
            break
        }
        path.addPath(tailPath)
        return path
    }

    func inset(by amount: CGFloat) -> Balloon {
        var copy = self
        copy.inset += amount
        return copy
    }
}

extension View {
    func balloon(_ tail: Balloon.Tail, fill: Color = Ink.surface, padding: EdgeInsets = EdgeInsets(top: 11, leading: 15, bottom: 11, trailing: 15)) -> some View {
        let extra: EdgeInsets = switch tail {
        case .leading: EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 0)
        case .trailing: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 10)
        case .bottom: EdgeInsets(top: 0, leading: 0, bottom: 10, trailing: 0)
        case .none: EdgeInsets()
        }
        return self
            .padding(padding)
            .padding(extra)
            .background(Balloon(tail: tail).fill(fill))
    }
}

// MARK: - Buttons

/// Buttons are capsules: the primary one solid (light on dark, dark on
/// light), the soft one an outline, the plain one just its label.
struct CandyButtonStyle: ButtonStyle {
    enum Kind { case primary, soft, plain }
    var kind: Kind = .primary
    var tint: Color = Ink.spot
    var compact = false

    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(compact ? .callout.weight(.medium) : .body.weight(.medium))
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 5 : 8)
            .foregroundStyle(kind == .primary ? AnyShapeStyle(Ink.canvas) : AnyShapeStyle(Ink.text))
            .contentShape(Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
        switch kind {
        case .primary: label.background(Capsule().fill(Ink.text))
        case .soft: label.quietSurface(Capsule(), fill: configuration.isPressed ? Ink.raised : .clear)
        case .plain: label
        }
    }
}

extension ButtonStyle where Self == CandyButtonStyle {
    static var candy: CandyButtonStyle { CandyButtonStyle() }
    static var candySoft: CandyButtonStyle { CandyButtonStyle(kind: .soft) }
    static func candy(_ kind: CandyButtonStyle.Kind, tint: Color = Ink.spot, compact: Bool = false) -> CandyButtonStyle {
        CandyButtonStyle(kind: kind, tint: tint, compact: compact)
    }
}

/// A round inked button.
struct CandyIconButton: View {
    var symbol: String
    var tint: Color = Ink.text
    var filled = false
    var size: CGFloat = 34
    var action: () -> Void

    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(filled ? AnyShapeStyle(Ink.canvas) : AnyShapeStyle(Ink.text))
                .frame(width: size, height: size)
                .contentShape(Circle())
                .opacity(enabled ? 1 : 0.4)
                .quietSurface(Circle(), fill: filled ? Ink.text : Ink.surface, line: !filled)
        }
        .buttonStyle(PressScale())
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(duration: 0.22, bounce: 0.4), value: configuration.isPressed)
    }
}

// MARK: - Small parts

struct Chip: View {
    var text: String
    var symbol: String?
    var tint: Color = Ink.text
    var spot = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.caption2.weight(.bold)) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(spot ? Ink.onSpot : Ink.text)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(spot ? Ink.spot : Ink.raised))
    }
}

/// The mascot's head on its own paper, so the ink reads in dark mode too.
struct MascotAvatar: View {
    var size: CGFloat = 36
    var ring = true

    var body: some View {
        Image("MascotHead")
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size, height: size)
            .background(Circle().fill(Ink.paper))
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Ink.spot, lineWidth: ring ? 2 : 0))
            .accessibilityHidden(true)
    }
}

/// A screen's title, lettered.
struct ScreenHeader<Trailing: View>: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var symbol: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Lettering.display(30, relativeTo: .largeTitle))
                    .foregroundStyle(Ink.text)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(Ink.muted)
                }
            }
            Spacer()
            trailing
        }
        .accessibilityElement(children: .contain)
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, symbol: String) {
        self.init(title: title, subtitle: subtitle, symbol: symbol) { EmptyView() }
    }
}

/// A heading inside a panel: lettered, with a drawn symbol.
struct PanelTitle: View {
    var title: LocalizedStringKey
    var symbol: String
    @Environment(\.inChat) private var inChat

    var body: some View {
        Label {
            Text(title).font(.headline).foregroundStyle(Ink.text)
        } icon: {
            Image(systemName: symbol).font(.callout).foregroundStyle(Ink.muted)
        }
    }
}

/// A text field drawn as an inked capsule.
struct CandyField: View {
    var placeholder: LocalizedStringKey
    @Binding var text: String
    var symbol: String?
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            if let symbol { Image(systemName: symbol).font(.callout.weight(.bold)).foregroundStyle(Ink.muted) }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(Ink.text)
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .quietSurface(RoundedRectangle(cornerRadius: 10, style: .continuous), fill: Ink.raised)
    }
}

/// Lays children left to right, wrapping like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var row: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                y += row + spacing
                x = 0
                row = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            row = max(row, size.height)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += row + spacing
                x = bounds.minX
                row = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

// MARK: - Hover

/// Small icon and text controls: muted at rest, a soft highlight and a
/// pointing hand under the pointer, darker while pressed.
struct HoverIconStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration, size: size)
    }

    private struct HoverLabel: View {
        let configuration: Configuration
        var size: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .foregroundStyle(hovering && enabled ? Ink.text : Ink.muted)
                .frame(minWidth: size, minHeight: size)
                .padding(.horizontal, 2)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Ink.text.opacity(configuration.isPressed ? 0.14 : hovering && enabled ? 0.08 : 0)))
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovering = $0 }
                #if os(macOS)
                .pointerStyle(.link)
                #endif
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

extension ButtonStyle where Self == HoverIconStyle {
    static var hoverIcon: HoverIconStyle { HoverIconStyle() }
}

/// A soft background under the pointer, for rows and cards you can click.
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = 10
    var inset: CGFloat = -6
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Ink.text.opacity(hovering ? 0.06 : 0))
                    .padding(inset))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = 10, inset: CGFloat = -6) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, inset: inset))
    }
}

// MARK: - Tips

/// A label that appears under the pointer, quickly: what a button does.
/// The system tooltip waits about a second and is easy to miss; this one
/// shows after 0.4 s in glass beside the control, and still sets `.help`
/// for VoiceOver.
struct Tip: ViewModifier {
    var text: Text
    var edge: Edge = .bottom
    @State private var hovering = false
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            // Read out by VoiceOver; no system tooltip on top of this one.
            .accessibilityHint(text)
            .onHover { inside in
                hovering = inside
                if inside {
                    Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        if hovering { withAnimation(.easeOut(duration: 0.15)) { shown = true } }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.1)) { shown = false }
                }
            }
            .overlay(alignment: alignment) {
                // A zero-thickness line on the chosen edge, with the tip
                // hung off its far side: the tip always sits beside the
                // control, never on top of it. (Alignment guides inside an
                // optional overlay were ignored, so tips covered buttons.)
                if shown {
                    Group {
                    switch edge {
                    case .top:
                        Color.clear.frame(height: 0)
                            .overlay(alignment: .bottom) { bubble.padding(.bottom, 10) }
                    case .trailing:
                        Color.clear.frame(width: 0)
                            .overlay(alignment: .leading) { bubble.padding(.leading, 10) }
                    default:
                        Color.clear.frame(height: 0)
                            .overlay(alignment: .top) { bubble.padding(.top, 10) }
                    }
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }
            .zIndex(shown ? 10 : 0)
    }

    /// A small quiet label: the sidebar's tone, a hairline, plain text.
    private var bubble: some View {
        text
            .font(.caption)
            .foregroundStyle(Ink.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .quietSurface(RoundedRectangle(cornerRadius: 6, style: .continuous), fill: Ink.sidebar)
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            .fixedSize()
    }

    private var alignment: Alignment {
        switch edge {
        case .trailing: .trailing
        case .top: .top
        default: .bottom
        }
    }
}

extension View {
    func tip(_ key: LocalizedStringKey, edge: Edge = .bottom) -> some View {
        modifier(Tip(text: Text(key), edge: edge))
    }

    func tip(_ text: Text, edge: Edge = .bottom) -> some View {
        modifier(Tip(text: text, edge: edge))
    }
}
