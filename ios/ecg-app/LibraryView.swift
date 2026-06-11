import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(UploadQueue.self) private var uploadQueue
    @Environment(ECGCoordinator.self) private var coordinator
    @Query(sort: \Recording.startedAt, order: .reverse) private var recordings: [Recording]
    @AppStorage("er1FolderBookmark") private var bookmarkData: Data?

    @State private var syncStatus: String?
    @State private var isSyncing = false
    @State private var showingPicker = false
    @State private var safeToDisconnect = false

    @State private var isPulling = false
    @State private var pullProgress: String?
    @State private var pullStatus: String?

    var body: some View {
        NavigationStack {
            List {
                bluetoothSection
                usbSection
                if uploadQueue.isUploading || uploadQueue.queueDepth > 0 || uploadQueue.inferenceCount > 0 || uploadQueue.lastError != nil {
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

    // MARK: - Bluetooth pull

    private var bluetoothSection: some View {
        Section("Bluetooth") {
            Button {
                Task { await runBluetoothPull() }
            } label: {
                HStack {
                    Label("Pull recordings from device", systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    if isPulling { ProgressView() }
                }
            }
            .disabled(isPulling || !isDeviceConnected || coordinator.isRecording)

            if !isDeviceConnected {
                Text("Connect your ER1 to pull stored recordings.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if coordinator.isRecording {
                Text("Stop the live recording before pulling.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let progress = pullProgress {
                Text(progress).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let status = pullStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var isDeviceConnected: Bool {
        if case .connected = coordinator.client.state { return true }
        return false
    }

    // MARK: - USB

    private var usbSection: some View {
        Section("USB import") {
            if safeToDisconnect {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Files saved \u{2014} safe to disconnect")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button {
                        withAnimation { safeToDisconnect = false }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
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
        Section("Activity") {
            if uploadQueue.isUploading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Uploading…")
                    Spacer()
                    if uploadQueue.queueDepth > 1 {
                        Text("\(uploadQueue.queueDepth - 1) more in queue")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            } else if uploadQueue.queueDepth > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                    Text("\(uploadQueue.queueDepth) waiting to upload")
                }
                .font(.subheadline)
            }
            if uploadQueue.inferenceCount > 0 {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Analysing \(uploadQueue.inferenceCount) recording\(uploadQueue.inferenceCount == 1 ? "" : "s")…")
                    Spacer()
                }
                .font(.subheadline)
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
                        RecordingRow(recording: rec) {
                            uploadQueue.retry(rec)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { delete(rec) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        if rec.source.isUploadable && rec.uploadState != .uploading {
                            Button { uploadQueue.retry(rec) } label: {
                                Label(rec.uploadState == .pending ? "Upload" : "Re-upload",
                                      systemImage: "arrow.clockwise")
                            }
                            .tint(.orange)
                        }
                    }
                }
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

    @MainActor
    private func runBluetoothPull() async {
        guard !isPulling, isDeviceConnected, !coordinator.isRecording else { return }
        isPulling = true
        pullStatus = nil
        pullProgress = "Listing recordings…"
        safeToDisconnect = false

        let client = coordinator.client
        client.beginTransfer()
        defer {
            client.endTransfer()
            isPulling = false
            pullProgress = nil
            uploadQueue.kick()
        }

        do {
            let names = try await client.listFiles()
            let existing = Set(recordings.map(\.filename))
            // Device names are `R<ts>`; an imported recording has filename `R<ts>`.
            let wanted = names.filter { !existing.contains($0) }
            guard !wanted.isEmpty else {
                pullStatus = "Up to date \u{2014} \(names.count) on device, all imported."
                return
            }

            let importer = BLEImporter(modelContainer: modelContext.container)
            var imported = 0
            for (i, name) in wanted.enumerated() {
                pullProgress = "Downloading \(i + 1)/\(wanted.count): \(name)"
                let data = try await client.downloadFile(name) { received, total in
                    let pct = total > 0 ? received * 100 / total : 0
                    pullProgress = "\(name)  \(i + 1)/\(wanted.count)  \(pct)%"
                }
                if try await importer.importFile(name: name, data: data) { imported += 1 }
            }
            pullStatus = "Imported \(imported) recording\(imported == 1 ? "" : "s")."
        } catch {
            pullStatus = "Pull failed: \(error.localizedDescription)"
        }
    }

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
        safeToDisconnect = false
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
                withAnimation { safeToDisconnect = true }
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

    private func delete(_ rec: Recording) {
        try? FileManager.default.removeItem(at: rec.fileURL)
        modelContext.delete(rec)
        try? modelContext.save()
    }

    private func delete(at offsets: IndexSet) {
        for idx in offsets {
            delete(recordings[idx])
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording
    var onRetry: (() -> Void)?

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
            if recording.uploadState == .failed {
                HStack(spacing: 6) {
                    if let err = recording.uploadError {
                        Text(err).foregroundStyle(.red).lineLimit(2)
                    }
                    Spacer()
                    if let onRetry {
                        Button(action: onRetry) {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    }
                }
                .font(.caption2)
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
        case .pending:       return "clock"
        case .uploading:     return "arrow.up.circle"
        case .uploaded:      return "brain"
        case .analyzed:      return "checkmark.seal.fill"
        case .skipped:       return "equal.circle"
        case .failed:        return "exclamationmark.triangle.fill"
        }
    }

    private var label: String {
        switch state {
        case .notApplicable: return source == .liveLocal ? "Local" : "—"
        case .pending:       return "Not uploaded"
        case .uploading:     return "Uploading…"
        case .uploaded:      return "Analysing…"
        case .analyzed:      return "Analysed"
        case .skipped:       return "Skipped (dup)"
        case .failed:        return "Failed"
        }
    }

    private var color: Color {
        switch state {
        case .notApplicable: return .secondary
        case .pending:       return .secondary
        case .uploading:     return .blue
        case .uploaded:      return .purple
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
            if counts.analyzed > 0  { Chip(text: "\(counts.analyzed)",  systemImage: "checkmark.seal.fill", color: .green) }
            if counts.analysing > 0 { Chip(text: "\(counts.analysing)", systemImage: "brain", color: .purple) }
            if counts.uploading > 0 { Chip(text: "\(counts.uploading)", systemImage: "arrow.up.circle", color: .blue) }
            if counts.pending > 0   { Chip(text: "\(counts.pending)",   systemImage: "clock", color: .secondary) }
            if counts.failed > 0    { Chip(text: "\(counts.failed)",    systemImage: "exclamationmark.triangle.fill", color: .orange) }
        }
        .font(.caption2.weight(.semibold))
        .textCase(nil)
    }

    private func tally() -> (analyzed: Int, analysing: Int, uploading: Int, pending: Int, failed: Int) {
        var analyzed = 0, analysing = 0, uploading = 0, pending = 0, failed = 0
        for r in recordings where r.source.isUploadable {
            switch r.uploadState {
            case .analyzed, .skipped: analyzed += 1
            case .uploaded:           analysing += 1
            case .uploading:          uploading += 1
            case .pending:            pending += 1
            case .failed:             failed += 1
            case .notApplicable:      break
            }
        }
        return (analyzed, analysing, uploading, pending, failed)
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
