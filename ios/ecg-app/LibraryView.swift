import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(UploadQueue.self) private var uploadQueue
    @Query(sort: \Recording.startedAt, order: .reverse) private var recordings: [Recording]
    @AppStorage("er1FolderBookmark") private var bookmarkData: Data?

    @State private var syncStatus: String?
    @State private var isSyncing = false
    @State private var showingPicker = false

    var body: some View {
        NavigationStack {
            List {
                usbSection
                if uploadQueue.isUploading || uploadQueue.queueDepth > 0 || uploadQueue.lastError != nil {
                    uploadsSection
                }
                recordingsSection
            }
            .navigationTitle("Library")
        }
        .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                saveBookmark(for: url)
                runSync()
            }
        }
        .task { runSyncIfPossible() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { runSyncIfPossible() }
        }
    }

    // MARK: - USB

    private var usbSection: some View {
        Section("USB import") {
            Menu {
                Button("Sync now") { runSync() }
                    .disabled(isSyncing || bookmarkData == nil)
                Button(bookmarkData == nil ? "Choose ER1 folder…" : "Change ER1 folder…") {
                    showingPicker = true
                }
            } label: {
                HStack {
                    Label("ECG sync", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if isSyncing { ProgressView() }
                }
            }
            if let status = syncStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Uploads

    private var uploadsSection: some View {
        Section("Uploads") {
            LabeledContent("Queue depth", value: "\(uploadQueue.queueDepth)")
            if uploadQueue.isUploading {
                HStack { ProgressView(); Text("Uploading…").foregroundStyle(.secondary) }
            }
            if let err = uploadQueue.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Recordings

    private var recordingsSection: some View {
        Section {
            if recordings.isEmpty {
                Text("No recordings yet").foregroundStyle(.secondary)
            } else {
                ForEach(recordings) { rec in
                    NavigationLink {
                        RecordingDetailView(recording: rec)
                    } label: {
                        RecordingRow(recording: rec)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if rec.uploadState == .failed || rec.uploadState == .pending {
                            Button("Upload now") { uploadQueue.retry(rec) }
                                .tint(.orange)
                        }
                    }
                }
                .onDelete(perform: delete)
            }
        } header: {
            HStack {
                Text("Saved recordings")
                Spacer()
                if !recordings.isEmpty {
                    UploadSummary(recordings: recordings)
                }
            }
        }
    }

    // MARK: - Actions

    private func runSyncIfPossible() {
        guard !isSyncing, bookmarkData != nil else { return }
        runSync()
    }

    private func runSync() {
        guard let data = bookmarkData else {
            showingPicker = true
            return
        }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            syncStatus = "ER1 folder unavailable. Re-pick to continue."
            return
        }
        if stale {
            let didStart = url.startAccessingSecurityScopedResource()
            if let refreshed = try? url.bookmarkData() { bookmarkData = refreshed }
            if didStart { url.stopAccessingSecurityScopedResource() }
        }

        isSyncing = true
        syncStatus = nil
        let container = modelContext.container
        Task {
            let importer = USBImporter(modelContainer: container)
            do {
                let result = try await importer.sync(folder: url)
                if result.importedCount == 0 && result.skipped == 0 && result.failures.isEmpty {
                    syncStatus = "Up to date."
                } else {
                    var parts = ["Imported \(result.importedCount)"]
                    if result.skipped > 0 { parts.append("skipped \(result.skipped)") }
                    if !result.failures.isEmpty { parts.append("\(result.failures.count) failed") }
                    syncStatus = parts.joined(separator: ", ")
                }
            } catch {
                syncStatus = "Sync failed: \(error.localizedDescription)"
            }
            isSyncing = false
            uploadQueue.kick()
        }
    }

    private func saveBookmark(for url: URL) {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        do {
            bookmarkData = try url.bookmarkData()
        } catch {
            syncStatus = "Couldn't remember folder: \(error.localizedDescription)"
        }
    }

    private func delete(at offsets: IndexSet) {
        for idx in offsets {
            let rec = recordings[idx]
            try? FileManager.default.removeItem(at: rec.fileURL)
            modelContext.delete(rec)
        }
        try? modelContext.save()
    }
}

private struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(recording.filename).font(.body.monospaced())
                Spacer()
                UploadBadge(state: recording.uploadState, source: recording.source)
            }
            HStack {
                Text(recording.startedAt,
                     format: .dateTime.year().month().day().hour().minute().second())
                Spacer()
                Text(formatDuration(recording.durationSeconds))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            if let err = recording.uploadError, recording.uploadState == .failed {
                Text(err).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
    }

    private func formatDuration(_ s: Double) -> String {
        let total = Int(s)
        let m = total / 60
        let sec = total % 60
        return String(format: "%d:%02d", m, sec)
    }
}

private struct UploadBadge: View {
    let state: UploadState
    let source: RecordingSource

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(label).fixedSize()
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.15))
        .clipShape(Capsule())
    }

    private var icon: String {
        switch state {
        case .notApplicable: return "iphone"
        case .pending:       return "arrow.up.circle"
        case .uploading:     return "arrow.up.circle.dotted"
        case .analyzed:      return "checkmark.seal.fill"
        case .skipped:       return "equal.circle"
        case .failed:        return "exclamationmark.triangle.fill"
        }
    }

    private var label: String {
        switch state {
        case .notApplicable: return source == .liveLocal ? "Local only" : "—"
        case .pending:       return "Queued"
        case .uploading:     return "Uploading"
        case .analyzed:      return "Uploaded"
        case .skipped:       return "Skipped (dup)"
        case .failed:        return "Failed"
        }
    }

    private var color: Color {
        switch state {
        case .notApplicable: return .secondary
        case .pending:       return .blue
        case .uploading:     return .blue
        case .analyzed:      return .green
        case .skipped:       return .gray
        case .failed:        return .orange
        }
    }
}

private struct UploadSummary: View {
    let recordings: [Recording]

    var body: some View {
        let counts = tally()
        HStack(spacing: 6) {
            if counts.analyzed > 0 { Chip(text: "\(counts.analyzed)", systemImage: "checkmark.seal.fill", color: .green) }
            if counts.inFlight > 0 { Chip(text: "\(counts.inFlight)", systemImage: "arrow.up.circle", color: .blue) }
            if counts.skipped  > 0 { Chip(text: "\(counts.skipped)",  systemImage: "equal.circle", color: .gray) }
            if counts.failed   > 0 { Chip(text: "\(counts.failed)",   systemImage: "exclamationmark.triangle.fill", color: .orange) }
        }
        .font(.caption2.weight(.semibold))
        .textCase(nil)
    }

    private func tally() -> (analyzed: Int, inFlight: Int, skipped: Int, failed: Int) {
        var a = 0, i = 0, s = 0, f = 0
        for r in recordings {
            switch r.uploadState {
            case .analyzed: a += 1
            case .pending, .uploading: i += 1
            case .skipped: s += 1
            case .failed: f += 1
            case .notApplicable: break
            }
        }
        return (a, i, s, f)
    }

    private struct Chip: View {
        let text: String
        let systemImage: String
        let color: Color
        var body: some View {
            HStack(spacing: 2) {
                Image(systemName: systemImage)
                Text(text)
            }
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
        }
    }
}
