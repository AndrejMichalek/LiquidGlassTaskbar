import AppKit
import SwiftUI

struct LauncherApp: Identifiable {
    let url: URL
    let name: String
    let icon: NSImage
    var id: String { url.path }
}

final class AppsModel: ObservableObject {
    @Published var apps: [LauncherApp] = []

    func reload() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = Self.scan()
            DispatchQueue.main.async {
                self?.apps = found
            }
        }
    }

    private static func scan() -> [LauncherApp] {
        let fm = FileManager.default
        var dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities"]
        dirs.append((NSHomeDirectory() as NSString).appendingPathComponent("Applications"))

        var seen = Set<String>()
        var result: [LauncherApp] = []

        func add(_ url: URL) {
            let path = url.path
            guard seen.insert(path).inserted else { return }
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 48, height: 48)
            result.append(LauncherApp(url: url, name: fm.displayName(atPath: path), icon: icon))
        }

        for dir in dirs {
            let dirURL = URL(fileURLWithPath: dir)
            guard let entries = try? fm.contentsOfDirectory(at: dirURL,
                                                            includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles]) else { continue }
            for url in entries {
                if url.pathExtension == "app" {
                    add(url)
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    // one level of subfolders (vendor folders and the like)
                    if let sub = try? fm.contentsOfDirectory(at: url,
                                                             includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles]) {
                        for subURL in sub where subURL.pathExtension == "app" {
                            add(subURL)
                        }
                    }
                }
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Win7 "Start menu" — a grid of all installed applications shown above
/// the Apps button.
final class AppsLauncherController: NSObject, NSWindowDelegate {
    private static let panelSize = NSSize(width: 560, height: 460)

    private let model = AppsModel()
    private lazy var panel: KeyablePanel = {
        let panel = KeyablePanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                                 styleMask: [.borderless],
                                 backing: .buffered,
                                 defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        return panel
    }()

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func show() {
        model.reload()
        // Fresh root view so the search query and focus reset.
        panel.contentView = NSHostingView(rootView: AppsGridView(
            model: model,
            onLaunch: { [weak self] in self?.hide() },
            onClose: { [weak self] in self?.hide() }
        ))
        if let screen = NSScreen.screens.first {
            let origin = NSPoint(x: screen.frame.minX + 8,
                                 y: screen.frame.minY + DockPanelController.barHeight + 8)
            panel.setFrame(NSRect(origin: origin, size: Self.panelSize), display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}

private struct AppsGridView: View {
    @ObservedObject var model: AppsModel
    var onLaunch: () -> Void
    var onClose: () -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [LauncherApp] {
        guard !query.isEmpty else { return model.apps }
        return model.apps.filter {
            $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            TextField("Search applications…", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit {
                    if let first = filtered.first {
                        launch(first)
                    }
                }
            if model.apps.isEmpty {
                Spacer()
                ProgressView()
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 12) {
                        ForEach(filtered) { app in
                            Button(action: { launch(app) }) {
                                VStack(spacing: 4) {
                                    Image(nsImage: app.icon)
                                        .resizable()
                                        .frame(width: 48, height: 48)
                                    Text(app.name)
                                        .font(.caption)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(width: 96)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(12)
        .frame(width: 560, height: 460)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.15)))
        .onAppear { searchFocused = true }
        .onExitCommand { onClose() }
    }

    private func launch(_ app: LauncherApp) {
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
        onLaunch()
    }
}
