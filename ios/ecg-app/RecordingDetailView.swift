import SwiftUI

struct RecordingDetailView: View {
    let recording: Recording

    @State private var samples: [Int16] = []
    @State private var windowSeconds: Double = 6
    @State private var startSecond: Double = 0

    private let sampleRate: Double = 125

    private var durationSeconds: Double {
        Double(samples.count) / sampleRate
    }

    private var windowSampleCount: Int {
        max(1, Int(windowSeconds * sampleRate))
    }

    private var visibleSamples: [Int16] {
        let start = Int(startSecond * sampleRate)
        guard start < samples.count else { return [] }
        let end = min(samples.count, start + windowSampleCount)
        return Array(samples[start..<end])
    }

    private var maxStartSecond: Double {
        max(0, durationSeconds - windowSeconds)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WaveformView(samples: visibleSamples, windowSize: windowSampleCount)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(spacing: 10) {
                    HStack {
                        Text(timeLabel(startSecond))
                        Spacer()
                        Text("\(Int(windowSeconds))s window")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(timeLabel(durationSeconds))
                    }
                    .font(.caption.monospacedDigit())

                    Slider(value: $startSecond, in: 0...max(maxStartSecond, 0.001))
                        .disabled(maxStartSecond <= 0)

                    Picker("Window", selection: $windowSeconds) {
                        Text("3s").tag(3.0)
                        Text("6s").tag(6.0)
                        Text("10s").tag(10.0)
                        Text("30s").tag(30.0)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: windowSeconds) { _, _ in
                        startSecond = min(startSecond, maxStartSecond)
                    }
                }

                GroupBox("Details") {
                    VStack(alignment: .leading, spacing: 6) {
                        detailRow("Filename", recording.filename)
                        detailRow("Started",
                                  recording.startedAt.formatted(date: .abbreviated, time: .standard))
                        if let ended = recording.endedAt {
                            detailRow("Ended",
                                      ended.formatted(date: .abbreviated, time: .standard))
                        }
                        detailRow("Duration", timeLabel(durationSeconds))
                        detailRow("Samples", recording.sampleCount.formatted())
                        detailRow("Size", ByteCountFormatter.string(
                            fromByteCount: Int64(recording.byteCount), countStyle: .file))
                        if let device = recording.deviceId {
                            detailRow("Device", device)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle(recording.filename)
        .task(id: recording.id) {
            samples = recording.loadSamples()
            startSecond = 0
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.body.monospacedDigit())
        }
    }

    private func timeLabel(_ s: Double) -> String {
        let total = max(0, Int(s))
        let h = total / 3600
        let m = (total / 60) % 60
        let sec = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }
}
