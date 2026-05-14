import SwiftUI

struct LivePaperView: View {
    let client: ER1Client
    var secondsPerRow: Int = 10
    var ampGain: Double = 1.0

    private static let localTime: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale.current
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    var body: some View {
        let computed = computeRows()
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(computed) { row in
                        PaperECGRow(
                            samples: client.paperSamples,
                            startIndex: row.bufferOffset,
                            sampleCount: row.sampleCount,
                            gaps: row.gaps,
                            sampleRate: ER1Client.sampleRate,
                            secondsPerRow: Double(secondsPerRow),
                            ampGain: ampGain,
                            valueMid: client.paperValueMid,
                            valueHalfSpan: client.paperValueHalfSpan,
                            startLabel: timeLabel(row.startMs)
                        )
                        .frame(height: 130)
                        .padding(.horizontal, 6)
                        .id(row.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: computed.last?.id) { _, newId in
                if let id = newId {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func computeRows() -> [LivePaperRow] {
        let sr = Int(ER1Client.sampleRate)
        let samplesPerRow = secondsPerRow * sr
        guard samplesPerRow > 0, client.paperSamples.count >= samplesPerRow else { return [] }
        let totalRows = client.paperSamples.count / samplesPerRow
        let intervalMs = 1000.0 / ER1Client.sampleRate

        var result: [LivePaperRow] = []
        result.reserveCapacity(totalRows)

        var gapIdx = 0
        for r in 0..<totalRows {
            let lo = r * samplesPerRow
            let hi = lo + samplesPerRow

            while gapIdx < client.paperGaps.count && client.paperGaps[gapIdx].upperBound < lo {
                gapIdx += 1
            }
            var localGaps: [ClosedRange<Int>] = []
            var scan = gapIdx
            while scan < client.paperGaps.count {
                let g = client.paperGaps[scan]
                if g.lowerBound >= hi { break }
                let s = max(g.lowerBound, lo) - lo
                let e = min(g.upperBound, hi - 1) - lo
                if s <= e { localGaps.append(s...e) }
                scan += 1
            }

            let rowStartMs = client.paperStartMs + Int64(Double(lo) * intervalMs)
            result.append(LivePaperRow(
                id: rowStartMs,
                startMs: rowStartMs,
                bufferOffset: lo,
                sampleCount: samplesPerRow,
                gaps: localGaps
            ))
        }
        return result
    }

    private func timeLabel(_ ms: Int64) -> String {
        let d = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        return Self.localTime.string(from: d)
    }
}

private struct LivePaperRow: Identifiable {
    let id: Int64
    let startMs: Int64
    let bufferOffset: Int
    let sampleCount: Int
    let gaps: [ClosedRange<Int>]
}
