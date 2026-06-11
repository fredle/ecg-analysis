import Foundation

@MainActor
@Observable
final class ViewerViewModel {
    struct Row: Identifiable, Sendable {
        let id: Int64
        let startMs: Int64
        let bufferOffset: Int
        let sampleCount: Int
        let gaps: [ClosedRange<Int>]
    }

    enum ViewState {
        case idle
        case loading
        case loaded
        case error(String)
    }

    var state: ViewState = .idle
    var center: Date = Date()
    var secondsPerRow: Int = 10
    var ampGain: Double = 0.5

    static let rowOptions: [Int] = [5, 10, 15, 20, 30]
    static let gainOptions: [Double] = [0.25, 0.5, 1.0, 2.0, 4.0, 8.0]

    private(set) var bufferStartMs: Int64 = 0
    private(set) var samples: [Int16] = []
    private(set) var gaps: [ClosedRange<Int>] = []
    private(set) var sampleRate: Int = 125
    private(set) var valueMid: Double = 0
    private(set) var valueHalfSpan: Double = 500

    private let initialWindowSec: Int = 240
    private let pageSec: Int = 120
    private let maxBufferSec: Int = 1800

    private var loadTask: Task<Void, Never>?
    private var isLoadingEarlier = false
    private var isLoadingLater = false

    var rows: [Row] {
        guard sampleRate > 0 else { return [] }
        let samplesPerRow = secondsPerRow * sampleRate
        guard samplesPerRow > 0, samples.count >= samplesPerRow else { return [] }
        let totalRows = samples.count / samplesPerRow
        let intervalMs = 1000.0 / Double(sampleRate)

        var result: [Row] = []
        result.reserveCapacity(totalRows)

        var gapIdx = 0
        for r in 0..<totalRows {
            let lo = r * samplesPerRow
            let hi = lo + samplesPerRow

            while gapIdx < gaps.count && gaps[gapIdx].upperBound < lo { gapIdx += 1 }
            var localGaps: [ClosedRange<Int>] = []
            var scan = gapIdx
            while scan < gaps.count {
                let g = gaps[scan]
                if g.lowerBound >= hi { break }
                let s = max(g.lowerBound, lo) - lo
                let e = min(g.upperBound, hi - 1) - lo
                if s <= e { localGaps.append(s...e) }
                scan += 1
            }

            let rowStartMs = bufferStartMs + Int64(Double(lo) * intervalMs)
            result.append(Row(
                id: rowStartMs,
                startMs: rowStartMs,
                bufferOffset: lo,
                sampleCount: samplesPerRow,
                gaps: localGaps
            ))
        }
        return result
    }

    func jumpTo(_ c: Date) {
        center = c
        loadTask?.cancel()
        state = .loading
        bufferStartMs = 0
        samples = []
        gaps = []
        loadTask = Task { [initialWindowSec] in
            await self.initialLoad(center: c, windowSec: initialWindowSec)
        }
    }

    func loadIfIdle() {
        if case .idle = state { jumpTo(center) }
    }

    func reload() { jumpTo(center) }

    func loadEarlierIfNeeded() {
        guard case .loaded = state, !isLoadingEarlier, !samples.isEmpty else { return }
        isLoadingEarlier = true
        Task { [pageSec] in
            defer { self.isLoadingEarlier = false }
            await self.extendEarlier(pageSec: pageSec)
        }
    }

    func loadLaterIfNeeded() {
        guard case .loaded = state, !isLoadingLater, !samples.isEmpty else { return }
        let bufferEndMs = bufferStartMs + Int64(Double(samples.count) * 1000.0 / Double(sampleRate))
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if bufferEndMs > now - 1_000 { return }
        isLoadingLater = true
        Task { [pageSec] in
            defer { self.isLoadingLater = false }
            await self.extendLater(pageSec: pageSec)
        }
    }

    private func initialLoad(center: Date, windowSec: Int) async {
        do {
            let resp = try await APIClient.shared.ecgRaw(center: center, windowSec: windowSec)
            if Task.isCancelled { return }
            sampleRate = resp.sample_rate
            bufferStartMs = resp.start_ms
            samples = resp.samples.map { Int16(clamping: $0) }
            gaps = Self.computeGaps(response: resp)
            recomputeScale()
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func msPerSample(_ rate: Int) -> Double { 1000.0 / Double(rate) }

    private func shiftRanges(_ ranges: [ClosedRange<Int>], by delta: Int) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        out.reserveCapacity(ranges.count)
        for r in ranges {
            let lo: Int = r.lowerBound + delta
            let hi: Int = r.upperBound + delta
            out.append(lo...hi)
        }
        return out
    }

    private func extendEarlier(pageSec: Int) async {
        let targetEndMs: Int64 = bufferStartMs
        let targetStartMs: Int64 = targetEndMs - Int64(pageSec) * 1000
        let centerMs: Int64 = (targetStartMs + targetEndMs) / 2
        let newCenter = Date(timeIntervalSince1970: Double(centerMs) / 1000.0)
        do {
            let resp = try await APIClient.shared.ecgRaw(center: newCenter, windowSec: pageSec)
            let newSamples: [Int16] = resp.samples.map { Int16(clamping: $0) }
            let msPerSamp: Double = msPerSample(resp.sample_rate)
            let newDurationMs: Int64 = Int64(Double(newSamples.count) * msPerSamp)
            let newEndMs: Int64 = resp.start_ms + newDurationMs

            var prepend: [Int16] = newSamples
            var newBlockGaps: [ClosedRange<Int>] = Self.computeGaps(response: resp)

            if newEndMs < bufferStartMs {
                let gapMs: Int64 = bufferStartMs - newEndMs
                let gapSamples: Int = Int(Double(gapMs) / msPerSamp)
                if gapSamples > 0 {
                    let from: Int = prepend.count
                    prepend.append(contentsOf: Array(repeating: Int16(0), count: gapSamples))
                    let hi: Int = from + gapSamples - 1
                    newBlockGaps.append(from...hi)
                }
            } else if newEndMs > bufferStartMs {
                let overlapMs: Int64 = newEndMs - bufferStartMs
                let overlapSamples: Int = Int(Double(overlapMs) / msPerSamp)
                let keep: Int = max(0, prepend.count - overlapSamples)
                prepend = Array(prepend.prefix(keep))
                newBlockGaps = newBlockGaps.compactMap { g -> ClosedRange<Int>? in
                    if g.lowerBound >= keep { return nil }
                    let hi: Int = Swift.min(g.upperBound, keep - 1)
                    return g.lowerBound...hi
                }
            }

            guard !prepend.isEmpty else { return }
            let shift: Int = prepend.count
            let shifted = shiftRanges(gaps, by: shift)
            gaps = newBlockGaps + shifted
            samples = prepend + samples
            let shiftMs: Int64 = Int64(Double(shift) * msPerSample(sampleRate))
            bufferStartMs -= shiftMs
            trimTail()
            recomputeScale()
        } catch {
            return
        }
    }

    private func extendLater(pageSec: Int) async {
        let msPerSamp: Double = msPerSample(sampleRate)
        let bufferDurationMs: Int64 = Int64(Double(samples.count) * msPerSamp)
        let bufferEndMs: Int64 = bufferStartMs + bufferDurationMs
        let centerMs: Int64 = bufferEndMs + Int64(pageSec) * 500
        let newCenter = Date(timeIntervalSince1970: Double(centerMs) / 1000.0)
        do {
            let resp = try await APIClient.shared.ecgRaw(center: newCenter, windowSec: pageSec)
            let newSamples: [Int16] = resp.samples.map { Int16(clamping: $0) }
            let respMsPerSamp: Double = msPerSample(resp.sample_rate)

            var append: [Int16] = newSamples
            var newBlockGaps: [ClosedRange<Int>] = Self.computeGaps(response: resp)

            if resp.start_ms > bufferEndMs {
                let gapMs: Int64 = resp.start_ms - bufferEndMs
                let leadingGap: Int = Int(Double(gapMs) / respMsPerSamp)
                if leadingGap > 0 {
                    let pad: [Int16] = Array(repeating: Int16(0), count: leadingGap)
                    append = pad + append
                    newBlockGaps = shiftRanges(newBlockGaps, by: leadingGap)
                    newBlockGaps.insert(0...(leadingGap - 1), at: 0)
                }
            } else if resp.start_ms < bufferEndMs {
                let overlapMs: Int64 = bufferEndMs - resp.start_ms
                let overlapSamples: Int = Int(Double(overlapMs) / respMsPerSamp)
                let drop: Int = Swift.min(overlapSamples, append.count)
                append = Array(append.dropFirst(drop))
                newBlockGaps = newBlockGaps.compactMap { g -> ClosedRange<Int>? in
                    if g.upperBound < drop { return nil }
                    let lo: Int = Swift.max(0, g.lowerBound - drop)
                    let hi: Int = g.upperBound - drop
                    return lo...hi
                }
            }

            guard !append.isEmpty else { return }
            let base: Int = samples.count
            samples.append(contentsOf: append)
            let shifted = shiftRanges(newBlockGaps, by: base)
            gaps.append(contentsOf: shifted)
            trimHead()
            recomputeScale()
        } catch {
            return
        }
    }

    private func trimTail() {
        let maxSamples = maxBufferSec * sampleRate
        guard samples.count > maxSamples else { return }
        let excess = samples.count - maxSamples
        samples.removeLast(excess)
        let cutoff = samples.count
        gaps = gaps.compactMap { g in
            if g.lowerBound >= cutoff { return nil }
            return g.lowerBound...min(g.upperBound, cutoff - 1)
        }
    }

    private func trimHead() {
        let maxSamples = maxBufferSec * sampleRate
        guard samples.count > maxSamples else { return }
        let excess = samples.count - maxSamples
        samples.removeFirst(excess)
        bufferStartMs += Int64(Double(excess) * 1000.0 / Double(sampleRate))
        gaps = gaps.compactMap { g in
            if g.upperBound < excess { return nil }
            return max(0, g.lowerBound - excess)...(g.upperBound - excess)
        }
    }

    private func recomputeScale() {
        guard !samples.isEmpty else { return }
        var vals: [Int16] = []
        vals.reserveCapacity(samples.count)
        var gapIdx = 0
        for i in 0..<samples.count {
            while gapIdx < gaps.count && gaps[gapIdx].upperBound < i { gapIdx += 1 }
            if gapIdx < gaps.count && gaps[gapIdx].contains(i) { continue }
            if !samples[i].isECGSaturation { vals.append(samples[i]) }
        }
        guard vals.count > 10 else { return }
        vals.sort()
        let p05 = Double(vals[Int(Double(vals.count) * 0.05)])
        let p95 = Double(vals[Int(Double(vals.count) * 0.95)])
        let mid = (p05 + p95) / 2.0
        let span = max(p95 - p05, 400.0)
        valueMid = mid
        valueHalfSpan = span / 2.0 * 1.2
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
