import CMacSanitySPI
import Foundation
import MacSanityCore
import Synchronization

/// Hardware brightness for one monitor over DDC/CI.
///
/// I2C transactions block for tens of milliseconds, so the actor runs on its own
/// serial dispatch queue (custom executor) rather than Swift's cooperative pool:
/// one monitor's transactions are strictly serialized, different monitors run in
/// parallel, and the main thread never waits on the bus.
actor DDCDevice {
    private let service: AVService
    private let queue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Latest requested brightness + whether a drain loop is already running.
    /// Lives in a mutex (not actor state) so the slider can submit synchronously
    /// and in order from the main thread — only the newest value is ever written.
    private let pending = Mutex<(target: UInt16?, draining: Bool)>((nil, false))

    /// Registry entry of the transport this device drives.
    nonisolated var entryID: UInt64 { service.entryID }

    init(service: AVService, label: String) {
        self.service = service
        self.queue = DispatchSerialQueue(label: "MacSanity.DDC.\(label)", qos: .userInitiated)
    }

    // MARK: Read

    /// Current and maximum brightness, or nil if the monitor didn't give a valid
    /// reply. Retries with growing gaps — DDC replies are flaky right after
    /// connect/wake and on some HDMI links.
    func readBrightness() -> (current: UInt16, max: UInt16)? {
        let request = DDCPacket.getVCP(DDCPacket.brightness)
        for attempt in 0..<4 {
            guard send(request) else { pause(ms: 30); continue }
            pause(ms: 40 + 20 * attempt)   // monitor needs ≥40 ms to prepare its reply
            var reply = [UInt8](repeating: 0, count: 11)
            if MSDDCRead(service.ref, &reply, UInt32(reply.count)),
               let value = DDCPacket.parseGetVCPReply(reply, expecting: DDCPacket.brightness) {
                return value
            }
            pause(ms: 30)
        }
        return nil
    }

    // MARK: Write (coalesced)

    /// Request a brightness value. Non-blocking; while a write is in flight only
    /// the most recent request is kept, so dragging a slider sends a bounded
    /// stream of writes and the final position always lands.
    nonisolated func submit(_ value: UInt16) {
        let startDrain = pending.withLock { state -> Bool in
            state.target = value
            if state.draining { return false }
            state.draining = true
            return true
        }
        if startDrain { Task { await self.drain() } }
    }

    private func drain() {
        while true {
            let next = pending.withLock { state -> UInt16? in
                guard let target = state.target else { state.draining = false; return nil }
                state.target = nil
                return target
            }
            guard let value = next else { return }
            _ = send(DDCPacket.setVCP(DDCPacket.brightness, value: value))
            pause(ms: 50)   // MCCS: give the monitor time to process before the next command
        }
    }

    // MARK: Bus

    /// Send a request twice, 10 ms apart. Through the Apple Silicon DCP a lone
    /// write is frequently dropped by the monitor — verified on hardware for both
    /// Get and Set (the monitor answers a dropped Get with a DDC null message);
    /// m1ddc and MonitorControl do the same. Both requests are idempotent.
    private func send(_ packet: [UInt8]) -> Bool {
        var ok = false
        for _ in 0..<2 {
            pause(ms: 10)
            ok = write(packet) || ok
        }
        return ok
    }

    private func write(_ packet: [UInt8]) -> Bool {
        packet.withUnsafeBufferPointer { MSDDCWrite(service.ref, $0.baseAddress!, UInt32($0.count)) }
    }

    private func pause(ms: Int) {
        Thread.sleep(forTimeInterval: Double(ms) / 1000)   // on our own queue — never the pool
    }
}
