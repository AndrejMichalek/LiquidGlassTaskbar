// Test app for the notification highlight: 10 s after launching it sets
// a dock badge of "1" (as if a notification arrived) and quits itself
// after 90 s.
//
// Build: see test/build_badge_test.sh or the README.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let window = NSWindow(contentRect: NSRect(x: 400, y: 400, width: 380, height: 120),
                      styleMask: [.titled, .closable, .miniaturizable],
                      backing: .buffered, defer: false)
window.title = "Notification Test"

let label = NSTextField(labelWithString: "Click another window.\nIn ~10 s I get a badge → my taskbar item turns orange.")
label.frame = NSRect(x: 20, y: 30, width: 340, height: 60)
label.alignment = .center
window.contentView?.addSubview(label)
window.makeKeyAndOrderFront(nil)
app.activate()

DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
    app.dockTile.badgeLabel = "1"
    label.stringValue = "Badge set! My taskbar item should be orange now.\nClick it — the orange clears."
}
DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
    app.terminate(nil)
}

app.run()
