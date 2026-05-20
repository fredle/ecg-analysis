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
    var inferenceCount: Int = 0
    var lastError: String?

    private static let pollInterval: UInt64 = 10_000_000_000 // 10 seconds

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

    /// On launch, recover recordings stuck in transient states and reconcile
    /// pending recordings against the server (files may already be analysed).
    private func recoverStale(in context: ModelContext) async {
        // Phase A: check uploading/failed recordings by session ID
        let uploadingRaw = UploadState.uploading.rawValue
        let failedRaw = UploadState.failed.rawValue
        let staleDesc = FetchDescriptor<Recording>(
            predicate: #Predicate<Recording> {
                $0.uploadStateRaw == uploadingRaw || $0.uploadStateRaw == failedRaw
            }
        )
        let stale = (try? context.fetch(staleDesc)) ?? []
        if !stale.isEmpty {
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
                logger.info("Re-queuing \(rec.filename) for upload")
                rec.uploadStateRaw = UploadState.pending.rawValue
                rec.uploadError = nil
            }
            try? context.save()
        }

        // Phase B: reconcile pending recordings against the server by filename.
        // Match both explicit "pending" and empty string (legacy recordings that
        // predate upload state tracking — the getter treats these as .pending).
        let pendingRaw = UploadState.pending.rawValue
        let emptyRaw = ""
        let usbRaw = RecordingSource.usbImport.rawValue
        let pendingDesc = FetchDescriptor<Recording>(
            predicate: #Predicate<Recording> {
                ($0.uploadStateRaw == pendingRaw || $0.uploadStateRaw == emptyRaw) &&
                $0.sourceRaw == usbRaw
            }
        )
        let pending = (try? context.fetch(pendingDesc)) ?? []
        guard !pending.isEmpty else { return }

        let filenames = pending.map(\.filename)
        logger.info("Reconciling \(filenames.count) pending recordings against server")

        guard let serverStatus = try? await APIClient.shared.fileStatus(filenames: filenames) else {
            logger.warning("Failed to reach server for file status reconciliation")
            return
        }

        for rec in pending {
            switch serverStatus[rec.filename] {
            case "analysed":
                logger.info("Server already analysed \(rec.filename)")
                rec.uploadStateRaw = UploadState.analyzed.rawValue
                rec.uploadError = nil
            case "uploaded":
                logger.info("Server has \(rec.filename) but not analysed")
                rec.uploadStateRaw = UploadState.uploaded.rawValue
                rec.uploadError = nil
            default:
                break  // still pending, will be uploaded
            }
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

            case .done(let sessionId):
                logger.info("Upload + inference done for \(rec.filename), session \(sessionId)")
                rec.remoteSessionId = sessionId
                rec.uploadStateRaw = UploadState.analyzed.rawValue
                try? context.save()

            case .error(let sessionId, let message):
                logger.error("Inference failed for \(rec.filename): \(message)")
                rec.remoteSessionId = sessionId
                rec.uploadStateRaw = UploadState.failed.rawValue
                rec.uploadError = message
                try? context.save()
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
            inferenceCount = uploaded.count

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
                    case "pending":
                        // File uploaded but inference never started — trigger it
                        logger.info("Triggering inference for \(rec.filename)")
                        try? await APIClient.shared.startInference(sessionId: sessionId)
                    case "error":
                        logger.error("Inference error for \(rec.filename): \(status.error ?? "unknown")")
                        rec.uploadStateRaw = UploadState.failed.rawValue
                        rec.uploadError = status.error ?? "Inference failed"
                        try? context.save()
                    default:
                        break
                    }
                } catch let e as APIError {
                    // 404 = session gone from server, need to re-upload
                    if case .http(404, _) = e {
                        logger.warning("Session gone for \(rec.filename), re-queuing")
                        rec.remoteSessionId = nil
                        rec.uploadStateRaw = UploadState.pending.rawValue
                        try? context.save()
                    }
                    // Other errors (network, timeout) — retry next cycle
                } catch {
                    // URLError etc — retry next cycle
                }
            }

            inferenceCount = uploaded.filter { $0.uploadStateRaw == UploadState.uploaded.rawValue }.count
            try? await Task.sleep(nanoseconds: Self.pollInterval)
        }
    }
}
