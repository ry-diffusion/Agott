import SwiftUI

/// The design lab: three directions for a calm, zen conversation with Agott,
/// live, side by side in time. Tap a tab to see one; switch day and night.
///
/// Each direction keeps Agott's identity (the mascot, Mochiy Pop One, the
/// pink spot colour, screentone) and drops everything but the conversation.
struct DesignLab: View {
    enum Direction: String, CaseIterable, Identifiable {
        case page, moon, balloon
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .page: "Page"
            case .moon: "Moon"
            case .balloon: "Balloon"
            }
        }

        var symbol: String {
            switch self {
            case .page: "book.pages"
            case .moon: "moon.stars"
            case .balloon: "bubble.left.and.bubble.right"
            }
        }

        var note: LocalizedStringKey {
            switch self {
            case .page: "Working demo, squared: paper and straight corners. Try Zen at the top right; Esc leaves it."
            case .moon: "Working proof of concept in Liquid Glass: a drifting sky, the mascot in a glass bubble, answers on glass."
            case .balloon: "Telegram's balloons in a narrow centred column, a soft pink glow behind."
            }
        }
    }

    enum Light: String, CaseIterable, Identifiable {
        case auto, day, night
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .auto: "Auto"
            case .day: "Day"
            case .night: "Night"
            }
        }
    }

    @State private var direction: Direction = LaunchOptions.value("-AgottLabTab").flatMap(Direction.init(rawValue:)) ?? .page
    @State private var light: Light = LaunchOptions.value("-AgottLabLight").flatMap(Light.init(rawValue:)) ?? .auto

    /// Night from 19h to 6h when automatic.
    private var isNight: Bool {
        switch light {
        case .day: return false
        case .night: return true
        case .auto:
            let hour = Calendar.current.component(.hour, from: .now)
            return hour >= 19 || hour < 6
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                switch direction {
                case .page: PageChat(night: isNight)
                case .moon: MoonChat(night: isNight)
                case .balloon: ZenBalloon(night: isNight)
                }
            }
            .id("\(direction.rawValue)-\(isNight)")
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            controls
        }
        .animation(.easeInOut(duration: 0.35), value: direction)
        .animation(.easeInOut(duration: 0.35), value: isNight)
        .background(Ink.canvas)
        // Day and night for the whole lab, so every colour resolves for it.
        .preferredColorScheme(isNight ? .dark : .light)
        #if os(macOS)
        // The same integrated top as the app: window buttons inside the
        // panels, empty space moves the window, double-click zooms.
        .background { WindowChromeArea() }
        .ignoresSafeArea(.container, edges: .top)
        #endif
        .background {
            // ⌘1 ⌘2 ⌘3 switch directions.
            ForEach(Array(Direction.allCases.enumerated()), id: \.offset) { index, item in
                Button("") { direction = item }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .hidden()
            }
        }
    }

    /// One small glass capsule beside the window buttons: which direction,
    /// and day or night. Nothing else on screen belongs to the lab.
    private var controls: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(Array(Direction.allCases.enumerated()), id: \.offset) { index, item in
                    Button {
                        direction = item
                    } label: {
                        Label(item.title, systemImage: item.symbol)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: direction.symbol)
                    Text(direction.title).font(Lettering.display(12, relativeTo: .caption))
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text(direction.note))

            Divider().frame(height: 14)

            Menu {
                ForEach(Light.allCases) { item in
                    Button { light = item } label: { Text(item.title) }
                }
            } label: {
                Image(systemName: light == .auto ? "circle.lefthalf.filled" : (isNight ? "moon.fill" : "sun.max.fill"))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("Day and night"))
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.top, 14)
    }
}

// MARK: - Sample

/// A late conversation, made up, used by every direction.
private enum ZenSample {
    struct Line: Identifiable {
        let id = UUID()
        var mine: Bool
        var text: String
    }

    static let lines: [Line] = [
        Line(mine: true, text: String(localized: "zen.sample.1", defaultValue: "I'm a bit down today")),
        Line(mine: false, text: String(localized: "zen.sample.2", defaultValue: "I figured. You were quiet in the group and didn't answer Ana. Want to talk about what weighed on you?")),
        Line(mine: true, text: String(localized: "zen.sample.3", defaultValue: "I think it's college, I feel behind on everything")),
        Line(mine: false, text: String(localized: "zen.sample.4", defaultValue: "That makes sense, it was a heavy week: three deliveries and Friday's call.\n\nBut look: you finished two. One is left, and it fits tomorrow morning, calmly.")),
        Line(mine: true, text: String(localized: "zen.sample.5", defaultValue: "yeah… thanks")),
        Line(mine: false, text: String(localized: "zen.sample.6", defaultValue: "I'm here. Want me to remind you at 9 tomorrow, or would you rather just rest now?")),
    ]
}

/// The quiet input every direction ends with: one line, the mic, send.
private struct ZenComposer: View {
    var night: Bool
    var large = false
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField(String(localized: "Message"), text: $text)
                .textFieldStyle(.plain)
                .font(large ? .title3 : .body)
                .padding(.leading, 18)
            Image(systemName: text.isEmpty ? "mic.fill" : "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(text.isEmpty ? AnyShapeStyle(Ink.text) : AnyShapeStyle(.white))
                .frame(width: 38, height: 38)
                .background(Circle().fill(text.isEmpty ? AnyShapeStyle(Ink.text.opacity(0.08)) : AnyShapeStyle(Ink.spot)))
                .padding(4)
        }
        .frame(height: large ? 54 : 46)
        .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - Balloon

/// Telegram's balloons, kept, but alone: a narrow centred column and a soft
/// pink glow behind it.
private struct ZenBalloon: View {
    var night: Bool

    var body: some View {
        ZStack {
            (night ? Color(.sRGB, red: 0.06, green: 0.055, blue: 0.07) : Color(.sRGB, red: 0.96, green: 0.955, blue: 0.95))
                .ignoresSafeArea()
            RadialGradient(colors: [Ink.spot.opacity(night ? 0.18 : 0.14), .clear], center: .center, startRadius: 40, endRadius: 520)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(night ? "Tonight" : "Today")
                        .font(Lettering.display(11.5, relativeTo: .caption))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                    ForEach(Array(ZenSample.lines.enumerated()), id: \.element.id) { index, line in
                        let next = index + 1 < ZenSample.lines.count ? ZenSample.lines[index + 1] : nil
                        HStack(alignment: .bottom, spacing: 6) {
                            if line.mine { Spacer(minLength: 80) }
                            if !line.mine {
                                Group {
                                    if next?.mine ?? true { MascotFace(mood: .idle, size: 28) } else { Color.clear }
                                }
                                .frame(width: 28)
                            }
                            MessageBubble(outgoing: line.mine) {
                                Text(line.text).font(.system(size: 15)).lineSpacing(3)
                            }
                            if !line.mine { Spacer(minLength: 60) }
                        }
                        .padding(.top, 6)
                    }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 40)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .safeAreaInset(edge: .bottom) {
                ZenComposer(night: night).frame(maxWidth: 520).padding(.horizontal, 40).padding(.bottom, 18)
            }
        }
        .environment(\.colorScheme, night ? .dark : .light)
    }
}
