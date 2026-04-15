import Foundation

final class ECGRecorder {
    private var handle: FileHandle?
    private(set) var sampleCount: Int = 0
    private(set) var byteCount: Int = 0
    private(set) var fileURL: URL?

    static func newFilename(at date: Date = Date()) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyyMMdd-HHmmss"
        return "live-\(df.string(from: date)).ecgraw"
    }

    func start(at url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        handle = h
        fileURL = url
        sampleCount = 0
        byteCount = 0
    }

    func append(samples: [Int16]) throws {
        guard let h = handle, !samples.isEmpty else { return }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try h.write(contentsOf: data)
        sampleCount += samples.count
        byteCount += data.count
    }

    func finish() throws {
        try handle?.close()
        handle = nil
    }
}
