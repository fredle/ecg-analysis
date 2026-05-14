import ActivityKit
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ECGCoordinator {
    let client = ER1Client()
    let hr = HRPeripheral()
    let recorder = ECGRecorder()

    private(set) var isRecording: Bool = false
    private(set) var recordingError: String?
    private var activeRecording: Recording?
    private weak var modelContext: ModelContext?

    private var liveActivity: Activity<ECGRecordingAttributes>?
    private var lastActivityUpdate: Date = .distantPast

    init() {
        client.onBPM = { [weak self] bpm in
            self?.hr.update(bpm: bpm)
        }
        client.onSamples = { [weak self] samples in
            self?.handleSamples(samples)
        }
    }

    func attach(context: ModelContext) {
        self.modelContext = context
    }

    private func handleSamples(_ samples: [Int16]) {
        guard isRecording, let rec = activeRecording else { return }
        do {
            try recorder.append(samples: samples)
            rec.sampleCount = recorder.sampleCount
            rec.byteCount = recorder.byteCount
            updateLiveActivity()
        } catch {
            recordingError = error.localizedDescription
            stopRecording()
        }
    }

    func startRecording() {
        guard !isRecording, let ctx = modelContext else { return }
        let started = Date()
        let filename = ECGRecorder.newFilename(at: started)
        let url = Recording.directory.appendingPathComponent(filename)
        do {
            try recorder.start(at: url)
            let rec = Recording(filename: filename, startedAt: started, source: .liveLocal)
            ctx.insert(rec)
            try? ctx.save()
            activeRecording = rec
            isRecording = true
            recordingError = nil
            startLiveActivity(deviceName: client.deviceName, startedAt: started)
        } catch {
            recordingError = error.localizedDescription
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        do {
            try recorder.finish()
        } catch {
            recordingError = error.localizedDescription
        }
        if let rec = activeRecording {
            rec.endedAt = Date()
            rec.sampleCount = recorder.sampleCount
            rec.byteCount = recorder.byteCount
            try? modelContext?.save()
        }
        endLiveActivity()
        activeRecording = nil
        isRecording = false
    }

    // MARK: - Live Activity

    private func startLiveActivity(deviceName: String, startedAt: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = ECGRecordingAttributes(deviceName: deviceName)
        let state = ECGRecordingAttributes.ContentState(
            bpm: client.lastBPM,
            isConnected: true,
            batteryPct: client.batteryPct,
            sampleCount: 0,
            startedAt: startedAt
        )
        let content = ActivityContent(state: state, staleDate: nil)
        do {
            liveActivity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
        } catch {
            // Live Activity is optional — don't block recording
        }
    }

    private func updateLiveActivity() {
        guard let activity = liveActivity, let rec = activeRecording else { return }
        let now = Date()
        guard now.timeIntervalSince(lastActivityUpdate) >= 2 else { return }
        lastActivityUpdate = now

        let isConnected: Bool
        if case .connected = client.state { isConnected = true } else { isConnected = false }

        let state = ECGRecordingAttributes.ContentState(
            bpm: client.lastBPM,
            isConnected: isConnected,
            batteryPct: client.batteryPct,
            sampleCount: rec.sampleCount,
            startedAt: rec.startedAt
        )
        let content = ActivityContent(state: state, staleDate: nil)
        Task { await activity.update(content) }
    }

    private func endLiveActivity() {
        guard let activity = liveActivity else { return }
        let finalState = ECGRecordingAttributes.ContentState(
            bpm: 0,
            isConnected: false,
            batteryPct: client.batteryPct,
            sampleCount: activeRecording?.sampleCount ?? recorder.sampleCount,
            startedAt: activeRecording?.startedAt ?? Date()
        )
        let content = ActivityContent(state: finalState, staleDate: nil)
        Task { await activity.end(content, dismissalPolicy: .default) }
        liveActivity = nil
    }
}
