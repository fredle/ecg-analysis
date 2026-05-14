import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(ECGCoordinator.self) private var coordinator
    @Environment(UploadQueue.self) private var uploadQueue
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("er1FolderBookmark") private var bookmarkData: Data?

    var body: some View {
        TabView {
            LiveView()
                .tabItem { Label("Live", systemImage: "waveform.path.ecg") }
            AnalyticsView()
                .tabItem { Label("Analytics", systemImage: "chart.bar") }
            TimelineView()
                .tabItem { Label("Timeline", systemImage: "list.bullet.rectangle") }
            NavigationStack {
                ViewerView()
            }
            .tabItem { Label("Viewer", systemImage: "waveform") }
            LibraryView()
                .tabItem { Label("Library", systemImage: "tray.full") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task { backgroundSync() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { backgroundSync() }
        }
    }

    private func backgroundSync() {
        guard let bookmark = bookmarkData else { return }
        let container = modelContext.container
        let queue = uploadQueue
        Task {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark,
                                     options: [],
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &stale) else { return }
            let importer = USBImporter(modelContainer: container)
            _ = try? await importer.sync(folder: url)
            queue.kick()
        }
    }
}

private struct LiveView: View {
    @Environment(ECGCoordinator.self) private var coordinator
    @State private var secondsPerRow: Int = 10
    @State private var ampGain: Double = 0.5

    private static let rowOptions: [Int] = [5, 10, 15, 20, 30]
    private static let gainOptions: [Double] = [0.1, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(.systemBackground))
                Divider()
                paperContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
            }
            .navigationTitle("Live")
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 6) {
            HStack {
                statusBadge
                Spacer()
                if coordinator.client.lastBPM > 0 {
                    HStack(spacing: 2) {
                        Text("\(coordinator.client.lastBPM)")
                            .font(.title2.bold().monospacedDigit())
                        Text("bpm").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "battery.100")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(coordinator.client.batteryPct)%")
                        .font(.caption).foregroundStyle(.secondary)
                }
                recordButton
            }

            WaveformView(
                samples: coordinator.client.displaySamples,
                latestSampleTime: coordinator.client.lastPacketAt,
                windowSize: ER1Client.displayWindow,
                fillerSentinel: ER1Client.fillerSample
            )
            .frame(height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 12) {
                zoomControl(label: "Time", value: "\(secondsPerRow)s",
                            canStep: canStep(secondsPerRow, in: Self.rowOptions),
                            onDecrease: { step(&secondsPerRow, in: Self.rowOptions, dir: -1) },
                            onIncrease: { step(&secondsPerRow, in: Self.rowOptions, dir: 1) })
                zoomControl(label: "Gain", value: formatGain(ampGain),
                            canStep: canStep(ampGain, in: Self.gainOptions),
                            onDecrease: { step(&ampGain, in: Self.gainOptions, dir: -1) },
                            onIncrease: { step(&ampGain, in: Self.gainOptions, dir: 1) })
            }
        }
    }

    @ViewBuilder
    private var paperContent: some View {
        if isConnected {
            if coordinator.client.paperSamples.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for ECG data…")
                        .foregroundStyle(.secondary).font(.caption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LivePaperView(
                    client: coordinator.client,
                    secondsPerRow: secondsPerRow,
                    ampGain: ampGain
                )
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.largeTitle).foregroundStyle(.secondary)
                Text(deviceStatus)
                    .foregroundStyle(.secondary).font(.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isConnected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(deviceStatus)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var recordButton: some View {
        if coordinator.isRecording {
            Button(role: .destructive) { coordinator.stopRecording() } label: {
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(.red)
            }
        } else {
            Button { coordinator.startRecording() } label: {
                Image(systemName: "record.circle")
            }
            .disabled(!isConnected)
        }
    }

    private func zoomControl(label: String, value: String,
                             canStep: (Bool, Bool),
                             onDecrease: @escaping () -> Void,
                             onIncrease: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Button(action: onDecrease) {
                Image(systemName: "minus").frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered).disabled(!canStep.0)
            Text(value).font(.caption.monospaced()).frame(minWidth: 40)
            Button(action: onIncrease) {
                Image(systemName: "plus").frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered).disabled(!canStep.1)
        }
    }

    private func canStep<T: Equatable>(_ current: T, in options: [T]) -> (Bool, Bool) {
        guard let i = options.firstIndex(of: current) else { return (false, false) }
        return (i > 0, i < options.count - 1)
    }

    private func step<T: Equatable>(_ value: inout T, in options: [T], dir: Int) {
        guard let i = options.firstIndex(of: value) else { return }
        let j = i + dir
        guard j >= 0, j < options.count else { return }
        value = options[j]
    }

    private func formatGain(_ g: Double) -> String {
        g == g.rounded() ? "\(Int(g))×" : String(format: "%.1f×", g)
    }

    private var isConnected: Bool {
        if case .connected = coordinator.client.state { return true }
        return false
    }

    private var deviceStatus: String {
        switch coordinator.client.state {
        case .poweredOff:        return "Bluetooth off"
        case .unauthorized:      return "Not authorized"
        case .idle:              return "Idle"
        case .scanning:          return "Scanning…"
        case .connecting(let n): return "Connecting \(n)…"
        case .connected(let n):  return n
        }
    }
}
