import Foundation
import SwiftData
import os

@MainActor
@Observable
final class UploadQueue {
    private weak var modelContext: ModelContext?
    private var uploadTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var hasRecovered = false

    private let logger = Logger(subsystem: "com.ecg-app", category: "UploadQueue")

    var queueDepth: Int = 0
    var isUploading: Bool = false
    var lastError: String?

    private static let pollInterval: UInt64 = 5_000_000_000 // 5 seconds

    func attach(context: ModelContext) {
        self.modelContext = context
    }

    func kick() {
        guard let context = modelContext else { return }
        if uploadTask == nil {
            uploadTask = Task { [weak self] in
                guard let self else { return }
                if !self.hasRecovered {
                    await self.recoverStale(in: context)
                    self.hasRecovered = true
                }
                await self.runUploads()
                self.uploadTask = nil
            }
        }
        if pollTask == nil {
            pollTask = Task { [weak self] in
                await self?.runInferencePoll()
                self?.pollTask = nil
            }
        }
    }

    func retry(_ rec: Recording) {
        rec.uploadStateRaw = UploadState.pending.rawValue
        rec.uploadError = nil
        try? modelContext?.save()
        kick()
    }

    /// On launch, recover recordings stuck in transient states. For any that
    /// have a remoteSessionId, check with the server first — inference may
    /// have already completed.
    private func recoverStale(in context: ModelContext) async {
        let uploadingRaw = UploadState.uploading.rawValue
        let failedRaw = UploadState.failed.rawValue
        let desc = FetchDescriptor<Recording>(
            predicate: #Predicate<Recording> {
                $0.uploadStateRaw == uploadingRaw || $0.uploadStateRaw == failedRaw
            }
        )
        let stale = (try? context.fetch(desc)) ?? []
        guard !stale.isEmpty else {
            logger.info("No stale recordings to recover")
            return
        }

        logger.info("Recovering \(stale.count) stale recordings")

        for rec in stale {
            if let sessionId = rec.remoteSessionId {
                logger.info("Checking server for \(rec.filename) (session \(sessionId))")
                if let status = try? await APIClient.shared.inferenceStatus(sessionId: sessionId) {
                    logger.info("Server says \(rec.filename) is \(status.status)")
                    switch status.status {
                    case "done":
                        rec.uploadStateRaw = UploadState.analyzed.rawValue
                        rec.uploadError = nil
                        try? context.save()
                        continue
                    case "processing":
                        rec.uploadStateRaw = UploadState.uploaded.rawValue
                        rec.uploadError = nil
                        try? context.save()
                        continue
                    default:
                        break
                    }
                } else {
                    logger.warning("Failed to reach server for \(rec.filename)")
                }
            }
            // No session or server doesn't know about it — re-queue
            logger.info("Re-queuing \(rec.filename) for upload")
            rec.uploadStateRaw = UploadState.pending.rawValue
            rec.uploadError = nil
        }
        try? context.save()
    }

    // MARK: - Phase 1: Upload files

    private func runUploads() async {
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
            logger.info("Uploading \(rec.filename)")
            await uploadOne(rec, in: context)
        }
        isUploading = false
    }

    private func uploadOne(_ rec: Recording, in context: ModelContext) async {
        rec.uploadStateRaw = UploadState.uploading.rawValue
        rec.uploadError = nil
        try? context.save()

        do {
            let result = try await BackgroundUploader.shared.upload(
                fileURL: rec.fileURL,
                filename: rec.filename
            )

            switch result {
            case .skipped:
                logger.info("Server skipped \(rec.filename)")
                rec.uploadStateRaw = UploadState.skipped.rawValue
                try? context.save()
                return

            case .accepted(let sessionId):
                logger.info("Upload accepted for \(rec.filename), session \(sessionId)")
                rec.remoteSessionId = sessionId
                rec.uploadStateRaw = UploadState.uploaded.rawValue
                try? context.save()

                // Fire inference start — if it fails or times out, the poll
                // loop will trigger it via the status endpoint instead.
                _ = try? await APIClient.shared.startInference(sessionId: sessionId)
            }
        } catch {
            logger.error("Upload failed for \(rec.filename): \(error.localizedDescription)")
            rec.uploadStateRaw = UploadState.failed.rawValue
            rec.uploadError = error.localizedDescription
            lastError = error.localizedDescription
            try? context.save()
        }
    }

    // MARK: - Phase 2: Poll for inference completion

    private func runInferencePoll() async {
        guard let context = modelContext else { return }
        while !Task.isCancelled {
            let uploadedRaw = UploadState.uploaded.rawValue
            let desc = FetchDescriptor<Recording>(
                predicate: #Predicate<Recording> { $0.uploadStateRaw == uploadedRaw },
                sortBy: [SortDescriptor(\Recording.startedAt)]
            )
            let uploaded = (try? context.fetch(desc)) ?? []

            if uploaded.isEmpty {
                try? await Task.sleep(nanoseconds: Self.pollInterval)
                continue
            }

            for rec in uploaded {
                guard let sessionId = rec.remoteSessionId else { continue }
                do {
                    let status = try await APIClient.shared.inferenceStatus(sessionId: sessionId)
                    switch status.status {
                    case "done":
                        logger.info("Inference done for \(rec.filename)")
                        rec.uploadStateRaw = UploadState.analyzed.rawValue
                        try? context.save()
                    case "error":
                        logger.error("Inference error for \(rec.filename): \(status.error ?? "unknown")")
                        rec.uploadStateRaw = UploadState.failed.rawValue
                        rec.uploadError = status.error ?? "Inference failed"
                        try? context.save()
                    default:
                        break
                    }
                } catch {
                    // Network error — retry next cycle
                }
            }

            try? await Task.sleep(nanoseconds: Self.pollInterval)
        }
    }
}
