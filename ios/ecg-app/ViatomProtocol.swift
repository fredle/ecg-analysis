import Foundation

enum ViatomCmd: UInt8 {
    case getVibrateConfig = 0x00
    case getRtData        = 0x03
    case setVibrate       = 0x04
    case getRtRri         = 0x07
    case getInfo          = 0xE1
    case syncTime         = 0xEC
    // Stored-file transfer (ER1 family). Verified against firmware:
    // list → start (returns size) → data (per-offset chunks) → end.
    case getFileList      = 0xF1
    case readFileStart    = 0xF2
    case readFileData     = 0xF3
    case readFileEnd      = 0xF4
}

enum ViatomProtocol {
    static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for b in bytes {
            crc ^= b
            for _ in 0..<8 {
                if crc & 0x80 != 0 {
                    crc = (crc << 1) ^ 0x07
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }

    static func build(cmd: ViatomCmd, seq: UInt8, payload: [UInt8] = []) -> Data {
        var frame: [UInt8] = []
        frame.append(0xA5)
        frame.append(cmd.rawValue)
        frame.append(~cmd.rawValue)
        frame.append(0x00)
        frame.append(seq)
        let len = UInt16(payload.count)
        frame.append(UInt8(len & 0xFF))
        frame.append(UInt8((len >> 8) & 0xFF))
        frame.append(contentsOf: payload)
        frame.append(crc8(frame))
        return Data(frame)
    }

    /// Payload for `readFileStart`: 16-byte filename field (UTF-8, NUL-padded /
    /// truncated) followed by a uint32-LE start offset (0 to read from the top).
    static func readFileStartPayload(name: String, offset: UInt32 = 0) -> [UInt8] {
        var p = Array(name.utf8.prefix(16))
        while p.count < 16 { p.append(0) }
        p.append(contentsOf: u32le(offset))
        return p
    }

    /// Payload for `readFileData`: uint32-LE offset of the next chunk to fetch
    /// (i.e. the number of bytes already received).
    static func readFileDataPayload(offset: UInt32) -> [UInt8] {
        u32le(offset)
    }

    /// Parse a `getFileList` response payload: a 1-byte count followed by that
    /// many 16-byte UTF-8 filename records (NUL/space padded).
    static func parseFileList(_ payload: [UInt8]) -> [String] {
        guard let count = payload.first else { return [] }
        var names: [String] = []
        var idx = 1
        for _ in 0..<Int(count) {
            guard idx + 16 <= payload.count else { break }
            let record = payload[idx..<idx + 16]
            idx += 16
            let nameBytes = record.prefix { $0 != 0 }
            if let s = String(bytes: nameBytes, encoding: .utf8) {
                let trimmed = s.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { names.append(trimmed) }
            }
        }
        return names
    }

    static func u32le(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF),
         UInt8((value >> 8) & 0xFF),
         UInt8((value >> 16) & 0xFF),
         UInt8((value >> 24) & 0xFF)]
    }

    static func readU32le<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var value: UInt32 = 0
        for (i, b) in bytes.prefix(4).enumerated() {
            value |= UInt32(b) << (8 * i)
        }
        return value
    }

    static func syncTimePayload(_ date: Date = Date()) -> [UInt8] {
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = UInt16(comps.year ?? 2026)
        return [
            UInt8(year & 0xFF),
            UInt8((year >> 8) & 0xFF),
            UInt8(comps.month ?? 1),
            UInt8(comps.day ?? 1),
            UInt8(comps.hour ?? 0),
            UInt8(comps.minute ?? 0),
            UInt8(comps.second ?? 0),
        ]
    }
}

struct ViatomPacket {
    let cmd: UInt8
    let status: UInt8   // byte[3]: 1 = success on file-transfer responses
    let seq: UInt8
    let payload: [UInt8]
}

struct ECGPacket {
    let batteryPct: UInt8
    let batteryState: UInt8
    let recordTime: UInt8
    let samples: [Int16]

    init?(payload: [UInt8]) {
        guard payload.count >= 24 else { return nil }
        self.batteryPct = payload[0]
        self.batteryState = payload[1]
        self.recordTime = payload[10]
        let sampleBytes = payload.count - 22
        let nSamples = sampleBytes / 2
        var s = [Int16]()
        s.reserveCapacity(nSamples)
        for i in 0..<nSamples {
            let lo = UInt16(payload[22 + i * 2])
            let hi = UInt16(payload[22 + i * 2 + 1])
            s.append(Int16(bitPattern: lo | (hi << 8)))
        }
        self.samples = s
    }
}

final class PacketReassembler {
    private var buffer: [UInt8] = []

    func append(_ data: Data) -> [ViatomPacket] {
        buffer.append(contentsOf: data)
        var out: [ViatomPacket] = []

        while true {
            guard let startIdx = buffer.firstIndex(of: 0xA5) else {
                buffer.removeAll()
                break
            }
            if startIdx > 0 {
                buffer.removeFirst(startIdx)
            }
            guard buffer.count >= 7 else { break }

            let cmd = buffer[1]
            let notCmd = buffer[2]
            guard cmd ^ notCmd == 0xFF else {
                buffer.removeFirst()
                continue
            }

            let lenL = UInt16(buffer[5])
            let lenH = UInt16(buffer[6])
            let payloadLen = Int(lenL | (lenH << 8))
            let total = 7 + payloadLen + 1
            guard buffer.count >= total else { break }

            let frame = Array(buffer[0..<total])
            let crcCalc = ViatomProtocol.crc8(Array(frame[0..<(total - 1)]))
            if crcCalc == frame[total - 1] {
                let payload = Array(frame[7..<(7 + payloadLen)])
                out.append(ViatomPacket(cmd: cmd, status: frame[3], seq: frame[4], payload: payload))
                buffer.removeFirst(total)
            } else {
                buffer.removeFirst()
            }
        }
        return out
    }

    func reset() { buffer.removeAll() }
}
