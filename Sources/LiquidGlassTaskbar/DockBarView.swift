import AppKit
import SwiftUI

struct DockBarView: View {
    @ObservedObject var tracker: WindowTracker
    var onCustomLauncher: () -> Void

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
        .frame(maxHeight: .infinity)
        // One Liquid Glass pill hugging its content, centered like the Dock.
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var itemsRow: some View {
        HStack(spacing: 4) {
            ForEach(tracker.items) { item in
                DockItemButton(item: item, tracker: tracker)
            }
        }
    }

    private var barDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.2))
            .frame(width: 1, height: 28)
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
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("All applications")
        .contextMenu {
            Button("Searchable app grid…") { onCustomLauncher() }
        }
    }

    private func openSystemApps() {
        // The system "Apps" window of macOS Tahoe (Launchpad's replacement)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.apps.launcher") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
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
                .contentShape(RoundedRectangle(cornerRadius: 8))
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

                Text(item.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(titleColor)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .frame(minWidth: 64, maxWidth: 220, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(backgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(item.isFocused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08),
                            lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
