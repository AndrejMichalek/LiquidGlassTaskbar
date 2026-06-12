# Design document — Windows 7 style taskbar for macOS Tahoe

The original design plan for this project. The implemented behavior is
documented in [README.md](README.md); this file records the architecture
and the reasoning behind the technology choices.

## Goal

A system Dock replacement that behaves like the Windows 7 taskbar:

- **1 window = 1 button** in the bar (app icon + window title)
- a minimized window stays in the bar as an item; clicking restores it
- clicking the *active* window's button minimizes it (Win7 toggle)
- apps with no open windows don't show at all
- an **"Apps"** button on the left — a launcher for all installed apps

## Feasibility — three honest constraints

1. **The system Dock cannot be disabled.** `Dock.app` is a system process
   (it also runs Mission Control). The standard trick, used by uBar as well:
   enable autohide with a huge delay — the Dock then never appears:
   ```sh
   defaults write com.apple.dock autohide -bool true
   defaults write com.apple.dock autohide-delay -float 1000
   killall Dock
   ```
   Fully reversible (the app restores it on quit).
2. **Accessibility permission.** The app cannot be sandboxed → not App
   Store distributable; built locally. It requests Accessibility on first
   launch.
3. **Reserving screen space** (so maximized windows don't extend beneath
   the bar) has no public API. The bar floats *above* normal windows;
   fullscreen windows live in their own Spaces where the bar stays out of
   the way.

## Technology

**Swift + AppKit (NSPanel) + SwiftUI** for the bar content. No
Electron/Tauri — the dock runs permanently, needs native C APIs
(Accessibility) and ~0% idle CPU.

| Task | API |
|---|---|
| Window lists, titles, minimized state, raise/minimize/close | Accessibility: `AXUIElement` + `AXObserver` |
| App lifecycle (launch/terminate/activate) | `NSWorkspace` notifications |
| App icons | `NSRunningApplication.icon` |
| Cross-Space window detection | `CGWindowListCopyWindowInfo` |
| Hover window previews (future) | `ScreenCaptureKit` (needs Screen Recording) |
| Launch at login | `SMAppService` |

Window titles come from the AX API (Accessibility permission suffices);
via CGWindowList they would require Screen Recording, which the app avoids.

Real-time updates ride on AX notifications: `kAXWindowCreatedNotification`,
`kAXUIElementDestroyedNotification`, `kAXTitleChangedNotification`,
`kAXWindowMiniaturizedNotification`, `kAXWindowDeminiaturizedNotification`,
`kAXFocusedWindowChangedNotification`. One `AXObserver` per process,
registered on app launch (NSWorkspace), removed on terminate.

### Building without Xcode

SwiftPM executable target + a script that assembles the `.app` bundle:

```
swift build -c release
→ CustomMacDock.app/Contents/{MacOS/CustomMacDock, Info.plist}
→ codesign
```

- `Info.plist`: `LSUIElement = true` (no dock icon of its own)
- **Signing:** TCC ties the Accessibility grant to bundle ID + code
  signature. Ad-hoc signatures change on every build → the permission would
  reset. Solution: a self-signed code-signing certificate in the keychain,
  used consistently (see README).

## Architecture

```
CustomMacDock.app
├── WindowTracker        AXObserver per app + NSWorkspace → @Published model
│     DockItem { windowID?, pid?, bundleID, title, icon, isMinimized,
│                isFocused, isPinned, isAttention }
├── DockPanel            NSPanel: above normal windows, .canJoinAllSpaces,
│                        pinned to the bottom edge
├── DockBarView (SwiftUI)  [Apps] │ [win 1][win 2]… │ [screenshot][desktop]
├── Actions              left click: restore+raise+activate / minimize when active
│                        right click: menu (New Window, Restore, Minimize,
│                        Close, Pin/Unpin, Hide, Quit)
├── AppsLauncherView     fallback grid of /Applications with search
├── SystemActions        Show Desktop, region screenshot, synthetic keystrokes
└── SystemDockManager    hides the system Dock + restores it on quit
```

Window filtering: standard windows and dialogs by AX subrole; windows
without a subrole (Steam-style custom chrome) are accepted based on their
window-server layer and size.

## Milestones

- **M0 — skeleton:** SwiftPM project + bundle build script, Accessibility
  prompt, bottom bar, window list of running apps, click to focus.
- **M1 — real-time + Win7 behavior:** AX observers, minimize-on-active-click,
  visual states, stable ordering, context menu.
- **M2 — full Dock replacement:** Apps launcher, system Dock hiding, login
  item, settings.
- **M3 — polish:** notification highlight, Show Desktop, screenshot button,
  extended dock-menu actions. (Hover previews, drag-reorder, multi-monitor:
  future.)

## Risks and gotchas encountered

- Apps with poor AX trees (Steam exposes only a 1×1 helper window) —
  solved via CGWindowList cross-referencing.
- The AX API doesn't return windows on unvisited Spaces — solved with
  app-level buttons + persistent tracking once seen.
- macOS 14+ cooperative activation silently ignores `activate()` from
  background apps — solved by activating through LaunchServices
  (`open -b`).
- The Tahoe Dock renamed its show-desktop notification to
  `com.apple.showdesktop.awake`.
- TCC resets the Accessibility grant when the code signature changes —
  solved with a stable self-signed certificate.

## Prior art

- **uBar** — commercial Windows-style taskbar, works on Tahoe
- **AltTab** — open source window-level switcher built on the same AX APIs
- **DockDoor** — open source hover window previews (reference for future work)
