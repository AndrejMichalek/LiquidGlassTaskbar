import SwiftUI

/// The fixed utility buttons on the bar that the user can show or hide via
/// the right-click menu on the icon area. The app/window buttons in the
/// middle are dynamic and not part of this.
enum DockTool: String, CaseIterable, Identifiable {
    case apps
    case screenshot
    case emoji
    case brightness
    case showDesktop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apps: return "Apps"
        case .screenshot: return "Screenshot (⇧⌘4)"
        case .emoji: return "Emoji & Symbols"
        case .brightness: return "Display Brightness"
        case .showDesktop: return "Show Desktop"
        }
    }
}

/// Persisted set of hidden tools (empty = everything shown). Stored as a set
/// of *hidden* keys so newly added tools default to visible.
final class ToolVisibility: ObservableObject {
    static let shared = ToolVisibility()

    private let key = "hiddenDockTools"
    @Published private var hidden: Set<DockTool>

    private init() {
        let raw = UserDefaults.standard.array(forKey: key) as? [String] ?? []
        hidden = Set(raw.compactMap(DockTool.init(rawValue:)))
    }

    func isEnabled(_ tool: DockTool) -> Bool { !hidden.contains(tool) }

    func set(_ tool: DockTool, enabled: Bool) {
        if enabled { hidden.remove(tool) } else { hidden.insert(tool) }
        UserDefaults.standard.set(hidden.map(\.rawValue), forKey: key)
    }
}
