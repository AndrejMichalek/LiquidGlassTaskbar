import AppKit
import SwiftUI

struct DockBarView: View {
    @ObservedObject var tracker: WindowTracker
    @ObservedObject private var metrics = BarMetrics.shared
    var onCustomLauncher: () -> Void
    var onResize: () -> Void

    @State private var dragStartScale: CGFloat?

    // Drag-to-reorder state. `dragKey` is the app group currently lifted,
    // `dragTranslation` the finger delta, `groupFrames` each group's layout
    // rect (captured continuously), and `dragOrigin` a snapshot of the order
    // and frames at drag start so live republishes can't disturb the math.
    @State private var dragKey: String?
    @State private var dragTranslation: CGFloat = 0
    @State private var groupFrames: [String: CGRect] = [:]
    @State private var dragOrigin: DragOrigin?

    var body: some View {
        HStack(spacing: 8) {
            AppsButton(onCustomLauncher: onCustomLauncher)
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
            TrailingIconButton(systemName: "display",
                               help: "Show Desktop") {
                SystemActions.showDesktop()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: metrics.barHeight)
        // One Liquid Glass pill hugging its content, centered like the Dock.
        .glassEffect(.regular, in: .rect(cornerRadius: metrics.cornerRadius))
        // Pinned to the bottom so resizing grows the bar upward, keeping
        // the bottom edge fixed.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        // Animates item changes and the pill width following them — buttons
        // morph between icon-only and icon+title states.
        .animation(.smooth(duration: 0.3), value: tracker.items)
    }

    private var itemsRow: some View {
        HStack(spacing: 4) {
            ForEach(groups) { group in
                groupView(group)
                    .transition(.blurReplace)
            }
        }
        .coordinateSpace(.named("dockbar"))
        .onPreferenceChange(GroupFramePreference.self) { groupFrames = $0 }
    }

    /// Consecutive items belonging to one app, collapsed into a single
    /// draggable unit so all of an app's windows move together.
    private var groups: [ItemGroup] {
        var result: [ItemGroup] = []
        for item in tracker.items {
            if let last = result.last, last.key == item.orderKey {
                result[result.count - 1].items.append(item)
            } else {
                result.append(ItemGroup(key: item.orderKey, items: [item]))
            }
        }
        return result
    }

    @ViewBuilder
    private func groupView(_ group: ItemGroup) -> some View {
        let dragging = dragKey == group.key
        let offsetX = dragging ? dragTranslation : gapOffset(for: group)
        HStack(spacing: 4) {
            ForEach(group.items) { item in
                DockItemButton(item: item,
                               tracker: tracker,
                               onDragChanged: { handleDragChanged(group, $0) },
                               onDragEnded: { handleDragEnded(group, $0) })
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: GroupFramePreference.self,
                                       value: [group.key: geo.frame(in: .named("dockbar"))])
            }
        )
        .offset(x: offsetX)
        .scaleEffect(dragging ? 1.05 : 1)
        .opacity(dragging ? 0.9 : 1)
        .zIndex(dragging ? 1 : 0)
        // The lifted group follows the finger with no animation; the others
        // spring aside to open the gap.
        .animation(dragging ? nil : .spring(response: 0.28, dampingFraction: 0.82),
                   value: offsetX)
    }

    // MARK: - Reorder math

    private func handleDragChanged(_ group: ItemGroup, _ translation: CGFloat) {
        if dragKey == nil {
            dragKey = group.key
            dragOrigin = DragOrigin(order: groups.map(\.key), frames: groupFrames)
        }
        dragTranslation = translation
    }

    private func handleDragEnded(_ group: ItemGroup, _ translation: CGFloat) {
        defer {
            dragKey = nil
            dragTranslation = 0
            dragOrigin = nil
        }
        guard let origin = dragOrigin,
              let from = origin.order.firstIndex(of: group.key),
              let frame = origin.frames[group.key] else { return }
        let target = insertionIndex(origin: origin, dragKey: group.key,
                                    fingerX: frame.midX + translation)
        var order = origin.order
        order.remove(at: from)
        order.insert(group.key, at: min(max(target, 0), order.count))
        tracker.setAppOrder(order)
    }

    /// Where the dragged group would land: the count of *other* groups whose
    /// center sits left of the finger.
    private func insertionIndex(origin: DragOrigin, dragKey: String, fingerX: CGFloat) -> Int {
        origin.order.reduce(0) { count, key in
            guard key != dragKey, let f = origin.frames[key], f.midX < fingerX else { return count }
            return count + 1
        }
    }

    /// Sideways shift for a non-dragged group so the row opens a gap at the
    /// drop target and closes the one the dragged group left behind.
    private func gapOffset(for group: ItemGroup) -> CGFloat {
        guard let dragKey, let origin = dragOrigin, group.key != dragKey,
              let from = origin.order.firstIndex(of: dragKey),
              let dragged = origin.frames[dragKey],
              let idx = origin.order.firstIndex(of: group.key) else { return 0 }
        let width = dragged.width + 4 // group width plus the HStack spacing
        let target = insertionIndex(origin: origin, dragKey: dragKey,
                                    fingerX: dragged.midX + dragTranslation)
        let othersIndex = idx < from ? idx : idx - 1
        let shiftedForGap = othersIndex >= target ? 1 : 0
        let closedVacated = idx > from ? 1 : 0
        return CGFloat(shiftedForGap - closedVacated) * width
    }

    /// Divider doubles as a resize handle: hovering shows the up/down
    /// resize cursor, and a vertical drag changes the bar's scale (the
    /// panel observes the scale and reframes itself). The visible line is
    /// 1pt; horizontal padding widens the grab area.
    private var barDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.25))
            .frame(width: 1, height: metrics.dividerHeight)
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
            // Declarative, system-managed cursor region — survives this app
            // never being frontmost, unlike imperative NSCursor.set().
            .pointerStyle(.rowResize)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartScale ?? metrics.scale
                        if dragStartScale == nil { dragStartScale = start }
                        // Keep the resize cursor while the pointer strays
                        // outside the narrow handle mid-drag.
                        if backgroundCursorEnabled { NSCursor.resizeUpDown.set() }
                        // Dragging up (negative height) enlarges the bar.
                        metrics.setScale(start - value.translation.height / 110)
                        onResize()
                    }
                    .onEnded { _ in dragStartScale = nil }
            )
    }
}

/// One app's contiguous run of items, dragged as a single unit.
private struct ItemGroup: Identifiable {
    let key: String
    var items: [DockItem]
    var id: String { key }
}

/// Order and geometry captured at the start of a reorder drag, so the math
/// stays stable even if the tracker republishes mid-drag.
private struct DragOrigin {
    let order: [String]
    let frames: [String: CGRect]
}

/// Collects each group's layout rect (in the "dockbar" space) for reorder
/// hit-testing.
private struct GroupFramePreference: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// Private WindowServer API (SkyLight). The window server only honors
// NSCursor changes from the frontmost app — which an .accessory app with a
// non-activating panel never is. The "SetsCursorInBackground" connection
// property opts this app out of that rule (same trick AltTab uses), so the
// resize cursor can be held while a drag strays outside the handle.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> UInt32

@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ cid: UInt32, _ targetCID: UInt32,
                                      _ key: CFString, _ value: CFTypeRef) -> CGError

private let backgroundCursorEnabled: Bool = {
    let cid = CGSMainConnectionID()
    return CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == .success
}()

private struct AppsButton: View {
    var onCustomLauncher: () -> Void
    @ObservedObject private var metrics = BarMetrics.shared
    @State private var hovering = false

    var body: some View {
        Button(action: openSystemApps) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x3.fill")
                Text("Apps").fontWeight(.semibold)
            }
            .font(.system(size: metrics.appsFontSize))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: metrics.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: metrics.buttonCornerRadius)
                    .fill(Color.accentColor.opacity(hovering ? 0.9 : 0.7))
            )
            .contentShape(RoundedRectangle(cornerRadius: metrics.buttonCornerRadius))
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
    @ObservedObject private var metrics = BarMetrics.shared
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: metrics.trailingFontSize))
                .frame(width: metrics.buttonHeight, height: metrics.buttonHeight)
                .background(
                    RoundedRectangle(cornerRadius: metrics.buttonCornerRadius)
                        .fill(hovering ? Color.primary.opacity(0.16) : Color.primary.opacity(0.06))
                )
                .contentShape(RoundedRectangle(cornerRadius: metrics.buttonCornerRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct DockItemButton: View {
    let item: DockItem
    let tracker: WindowTracker
    var onDragChanged: (CGFloat) -> Void
    var onDragEnded: (CGFloat) -> Void
    @ObservedObject private var metrics = BarMetrics.shared
    @State private var hovering = false

    var body: some View {
        label
            .contentShape(RoundedRectangle(cornerRadius: metrics.buttonCornerRadius))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help(item.isPlaceholder ? "Launch \(item.appName)" : item.title)
            .onTapGesture { primaryAction() }
            // Reorder drag. Global space keeps the translation stable while
            // the group is offset; the 8 pt threshold lets a plain click fall
            // through to the tap handler above.
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .global)
                    .onChanged { onDragChanged($0.translation.width) }
                    .onEnded { onDragEnded($0.translation.width) }
            )
            .contextMenu { contextMenuItems }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Group {
                if let icon = item.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable()
                }
            }
            .frame(width: metrics.iconSize, height: metrics.iconSize)
            .opacity(item.isMinimized ? 0.5 : 1)

            if showsTitle {
                Text(item.title)
                    .font(.system(size: metrics.fontSize))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(titleColor)
                    .frame(width: titleWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: metrics.buttonHeight)
        .background(RoundedRectangle(cornerRadius: metrics.buttonCornerRadius).fill(backgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: metrics.buttonCornerRadius)
                .stroke(item.isFocused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08),
                        lineWidth: 1)
        )
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
    /// truncate with an ellipsis. Scales with the bar.
    private var titleWidth: CGFloat {
        let size = (item.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: metrics.fontSize)])
        return min(ceil(size.width) + 2, metrics.maxTitleWidth)
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
