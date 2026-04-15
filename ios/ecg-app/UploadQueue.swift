import Foundation
import SwiftData

@MainActor
@Observable
final class UploadQueue {
    private weak var modelContext: ModelContext?
    private var task: Task<Void, Never>?

    var queueDepth: Int = 0
    var isUploading: Bool = false
    var lastError: String?

    func attach(context: ModelContext) {
        self.modelContext = context
    }

    func kick() {
        guard task == nil, modelContext != nil else { return }
        task = Task { [weak self] in
            await self?.run()
            self?.task = nil
        }
    }

    func retry(_ rec: Recording) {
        rec.uploadStateRaw = UploadState.pending.rawValue
        rec.uploadError = nil
        try? modelContext?.save()
        kick()
    }

    private func run() async {
        guard let context = modelContext else { return }
        while !Task.isCancelled {
            let pendingRaw = UploadState.pending.rawValue
            let desc = FetchDescriptor<Recording>(
                predicate: #Predicate<Recording> { $0.uploadStateRaw == pendingRaw },
                sortBy: [SortDescriptor(\Recording.startedAt)]
            )
            let pending = (try? context.fetch(desc)) ?? []
            queueDepth = pending.count
            guard let rec = pending.first else {
                isUploading = false
                return
            }
            isUploading = true
            await processOne(rec, in: context)
        }
        isUploading = false
    }

    private func processOne(_ rec: Recording, in context: ModelContext) async {
        rec.uploadStateRaw = UploadState.uploading.rawValue
        rec.uploadError = nil
        try? context.save()

        do {
            let result = try await APIClient.shared.uploadRFile(
                fileURL: rec.fileURL,
                filename: rec.filename
            )

            switch result {
            case .skipped:
                rec.uploadStateRaw = UploadState.skipped.rawValue
                try? context.save()
                return

            case .accepted(let sessionId):
                rec.remoteSessionId = sessionId
                try? context.save()

                var resolved = false
                for try await event in APIClient.shared.streamProgress(sessionId: sessionId) {
                    switch event.kind {
                    case .done:
                        rec.uploadStateRaw = UploadState.analyzed.rawValue
                        resolved = true
                    case .error:
                        rec.uploadStateRaw = UploadState.failed.rawValue
                        rec.uploadError = event.data
                        resolved = true
                    default:
                        break
                    }
                }
                if !resolved {
                    rec.uploadStateRaw = UploadState.failed.rawValue
                    rec.uploadError = "Stream ended without result"
                }
                try? context.save()
            }
        } catch {
            rec.uploadStateRaw = UploadState.failed.rawValue
            rec.uploadError = error.localizedDescription
            lastError = error.localizedDescription
            try? context.save()
        }
    }
}
