#if os(macOS)
import AppKit
import SwiftUI

/// Empty space that behaves like a title bar: drag to move the window,
/// double-click to zoom (or minimise, or nothing, following System Settings
/// → Desktop & Dock → "Double-click a window's title bar").
///
/// The app draws its own top, so without this the window could only be
/// moved and zoomed from a 28 pt strip nobody can see.
struct WindowChromeArea: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ view: ChromeView, context: Context) {}

    final class ChromeView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

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
        }

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
#endif
