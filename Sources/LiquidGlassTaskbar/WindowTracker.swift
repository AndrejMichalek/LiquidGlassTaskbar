import AppKit
import ApplicationServices

/// One taskbar item: either a specific window (Win7 style), or an app
/// without visible windows (a placeholder with the app icon and name).
struct DockItem: Identifiable, Equatable {
    let id: String
    let windowID: Int?
    let pid: pid_t?
    let bundleID: String?
    let appName: String
    let icon: NSImage?
    let title: String
    let isMinimized: Bool
    let isFocused: Bool
    let isPinned: Bool
    let isAttention: Bool

    var isPlaceholder: Bool { windowID == nil }

    static func == (lhs: DockItem, rhs: DockItem) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.isMinimized == rhs.isMinimized
            && lhs.isFocused == rhs.isFocused
            && lhs.isPinned == rhs.isPinned
            && lhs.isAttention == rhs.isAttention
    }
}

struct PinnedApp: Codable, Equatable {
    let bundleID: String
    let path: String
    let name: String
}

private final class TrackedWindow {
    let id: Int
    let element: AXUIElement
    var title: String
    var isMinimized: Bool
    var isFocused = false

    init(id: Int, element: AXUIElement, title: String, isMinimized: Bool) {
        self.id = id
        self.element = element
        self.title = title
        self.isMinimized = isMinimized
    }
}

private final class AppContext {
    let app: NSRunningApplication
    let element: AXUIElement
    let name: String
    let icon: NSImage?
    var observer: AXObserver?
    var windows: [TrackedWindow] = []
    /// The app has a real window in CGWindowList (another Space) that the
    /// AX API cannot see.
    var hasHiddenWindows = false
    /// The app posted a notification (badge change) the user hasn't
    /// reacted to yet.
    var needsAttention = false

    init(app: NSRunningApplication) {
        self.app = app
        self.element = AXUIElementCreateApplication(app.processIdentifier)
        self.name = app.localizedName ?? "Application"
        self.icon = app.icon
    }
}

private let axObserverCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
    tracker.handleAXEvent(notification as String, element: element)
}

final class WindowTracker: ObservableObject {
    @Published private(set) var items: [DockItem] = []
    @Published private(set) var started = false

    private var contexts: [pid_t: AppContext] = [:]
    private var pidOrder: [pid_t] = []
    private var nextWindowID = 1
    private var reconcileTimer: Timer?

    private var pinned: [PinnedApp] = []
    private var placeholderIcons: [String: NSImage] = [:]
    private let pinsKey = "pinnedApps"

    // MARK: - Lifecycle

    init() {
        if let data = UserDefaults.standard.data(forKey: pinsKey),
           let pins = try? JSONDecoder().decode([PinnedApp].self, from: data) {
            pinned = pins
        }
    }

    func start() {
        guard !started else { return }
        started = true

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appLaunched(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appActivated(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // Switching Spaces makes previously invisible windows show up
        // in the AX window list.
        nc.addObserver(self, selector: #selector(spaceChanged(_:)),
                       name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            addApp(app)
        }
        refreshFocus()
        publish()

        // Safety net for missed AX notifications and for apps that were
        // not AX-ready right after launching.
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.reconcile()
        }
    }

    func forceReconcile() {
        reconcile()
    }

    // MARK: - Pinning

    func pinApp(windowID: Int) {
        guard let (ctx, _) = find(windowID),
              let bundleID = ctx.app.bundleIdentifier,
              let url = activationURL(for: ctx),
              !pinned.contains(where: { $0.bundleID == bundleID }) else { return }
        pinned.append(PinnedApp(bundleID: bundleID, path: url.path, name: ctx.name))
        savePins()
        publish()
    }

    func unpinApp(bundleID: String?) {
        guard let bundleID else { return }
        pinned.removeAll { $0.bundleID == bundleID }
        savePins()
        publish()
    }

    func launchPinned(bundleID: String?) {
        guard let bundleID,
              pinned.contains(where: { $0.bundleID == bundleID }) else { return }
        openViaBundleID(bundleID)
    }

    /// Launch/activate via `open -b` — the only path verified to work even
    /// for apps with a non-standard bundle (Steam registers a directory
    /// without an .app extension in LaunchServices; openApplication(at:)
    /// would open it as a folder in Finder).
    private func openViaBundleID(_ bundleID: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", bundleID]
        try? process.run()
    }

    /// Click on a windowless item: activates a running app (jumping to its
    /// Space), launches a pinned app that isn't running. Activation goes
    /// through LaunchServices "open" — macOS cooperative activation often
    /// silently rejects NSRunningApplication.activate() coming from a
    /// background app.
    func handlePlaceholderClick(_ item: DockItem) {
        if let pid = item.pid, let ctx = contexts[pid] {
            ctx.app.unhide()
            if let bundleID = ctx.app.bundleIdentifier {
                openViaBundleID(bundleID)
            } else {
                ctx.app.activate()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.forceReconcile()
            }
        } else {
            launchPinned(bundleID: item.bundleID)
        }
    }

    /// "New Window" like in the system Dock menu: activate the app and
    /// send it ⌘N.
    func newWindow(_ item: DockItem) {
        guard let pid = item.pid, let ctx = contexts[pid] else {
            launchPinned(bundleID: item.bundleID)
            return
        }
        if let bundleID = ctx.app.bundleIdentifier {
            openViaBundleID(bundleID)
        } else {
            ctx.app.activate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            SystemActions.postKeystroke(keyCode: 45, flags: .maskCommand, toPid: pid) // kVK_ANSI_N
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                self?.forceReconcile()
            }
        }
    }

    func hideApp(_ item: DockItem) {
        guard let pid = item.pid else { return }
        contexts[pid]?.app.hide()
    }

    /// Path stored with a pin — informational only (icon, name); launching
    /// always goes through the bundle ID.
    private func activationURL(for ctx: AppContext) -> URL? {
        if let bundleID = ctx.app.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url
        }
        return ctx.app.bundleURL
    }

    func pinAppByBundleID(_ bundleID: String?) {
        guard let bundleID,
              !pinned.contains(where: { $0.bundleID == bundleID }),
              let ctx = contexts.values.first(where: { $0.app.bundleIdentifier == bundleID }),
              let url = activationURL(for: ctx) else { return }
        pinned.append(PinnedApp(bundleID: bundleID, path: url.path, name: ctx.name))
        savePins()
        publish()
    }

    func quitAppByPid(_ pid: pid_t?) {
        guard let pid, let ctx = contexts[pid] else { return }
        ctx.app.terminate()
    }

    private func savePins() {
        if let data = try? JSONEncoder().encode(pinned) {
            UserDefaults.standard.set(data, forKey: pinsKey)
        }
    }

    private func placeholderIcon(_ pin: PinnedApp) -> NSImage {
        if let icon = placeholderIcons[pin.path] {
            return icon
        }
        let icon = NSWorkspace.shared.icon(forFile: pin.path)
        placeholderIcons[pin.path] = icon
        return icon
    }

    // MARK: - UI actions

    func handlePrimaryClick(_ windowID: Int) {
        guard let (ctx, window) = find(windowID) else { return }
        if !window.isMinimized && window.isFocused && ctx.app.isActive {
            // Win7: clicking the active window minimizes it
            AX.setMinimized(window.element, true)
            window.isMinimized = true
            window.isFocused = false
            publish()
        } else {
            focusWindow(ctx, window)
        }
    }

    func restore(_ windowID: Int) {
        guard let (ctx, window) = find(windowID) else { return }
        focusWindow(ctx, window)
    }

    func minimize(_ windowID: Int) {
        guard let (_, window) = find(windowID) else { return }
        AX.setMinimized(window.element, true)
        window.isMinimized = true
        publish()
    }

    func closeWindow(_ windowID: Int) {
        guard let (_, window) = find(windowID) else { return }
        AX.pressCloseButton(window.element)
    }

    func quitApp(_ windowID: Int) {
        guard let (ctx, _) = find(windowID) else { return }
        ctx.app.terminate()
    }

    // MARK: - NSWorkspace notifications

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular else { return }
        addApp(app)
        publish()
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        removeApp(app.processIdentifier)
        publish()
    }

    @objc private func appActivated(_ note: Notification) {
        // Opening the app counts as reacting — the orange highlight clears.
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            contexts[app.processIdentifier]?.needsAttention = false
        }
        refreshFocus()
        publish()
    }

    @objc private func spaceChanged(_ note: Notification) {
        reconcile()
    }

    // MARK: - AX events

    func handleAXEvent(_ notification: String, element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification:
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            if let ctx = contexts[pid] {
                addWindowIfNeeded(ctx, element)
            }
        case kAXUIElementDestroyedNotification:
            for ctx in contexts.values {
                ctx.windows.removeAll { CFEqual($0.element, element) }
            }
        case kAXTitleChangedNotification:
            if let (_, window) = findByElement(element) {
                window.title = AX.title(element) ?? window.title
            }
        case kAXWindowMiniaturizedNotification:
            findByElement(element)?.1.isMinimized = true
        case kAXWindowDeminiaturizedNotification:
            findByElement(element)?.1.isMinimized = false
        default:
            break
        }
        refreshFocus()
        publish()
    }

    // MARK: - App and window management

    private func addApp(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard contexts[pid] == nil, pid != ProcessInfo.processInfo.processIdentifier else { return }
        let ctx = AppContext(app: app)
        contexts[pid] = ctx
        pidOrder.append(pid)
        setupObserver(ctx)
        syncWindows(ctx)
    }

    private func removeApp(_ pid: pid_t) {
        guard let ctx = contexts.removeValue(forKey: pid) else { return }
        pidOrder.removeAll { $0 == pid }
        if let observer = ctx.observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(observer),
                                  .defaultMode)
        }
    }

    private func setupObserver(_ ctx: AppContext) {
        guard ctx.observer == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(ctx.app.processIdentifier, axObserverCallback, &observer) == .success,
              let observer else { return }
        ctx.observer = observer
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification,
                     kAXFocusedWindowChangedNotification,
                     kAXMainWindowChangedNotification] {
            AXObserverAddNotification(observer, ctx.element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private func registerWindowNotifications(_ ctx: AppContext, _ element: AXUIElement) {
        guard let observer = ctx.observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXUIElementDestroyedNotification,
                     kAXTitleChangedNotification,
                     kAXWindowMiniaturizedNotification,
                     kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
    }

    private func addWindowIfNeeded(_ ctx: AppContext, _ element: AXUIElement) {
        guard AX.isTrackableWindow(element),
              !ctx.windows.contains(where: { CFEqual($0.element, element) }) else { return }
        let window = TrackedWindow(id: nextWindowID,
                                   element: element,
                                   title: AX.title(element) ?? "",
                                   isMinimized: AX.isMinimized(element))
        nextWindowID += 1
        ctx.windows.append(window)
        registerWindowNotifications(ctx, element)
    }

    private func syncWindows(_ ctx: AppContext) {
        let current = AX.windows(of: ctx.element).filter { AX.isTrackableWindow($0) }
        // Windows on other Spaces are absent from the AX list — only remove
        // truly destroyed elements, otherwise a window would vanish from
        // the bar whenever the user leaves its Space.
        ctx.windows.removeAll { tracked in
            let inCurrent = current.contains { CFEqual($0, tracked.element) }
            return !inCurrent && !AX.isAlive(tracked.element)
        }
        for element in current {
            addWindowIfNeeded(ctx, element)
        }
        for window in ctx.windows {
            window.title = AX.title(window.element) ?? window.title
            window.isMinimized = AX.isMinimized(window.element)
        }
    }

    private func reconcile() {
        if UserDefaults.standard.bool(forKey: "diagnosticsRequested") {
            UserDefaults.standard.set(false, forKey: "diagnosticsRequested")
            writeDiagnostics()
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if contexts[app.processIdentifier] == nil {
                addApp(app)
            }
        }
        for pid in pidOrder where contexts[pid]?.app.isTerminated == true {
            removeApp(pid)
        }
        for ctx in contexts.values {
            if ctx.observer == nil {
                setupObserver(ctx)
            }
            syncWindows(ctx)
        }
        updateHiddenWindowFlags()
        updateBadges()
        refreshFocus()
        publish()
    }

    // MARK: - Notification badges

    private var dockAXElement: AXUIElement?
    private var lastBadges: [String: String] = [:]
    private var didBaselineBadges = false
    private var bundleIDForDockURL: [String: String] = [:]

    /// App badges are read from the AX tree of the (hidden) system Dock —
    /// macOS doesn't expose other apps' notifications to third parties
    /// any other way.
    private func updateBadges() {
        if dockAXElement == nil,
           let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
            dockAXElement = AXUIElementCreateApplication(dock.processIdentifier)
        }
        guard let dockAXElement else { return }

        var current: [String: String] = [:]
        for list in AX.elements(dockAXElement, kAXChildrenAttribute) {
            for item in AX.elements(list, kAXChildrenAttribute)
            where (AX.copyValue(item, kAXSubroleAttribute) as String?) == "AXApplicationDockItem" {
                guard let badge: String = AX.copyValue(item, "AXStatusLabel"), !badge.isEmpty,
                      let url: NSURL = AX.copyValue(item, "AXURL"),
                      let path = url.path else { continue }
                let bundleID: String
                if let cached = bundleIDForDockURL[path] {
                    bundleID = cached
                } else if let id = Bundle(url: url as URL)?.bundleIdentifier {
                    bundleIDForDockURL[path] = id
                    bundleID = id
                } else {
                    continue
                }
                current[bundleID] = badge
            }
        }

        defer {
            lastBadges = current
            didBaselineBadges = true
        }
        // The first scan after launch is just a baseline — apps with a
        // long-standing badge (eternally unread Teams…) shouldn't light up
        // right away.
        guard didBaselineBadges else { return }

        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for (bundleID, badge) in current where lastBadges[bundleID] != badge {
            // A decreasing count (messages read elsewhere) is not a new
            // notification.
            if let old = lastBadges[bundleID].flatMap(Int.init),
               let new = Int(badge), new < old {
                continue
            }
            for ctx in contexts.values
            where ctx.app.bundleIdentifier == bundleID && ctx.app.processIdentifier != frontPid {
                ctx.needsAttention = true
            }
        }
    }

    /// CGWindowList sees windows across all Spaces — it reveals apps whose
    /// windows the AX API doesn't (yet) return.
    private func updateHiddenWindowFlags() {
        let cgAll = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        var pidsWithRealWindows = Set<Int>()
        for cg in cgAll {
            guard (cg[kCGWindowLayer as String] as? Int) == 0,
                  let owner = cg[kCGWindowOwnerPID as String] as? Int,
                  let bounds = cg[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? CGFloat, width >= 100,
                  let height = bounds["Height"] as? CGFloat, height >= 50 else { continue }
            pidsWithRealWindows.insert(owner)
        }
        for ctx in contexts.values {
            ctx.hasHiddenWindows = ctx.windows.isEmpty
                && pidsWithRealWindows.contains(Int(ctx.app.processIdentifier))
        }
    }

    // MARK: - Focus

    private func focusWindow(_ ctx: AppContext, _ window: TrackedWindow) {
        if window.isMinimized {
            AX.setMinimized(window.element, false)
            window.isMinimized = false
        }
        AX.raise(window.element)
        AX.setFocusedWindow(ctx.element, window.element)
        ctx.app.activate()
        publish()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            // Cooperative activation may have rejected the request
            // (typically for a window on another Space) — LaunchServices
            // "open" always goes through.
            if !ctx.app.isActive, let bundleID = ctx.app.bundleIdentifier {
                self.openViaBundleID(bundleID)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    AX.raise(window.element)
                    self.refreshFocus()
                    self.publish()
                }
            } else {
                self.refreshFocus()
                self.publish()
            }
        }
    }

    private func refreshFocus() {
        let front = NSWorkspace.shared.frontmostApplication
        var focusedElement: AXUIElement?
        if let front, let ctx = contexts[front.processIdentifier] {
            focusedElement = AX.focusedWindow(of: ctx.element)
        }
        for (pid, ctx) in contexts {
            for window in ctx.windows {
                if let focusedElement, pid == front?.processIdentifier {
                    window.isFocused = CFEqual(window.element, focusedElement)
                } else {
                    window.isFocused = false
                }
            }
        }
    }

    // MARK: - Publishing to the UI

    private func publish() {
        var out: [DockItem] = []
        var usedPids = Set<pid_t>()

        // Pinned apps always come first, in pin order — their windows show
        // at the pin position; with no windows the placeholder remains
        // (Win7 style).
        for pin in pinned {
            if let pid = pidOrder.first(where: { contexts[$0]?.app.bundleIdentifier == pin.bundleID }),
               let ctx = contexts[pid], !ctx.windows.isEmpty {
                usedPids.insert(pid)
                out.append(contentsOf: windowItems(ctx, pid: pid, isPinned: true))
            } else {
                let runningPid = pidOrder.first { contexts[$0]?.app.bundleIdentifier == pin.bundleID }
                let attention = runningPid.flatMap { contexts[$0]?.needsAttention } ?? false
                out.append(DockItem(id: "p\(pin.bundleID)",
                                    windowID: nil,
                                    pid: runningPid,
                                    bundleID: pin.bundleID,
                                    appName: pin.name,
                                    icon: placeholderIcon(pin),
                                    title: pin.name,
                                    isMinimized: false,
                                    isFocused: false,
                                    isPinned: true,
                                    isAttention: attention))
            }
        }

        for pid in pidOrder where !usedPids.contains(pid) {
            guard let ctx = contexts[pid] else { continue }
            let isPinned = pinned.contains { $0.bundleID == ctx.app.bundleIdentifier }
            if ctx.windows.isEmpty {
                // Windows on an unvisited Space — show an app-level button;
                // clicking activates the app, macOS jumps to its Space, and
                // the AX window gets registered.
                if ctx.hasHiddenWindows && !isPinned {
                    out.append(DockItem(id: "a\(pid)",
                                        windowID: nil,
                                        pid: pid,
                                        bundleID: ctx.app.bundleIdentifier,
                                        appName: ctx.name,
                                        icon: ctx.icon,
                                        title: ctx.name,
                                        isMinimized: false,
                                        isFocused: false,
                                        isPinned: false,
                                        isAttention: ctx.needsAttention))
                }
                continue
            }
            out.append(contentsOf: windowItems(ctx, pid: pid, isPinned: isPinned))
        }

        if out != items {
            items = out
        }
    }

    private func windowItems(_ ctx: AppContext, pid: pid_t, isPinned: Bool) -> [DockItem] {
        ctx.windows.map { window in
            DockItem(id: "w\(window.id)",
                     windowID: window.id,
                     pid: pid,
                     bundleID: ctx.app.bundleIdentifier,
                     appName: ctx.name,
                     icon: ctx.icon,
                     title: window.title.isEmpty ? ctx.name : window.title,
                     isMinimized: window.isMinimized,
                     isFocused: window.isFocused,
                     isPinned: isPinned,
                     isAttention: ctx.needsAttention)
        }
    }

    private func find(_ windowID: Int) -> (AppContext, TrackedWindow)? {
        for ctx in contexts.values {
            if let window = ctx.windows.first(where: { $0.id == windowID }) {
                return (ctx, window)
            }
        }
        return nil
    }

    private func findByElement(_ element: AXUIElement) -> (AppContext, TrackedWindow)? {
        for ctx in contexts.values {
            if let window = ctx.windows.first(where: { CFEqual($0.element, element) }) {
                return (ctx, window)
            }
        }
        return nil
    }

    // MARK: - Diagnostics

    func writeDiagnostics() {
        var lines: [String] = []
        lines.append("LiquidGlassTaskbar diagnostics")
        lines.append("AX trusted: \(AXIsProcessTrusted()), started: \(started)")
        lines.append("pinned: \(pinned.map(\.bundleID))")
        lines.append("badges: \(lastBadges)")
        lines.append("items in bar: \(items.count)")
        if let dockAXElement {
            for list in AX.elements(dockAXElement, kAXChildrenAttribute) {
                for item in AX.elements(list, kAXChildrenAttribute) {
                    let title: String? = AX.copyValue(item, kAXTitleAttribute)
                    let label: String? = AX.copyValue(item, "AXStatusLabel")
                    lines.append("dockItem: subrole=\(AX.subrole(item) ?? "nil")"
                        + " title=\(title ?? "nil") statusLabel=\(label ?? "nil")")
                }
            }
        } else {
            lines.append("dockAXElement: nil")
        }

        let cgAll = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            let ctx = contexts[pid]
            lines.append("")
            lines.append("[\(app.localizedName ?? "?")] pid=\(pid) bundle=\(app.bundleIdentifier ?? "?")"
                + " ctx=\(ctx != nil) observer=\(ctx?.observer != nil) tracked=\(ctx?.windows.count ?? 0)")

            let element = ctx?.element ?? AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
            guard error == .success, let array = value as? [AnyObject] else {
                lines.append("  kAXWindows error: \(error.rawValue)")
                continue
            }
            for object in array where CFGetTypeID(object) == AXUIElementGetTypeID() {
                let window = object as! AXUIElement
                let role: String? = AX.copyValue(window, kAXRoleAttribute)
                lines.append("  window: role=\(role ?? "nil")"
                    + " subrole=\(AX.subrole(window) ?? "nil")"
                    + " min=\(AX.isMinimized(window))"
                    + " trackable=\(AX.isTrackableWindow(window))"
                    + " wid=\(AX.windowID(window).map(String.init) ?? "nil")"
                    + " title=\((AX.title(window) ?? "").prefix(60))")
            }
            for cg in cgAll where (cg[kCGWindowOwnerPID as String] as? Int) == Int(pid) {
                let bounds = cg[kCGWindowBounds as String] as? [String: Any] ?? [:]
                lines.append("  cg: id=\(cg[kCGWindowNumber as String] as? Int ?? 0)"
                    + " layer=\(cg[kCGWindowLayer as String] as? Int ?? -1)"
                    + " onscreen=\(cg[kCGWindowIsOnscreen as String] as? Bool ?? false)"
                    + " w=\(bounds["Width"] as? Int ?? -1) h=\(bounds["Height"] as? Int ?? -1)")
            }
        }
        try? lines.joined(separator: "\n")
            .write(toFile: "/tmp/LiquidGlassTaskbar-diag.txt", atomically: true, encoding: .utf8)
    }
}
