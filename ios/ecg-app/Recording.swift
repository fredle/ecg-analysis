import Foundation
import SwiftData

enum RecordingSource: String, Codable {
    case liveLocal
    case usbImport
}

enum UploadState: String, Codable {
    case notApplicable
    case pending
    case uploading
    case analyzed
    case skipped
    case failed
}

@Model
final class Recording {
    var filename: String
    var startedAt: Date
    var endedAt: Date?
    var sampleCount: Int
    var byteCount: Int
    var deviceId: String?

    var sourceRaw: String = ""
    var uploadStateRaw: String = ""
    var remoteSessionId: String?
    var remoteStartTime: Date?
    var remoteEndTime: Date?
    var uploadError: String?

    @Attribute(.externalStorage)
    var samplesData: Data?

    init(filename: String, startedAt: Date, source: RecordingSource = .liveLocal) {
        self.filename = filename
        self.startedAt = startedAt
        self.endedAt = nil
        self.sampleCount = 0
        self.byteCount = 0
        self.deviceId = nil
        self.samplesData = nil
        self.sourceRaw = source.rawValue
        self.uploadStateRaw = (source == .usbImport ? UploadState.pending : .notApplicable).rawValue
    }

    var source: RecordingSource {
        get {
            if let s = RecordingSource(rawValue: sourceRaw) { return s }
            return filename.hasSuffix(".ecgraw") ? .liveLocal : .usbImport
        }
        set { sourceRaw = newValue.rawValue }
    }

    var uploadState: UploadState {
        get {
            if let s = UploadState(rawValue: uploadStateRaw) { return s }
            return source == .usbImport ? .pending : .notApplicable
        }
        set { uploadStateRaw = newValue.rawValue }
    }

    var samples: [Int16] {
        get {
            guard let data = samplesData else { return [] }
            return data.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Int16.self))
            }
        }
        set {
            samplesData = newValue.withUnsafeBufferPointer { Data(buffer: $0) }
        }
    }

    func loadSamples() -> [Int16] {
        switch source {
        case .liveLocal:
            guard let data = try? Data(contentsOf: fileURL) else { return [] }
            return data.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Int16.self))
            }
        case .usbImport:
            return samples
        }
    }

    var durationSeconds: Double {
        Double(sampleCount) / 125.0
    }

    var fileURL: URL {
        Recording.directory.appendingPathComponent(filename)
    }

    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("ECG", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
