import AppKit
import SwiftUI

/// Floating Liquid Glass bar above the bottom edge of the primary display.
final class DockPanelController {
    static let barHeight: CGFloat = 54
    static let sideInset: CGFloat = 10
    static let bottomInset: CGFloat = 8

    private let panel: NSPanel
    private let geometry: BarGeometry

    init(tracker: WindowTracker, geometry: BarGeometry, onCustomLauncher: @escaping () -> Void) {
        self.geometry = geometry
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
        panel.contentView = NSHostingView(rootView: DockBarView(tracker: tracker,
                                                                geometry: geometry,
                                                                onCustomLauncher: onCustomLauncher))
        self.panel = panel

        reframe()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.reframe()
        }

        // Bottom-edge clicks may be delivered to the app underneath instead
        // of our (transparent-ish) strip — the global monitor catches those
        // and routes them to the button above. Clicks our window does get
        // are handled by the strip's own tap gesture; the two paths are
        // disjoint, so nothing fires twice.
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.handleGlobalEdgeClick()
        }
    }

    private func handleGlobalEdgeClick() {
        guard panel.isVisible, let screen = NSScreen.screens.first else { return }
        let location = NSEvent.mouseLocation
        guard location.y <= screen.frame.minY + Self.bottomInset + 1,
              location.x >= panel.frame.minX, location.x <= panel.frame.maxX else { return }
        geometry.routeEdgeClick?(location.x - panel.frame.minX)
    }

    private func reframe() {
        guard let screen = NSScreen.screens.first else { return }
        let frame = screen.frame
        // Reaches the very bottom edge — the strip below the pill stays
        // clickable so edge clicks land on the button above (Fitts's law,
        // like the Windows taskbar).
        panel.setFrame(NSRect(x: frame.minX + Self.sideInset,
                              y: frame.minY,
                              width: frame.width - Self.sideInset * 2,
                              height: Self.barHeight + Self.bottomInset),
                       display: true)
    }

    // MARK: - Fullscreen auto-hide (Dock-like edge reveal)

    private var fullscreenHideMode = false
    private var revealed = false
    private var mouseTimer: Timer?

    /// Keeps the revealed bar visible while e.g. the app launcher is open.
    var shouldStayRevealed: (() -> Bool)?

    func setFullscreenHideMode(_ enabled: Bool) {
        guard fullscreenHideMode != enabled else { return }
        fullscreenHideMode = enabled
        revealed = false
        if enabled {
            setPanelVisible(false)
            mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.checkMouse()
            }
        } else {
            mouseTimer?.invalidate()
            mouseTimer = nil
            setPanelVisible(true)
        }
    }

    private func checkMouse() {
        guard let screen = NSScreen.screens.first else { return }
        let location = NSEvent.mouseLocation
        guard location.x >= screen.frame.minX, location.x <= screen.frame.maxX else { return }
        if !revealed {
            if location.y <= screen.frame.minY + 2 {
                revealed = true
                setPanelVisible(true)
            }
        } else {
            if shouldStayRevealed?() == true { return }
            // Generous slack so the bar doesn't vanish under an open
            // context menu.
            let hideThreshold = screen.frame.minY + Self.bottomInset + Self.barHeight + 150
            if location.y > hideThreshold {
                revealed = false
                setPanelVisible(false)
            }
        }
    }

    private func setPanelVisible(_ visible: Bool) {
        if visible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.fullscreenHideMode, !self.revealed else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            })
        }
    }
}
