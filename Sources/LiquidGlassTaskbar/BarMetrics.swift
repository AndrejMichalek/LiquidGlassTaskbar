import SwiftUI

/// Shared, persisted sizing for the bar. `scale` is driven by the resize
/// handle on the dividers; every metric derives from it so the bar, its
/// buttons, and the window reserved zone all stay in sync.
final class BarMetrics: ObservableObject {
    static let shared = BarMetrics()

    static let minScale: CGFloat = 0.65
    static let maxScale: CGFloat = 1.7
    private let key = "barScale"

    @Published private(set) var scale: CGFloat

    private init() {
        let stored = UserDefaults.standard.double(forKey: key)
        scale = stored == 0 ? 1.0 : Self.clamp(CGFloat(stored))
    }

    func setScale(_ newValue: CGFloat) {
        let clamped = Self.clamp(newValue)
        guard clamped != scale else { return }
        scale = clamped
        UserDefaults.standard.set(Double(clamped), forKey: key)
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, minScale), maxScale)
    }

    var barHeight: CGFloat { (54 * scale).rounded() }
    var iconSize: CGFloat { (26 * scale).rounded() }
    var buttonHeight: CGFloat { (34 * scale).rounded() }
    var fontSize: CGFloat { (12 * scale).rounded() }
    var appsFontSize: CGFloat { (13 * scale).rounded() }
    var trailingFontSize: CGFloat { (14 * scale).rounded() }
    var dividerHeight: CGFloat { (28 * scale).rounded() }
    var cornerRadius: CGFloat { barHeight * 0.48 }
    /// Concentric with the pill: inner radius = outer radius minus the
    /// vertical inset of a button inside the bar.
    var buttonCornerRadius: CGFloat { max(6, cornerRadius - (barHeight - buttonHeight) / 2) }
    var maxTitleWidth: CGFloat { (170 * scale).rounded() }
}
