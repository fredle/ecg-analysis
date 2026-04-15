import Foundation

enum ViatomCmd: UInt8 {
    case getVibrateConfig = 0x00
    case getRtData        = 0x03
    case setVibrate       = 0x04
    case getRtRri         = 0x07
    case getInfo          = 0xE1
    case syncTime         = 0xEC
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
    let seq: UInt8
    let payload: [UInt8]
}

struct ECGPacket {
    let batteryPct: UInt8
    let batteryState: UInt8
    let recordTime: UInt8
    let samples: [Int16]

    init?(payload: [UInt8]) {
        guard payload.count >= 278 else { return nil }
        self.batteryPct = payload[0]
        self.batteryState = payload[1]
        self.recordTime = payload[10]
        var s = [Int16]()
        s.reserveCapacity(128)
        for i in 0..<128 {
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
                out.append(ViatomPacket(cmd: cmd, seq: frame[4], payload: payload))
                buffer.removeFirst(total)
            } else {
                buffer.removeFirst()
            }
        }
        return out
    }

    func reset() { buffer.removeAll() }
}
