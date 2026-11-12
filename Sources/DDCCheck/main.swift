// Standalone checks for DDCPacket. Run with `swift run DDCCheck`.
// Exits 0 if all pass, 1 otherwise (stands in for XCTest, like ClassifierCheck).

import Foundation
import MacSanityCore

var failures = 0
@MainActor func check(_ name: String, _ ok: Bool) {
    print(ok ? "PASS  \(name)" : "FAIL  \(name)")
    if !ok { failures += 1 }
}

/// Build a well-formed reply with a correct checksum.
func reply(result: UInt8 = 0, code: UInt8 = 0x10, max: UInt16, current: UInt16) -> [UInt8] {
    var r: [UInt8] = [0x6E, 0x88, 0x02, result, code, 0x00,
                      UInt8(max >> 8), UInt8(max & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF)]
    r.append(r.reduce(0x50, ^))
    return r
}

// Request encoding — known-good bytes (as used by m1ddc / ddcutil).
check("getVCP brightness bytes", DDCPacket.getVCP(0x10) == [0x82, 0x01, 0x10, 0xAC])
check("setVCP brightness 50", DDCPacket.setVCP(0x10, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
check("setVCP brightness 0", DDCPacket.setVCP(0x10, value: 0) == [0x84, 0x03, 0x10, 0x00, 0x00, 0xA8])
check("setVCP high byte", DDCPacket.setVCP(0x10, value: 0x0102) == [0x84, 0x03, 0x10, 0x01, 0x02, 0xAB])

// Reply parsing.
let good = DDCPacket.parseGetVCPReply(reply(max: 100, current: 42), expecting: 0x10)
check("parse valid reply", good?.current == 42 && good?.max == 100)

var badSum = reply(max: 100, current: 42); badSum[10] ^= 0x01
check("reject bad checksum", DDCPacket.parseGetVCPReply(badSum, expecting: 0x10) == nil)
check("reject unsupported result", DDCPacket.parseGetVCPReply(reply(result: 1, max: 100, current: 42), expecting: 0x10) == nil)
check("reject wrong VCP echo", DDCPacket.parseGetVCPReply(reply(code: 0x12, max: 100, current: 42), expecting: 0x10) == nil)
check("reject zero max", DDCPacket.parseGetVCPReply(reply(max: 0, current: 0), expecting: 0x10) == nil)
check("reject short reply", DDCPacket.parseGetVCPReply(Array(reply(max: 100, current: 42).prefix(9)), expecting: 0x10) == nil)
check("reject all-0xFF (no monitor)", DDCPacket.parseGetVCPReply([UInt8](repeating: 0xFF, count: 11), expecting: 0x10) == nil)
check("reject all-zero", DDCPacket.parseGetVCPReply([UInt8](repeating: 0, count: 11), expecting: 0x10) == nil)
let clamped = DDCPacket.parseGetVCPReply(reply(max: 100, current: 250), expecting: 0x10)
check("clamp current to max", clamped?.current == 100)

print(failures == 0 ? "\nAll DDC checks passed." : "\n\(failures) DDC check(s) failed.")
exit(failures == 0 ? 0 : 1)
