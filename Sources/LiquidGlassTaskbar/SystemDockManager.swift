import AppKit

/// The system Dock cannot be disabled — instead it is hidden by enabling
/// autohide with an extreme delay, so it never slides out.
final class SystemDockManager {
    static let shared = SystemDockManager()

    private let dockDomain = "com.apple.dock" as CFString
    private let wantsKey = "userWantsSystemDockHidden"
    private let savedAutohideKey = "savedSystemDockAutohide"
    private let savedMineffectKey = "savedSystemDockMineffect"
    private let savedMinimizeToAppKey = "savedSystemDockMinimizeToApp"

    var userWantsHidden: Bool {
        get { UserDefaults.standard.bool(forKey: wantsKey) }
        set { UserDefaults.standard.set(newValue, forKey: wantsKey) }
    }

    func hideSystemDock() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: savedAutohideKey) == nil {
            let autohide = (CFPreferencesCopyAppValue("autohide" as CFString, dockDomain) as? Bool) ?? false
            let mineffect = (CFPreferencesCopyAppValue("mineffect" as CFString, dockDomain) as? String) ?? "genie"
            let minimizeToApp = (CFPreferencesCopyAppValue("minimize-to-application" as CFString, dockDomain) as? Bool) ?? false
            defaults.set(autohide, forKey: savedAutohideKey)
            defaults.set(mineffect, forKey: savedMineffectKey)
            defaults.set(minimizeToApp, forKey: savedMinimizeToAppKey)
        }
        CFPreferencesSetAppValue("autohide" as CFString, kCFBooleanTrue, dockDomain)
        CFPreferencesSetAppValue("autohide-delay" as CFString, NSNumber(value: 1000.0), dockDomain)
        // The hidden Dock sits at the bottom edge, so the scale effect
        // visually minimizes windows into our bar; genie would suck them
        // into empty space.
        CFPreferencesSetAppValue("mineffect" as CFString, "scale" as CFString, dockDomain)
        CFPreferencesSetAppValue("minimize-to-application" as CFString, kCFBooleanTrue, dockDomain)
        CFPreferencesAppSynchronize(dockDomain)
        restartDock()
    }

    func showSystemDock() {
        let defaults = UserDefaults.standard
        let autohide = defaults.bool(forKey: savedAutohideKey)
        let mineffect = defaults.string(forKey: savedMineffectKey) ?? "genie"
        let minimizeToApp = defaults.bool(forKey: savedMinimizeToAppKey)
        CFPreferencesSetAppValue("autohide" as CFString,
                                 autohide ? kCFBooleanTrue : kCFBooleanFalse,
                                 dockDomain)
        CFPreferencesSetAppValue("autohide-delay" as CFString, nil, dockDomain)
        CFPreferencesSetAppValue("mineffect" as CFString, mineffect as CFString, dockDomain)
        CFPreferencesSetAppValue("minimize-to-application" as CFString,
                                 minimizeToApp ? kCFBooleanTrue : kCFBooleanFalse,
                                 dockDomain)
        CFPreferencesAppSynchronize(dockDomain)
        restartDock()
    }

    private func restartDock() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
    }
}
