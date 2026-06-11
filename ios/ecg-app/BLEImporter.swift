import Foundation
import SwiftData

/// Imports recordings pulled over Bluetooth from an ER1-family device into the
/// store. Mirrors `USBImporter`, but takes the file bytes in memory (the BLE
/// transfer already produced them) rather than enumerating a folder. Runs off
/// the main actor so decoding large files doesn't block the UI.
@ModelActor
actor BLEImporter {
    private static let filenamePattern = #/^R(?<ts>\d{14})$/#

    /// Import one downloaded file. Returns `true` if a new recording was created,
    /// `false` if one with the same name already existed.
    func importFile(name: String, data: Data) throws -> Bool {
        guard let match = try? Self.filenamePattern.wholeMatch(in: name) else {
            throw USBImportError.invalidFilename(name)
        }
        let timestamp = String(match.output.ts)
        let localFilename = "R\(timestamp)"

        let existing = try modelContext.fetch(FetchDescriptor<Recording>(
            predicate: #Predicate { $0.filename == localFilename }
        ))
        if !existing.isEmpty { return false }

        guard let startedAt = Self.parseTimestamp(timestamp) else {
            throw USBImportError.badTimestamp(timestamp)
        }

        let samples = try ECGDecoder.decode(data)

        let destURL = Recording.directory.appendingPathComponent(localFilename)
        if !FileManager.default.fileExists(atPath: destURL.path) {
            try data.write(to: destURL, options: .atomic)
        }

        let recording = Recording(filename: localFilename, startedAt: startedAt, source: .bleImport)
        recording.sampleCount = samples.count
        recording.byteCount = data.count
        recording.endedAt = startedAt.addingTimeInterval(Double(samples.count) / 125.0)
        recording.samples = samples

        modelContext.insert(recording)
        try modelContext.save()
        return true
    }

    private static func parseTimestamp(_ ts: String) -> Date? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyyMMddHHmmss"
        return df.date(from: ts)
    }
}
