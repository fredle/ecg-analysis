import Foundation
import SwiftData
import os

/// Drives USB-imported recordings from local files all the way to "analysed"
/// on the server, and keeps local state in sync with the server.
///
/// Identity is the **filename** (R<YYYYMMDDHHMMSS>), never the ephemeral upload
/// session id. The server is the source of truth for whether a recording has
/// been analysed; this queue reconciles against it on launch and periodically,
/// so a recording can never get stuck showing "Analysing…" after the server has
/// finished, and an already-analysed recording is never re-uploaded.
///
/// State machine (usbImport recordings):
///   pending → uploading → analyzed            (happy path: upload analyses too)
///                       ↘ uploaded → analyzed (server has bytes, finish by name)
///                       ↘ failed              (terminal; manual retry)
@MainActor
@Observable
final class UploadQueue {
    private weak var modelContext: ModelContext?
    private var uploadTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var hasRecovered = false

    private let logger = Logger(subsystem: "com.ecg-app", category: "UploadQueue")

    var queueDepth: Int = 0
    var isUploading: Bool = false
    var inferenceCount: Int = 0
    var lastError: String?

    /// How often to reconcile/finish in-flight work in the background.
    private static let maintenanceInterval: UInt64 = 20_000_000_000 // 20 seconds

    /// Local states that may be out of sync with the server and so should be
    /// reconciled on launch.
    private static let recoverableStates: Set<String> = [
        UploadState.pending.rawValue,
        "",                                   // legacy: empty rawValue
        UploadState.uploading.rawValue,
        UploadState.uploaded.rawValue,
        UploadState.failed.rawValue,
    ]

    func attach(context: ModelContext) {
        self.modelContext = context
    }

    func kick() {
        guard let context = modelContext else { return }
        if uploadTask == nil {
            uploadTask = Task { [weak self] in
                guard let self else { return }
                if !self.hasRecovered {
                    await self.reconcile(in: context)
                    self.hasRecovered = true
                }
                await self.runUploads()
                self.uploadTask = nil
            }
        }
        if maintenanceTask == nil {
            maintenanceTask = Task { [weak self] in
                await self?.runMaintenance()
                self?.maintenanceTask = nil
            }
        }
    }

    func retry(_ rec: Recording) {
        rec.uploadStateRaw = UploadState.pending.rawValue
        rec.uploadError = nil
        try? modelContext?.save()
        kick()
    }

    // MARK: - Reconciliation (server is the source of truth)

    /// Compare every non-terminal usbImport recording against the server's
    /// authoritative per-file state and adopt it. Runs once on launch.
    private func reconcile(in context: ModelContext) async {
        let usbRaw = RecordingSource.usbImport.rawValue
        let desc = FetchDescriptor<Recording>(
            predicate: #Predicate<Recording> { $0.sourceRaw == usbRaw }
        )
        let all = (try? context.fetch(desc)) ?? []
        let candidates = all.filter { Self.recoverableStates.contains($0.uploadStateRaw) }
        guard !candidates.isEmpty else { return }

        let filenames = candidates.map(\.filename)
        logger.info("Reconciling \(filenames.count) recordings against server")

        guard let serverStatus = try? await APIClient.shared.fileStatus(filenames: filenames) else {
            logger.warning("Reconcile: server unreachable, leaving local state untouched")
            return
        }

        for rec in candidates {
            apply(verdict: serverStatus[rec.filename], to: rec)
        }
        try? context.save()
    }

    /// Map a server file-status verdict onto a local recording.
    private func apply(verdict: String?, to rec: Recording) {
        switch verdict {
        case "analysed":
            logger.info("Server already analysed \(rec.filename)")
            rec.uploadStateRaw = UploadState.analyzed.rawValue
            rec.uploadError = nil
        case "uploaded":
            // Server holds the bytes but hasn't analysed them — finish by name.
            rec.uploadStateRaw = UploadState.uploaded.rawValue
            rec.uploadError = nil
        case "failed":
            rec.uploadStateRaw = UploadState.failed.rawValue
        case "unknown", .none:
            // Server doesn't have it. Re-queue for upload, unless it's a genuine
            // failure the user must retry explicitly.
            if rec.uploadStateRaw != UploadState.failed.rawValue {
                rec.uploadStateRaw = UploadState.pending.rawValue
                rec.uploadError = nil
            }
        default:
            break
        }
    }

    // MARK: - Phase 1: Upload (and analyse) pending recordings

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
        lastError = nil
        try? context.save()

        do {
            // Background URLSession: the upload+analysis request survives app
            // suspension/termination and relaunches the app on completion.
            let result = try await BackgroundUploader.shared.upload(
                fileURL: rec.fileURL,
                filename: rec.filename
            )

            switch result {
            case .skipped:
                logger.info("Server skipped \(rec.filename) (invalid)")
                rec.uploadStateRaw = UploadState.skipped.rawValue

            case .done(let sessionId):
                logger.info("Analysed \(rec.filename) (session \(sessionId))")
                rec.remoteSessionId = sessionId
                rec.uploadStateRaw = UploadState.analyzed.rawValue
                rec.uploadError = nil

            case .pending(let sessionId):
                // Bytes are on the server but analysis didn't complete in this
                // request — maintenance will finish it by filename.
                logger.info("Uploaded \(rec.filename), analysis pending (session \(sessionId))")
                rec.remoteSessionId = sessionId
                rec.uploadStateRaw = UploadState.uploaded.rawValue

            case .error(let sessionId, let message):
                logger.error("Analysis failed for \(rec.filename): \(message)")
                rec.remoteSessionId = sessionId
                rec.uploadStateRaw = UploadState.failed.rawValue
                rec.uploadError = message
            }
            try? context.save()
        } catch {
            logger.error("Upload failed for \(rec.filename): \(error.localizedDescription)")
            rec.uploadStateRaw = UploadState.failed.rawValue
            rec.uploadError = error.localizedDescription
            lastError = error.localizedDescription
            try? context.save()
        }
    }

    // MARK: - Phase 2: Maintenance — finish analysis for uploaded recordings

    private func runMaintenance() async {
        guard let context = modelContext else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.maintenanceInterval)
            await finishAnalysis(in: context)
        }
    }

    /// For recordings whose bytes are on the server but aren't analysed yet, ask
    /// the server to analyse them by filename (no bytes re-sent). This is the
    /// recovery path for uploads whose analysis was interrupted.
    private func finishAnalysis(in context: ModelContext) async {
        let uploadedRaw = UploadState.uploaded.rawValue
        let desc = FetchDescriptor<Recording>(
            predicate: #Predicate<Recording> { $0.uploadStateRaw == uploadedRaw },
            sortBy: [SortDescriptor(\Recording.startedAt)]
        )
        let uploaded = (try? context.fetch(desc)) ?? []
        inferenceCount = uploaded.count
        guard !uploaded.isEmpty else { return }

        let filenames = uploaded.map(\.filename)
        logger.info("Finishing analysis for \(filenames.count) recording(s)")

        guard let results = try? await APIClient.shared.analyse(filenames: filenames) else {
            logger.warning("finishAnalysis: server unreachable")
            return
        }

        for rec in uploaded {
            switch results[rec.filename] {
            case "analyzed":
                rec.uploadStateRaw = UploadState.analyzed.rawValue
                rec.uploadError = nil
            case "error":
                rec.uploadStateRaw = UploadState.failed.rawValue
                rec.uploadError = "Analysis failed on server"
            case "unknown":
                // Server lost the bytes — re-upload from scratch.
                rec.uploadStateRaw = UploadState.pending.rawValue
                rec.uploadError = nil
            default:
                break
            }
        }
        try? context.save()
        inferenceCount = uploaded.filter { $0.uploadStateRaw == uploadedRaw }.count
        kick()  // pick up any recordings re-queued to pending
    }
}
