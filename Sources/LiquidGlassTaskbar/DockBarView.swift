import AppKit
import SwiftUI

/// Button frames in the "bar" coordinate space, for routing clicks on the
/// bottom edge strip to the button above. Reference type on purpose —
/// frame updates must not trigger re-renders.
private final class BarGeometry: ObservableObject {
    var frames: [String: CGRect] = [:]
}

struct DockBarView: View {
    @ObservedObject var tracker: WindowTracker
    var onCustomLauncher: () -> Void
    @StateObject private var geometry = BarGeometry()

    var body: some View {
        HStack(spacing: 8) {
            AppsButton(onCustomLauncher: onCustomLauncher)
                .reportBarFrame(id: "apps", into: geometry)
            barDivider
            if !tracker.started {
                Text("Grant LiquidGlassTaskbar access in System Settings → Privacy & Security → Accessibility")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            // Hug the content while it fits; fall back to a scrolling row
            // that takes the full width when there are too many windows.
            ViewThatFits(in: .horizontal) {
                itemsRow
                ScrollView(.horizontal, showsIndicators: false) {
                    itemsRow
                }
            }
            barDivider
            TrailingIconButton(systemName: "camera.viewfinder",
                               help: "Screenshot selection (⇧⌘4)") {
                SystemActions.screenshotSelection()
            }
            .reportBarFrame(id: "screenshot", into: geometry)
            TrailingIconButton(systemName: "display",
                               help: "Show Desktop") {
                SystemActions.showDesktop()
            }
            .reportBarFrame(id: "desktop", into: geometry)
        }
        .padding(.horizontal, 12)
        .frame(height: DockPanelController.barHeight)
        // One Liquid Glass pill hugging its content, centered like the Dock.
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .padding(.bottom, DockPanelController.bottomInset)
        // Faint shadow strip under the pill — alpha above the window
        // server's click-through threshold, so bottom-edge clicks stay in
        // our window; the tap handler routes them to the button above.
        .background(alignment: .bottom) {
            Color.black.opacity(0.1)
                .frame(height: DockPanelController.bottomInset)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .named("bar")) { location in
                    handleEdgeClick(atX: location.x)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: "bar")
        // Animates item changes and the pill width following them — buttons
        // morph between icon-only and icon+title states.
        .animation(.smooth(duration: 0.3), value: tracker.items)
    }

    private var itemsRow: some View {
        HStack(spacing: 4) {
            ForEach(tracker.items) { item in
                DockItemButton(item: item, tracker: tracker)
                    .transition(.blurReplace)
                    .reportBarFrame(id: "item-\(item.id)", into: geometry)
            }
        }
    }

    /// A click on the bottom strip acts as a click on the button above it.
    private func handleEdgeClick(atX x: CGFloat) {
        func hit(_ id: String) -> Bool {
            guard let frame = geometry.frames[id] else { return false }
            return x >= frame.minX && x <= frame.maxX
        }
        if hit("apps") {
            if !SystemActions.openSystemAppsWindow() { onCustomLauncher() }
            return
        }
        if hit("screenshot") {
            SystemActions.screenshotSelection()
            return
        }
        if hit("desktop") {
            SystemActions.showDesktop()
            return
        }
        // Only current items — stale frames of removed buttons never match.
        for item in tracker.items where hit("item-\(item.id)") {
            if let windowID = item.windowID {
                tracker.handlePrimaryClick(windowID)
            } else {
                tracker.handlePlaceholderClick(item)
            }
            return
        }
    }

    private var barDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.2))
            .frame(width: 1, height: 28)
    }
}

private extension View {
    func reportBarFrame(id: String, into geometry: BarGeometry) -> some View {
        onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("bar")) }) { frame in
            geometry.frames[id] = frame
        }
    }
}

/// Button hit area extended below its visual bounds down to the screen
/// edge, so a click with the cursor slammed to the bottom still lands on
/// the button above it.
private struct EdgeReachShape: Shape {
    var cornerRadius: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        var path = RoundedRectangle(cornerRadius: cornerRadius).path(in: rect)
        path.addRect(CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 40))
        return path
    }
}

private struct AppsButton: View {
    var onCustomLauncher: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: openSystemApps) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x3.fill")
                Text("Apps").fontWeight(.semibold)
            }
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(hovering ? 0.9 : 0.7))
            )
            .contentShape(EdgeReachShape())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("All applications")
        .contextMenu {
            Button("Searchable app grid…") { onCustomLauncher() }
        }
    }

    private func openSystemApps() {
        if !SystemActions.openSystemAppsWindow() {
            onCustomLauncher()
        }
    }
}

private struct TrailingIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14))
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(hovering ? Color.primary.opacity(0.16) : Color.primary.opacity(0.06))
                )
                .contentShape(EdgeReachShape())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct DockItemButton: View {
    let item: DockItem
    let tracker: WindowTracker
    @State private var hovering = false

    var body: some View {
        Button(action: primaryAction) {
            HStack(spacing: 6) {
                Group {
                    if let icon = item.icon {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: "app.dashed").resizable()
                    }
                }
                .frame(width: 26, height: 26)
                .opacity(item.isMinimized ? 0.5 : 1)

                if showsTitle {
                    Text(item.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(titleColor)
                        .frame(width: titleWidth, alignment: .leading)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(backgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(item.isFocused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08),
                            lineWidth: 1)
            )
            .contentShape(EdgeReachShape())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(item.isPlaceholder ? "Launch \(item.appName)" : item.title)
        .contextMenu { contextMenuItems }
    }

    private func primaryAction() {
        if let windowID = item.windowID {
            tracker.handlePrimaryClick(windowID)
        } else {
            tracker.handlePlaceholderClick(item)
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if let windowID = item.windowID {
            Button("New Window") { tracker.newWindow(item) }
            Divider()
            if item.isMinimized {
                Button("Restore") { tracker.restore(windowID) }
            } else {
                Button("Minimize") { tracker.minimize(windowID) }
            }
            Button("Close Window") { tracker.closeWindow(windowID) }
            Divider()
            if item.isPinned {
                Button("Unpin \(item.appName)") { tracker.unpinApp(bundleID: item.bundleID) }
            } else {
                Button("Pin \(item.appName)") { tracker.pinApp(windowID: windowID) }
            }
            Divider()
            Button("Hide \(item.appName)") { tracker.hideApp(item) }
            Button("Quit \(item.appName)") { tracker.quitApp(windowID) }
        } else {
            Button(item.pid != nil ? "Activate \(item.appName)" : "Launch \(item.appName)") {
                tracker.handlePlaceholderClick(item)
            }
            Button("New Window") { tracker.newWindow(item) }
            Divider()
            if item.isPinned {
                Button("Unpin") { tracker.unpinApp(bundleID: item.bundleID) }
            } else {
                Button("Pin") { tracker.pinAppByBundleID(item.bundleID) }
            }
            if item.pid != nil {
                Divider()
                Button("Hide \(item.appName)") { tracker.hideApp(item) }
                Button("Quit \(item.appName)") { tracker.quitAppByPid(item.pid) }
            }
        }
    }

    /// Pinned apps without windows show as icon-only buttons (Win7 style).
    private var showsTitle: Bool {
        !(item.isPlaceholder && item.isPinned)
    }

    /// Exact text width so buttons hug short titles; long ones cap and
    /// truncate with an ellipsis.
    private var titleWidth: CGFloat {
        let size = (item.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
        return min(ceil(size.width) + 2, 170)
    }

    private var titleColor: Color {
        if item.isPlaceholder { return Color.secondary }
        return item.isMinimized ? Color.secondary : Color.primary
    }

    private var backgroundColor: Color {
        // An unanswered notification takes precedence over everything
        // (the Win7 taskbar flash).
        if item.isAttention { return Color.orange.opacity(0.5) }
        if item.isFocused { return Color.accentColor.opacity(0.3) }
        if hovering { return Color.primary.opacity(0.16) }
        if item.isPlaceholder { return Color.primary.opacity(0.03) }
        if item.isMinimized { return Color.primary.opacity(0.04) }
        return Color.primary.opacity(0.09)
    }
}
