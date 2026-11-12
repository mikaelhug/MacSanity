/// DDC/CI (VESA MCCS) packet encoding and reply parsing — pure, so it can be
/// checked without hardware (`swift run DDCCheck`).
///
/// Wire format (host → monitor at 7-bit I2C address 0x37, written as 0x6E):
///   0x51 (source), 0x80|len, payload…, checksum
/// The transport layer sends the 0x51 source byte as the I2C "data address",
/// so the packets built here start at the length byte. The checksum is the XOR
/// of the destination address 0x6E and every byte that precedes it.
public enum DDCPacket {
    /// VCP feature 0x10 — Luminance (backlight brightness).
    public static let brightness: UInt8 = 0x10

    private static let destination: UInt8 = 0x6E   // 0x37 << 1 (write)
    private static let source: UInt8 = 0x51
    /// Replies are XOR-checked against the "virtual host address" 0x50.
    private static let replySeed: UInt8 = 0x50

    /// "Get VCP Feature" request: 0x82 0x01 code chk.
    public static func getVCP(_ code: UInt8) -> [UInt8] {
        withChecksum([0x82, 0x01, code])
    }

    /// "Set VCP Feature" request: 0x84 0x03 code valueHi valueLo chk.
    public static func setVCP(_ code: UInt8, value: UInt16) -> [UInt8] {
        withChecksum([0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// Parse a "Get VCP Feature Reply" (11 bytes as read from the bus):
    ///   [0] 0x6E source  [1] 0x88 length  [2] 0x02 opcode  [3] result (0 = OK)
    ///   [4] VCP code     [5] type         [6–7] max        [8–9] current  [10] chk
    /// Returns nil for anything malformed, an unsupported-code result, a reply for
    /// a different feature, a bad checksum, or a zero maximum.
    public static func parseGetVCPReply(_ reply: [UInt8], expecting code: UInt8) -> (current: UInt16, max: UInt16)? {
        guard reply.count >= 11,
              reply[0] == destination,
              reply[1] & 0x80 != 0, reply[1] & 0x7F == 8,
              reply[2] == 0x02,
              reply[3] == 0x00,
              reply[4] == code
        else { return nil }
        let checksum = reply[0..<10].reduce(replySeed, ^)
        guard checksum == reply[10] else { return nil }
        let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        guard max > 0 else { return nil }
        return (Swift.min(current, max), max)
    }

    private static func withChecksum(_ body: [UInt8]) -> [UInt8] {
        body + [body.reduce(destination ^ source, ^)]
    }
}
