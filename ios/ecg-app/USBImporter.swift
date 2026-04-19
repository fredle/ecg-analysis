import Foundation
import SwiftData

struct USBImportResult: Sendable {
    var importedCount: Int = 0
    var skipped: Int = 0
    var failures: [String] = []
}

enum USBImportError: Error {
    case invalidFilename(String)
    case badTimestamp(String)
    case folderUnavailable
}

@ModelActor
actor USBImporter {
    private static let filenamePattern = #/^(?<device>[A-Za-z0-9]*?)R(?<ts>\d{14})$/#

    func sync(folder: URL) throws -> USBImportResult {
        let didStart = folder.startAccessingSecurityScopedResource()
        defer { if didStart { folder.stopAccessingSecurityScopedResource() } }

        let root = Self.resolveUserfilesRoot(under: folder)

        var result = USBImportResult()
        for sourceURL in Self.recordingFiles(under: root) {
            do {
                if try importFile(at: sourceURL) {
                    result.importedCount += 1
                } else {
                    result.skipped += 1
                }
            } catch {
                result.failures.append("\(sourceURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if result.importedCount > 0 {
            try modelContext.save()
        }
        return result
    }

    private func importFile(at sourceURL: URL) throws -> Bool {
        let sourceName = sourceURL.lastPathComponent
        guard let match = try Self.filenamePattern.wholeMatch(in: sourceName) else {
            throw USBImportError.invalidFilename(sourceName)
        }
        let timestamp = String(match.output.ts)
        let devicePrefix = String(match.output.device)
        let deviceId = devicePrefix.isEmpty ? nil : devicePrefix
        let localFilename = "R\(timestamp)"

        let existing = try modelContext.fetch(FetchDescriptor<Recording>(
            predicate: #Predicate { $0.filename == localFilename }
        ))
        if !existing.isEmpty { return false }

        guard let startedAt = Self.parseTimestamp(timestamp) else {
            throw USBImportError.badTimestamp(timestamp)
        }

        let data = try Data(contentsOf: sourceURL)
        let samples = try ECGDecoder.decode(data)

        let destURL = Recording.directory.appendingPathComponent(localFilename)
        if !FileManager.default.fileExists(atPath: destURL.path) {
            try data.write(to: destURL, options: .atomic)
        }

        let recording = Recording(filename: localFilename, startedAt: startedAt, source: .usbImport)
        recording.sampleCount = samples.count
        recording.byteCount = data.count
        recording.endedAt = startedAt.addingTimeInterval(Double(samples.count) / 125.0)
        recording.deviceId = deviceId
        recording.samples = samples

        modelContext.insert(recording)
        return true
    }

    private static func resolveUserfilesRoot(under folder: URL) -> URL {
        if folder.lastPathComponent.lowercased() == "userfiles" {
            return folder
        }
        let candidate = folder.appendingPathComponent("userfiles", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
            return candidate
        }
        return folder
    }

    private static func recordingFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [URL] = []
        for case let url as URL in enumerator {
            if (try? filenamePattern.wholeMatch(in: url.lastPathComponent)) != nil {
                out.append(url)
            }
        }
        return out
    }

    private static func parseTimestamp(_ ts: String) -> Date? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyyMMddHHmmss"
        return df.date(from: ts)
    }
}
