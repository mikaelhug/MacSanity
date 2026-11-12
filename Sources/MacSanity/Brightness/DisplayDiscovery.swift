import AppKit
import CMacSanitySPI
import CoreGraphics
import IOKit

/// An opened IOAVService (the DDC/CI transport for one external display). Holds
/// its own reference to the `DCPAVServiceProxy` registry entry for as long as the
/// AV service lives, rather than relying on the private API to retain it. The
/// refs are immutable and only ever used from one `DDCDevice`'s serial queue.
final class AVService: @unchecked Sendable {
    let ref: CFTypeRef
    /// Registry entry ID of the proxy — identifies this exact connection, so a
    /// rediscovery can tell "same monitor, same transport" from a replug.
    let entryID: UInt64
    private let entry: io_service_t

    /// Retains `entry`; returns nil if no AV service can be opened on it.
    init?(entry: io_service_t) {
        guard let ref = MSAVServiceCreate(entry) else { return nil }
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        IOObjectRetain(entry)
        self.ref = ref
        self.entry = entry
        self.entryID = id
    }

    deinit { IOObjectRelease(entry) }
}

/// An external display that has a DDC-capable transport. Whether it actually
/// *answers* DDC is decided later by probing (see `BrightnessController`).
struct DisplayCandidate {
    let displayID: CGDirectDisplayID
    /// Stable across reconnects and launches: vendor-model-serial.
    let key: String
    let name: String
    let avService: AVService
    /// The display's DCP framebuffer node (`dispextN`).
    let port: String
}

/// Maps each online external `CGDirectDisplayID` to the `DCPAVServiceProxy` that
/// drives its DDC channel on Apple Silicon.
///
/// Registry layout (macOS 26):
///   …/dispext0@A0000000/IOMobileFramebufferShim                    ← the framebuffer
///   …/dcpext0@…/…/dispext0:dcpav-service-epic:0/DCPAVServiceProxy  ← its AV service
/// CoreDisplay reports the framebuffer's exact path ("IODisplayLocation") for a
/// display ID, so the `dispextN` node name pairs the two without guessing.
@MainActor
enum DisplayDiscovery {
    static func externalDisplays() -> [DisplayCandidate] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }

        let services = externalAVServices()
        defer { services.values.forEach { IOObjectRelease($0) } }
        guard !services.isEmpty else { return [] }

        var result: [DisplayCandidate] = []
        for id in ids.prefix(Int(count)) where CGDisplayIsBuiltin(id) == 0 {
            guard let fb = framebuffer(for: id) else { continue }
            defer { IOObjectRelease(fb.entry) }
            guard let service = services[fb.nodeName],
                  let avService = AVService(entry: service) else { continue }
            result.append(DisplayCandidate(
                displayID: id,
                key: stableKey(for: id, attributes: fb.attributes),
                name: displayName(for: id, attributes: fb.attributes),
                avService: avService,
                port: fb.nodeName
            ))
        }

        // Identical monitors without serial numbers share a key. Qualify *all* of
        // them by their DCP port (dispextN) so each key follows a connection, not
        // the order the displays happen to be arranged or enumerated in.
        let counts = Dictionary(grouping: result, by: \.key).mapValues(\.count)
        result = result.map { c in
            guard counts[c.key, default: 0] > 1 else { return c }
            return DisplayCandidate(displayID: c.displayID, key: "\(c.key)@\(c.port)",
                                    name: c.name, avService: c.avService, port: c.port)
        }
        // Left-to-right, matching the physical arrangement.
        return result.sorted { CGDisplayBounds($0.displayID).minX < CGDisplayBounds($1.displayID).minX }
    }

    // MARK: Registry

    /// External `DCPAVServiceProxy` entries keyed by their framebuffer node name
    /// (`dispextN`), taken from the parent AFK endpoint "dispextN:dcpav-service-epic:0".
    /// Caller releases the returned services.
    private static func externalAVServices() -> [String: io_service_t] {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(iterator) }

        var result: [String: io_service_t] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            guard stringProperty(service, "Location") == "External",
                  let endpoint = parentName(of: service),
                  let node = endpoint.split(separator: ":").first.map(String.init),
                  result[node] == nil
            else { IOObjectRelease(service); continue }
            result[node] = service
        }
        return result
    }

    private struct Framebuffer {
        let entry: io_registry_entry_t
        let nodeName: String
        let attributes: [String: Any]
    }

    /// The display's `IOMobileFramebufferShim`, preferring CoreDisplay's exact
    /// registry path and falling back to an unambiguous EDID-attribute match.
    private static func framebuffer(for id: CGDirectDisplayID) -> Framebuffer? {
        if let info = MSCopyDisplayInfoDictionary(id) as? [String: Any],
           let location = info["IODisplayLocation"] as? String {
            let entry = IORegistryEntryFromPath(kIOMainPortDefault, location)
            if entry != 0 {
                if let node = parentName(of: entry) {
                    return Framebuffer(entry: entry, nodeName: node, attributes: productAttributes(entry))
                }
                IOObjectRelease(entry)
            }
        }
        return framebufferByAttributes(for: id)
    }

    /// Fallback: match vendor/model/serial against each external framebuffer's
    /// ProductAttributes. Refuses to guess when more than one framebuffer matches —
    /// driving the wrong monitor is worse than showing no slider.
    private static func framebufferByAttributes(for id: CGDirectDisplayID) -> Framebuffer? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var matches: [Framebuffer] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            let attrs = productAttributes(entry)
            if intValue(attrs["LegacyManufacturerID"]) == Int(CGDisplayVendorNumber(id)),
               intValue(attrs["ProductID"]) == Int(CGDisplayModelNumber(id)),
               intValue(attrs["SerialNumber"]) ?? 0 == Int(CGDisplaySerialNumber(id)),
               let node = parentName(of: entry), node.hasPrefix("dispext") {
                matches.append(Framebuffer(entry: entry, nodeName: node, attributes: attrs))
            } else {
                IOObjectRelease(entry)
            }
        }
        guard matches.count == 1 else {
            matches.forEach { IOObjectRelease($0.entry) }
            return nil
        }
        return matches[0]
    }

    // MARK: Identity

    private static func stableKey(for id: CGDirectDisplayID, attributes: [String: Any]) -> String {
        let vendor = CGDisplayVendorNumber(id)
        let model = CGDisplayModelNumber(id)
        let serial = CGDisplaySerialNumber(id)
        if serial != 0 { return "\(vendor)-\(model)-\(serial)" }
        if let alnum = attributes["AlphanumericSerialNumber"] as? String, !alnum.isEmpty {
            return "\(vendor)-\(model)-\(alnum)"
        }
        return "\(vendor)-\(model)"
    }

    private static func displayName(for id: CGDirectDisplayID, attributes: [String: Any]) -> String {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        if let name = screen?.localizedName, !name.isEmpty { return name }
        if let name = attributes["ProductName"] as? String, !name.isEmpty { return name }
        return "External Display"
    }

    // MARK: IOKit helpers

    private static func productAttributes(_ entry: io_registry_entry_t) -> [String: Any] {
        let display = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
        return display?["ProductAttributes"] as? [String: Any] ?? [:]
    }

    private static func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    private static func parentName(of entry: io_registry_entry_t) -> String? {
        var parent = io_registry_entry_t()
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        var buffer = [CChar](repeating: 0, count: 128)   // io_name_t
        guard IORegistryEntryGetName(parent, &buffer) == KERN_SUCCESS else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func intValue(_ any: Any?) -> Int? {
        (any as? NSNumber)?.intValue
    }
}
