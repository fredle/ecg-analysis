import Foundation

@MainActor
@Observable
final class ViewerViewModel {
    struct Payload: Sendable {
        let samples: [Int16]
        let gaps: [ClosedRange<Int>]
        let startMs: Int64
        let sampleRate: Int
        let windowSec: Int
    }

    enum ViewState {
        case idle
        case loading
        case ready(Payload)
        case error(String)
    }

    var state: ViewState = .idle
    var center: Date = Date() {
        didSet { if center != oldValue { reload() } }
    }
    var windowSec: Int = 60 {
        didSet { if windowSec != oldValue { reload() } }
    }

    private var loadTask: Task<Void, Never>?

    func loadIfIdle() {
        if case .idle = state { reload() }
    }

    func reload() {
        loadTask?.cancel()
        let c = center
        let w = windowSec
        loadTask = Task {
            state = .loading
            do {
                let response = try await APIClient.shared.ecgRaw(center: c, windowSec: w)
                if Task.isCancelled { return }
                let samples = response.samples.map { Int16(clamping: $0) }
                let gaps = Self.computeGaps(response: response)
                state = .ready(Payload(
                    samples: samples,
                    gaps: gaps,
                    startMs: response.start_ms,
                    sampleRate: response.sample_rate,
                    windowSec: response.window_sec
                ))
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                state = .error(error.localizedDescription)
            }
        }
    }

    static func computeGaps(response: ECGRawWindow) -> [ClosedRange<Int>] {
        let totalSamples = response.samples.count
        guard totalSamples > 0 else { return [] }

        let windowStartMs = response.start_ms
        let windowEndMs = windowStartMs + Int64(response.window_sec) * 1000
        let sampleRate = Double(response.sample_rate)

        let covered = response.data_ranges
            .compactMap { pair -> (Int64, Int64)? in
                guard pair.count >= 2 else { return nil }
                let s = max(pair[0], windowStartMs)
                let e = min(pair[1], windowEndMs)
                return s < e ? (s, e) : nil
            }
            .sorted(by: { $0.0 < $1.0 })

        var gaps: [ClosedRange<Int>] = []
        var cursor = windowStartMs
        for (s, e) in covered {
            if cursor < s {
                let fromIdx = max(0, Int(Double(cursor - windowStartMs) / 1000.0 * sampleRate))
                let toIdx = min(totalSamples - 1,
                                Int(Double(s - windowStartMs) / 1000.0 * sampleRate))
                if fromIdx <= toIdx { gaps.append(fromIdx...toIdx) }
            }
            cursor = max(cursor, e)
        }
        if cursor < windowEndMs {
            let fromIdx = max(0, Int(Double(cursor - windowStartMs) / 1000.0 * sampleRate))
            let toIdx = totalSamples - 1
            if fromIdx <= toIdx { gaps.append(fromIdx...toIdx) }
        }
        return gaps
    }
}
