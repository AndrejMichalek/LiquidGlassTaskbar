import AppKit
import CoreGraphics
import IOKit

/// DDC/CI brightness control for external displays on Apple Silicon.
///
/// macOS has no public API for third-party monitor backlight, so this talks
/// to the monitor over the I²C side channel of the video link — VCP feature
/// 0x10 (luminance) of the DDC/CI spec — the same approach MonitorControl
/// and Lunar use. On Apple Silicon the bus is reached through the private
/// `IOAVService*` IOKit functions (the old Intel `IOI2C*`/`IOFramebuffer`
/// path doesn't exist on the iOS-derived kernel). Built-in and Apple
/// displays use a different protocol and are intentionally ignored.
enum DDC {
    /// 7-bit DDC/CI slave address and the data offset, per the spec.
    private static let address: UInt8 = 0x37
    private static let dataAddress: UInt8 = 0x51
    /// VCP feature code for luminance (brightness).
    private static let vcpBrightness: UInt8 = 0x10

    /// An external display paired with the AV service that drives its bus.
    struct Display {
        let id: CGDirectDisplayID
        let name: String
        let service: CFTypeRef
    }

    // MARK: - Public API

    /// Every online external (non-built-in) display matched to an
    /// IOAVService over which DDC can be sent. Empty on Intel, when no
    /// external display is attached, or when none expose an AV service.
    static func externalDisplays() -> [Display] {
        let displays = onlineExternalDisplays()
        guard !displays.isEmpty else { return [] }
        let candidates = externalAVServices()
        guard !candidates.isEmpty else { return [] }

        // Greedy best-match: highest-scoring (display, service) pairs first,
        // each display and each service used once. With the common single
        // external display the score is often 0 and it simply takes the lone
        // service.
        var result: [Display] = []
        var usedService = Set<Int>()
        var usedDisplay = Set<CGDirectDisplayID>()
        let scored = displays.flatMap { display in
            candidates.enumerated().map { index, candidate in
                (score: matchScore(display: display, candidate: candidate),
                 display: display, index: index, service: candidate.service)
            }
        }
        .sorted { $0.score > $1.score }
        for pair in scored where !usedService.contains(pair.index) && !usedDisplay.contains(pair.display.id) {
            usedService.insert(pair.index)
            usedDisplay.insert(pair.display.id)
            result.append(Display(id: pair.display.id, name: pair.display.name, service: pair.service))
        }
        // Stable left-to-right order by display ID.
        return result.sorted { $0.id < $1.id }
    }

    /// Send a brightness level (0...100) to a display over DDC. Returns the
    /// raw IOReturn of the last write cycle (0 = success, -999 = symbol
    /// missing). Blocking — call off the main thread.
    @discardableResult
    static func writeBrightness(service: CFTypeRef, level: UInt16) -> Int32 {
        guard let writeI2C = ioavWriteI2C else { return -999 }
        let value = min(level, 100)
        let send: [UInt8] = [vcpBrightness, UInt8(value >> 8), UInt8(value & 0xFF)]
        // DDC/CI set-VCP frame: length byte, command, payload, checksum.
        var packet: [UInt8] = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
        packet[packet.count - 1] = checksum(seed: (address << 1) ^ dataAddress,
                                            data: packet, through: packet.count - 2)
        var result: Int32 = -1
        // Two write cycles with a short settle, like the reference clients —
        // some panels drop the first transaction.
        for _ in 0 ..< 2 {
            usleep(10000)
            result = writeI2C(service, UInt32(address), UInt32(dataAddress), &packet, UInt32(packet.count))
        }
        return result
    }

    // MARK: - Display enumeration

    private static func onlineExternalDisplays() -> [(id: CGDirectDisplayID, name: String, serial: UInt32)] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.compactMap { id in
            guard CGDisplayIsBuiltin(id) == 0 else { return nil }
            return (id, screenName(for: id) ?? "Display \(id)", CGDisplaySerialNumber(id))
        }
    }

    private static func screenName(for id: CGDirectDisplayID) -> String? {
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               number.uint32Value == id {
                return screen.localizedName
            }
        }
        return nil
    }

    // MARK: - IOAVService discovery

    private struct AVServiceCandidate {
        let service: CFTypeRef
        let productName: String?
        let serialNumber: Int64?
    }

    /// Walk the IORegistry pairing each external `DCPAVServiceProxy` (the I²C
    /// endpoint) with the product info of the framebuffer it sits under.
    private static func externalAVServices() -> [AVServiceCandidate] {
        guard let createService = ioavCreateWithService else { return [] }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return [] }
        defer { IOObjectRelease(root) }
        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(root, kIOServicePlane,
                                            IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        let framebufferClasses: Set<String> = ["AppleCLCD2", "IOMobileFramebufferShim"]
        var pending: (productName: String?, serial: Int64?)?
        var candidates: [AVServiceCandidate] = []

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let className = IOObjectCopyClass(entry).takeRetainedValue() as String
            if framebufferClasses.contains(className) {
                pending = framebufferProductInfo(entry)
            } else if className == "DCPAVServiceProxy" {
                guard copyStringProperty(entry, "Location") == "External",
                      let service = createService(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                candidates.append(AVServiceCandidate(service: service,
                                                     productName: pending?.productName,
                                                     serialNumber: pending?.serial))
            }
        }
        return candidates
    }

    private static func framebufferProductInfo(_ entry: io_registry_entry_t) -> (productName: String?, serial: Int64?) {
        guard let attributes = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString,
                                                               kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSDictionary,
            let product = attributes["ProductAttributes"] as? NSDictionary else {
            return (nil, nil)
        }
        return (product["ProductName"] as? String,
                (product["SerialNumber"] as? NSNumber)?.int64Value)
    }

    private static func copyStringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    private static func matchScore(display: (id: CGDirectDisplayID, name: String, serial: UInt32),
                                   candidate: AVServiceCandidate) -> Int {
        var score = 0
        if let name = candidate.productName, !name.isEmpty,
           display.name.localizedCaseInsensitiveContains(name)
            || name.localizedCaseInsensitiveContains(display.name) {
            score += 5
        }
        if let serial = candidate.serialNumber, serial != 0, display.serial != 0,
           UInt32(truncatingIfNeeded: serial) == display.serial {
            score += 5
        }
        return score
    }

    // MARK: - Checksum

    private static func checksum(seed: UInt8, data: [UInt8], through end: Int) -> UInt8 {
        var value = seed
        for i in 0 ... end { value ^= data[i] }
        return value
    }
}

// MARK: - Private IOKit symbols

// IOAVService* are exported by IOKit but absent from public headers; resolve
// them at runtime so a missing symbol degrades to "no DDC" instead of a link
// error (same dlsym approach as CoreDockSendNotification).
private let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

private typealias IOAVServiceCreateWithServiceFn =
    @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
private typealias IOAVServiceWriteI2CFn =
    @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutablePointer<UInt8>, UInt32) -> Int32

private let ioavCreateWithService: IOAVServiceCreateWithServiceFn? = {
    guard let symbol = dlsym(rtldDefault, "IOAVServiceCreateWithService") else { return nil }
    return unsafeBitCast(symbol, to: IOAVServiceCreateWithServiceFn.self)
}()

private let ioavWriteI2C: IOAVServiceWriteI2CFn? = {
    guard let symbol = dlsym(rtldDefault, "IOAVServiceWriteI2C") else { return nil }
    return unsafeBitCast(symbol, to: IOAVServiceWriteI2CFn.self)
}()
