import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let tracker = WindowTracker()
    private let launcher = AppsLauncherController()
    private var dockPanel: DockPanelController?
    private var statusItem: NSStatusItem?
    private var trustTimer: Timer?
    private var hideDockMenuItem: NSMenuItem?
    private var loginMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        dockPanel = DockPanelController(tracker: tracker) { [weak self] in
            self?.launcher.toggle()
        }

        if AXIsProcessTrusted() {
            start()
        } else {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.start()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave the user without any dock at all.
        if SystemDockManager.shared.userWantsHidden {
            SystemDockManager.shared.showSystemDock()
        }
    }

    private func start() {
        tracker.start()
        if SystemDockManager.shared.userWantsHidden {
            SystemDockManager.shared.hideSystemDock()
        }
    }

    // MARK: - Status bar menu

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "dock.rectangle",
                                     accessibilityDescription: "LiquidGlassTaskbar")

        let menu = NSMenu()
        menu.delegate = self

        let hide = NSMenuItem(title: "Hide System Dock",
                              action: #selector(toggleSystemDock(_:)), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)

        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        menu.addItem(login)

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh Window List",
                                 action: #selector(refreshWindows(_:)), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LiquidGlassTaskbar",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
        hideDockMenuItem = hide
        loginMenuItem = login
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        hideDockMenuItem?.state = SystemDockManager.shared.userWantsHidden ? .on : .off
        loginMenuItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleSystemDock(_ sender: Any?) {
        let manager = SystemDockManager.shared
        manager.userWantsHidden.toggle()
        if manager.userWantsHidden {
            manager.hideSystemDock()
        } else {
            manager.showSystemDock()
        }
    }

    @objc private func toggleLoginItem(_ sender: Any?) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Login item error: \(error)")
        }
    }

    @objc private func refreshWindows(_ sender: Any?) {
        tracker.forceReconcile()
    }
}
