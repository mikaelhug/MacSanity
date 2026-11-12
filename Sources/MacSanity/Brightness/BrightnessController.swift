import AppKit
import Observation
import os

private let log = Logger(subsystem: "com.macsanity.app", category: "Brightness")

/// One brightness slider in the menu.
struct MonitorBrightness: Identifiable, Equatable {
    /// The display's stable key (vendor-model-serial).
    let id: String
    let name: String
    var value: Int
    var max: Int
    /// `true` when the monitor answered a DDC brightness read (auto-detected).
    /// `false` for a user-enabled, write-only monitor whose position is unverified.
    let verified: Bool
}

/// An external display with a DDC transport that did not answer a brightness
/// read. Offered in "Other Displays" for manual (write-only) enabling.
struct UndetectedDisplay: Identifiable, Equatable {
    let id: String
    let name: String
}

/// Discovers DDC/CI-capable monitors and drives their hardware brightness.
///
/// Strictly hardware: every change goes to the monitor over DDC. There is no
/// gamma, overlay, or any other software dimming — a monitor that can't be
/// driven over DDC simply gets no slider (unless the user opts it in manually).
///
/// Idle cost is zero: no timers or polling. Work happens only on launch, display
/// reconfiguration (hotplug), wake, menu open, and slider movement.
@MainActor
@Observable
final class BrightnessController {
    private(set) var monitors: [MonitorBrightness] = []
    private(set) var undetected: [UndetectedDisplay] = []

    @ObservationIgnored private var devices: [String: DDCDevice] = [:]
    /// The displays found by the last discovery, kept for re-probing.
    @ObservationIgnored private var candidates: [String: DisplayCandidate] = [:]
    @ObservationIgnored private var manualKeys: Set<String> = []
    /// Slider positions of manual monitors; persisted when the menu closes rather
    /// than on every drag tick.
    @ObservationIgnored private var manualValues: [String: Int] = [:]
    @ObservationIgnored private var manualValuesDirty = false
    /// When each undetected display was last probed (menu-open retries are throttled).
    @ObservationIgnored private var lastProbe: [String: Date] = [:]
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var lastRead: [String: Date] = [:]
    @ObservationIgnored private var lastWrite: [String: Date] = [:]
    /// Left-to-right position of each display, from the last discovery.
    @ObservationIgnored private var order: [String: Int] = [:]
    /// Bumped on every rediscovery so results from a superseded probe are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    func start() {
        guard screenObserver == nil else { return }
        manualKeys = Set(Defaults.manualDDCDisplays)
        manualValues = Defaults.manualDDCValues
        // Hotplug, arrangement and resolution changes all land here. (Wake is
        // forwarded separately by AppModel — it doesn't always reconfigure screens;
        // the shared debounce collapses the two when it does.)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRediscovery() }
        }
        rediscover()
    }

    func handleWake() { scheduleRediscovery() }

    /// The DCP needs a moment after a connect/wake before I2C is usable, and a
    /// single plug-in fires several notifications — so wait for things to settle.
    private func scheduleRediscovery(after delay: Duration = .milliseconds(1500)) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.rediscover()
        }
    }

    // MARK: Discovery + probing

    private func rediscover() {
        generation += 1
        let gen = generation
        let found = DisplayDiscovery.externalDisplays()
        log.info("Display discovery: \(found.count) external display(s) with a DDC transport")
        let present = Set(found.map(\.key))
        order = Dictionary(uniqueKeysWithValues: found.enumerated().map { ($1.key, $0) })
        candidates = Dictionary(uniqueKeysWithValues: found.map { ($0.key, $0) })

        // Keep the existing device while its transport is unchanged: it owns the
        // monitor's serial bus queue, so an in-flight slider drain and the re-probe
        // below stay serialized instead of racing on the same I2C bus. A new
        // device is made only for a new or replugged (re-registered) transport.
        devices = Dictionary(uniqueKeysWithValues: found.map { c in
            if let existing = devices[c.key], existing.entryID == c.avService.entryID {
                return (c.key, existing)
            }
            return (c.key, DDCDevice(service: c.avService, label: c.key))
        })
        // Drop sliders for displays that are gone; keep the rest steady while re-probing.
        monitors.removeAll { !present.contains($0.id) }
        undetected.removeAll { !present.contains($0.id) }

        for candidate in found {
            probe(candidate, generation: gen, retryAfterFailure: true)
        }
    }

    private func probe(_ candidate: DisplayCandidate, generation gen: Int, retryAfterFailure: Bool) {
        guard let device = devices[candidate.key] else { return }
        lastProbe[candidate.key] = Date()
        Task { [weak self] in
            let result = await device.readBrightness()
            guard let self, gen == self.generation else { return }
            if let result {
                log.info("DDC brightness detected on \(candidate.name, privacy: .public) [\(candidate.key, privacy: .public)]: \(result.current)/\(result.max)")
                self.lastRead[candidate.key] = Date()
                self.upsert(MonitorBrightness(id: candidate.key, name: candidate.name,
                                              value: Int(result.current), max: Int(result.max),
                                              verified: true))
                self.undetected.removeAll { $0.id == candidate.key }
            } else if self.monitors.contains(where: { $0.id == candidate.key && $0.verified }) {
                // Was verified before (e.g. this is a resolution change) — a single
                // missed reply doesn't demote it.
            } else if retryAfterFailure {
                try? await Task.sleep(for: .seconds(3))
                guard gen == self.generation else { return }
                self.probe(candidate, generation: gen, retryAfterFailure: false)
            } else {
                log.info("No DDC brightness reply from \(candidate.name, privacy: .public) [\(candidate.key, privacy: .public)]")
                self.markUndetected(candidate)
            }
        }
    }

    private func markUndetected(_ candidate: DisplayCandidate) {
        if !undetected.contains(where: { $0.id == candidate.key }) {
            undetected.append(UndetectedDisplay(id: candidate.key, name: candidate.name))
        }
        if manualKeys.contains(candidate.key) {
            upsert(manualMonitor(id: candidate.key, name: candidate.name))
        } else {
            monitors.removeAll { $0.id == candidate.key }
        }
    }

    private func manualMonitor(id: String, name: String) -> MonitorBrightness {
        // Last value MacSanity wrote, or mid-scale. Nothing is written until the
        // user moves the slider, so enabling never changes brightness by surprise.
        MonitorBrightness(id: id, name: name, value: manualValues[id] ?? 50,
                          max: 100, verified: false)
    }

    private func upsert(_ monitor: MonitorBrightness) {
        if let i = monitors.firstIndex(where: { $0.id == monitor.id }) {
            if monitors[i] != monitor { monitors[i] = monitor }
        } else {
            monitors.append(monitor)
            // Keep the left-to-right order discovery produced.
            monitors.sort { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
        }
    }

    // MARK: Menu open

    /// Re-read verified monitors so the sliders reflect changes made with the
    /// monitor's own buttons, and give undetected ones another chance (a monitor
    /// in standby at launch answers once it's awake, without any screen
    /// reconfiguration to trigger a probe). Throttled, and skipped right after the
    /// user dragged.
    func refreshForMenuOpen() {
        let now = Date()
        for display in undetected {
            if let t = lastProbe[display.id], now.timeIntervalSince(t) < 10 { continue }
            guard let candidate = candidates[display.id] else { continue }
            probe(candidate, generation: generation, retryAfterFailure: false)
        }
        for monitor in monitors where monitor.verified {
            let key = monitor.id
            if let t = lastRead[key], now.timeIntervalSince(t) < 2 { continue }
            if let t = lastWrite[key], now.timeIntervalSince(t) < 2 { continue }
            guard let device = devices[key] else { continue }
            lastRead[key] = now
            let gen = generation
            Task { [weak self] in
                guard let result = await device.readBrightness() else { return }
                guard let self, gen == self.generation,
                      let i = self.monitors.firstIndex(where: { $0.id == key }) else { return }
                // A drag that started while the read was in flight wins.
                if let t = self.lastWrite[key], Date().timeIntervalSince(t) < 2 { return }
                self.monitors[i].value = Int(result.current)
                self.monitors[i].max = Int(result.max)
            }
        }
    }

    // MARK: Intents

    func setBrightness(_ key: String, to value: Int) {
        guard let i = monitors.firstIndex(where: { $0.id == key }), let device = devices[key] else { return }
        let clamped = Swift.max(0, Swift.min(value, monitors[i].max))
        lastWrite[key] = Date()
        if monitors[i].value != clamped { monitors[i].value = clamped }
        device.submit(UInt16(clamped))
        if !monitors[i].verified {
            manualValues[key] = clamped
            manualValuesDirty = true
        }
    }

    /// Persist manual slider positions once, when the menu closes.
    func menuDidClose() {
        guard manualValuesDirty else { return }
        manualValuesDirty = false
        Defaults.manualDDCValues = manualValues
    }

    func isManuallyEnabled(_ key: String) -> Bool { manualKeys.contains(key) }

    /// Opt an undetected monitor into a write-only (unverified) slider, or back out.
    func setManuallyEnabled(_ key: String, _ enabled: Bool) {
        if enabled { manualKeys.insert(key) } else { manualKeys.remove(key) }
        Defaults.manualDDCDisplays = manualKeys.sorted()
        guard let display = undetected.first(where: { $0.id == key }) else { return }
        if enabled {
            upsert(manualMonitor(id: display.id, name: display.name))
        } else {
            monitors.removeAll { $0.id == key && !$0.verified }
        }
    }
}
