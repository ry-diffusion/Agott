import CoreText
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Agott's visual world: Liquid Glass with a manga heart.
///
/// The structure is the system's: controls and navigation float on Liquid
/// Glass above plain content, so Agott sits naturally beside every other app
/// on macOS 26 and later. The personality is the mascot's: speech balloons,
/// screentone dots instead of grey fills, lettered titles, an ink face, and
/// exactly one spot colour, a riso pink, the way a manga cover gets a second
/// ink. Content has no borders; it is separated by tone and space, and the
/// glass layer carries the depth.
enum Ink {
    // MARK: Colour

    /// The page. Newsprint grey-white, not cream.
    static let canvas = dynamic(dark: (0.071, 0.068, 0.082), light: (0.953, 0.949, 0.937))
    /// Inside a panel.
    static let surface = dynamic(dark: (0.112, 0.107, 0.126), light: (1.0, 1.0, 1.0))
    /// A field or well inside a panel.
    static let raised = dynamic(dark: (0.150, 0.144, 0.168), light: (0.965, 0.961, 0.950))
    /// Linework and text.
    static let text = dynamic(dark: (0.930, 0.918, 0.900), light: (0.078, 0.070, 0.098))
    static let muted = dynamic(dark: (0.690, 0.672, 0.710), light: (0.380, 0.360, 0.410))
    static let hairline = dynamic(dark: (0.240, 0.232, 0.262), light: (0.860, 0.852, 0.838))
    /// The spot colour.
    static let spot = dynamic(dark: (1.0, 0.43, 0.71), light: (1.0, 0.29, 0.62))
    /// Text that sits on the spot colour.
    static let onSpot = Color(.sRGB, red: 0.078, green: 0.070, blue: 0.098)
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

    /// Display lettering: titles, names, balloon shouts. Scales with Dynamic Type.
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom(family, size: size, relativeTo: style)
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

struct Panel: ViewModifier {
    var padding: CGFloat
    var toned: Bool

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).fill(Ink.surface)
                    if toned {
                        // A corner of pink tone, like a spot-colour panel.
                        Screentone(color: Ink.spot.opacity(0.55), spacing: 6, from: 0.9, to: 0, axis: .horizontal)
                            .frame(width: 120, height: 46)
                            .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                            .clipShape(UnevenRoundedRectangle(topTrailingRadius: Radius.surface, style: .continuous))
                    }
                }
            }
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
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

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let tailSize: CGFloat = 10
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

/// Buttons are Liquid Glass: the primary one tinted with the spot colour,
/// the rest clear glass. Both are interactive, so they respond to the press
/// the way system controls do.
struct CandyButtonStyle: ButtonStyle {
    enum Kind { case primary, soft, plain }
    var kind: Kind = .primary
    var tint: Color = Ink.spot
    var compact = false

    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(compact ? .callout.weight(.semibold) : .body.weight(.bold))
            .padding(.horizontal, compact ? 12 : 18)
            .padding(.vertical, compact ? 6 : 10)
            .foregroundStyle(kind == .primary ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.text))
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.3), value: configuration.isPressed)
        switch kind {
        case .primary: label.glassEffect(.regular.tint(tint).interactive(), in: .capsule)
        case .soft: label.glassEffect(.regular.interactive(), in: .capsule)
        case .plain: label.glassEffect(.clear.interactive(), in: .capsule)
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
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.text))
                .frame(width: size, height: size)
                .contentShape(Circle())
                .opacity(enabled ? 1 : 0.4)
                .glassEffect(filled ? .regular.tint(Ink.spot).interactive() : .regular.interactive(), in: .circle)
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

    var body: some View {
        Label {
            Text(title).font(Lettering.display(15, relativeTo: .headline))
        } icon: {
            Image(systemName: symbol).font(.callout.weight(.bold))
        }
        .foregroundStyle(Ink.text)
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
        .padding(.horizontal, 14).padding(.vertical, 9)
        .glassEffect(.regular.interactive(), in: .capsule)
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
