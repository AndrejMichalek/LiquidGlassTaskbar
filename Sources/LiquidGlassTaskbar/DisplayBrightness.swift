import AppKit
import CoreGraphics

/// Tracks external displays and drives their brightness over DDC. Brightness
/// is stored per display (keyed by stable hardware identity) because reading
/// it back over DDC is unreliable on most monitors — the slider reflects the
/// last value we set, like MonitorControl/Lunar do.
final class DisplayBrightnessManager: ObservableObject {
    static let shared = DisplayBrightnessManager()

    struct ExternalDisplay: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        let service: CFTypeRef
        var brightness: Double // 0...1
    }

    @Published private(set) var displays: [ExternalDisplay] = []

    private let defaultsPrefix = "extBrightness_"
    private let writeQueue = DispatchQueue(label: "sk.michalek.LiquidGlassTaskbar.ddc")
    // Coalesced write state: the newest pending level per display, guarded by
    // `lock`. While a drain is running, fresh values overwrite the pending
    // entry instead of queuing, so a drag never backs up the I²C bus.
    private let lock = NSLock()
    private var pending: [CGDirectDisplayID: (level: UInt16, service: CFTypeRef)] = [:]
    private var draining = false

    private init() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Re-enumerate displays and seed each slider from its stored level.
    func refresh() {
        displays = DDC.externalDisplays().map { display in
            let stored = UserDefaults.standard.object(forKey: key(display.id)) as? Double
            return ExternalDisplay(id: display.id,
                                   name: display.name,
                                   service: display.service,
                                   brightness: stored ?? 0.8)
        }
    }

    /// Set a display's brightness (0...1): persist it, update the slider, and
    /// push it to the monitor. Rapid changes during a drag are coalesced so
    /// the I²C bus never backs up.
    func setBrightness(_ value: Double, for id: CGDirectDisplayID) {
        let clamped = min(max(value, 0), 1)
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        displays[index].brightness = clamped
        UserDefaults.standard.set(clamped, forKey: key(id))

        let level = UInt16((clamped * 100).rounded())
        let service = displays[index].service
        lock.lock()
        pending[id] = (level, service)
        let startDrain = !draining
        if startDrain { draining = true }
        lock.unlock()
        if startDrain {
            writeQueue.async { [weak self] in self?.drain() }
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let next = pending.popFirst() else {
                draining = false
                lock.unlock()
                return
            }
            lock.unlock()
            DDC.writeBrightness(service: next.value.service, level: next.value.level)
        }
    }

    private func key(_ id: CGDirectDisplayID) -> String {
        "\(defaultsPrefix)\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }
}
