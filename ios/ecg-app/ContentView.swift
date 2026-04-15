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

    var body: some View {
        NavigationStack {
            List {
                Section("Live ECG") {
                    WaveformView(samples: coordinator.client.displaySamples,
                                 latestSampleTime: coordinator.client.lastPacketAt,
                                 windowSize: ER1Client.displayWindow,
                                 fillerSentinel: ER1Client.fillerSample)
                        .frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                Section("Device") {
                    LabeledContent("Status", value: deviceStatus)
                    LabeledContent("Heart rate",
                                   value: coordinator.client.lastBPM > 0 ? "\(coordinator.client.lastBPM) bpm" : "—")
                    LabeledContent("Battery", value: "\(coordinator.client.batteryPct)%")
                    LabeledContent("Samples", value: "\(coordinator.client.totalSamples)")
                }

                Section("HR Relay") {
                    LabeledContent("Advertising",
                                   value: coordinator.hr.state == .advertising ? "Yes" : "No")
                    LabeledContent("Subscribers", value: "\(coordinator.hr.subscriberCount)")
                    LabeledContent("Last BPM sent",
                                   value: coordinator.hr.currentBPM > 0 ? "\(coordinator.hr.currentBPM)" : "—")
                }

                Section("Recording") {
                    if coordinator.isRecording {
                        Button(role: .destructive) { coordinator.stopRecording() } label: {
                            Label("Stop recording", systemImage: "stop.circle.fill")
                        }
                    } else {
                        Button { coordinator.startRecording() } label: {
                            Label("Start recording", systemImage: "record.circle")
                        }
                        .disabled(!isConnected)
                    }
                    if let err = coordinator.recordingError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Live")
        }
    }

    private var isConnected: Bool {
        if case .connected = coordinator.client.state { return true }
        return false
    }

    private var deviceStatus: String {
        switch coordinator.client.state {
        case .poweredOff:        return "Bluetooth off"
        case .unauthorized:      return "Bluetooth not authorized"
        case .idle:              return "Idle"
        case .scanning:          return "Scanning…"
        case .connecting(let n): return "Connecting \(n)…"
        case .connected(let n):  return n
        }
    }
}
