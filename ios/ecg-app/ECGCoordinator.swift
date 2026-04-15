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
        activeRecording = nil
        isRecording = false
    }
}
