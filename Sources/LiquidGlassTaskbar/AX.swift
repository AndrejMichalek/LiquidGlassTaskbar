import AppKit
import ApplicationServices

// Private but stable for years (used by AltTab, yabai, …) — the only way
// to get a CGWindowID out of an AXUIElement.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

/// Thin wrappers over the Accessibility C API.
enum AX {
    static func copyValue<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let array = value as? [AnyObject] else {
            return []
        }
        return array.compactMap { object in
            guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
            return (object as! AXUIElement)
        }
    }

    static func windows(of appElement: AXUIElement) -> [AXUIElement] {
        elements(appElement, kAXWindowsAttribute)
    }

    static func title(_ window: AXUIElement) -> String? {
        copyValue(window, kAXTitleAttribute)
    }

    static func subrole(_ window: AXUIElement) -> String? {
        copyValue(window, kAXSubroleAttribute)
    }

    /// Standard windows and dialogs — no palettes, popovers, or inspectors.
    /// Apps with custom window chrome (Steam etc.) report no subrole;
    /// those are accepted if they at least have a title.
    static func isTrackableWindow(_ window: AXUIElement) -> Bool {
        guard (copyValue(window, kAXRoleAttribute) as String?) == kAXWindowRole else { return false }
        let sub = subrole(window)
        if sub == kAXStandardWindowSubrole || sub == kAXDialogSubrole {
            return true
        }
        if sub == nil || sub == "AXUnknown" {
            if !(title(window) ?? "").isEmpty {
                return true
            }
            // Steam-style: window with no subrole and no title — let the
            // window-server layer decide.
            return isNormalLayerWindow(window)
        }
        return false
    }

    static func windowID(_ window: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(window, &wid) == .success, wid != 0 else { return nil }
        return wid
    }

    /// Real windows live at layer 0; menus, popovers, and tooltips sit
    /// higher. A minimum size filters out tiny helper windows.
    static func isNormalLayerWindow(_ window: AXUIElement) -> Bool {
        guard let wid = windowID(window),
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]])?.first,
              let layer = info[kCGWindowLayer as String] as? Int,
              layer == 0 else {
            return false
        }
        if let bounds = info[kCGWindowBounds as String] as? [String: Any],
           let width = bounds["Width"] as? CGFloat,
           let height = bounds["Height"] as? CGFloat {
            return width >= 100 && height >= 50
        }
        return true
    }

    /// Windows on other Spaces drop out of the kAXWindows list, but their
    /// element stays valid — only a truly destroyed element returns
    /// invalidUIElement.
    static func isAlive(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return error != .invalidUIElement
    }

    static func isMinimized(_ window: AXUIElement) -> Bool {
        (copyValue(window, kAXMinimizedAttribute) as Bool?) ?? false
    }

    static func setMinimized(_ window: AXUIElement, _ minimized: Bool) {
        let value = (minimized ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, value)
    }

    static func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue as CFTypeRef)
    }

    static func setFocusedWindow(_ appElement: AXUIElement, _ window: AXUIElement) {
        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
    }

    static func focusedWindow(of appElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    static func pressCloseButton(_ window: AXUIElement) {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return
        }
        AXUIElementPerformAction((value as! AXUIElement), kAXPressAction as CFString)
    }

    static func isFullscreen(_ window: AXUIElement) -> Bool {
        (copyValue(window, "AXFullScreen") as Bool?) ?? false
    }

    /// Window frame in AX coordinates (origin at the top-left of the
    /// primary screen, y growing downwards).
    static func frame(_ window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, CFGetTypeID(positionRef) == AXValueGetTypeID(),
              let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue((positionRef as! AXValue), .cgPoint, &position)
        AXValueGetValue((sizeRef as! AXValue), .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    static func setSize(_ window: AXUIElement, _ size: CGSize) {
        var newSize = size
        if let value = AXValueCreate(.cgSize, &newSize) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }
}
