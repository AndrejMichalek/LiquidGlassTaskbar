import AppKit

enum SystemActions {
    /// Show Desktop — CoreDockSendNotification is private API, but stable
    /// for years. The symbol lives in HIServices (linked via
    /// ApplicationServices); the Tahoe Dock listens for
    /// "com.apple.showdesktop.awake" (it no longer knows the old
    /// "com.apple.showdesktop"). Fallback: the F11 key.
    static func showDesktop() {
        typealias Fn = @convention(c) (CFString, Int32) -> Void
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        if let symbol = dlsym(rtldDefault, "CoreDockSendNotification") {
            unsafeBitCast(symbol, to: Fn.self)("com.apple.showdesktop.awake" as CFString, 0)
        } else {
            postKeystroke(keyCode: 103, flags: []) // kVK_F11
        }
    }

    /// Region screenshot — synthetic ⇧⌘4.
    static func screenshotSelection() {
        postKeystroke(keyCode: 21, flags: [.maskCommand, .maskShift]) // kVK_ANSI_4
    }

    /// Posts a keyboard shortcut — globally, or directly to a process.
    static func postKeystroke(keyCode: CGKeyCode, flags: CGEventFlags, toPid pid: pid_t? = nil) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        if let pid {
            down.postToPid(pid)
            up.postToPid(pid)
        } else {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}
