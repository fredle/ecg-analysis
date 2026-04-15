import Foundation

enum ECGDecoderError: Error {
    case tooShort
    case badHeaderSize(UInt8)
    case truncated
}

enum ECGDecoder {
    static func decode(_ fileData: Data) throws -> [Int16] {
        guard fileData.count >= 9 else { throw ECGDecoderError.tooShort }
        let headerSize = Int(fileData[fileData.startIndex + 8])
        guard headerSize == 9 else { throw ECGDecoderError.badHeaderSize(UInt8(headerSize)) }
        guard fileData.count > headerSize + 1 else { return [] }

        let data = fileData[(fileData.startIndex + headerSize)...]
        var samples: [Int16] = []
        samples.reserveCapacity(data.count)
        var acc: Int32 = 0
        var i = data.startIndex + 1

        while i < data.endIndex {
            let b = data[i]
            switch b {
            case 0x80:
                guard data.index(i, offsetBy: 2) < data.endIndex else { throw ECGDecoderError.truncated }
                let lo = Int32(data[i + 1])
                let hi = Int32(data[i + 2])
                let raw = UInt16(truncatingIfNeeded: (hi << 8) | lo)
                acc = Int32(Int16(bitPattern: raw))
                i += 3
            case 0x7F:
                guard i + 1 < data.endIndex else { throw ECGDecoderError.truncated }
                acc &+= 127 + Int32(data[i + 1])
                i += 2
            case 0x81:
                guard i + 1 < data.endIndex else { throw ECGDecoderError.truncated }
                acc &-= 127 + Int32(data[i + 1])
                i += 2
            default:
                acc &+= b > 127 ? Int32(b) - 256 : Int32(b)
                i += 1
            }
            samples.append(Int16(clamping: acc))
        }
        return samples
    }
}
