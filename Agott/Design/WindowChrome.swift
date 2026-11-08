#if os(macOS)
import AppKit
import SwiftUI

/// Empty space in a top bar that behaves like a title bar: drag to move the
/// window, double-click to zoom it (or what System Settings says). Put it
/// behind a top bar: its buttons keep their clicks, the gaps between them
/// become title bar.
struct TitleBarArea: NSViewRepresentable {
    func makeNSView(context: Context) -> TitleBarView { TitleBarView() }
    func updateNSView(_ view: TitleBarView, context: Context) {}
}

class TitleBarView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
        } else {
            window.performDrag(with: event)
        }
    }
}

extension View {
    /// Makes the empty parts of this top bar act as the window's title bar.
    func titleBar() -> some View { background { TitleBarArea() } }
}

/// Empty space that behaves like a title bar: drag to move the window,
/// double-click to zoom (or minimise, or nothing, following System Settings
/// → Desktop & Dock → "Double-click a window's title bar").
///
/// The app draws its own top, so without this the window could only be
/// moved and zoomed from a 28 pt strip nobody can see.
struct WindowChromeArea: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ view: ChromeView, context: Context) {}

    final class ChromeView: TitleBarView {
        /// A transparent title bar with no toolbar. An empty toolbar used to
        /// lower the window buttons, but its strip took every click across
        /// the top of the window (sidebar, search, History, New
        /// conversation) to drag the window instead.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            if window.toolbar != nil { window.toolbar = nil }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            // See-through where nothing is drawn, so the sidebar's material
            // can show the desktop behind it, blurred.
            window.isOpaque = false
            window.backgroundColor = .clear
            placeWindowButtons()
            // AppKit puts the buttons back on every layout; put them back
            // where they belong each time.
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didExitFullScreenNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
            }
        }

        override func layout() {
            super.layout()
            placeWindowButtons()
        }

        @objc private func windowChanged(_ note: Notification) {
            DispatchQueue.main.async { [weak self] in self?.placeWindowButtons() }
        }

        /// The close, minimise and zoom buttons inset from the corner like a
        /// notebook app's, centred on the strip every top bar is drawn in
        /// (`WindowBar.height`), instead of crowded into the corner.
        private func placeWindowButtons() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let titlebar = close.superview, let container = titlebar.superview else { return }
            let height = WindowBar.height
            var frame = container.frame
            if frame.height != height {
                frame.size.height = height
                frame.origin.y = window.frame.height - height
                container.frame = frame
            }
            for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                guard let button = window.standardWindowButton(kind) else { continue }
                let origin = NSPoint(x: WindowBar.buttonsInset + CGFloat(index) * 20,
                                     y: (titlebar.frame.height - button.frame.height) / 2)
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }

    }
}

/// The system's sidebar material: the desktop behind the window, blurred
/// and toned, the way Finder's and Claude's sidebars look.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
#else
import SwiftUI

extension View {
    /// No title bar to stand in for on the iPhone.
    func titleBar() -> some View { self }
}
#endif
