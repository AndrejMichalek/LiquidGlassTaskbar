import AppKit
import SwiftUI

/// Floating Liquid Glass bar above the bottom edge of the primary display.
final class DockPanelController {
    // Driven by the resize handle; everything else derives from it.
    static var barHeight: CGFloat { BarMetrics.shared.barHeight }
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

        // A local mouse monitor handles two things SwiftUI can't do
        // reliably in a non-activating panel: routing bottom-strip clicks
        // to the button above, and dragging a divider to resize the bar.
        // Everything else falls through so normal buttons keep working.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleLocalMouse(event) ?? event
        }
    }

    private var resizing = false
    private var resizeStartMouseY: CGFloat = 0
    private var resizeStartScale: CGFloat = 1

    private func handleLocalMouse(_ event: NSEvent) -> NSEvent? {
        if resizing {
            switch event.type {
            case .leftMouseDragged:
                // Mouse y grows upward, so dragging up enlarges the bar.
                let dy = NSEvent.mouseLocation.y - resizeStartMouseY
                BarMetrics.shared.setScale(resizeStartScale + dy / 110)
                reframe()
                return nil
            case .leftMouseUp:
                resizing = false
                NSCursor.pop()
                return nil
            default:
                return nil
            }
        }

        guard event.window === panel, event.type == .leftMouseDown else { return event }
        // locationInWindow: origin at the panel's bottom-left, y upwards.
        let point = event.locationInWindow
        if isOnDivider(x: point.x) {
            resizing = true
            resizeStartMouseY = NSEvent.mouseLocation.y
            resizeStartScale = BarMetrics.shared.scale
            NSCursor.resizeUpDown.push()
            return nil
        }
        guard point.y <= Self.bottomInset else { return event }
        geometry.routeEdgeClick?(point.x)
        return nil
    }

    private func isOnDivider(x: CGFloat) -> Bool {
        for id in ["divider-left", "divider-right"] {
            if let frame = geometry.frames[id], x >= frame.minX, x <= frame.maxX {
                return true
            }
        }
        return false
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
