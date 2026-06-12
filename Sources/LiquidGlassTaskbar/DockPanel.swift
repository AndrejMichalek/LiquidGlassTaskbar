import AppKit
import SwiftUI

/// Floating Liquid Glass bar above the bottom edge of the primary display.
final class DockPanelController {
    static let barHeight: CGFloat = 54
    static let sideInset: CGFloat = 10
    static let bottomInset: CGFloat = 8

    private let panel: NSPanel

    init(tracker: WindowTracker, onCustomLauncher: @escaping () -> Void) {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.level = .statusBar
        // No .fullScreenAuxiliary — the bar stays out of fullscreen Spaces,
        // just like the Windows taskbar does for fullscreen apps.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: DockBarView(tracker: tracker, onCustomLauncher: onCustomLauncher))
        self.panel = panel

        reframe()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.reframe()
        }
    }

    private func reframe() {
        guard let screen = NSScreen.screens.first else { return }
        let frame = screen.frame
        panel.setFrame(NSRect(x: frame.minX + Self.sideInset,
                              y: frame.minY + Self.bottomInset,
                              width: frame.width - Self.sideInset * 2,
                              height: Self.barHeight),
                       display: true)
    }
}
