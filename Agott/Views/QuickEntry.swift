#if os(macOS)
import AppKit
import ScreenCaptureKit
import SwiftUI

/// Quick entry, over whatever you are doing: the screen dims a little, each
/// window offers "send a screenshot of …", a drag captures any part of the
/// screen, and a bar at the bottom takes the question. Esc or a click on
/// nothing puts it away. Opened by tapping the ask key or the text shortcut.
@MainActor
final class QuickEntryController {
    static let shared = QuickEntryController()
    private var panel: OverlayPanel?
    var isShown: Bool { panel?.isVisible ?? false }

    func toggle() { isShown ? hide() : show() }

    func show() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let panel = self.panel ?? OverlayPanel(contentRect: screen.frame,
                                               styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                                               backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.setFrame(screen.frame, display: true)
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            ?? CGMainDisplayID()
        panel.contentView = NSHostingView(rootView: QuickEntryView(displayID: displayID) { [weak self] in self?.hide() })
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }
}

/// A window on screen that can be sent as a picture.
private struct ShareableWindow: Identifiable {
    var id: CGWindowID
    var app: String
    /// In the panel's coordinates (top-left origin).
    var frame: CGRect
    var window: SCWindow
}

struct QuickEntryView: View {
    var displayID: CGDirectDisplayID
    var close: () -> Void

    @State private var text = ""
    @State private var pending: [FileAttachment] = []
    @State private var windows: [ShareableWindow] = []
    @State private var hovered: CGWindowID?
    @State private var selection: CGRect?
    @State private var newChat = true
    @State private var capturing = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            // The dimmed screen: drag to capture a part, click to leave.
            Color.black.opacity(0.08)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            selection = CGRect(x: min(value.startLocation.x, value.location.x),
                                               y: min(value.startLocation.y, value.location.y),
                                               width: abs(value.location.x - value.startLocation.x),
                                               height: abs(value.location.y - value.startLocation.y))
                        }
                        .onEnded { _ in
                            if let rect = selection, rect.width > 8, rect.height > 8 { Task { await capture(rect) } }
                            selection = nil
                        })
                .onTapGesture { close() }

            ForEach(windows) { item in
                windowChip(item)
            }

            if let selection {
                Rectangle()
                    .fill(Ink.spot.opacity(0.08))
                    .overlay(Rectangle().strokeBorder(Ink.spot, lineWidth: 1.5))
                    .frame(width: selection.width, height: selection.height)
                    .position(x: selection.midX, y: selection.midY)
                    .allowsHitTesting(false)
            }

            VStack {
                Spacer()
                Text(windows.isEmpty ? "Drag to capture part of the screen" : "Drag to capture part of the screen, or send a window")
                    .font(.caption)
                    .foregroundStyle(Ink.text)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .quietSurface(RoundedRectangle(cornerRadius: 6, style: .continuous), fill: Ink.surface)
                    .padding(.bottom, 10)
                bar
                    .frame(maxWidth: 640)
                    .padding(.bottom, 64)
            }
        }
        .ignoresSafeArea()
        .onAppear { focused = true }
        .task { windows = await Self.shareableWindows(on: displayID) }
        .background {
            Button("") { close() }.keyboardShortcut(.cancelAction).hidden()
        }
    }

    /// The question box: what is attached, the field, new or current chat, send.
    private var bar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pending.isEmpty {
                PendingAttachments(attachments: $pending)
            }
            HStack(spacing: 10) {
                ThinkingOrb(mode: capturing ? .globe : .ring, size: 20, active: capturing)
                TextField(String(localized: "How can I help you today?"), text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit(send)
                Menu {
                    Button("New conversation") { newChat = true }
                    Button("Continue the current one") { newChat = false }
                } label: {
                    Text(newChat ? "New conversation" : "Current conversation").font(.callout)
                }
                .menuStyle(.button)
                .buttonStyle(HoverIconStyle(size: 30))
                .fixedSize()
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Ink.spot))
                }
                .buttonStyle(PressScale())
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pending.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Ink.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
    }

    /// A window's label; hovering outlines the window, clicking sends it.
    private func windowChip(_ item: ShareableWindow) -> some View {
        ZStack(alignment: .topLeading) {
            if hovered == item.id {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Ink.spot, lineWidth: 2)
                    .frame(width: item.frame.width, height: item.frame.height)
                    .allowsHitTesting(false)
            }
            Button { Task { await capture(item) } } label: {
                Text("Send a screenshot of \(item.app)")
                    .font(.caption)
                    .foregroundStyle(Ink.text)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .quietSurface(RoundedRectangle(cornerRadius: 6, style: .continuous), fill: Ink.surface)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
            .padding(8)
        }
        .frame(width: item.frame.width, height: item.frame.height, alignment: .topLeading)
        .position(x: item.frame.midX, y: item.frame.midY)
    }

    private func send() {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty || !pending.isEmpty else { return }
        let attachments = pending
        close()
        Copilot.shared.ask(question, attachments: attachments, newChat: newChat)
    }

    // MARK: Capture

    private func capture(_ item: ShareableWindow) async {
        capturing = true
        defer { capturing = false }
        let filter = SCContentFilter(desktopIndependentWindow: item.window)
        await attach(filter: filter, size: item.window.frame.size, sourceRect: nil)
    }

    private func capture(_ rect: CGRect) async {
        capturing = true
        defer { capturing = false }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
        let ours = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
        await attach(filter: filter, size: rect.size, sourceRect: rect)
    }

    private func attach(filter: SCContentFilter, size: CGSize, sourceRect: CGRect?) async {
        let configuration = SCStreamConfiguration()
        let scale = min(2.0, 2400 / max(size.width, 1))
        configuration.width = Int(size.width * scale)
        configuration.height = Int(size.height * scale)
        configuration.showsCursor = false
        if let sourceRect { configuration.sourceRect = sourceRect }
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        let file = FileManager.default.temporaryDirectory.appending(path: "Agott capture \(UUID().uuidString.prefix(6)).png")
        guard (try? png.write(to: file)) != nil, let attachment = try? AttachmentStore.add(file) else { return }
        pending.append(attachment)
        try? FileManager.default.removeItem(at: file)
    }

    /// Windows on this display worth sending, front to back.
    private static func shareableWindows(on displayID: CGDirectDisplayID) async -> [ShareableWindow] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return [] }
        let bounds = CGDisplayBounds(displayID)
        let ours = Bundle.main.bundleIdentifier
        return content.windows
            .filter { $0.windowLayer == 0 && $0.frame.width > 240 && $0.frame.height > 160 && $0.isOnScreen
                && $0.owningApplication?.bundleIdentifier != ours && bounds.intersects($0.frame) }
            .prefix(8)
            .map { window in
                ShareableWindow(id: window.windowID, app: window.owningApplication?.applicationName ?? String(localized: "this window"),
                                frame: window.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY), window: window)
            }
    }
}
#endif
