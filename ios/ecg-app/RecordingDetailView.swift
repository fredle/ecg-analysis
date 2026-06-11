import SwiftUI

struct RecordingDetailView: View {
    let recording: Recording

    @State private var samples: [Int16] = []
    @State private var secondsPerRow: Int = 10
    @State private var ampGain: Double = 0.5

    private let sampleRate: Double = 125

    private var durationSeconds: Double {
        Double(samples.count) / sampleRate
    }

    private static let rowOptions: [Int] = [5, 10, 15, 20, 30]
    private static let gainOptions: [Double] = [0.25, 0.5, 1.0, 2.0, 4.0, 8.0]

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(.systemBackground))
            Divider()
            if samples.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading…").foregroundStyle(.secondary).font(.caption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                paperScroller
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle(recording.filename)
        .task(id: recording.id) {
            samples = recording.loadSamples()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 10) {
            detailsBar

            HStack(spacing: 12) {
                zoomControl(
                    label: "Time",
                    value: "\(secondsPerRow)s",
                    canDecrease: canStep(Self.rowOptions, current: secondsPerRow, dir: -1),
                    canIncrease: canStep(Self.rowOptions, current: secondsPerRow, dir: 1),
                    onDecrease: { step(Self.rowOptions, current: &secondsPerRow, dir: -1) },
                    onIncrease: { step(Self.rowOptions, current: &secondsPerRow, dir: 1) }
                )
                zoomControl(
                    label: "Gain",
                    value: ampGain == ampGain.rounded() ? "\(Int(ampGain))×" : String(format: "%.1f×", ampGain),
                    canDecrease: canStep(Self.gainOptions, current: ampGain, dir: -1),
                    canIncrease: canStep(Self.gainOptions, current: ampGain, dir: 1),
                    onDecrease: { step(Self.gainOptions, current: &ampGain, dir: -1) },
                    onIncrease: { step(Self.gainOptions, current: &ampGain, dir: 1) }
                )
            }
        }
    }

    private var detailsBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.startedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                Text(timeLabel(durationSeconds))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let device = recording.deviceId {
                Text(device).font(.caption2).foregroundStyle(.secondary)
            }
            if recording.source.isUploadable {
                UploadStatusLabel(state: recording.uploadState)
            }
        }
    }

    // MARK: - Paper scroller

    private var paperScroller: some View {
        let rowSamples = secondsPerRow * Int(sampleRate)
        let totalRows = max(1, samples.count / rowSamples)
        let scale = computeScale()

        return ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(0..<totalRows, id: \.self) { rowIndex in
                    let offset = rowIndex * rowSamples
                    let count = min(rowSamples, samples.count - offset)
                    let seconds = Double(offset) / sampleRate
                    PaperECGRow(
                        samples: samples,
                        startIndex: offset,
                        sampleCount: count,
                        gaps: [],
                        sampleRate: sampleRate,
                        secondsPerRow: Double(secondsPerRow),
                        ampGain: ampGain,
                        valueMid: scale.mid,
                        valueHalfSpan: scale.halfSpan,
                        startLabel: timeLabel(seconds)
                    )
                    .frame(height: 130)
                    .padding(.horizontal, 6)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Scale

    private func computeScale() -> (mid: Double, halfSpan: Double) {
        guard samples.count > 10 else { return (0, 500) }
        var sorted = samples.filter { !$0.isECGSaturation }
        guard sorted.count > 10 else { return (0, 500) }
        sorted.sort()
        let p05 = Double(sorted[Int(Double(sorted.count) * 0.05)])
        let p95 = Double(sorted[Int(Double(sorted.count) * 0.95)])
        let mid = (p05 + p95) / 2.0
        let span = max(p95 - p05, 400.0)
        return (mid, span / 2.0 * 1.2)
    }

    // MARK: - Zoom controls

    private func zoomControl(label: String,
                             value: String,
                             canDecrease: Bool,
                             canIncrease: Bool,
                             onDecrease: @escaping () -> Void,
                             onIncrease: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Button(action: onDecrease) {
                Image(systemName: "minus").frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .disabled(!canDecrease)

            Text(value)
                .font(.caption.monospaced())
                .frame(minWidth: 48)

            Button(action: onIncrease) {
                Image(systemName: "plus").frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .disabled(!canIncrease)
        }
    }

    private func canStep<T: Equatable>(_ options: [T], current: T, dir: Int) -> Bool {
        guard let i = options.firstIndex(of: current) else { return true }
        let j = i + dir
        return j >= 0 && j < options.count
    }

    private func step<T: Equatable>(_ options: [T], current: inout T, dir: Int) {
        guard let i = options.firstIndex(of: current) else { return }
        let j = i + dir
        guard j >= 0, j < options.count else { return }
        current = options[j]
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

struct UploadStatusLabel: View {
    let state: UploadState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(label)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(color)
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
        case .notApplicable: return "Local"
        case .pending:       return "Not uploaded"
        case .uploading:     return "Uploading…"
        case .uploaded:      return "Analysing…"
        case .analyzed:      return "Analysed"
        case .skipped:       return "Duplicate"
        case .failed:        return "Upload failed"
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
