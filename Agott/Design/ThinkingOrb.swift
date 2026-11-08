import SwiftUI

/// A small dotted orb that shows what Agott is doing while it works: a globe
/// with a scan line while it searches, particles on orbits while it thinks,
/// a rolling wave while it listens, a constellation wiring itself while it
/// connects people, a slowly breathing ring while it waits.
///
/// Monochrome dots drawn on a Canvas; depth is told by dot size and ink, the
/// way a dotted globe reads in print. The idea of "one orb per verb" comes
/// from thinking-orbs by Jakub Antalik (MIT licence,
/// github.com/Jakubantalik/thinking-orbs); this is an independent SwiftUI
/// drawing of it.
struct ThinkingOrb: View {
    enum Mode: CaseIterable { case orbits, globe, wave, web, ring }

    var mode: Mode
    var size: CGFloat = 18
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active || reduceMotion)) { context in
            let t = (active && !reduceMotion) ? context.date.timeIntervalSinceReferenceDate : 0
            Canvas { canvas, area in
                Self.draw(mode, at: t, in: &canvas, area: area, ink: Ink.text)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: Drawing

    /// A point on the unit sphere after the scene's rotation, x right, y down, z toward you.
    private struct Point { var x: Double; var y: Double; var z: Double }

    private static func draw(_ mode: Mode, at t: Double, in canvas: inout GraphicsContext, area: CGSize, ink: Color) {
        let radius = Double(min(area.width, area.height)) * 0.42
        let center = CGPoint(x: area.width / 2, y: area.height / 2)
        // Dots scale with the orb, so the inline and avatar sizes both read.
        let dot = max(0.55, radius * 0.075)

        func plot(_ p: Point, weight: Double = 1) {
            let depth = (p.z + 1) / 2 // 0 far … 1 near
            let r = dot * (0.55 + 0.75 * depth) * weight
            let alpha = (0.22 + 0.78 * depth) * min(1, weight)
            let rect = CGRect(x: center.x + p.x * radius - r, y: center.y + p.y * radius - r, width: r * 2, height: r * 2)
            canvas.fill(Path(ellipseIn: rect), with: .color(ink.opacity(alpha)))
        }

        func rotate(_ x: Double, _ y: Double, _ z: Double, yaw: Double, tilt: Double) -> Point {
            let x1 = x * cos(yaw) + z * sin(yaw)
            let z1 = -x * sin(yaw) + z * cos(yaw)
            let y2 = y * cos(tilt) - z1 * sin(tilt)
            let z2 = y * sin(tilt) + z1 * cos(tilt)
            return Point(x: x1, y: y2, z: z2)
        }

        switch mode {
        case .globe:
            // Latitude rings of dots turning slowly; a meridian sweeps across
            // and lights the dots it passes.
            let yaw = t * 0.9
            let scan = (t * 2.4).truncatingRemainder(dividingBy: 2 * .pi)
            for ring in 1...5 {
                let lat = Double(ring) / 6 * .pi - .pi / 2
                let count = max(4, Int((11 * cos(lat)).rounded()))
                for index in 0..<count {
                    let lon = Double(index) / Double(count) * 2 * .pi
                    let p = rotate(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon), yaw: yaw, tilt: 0.38)
                    let offset = abs(remainder(lon + yaw - scan, 2 * .pi))
                    plot(p, weight: offset < 0.45 ? 1.5 : 0.85)
                }
            }

        case .orbits:
            // Three particles on tilted orbits, each orbit a faint trail of dots.
            for orbit in 0..<3 {
                let tilt = 0.5 + Double(orbit) * 0.75
                let yaw = Double(orbit) * 2.1 + t * 0.25
                for index in 0..<12 {
                    let a = Double(index) / 12 * 2 * .pi
                    plot(rotate(cos(a), 0, sin(a), yaw: yaw, tilt: tilt), weight: 0.45)
                }
                let a = t * (1.9 + Double(orbit) * 0.45) + Double(orbit) * 2
                plot(rotate(cos(a), 0, sin(a), yaw: yaw, tilt: tilt), weight: 1.7)
            }

        case .wave:
            // Rings stacked like a globe whose radius rolls with a wave, the
            // way a voice moves a level meter.
            for ring in 0..<5 {
                // Rings between the poles only: at the poles they would pile up.
                let v = (Double(ring) / 4 * 2 - 1) * 0.78
                let swell = 0.72 + 0.28 * sin(t * 4.2 - Double(ring) * 1.1)
                let width = sqrt(max(0, 1 - v * v)) * swell
                for index in 0..<12 {
                    let a = Double(index) / 12 * 2 * .pi + t * 0.6
                    plot(rotate(cos(a) * width, v, sin(a) * width, yaw: 0, tilt: 0.35))
                }
            }

        case .web:
            // Nodes spread over the sphere, joined when close: a constellation
            // that turns and wires itself.
            let count = 11
            var nodes: [Point] = []
            for index in 0..<count {
                // Fibonacci sphere: even spread without randomness.
                let y = 1 - (Double(index) + 0.5) / Double(count) * 2
                let r = sqrt(1 - y * y)
                let a = Double(index) * 2.399963
                nodes.append(rotate(cos(a) * r, y, sin(a) * r, yaw: t * 0.7, tilt: 0.4))
            }
            let pulse = (sin(t * 2.2) + 1) / 2
            for i in 0..<count {
                for j in (i + 1)..<count {
                    let a = nodes[i], b = nodes[j]
                    let distance = sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2) + pow(a.z - b.z, 2))
                    guard distance < 0.95 else { continue }
                    var line = Path()
                    line.move(to: CGPoint(x: center.x + a.x * radius, y: center.y + a.y * radius))
                    line.addLine(to: CGPoint(x: center.x + b.x * radius, y: center.y + b.y * radius))
                    let depth = ((a.z + b.z) / 2 + 1) / 2
                    canvas.stroke(line, with: .color(ink.opacity((0.08 + 0.3 * depth) * (0.6 + 0.4 * pulse))),
                                  lineWidth: max(0.4, dot * 0.45))
                }
            }
            for node in nodes { plot(node, weight: 1.15) }

        case .ring:
            // One ring facing you, breathing and slowly changing shape.
            let count = 16
            for index in 0..<count {
                let a = Double(index) / Double(count) * 2 * .pi
                let breath = 0.82 + 0.1 * sin(t * 1.6) + 0.06 * sin(a * 3 + t * 1.1)
                let p = Point(x: cos(a + t * 0.3) * breath, y: sin(a + t * 0.3) * breath,
                              z: 0.4 + 0.6 * sin(a * 2 + t))
                plot(p)
            }
        }
    }
}

extension ThinkingOrb.Mode {
    /// The orb for a step, from what kind of work it is.
    init(step: Step?) {
        guard let step else { self = .ring; return }
        if step.kind == .thinking { self = .orbits; return }
        switch step.symbol {
        case "magnifyingglass", "brain.head.profile", "safari", "film", "map", "mappin.and.ellipse": self = .globe
        case "person.2", "person.3", "heart.text.square", "circle.grid.2x2", "theatermasks": self = .web
        default: self = .orbits
        }
    }
}
