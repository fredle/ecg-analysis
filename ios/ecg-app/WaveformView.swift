import SwiftUI

struct WaveformView: View {
    let samples: [Int16]
    var latestSampleTime: Date? = nil
    var sampleRate: Double = 125
    var lineColor: Color = .green
    var gridColor: Color = Color.green.opacity(0.15)
    var background: Color = .black
    var windowSize: Int = 750
    var gaps: [ClosedRange<Int>] = []
    /// Optional sentinel value in `samples` meaning "no data". Runs of this
    /// value are rendered as a flat grey line and excluded from the y-scale.
    var fillerSentinel: Int16? = nil

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))
            drawGrid(ctx: ctx, size: size)
            drawGaps(ctx: ctx, size: size)
            drawTrace(ctx: ctx, size: size)
        }
        .accessibilityLabel("ECG waveform")
    }

    private func drawGaps(ctx: GraphicsContext, size: CGSize) {
        guard !gaps.isEmpty, windowSize > 1 else { return }
        let xScale = size.width / CGFloat(max(windowSize - 1, 1))
        for gap in gaps {
            let x0 = CGFloat(gap.lowerBound) * xScale
            let x1 = CGFloat(gap.upperBound) * xScale
            let rect = CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: size.height)
            ctx.fill(Path(rect), with: .color(Color.gray.opacity(0.35)))
        }
    }

    private func drawGrid(ctx: GraphicsContext, size: CGSize) {
        var path = Path()
        let xStep = size.width / 6
        let yStep = size.height / 4
        for i in 1..<6 {
            let x = xStep * CGFloat(i)
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        for i in 1..<4 {
            let y = yStep * CGFloat(i)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        ctx.stroke(path, with: .color(gridColor), lineWidth: 0.5)
    }

    private func drawTrace(ctx: GraphicsContext, size: CGSize) {
        guard samples.count > 1 else { return }

        let (minV, maxV) = extent()
        let mid = Double(minV + maxV) / 2.0
        let span = max(Double(maxV - minV), 400.0)
        let halfRange = span / 2.0 * 1.15

        let xScale = size.width / CGFloat(max(windowSize - 1, 1))
        let height = size.height
        let yFor: (Int16) -> CGFloat = { v in
            let norm = (Double(v) - mid) / halfRange
            return height / 2 - CGFloat(norm) * (height / 2)
        }

        // Newest sample pinned to the right edge. Older samples extend left
        // by their index; samples older than windowSize scroll off-screen.
        let lastIndex = samples.count - 1
        let lastSampleX = size.width
        let midY = height / 2

        // Trace path breaks across filler runs; filler is drawn as a flat
        // grey "no data" line at midY.
        var tracePath = Path()
        var fillerPath = Path()
        var tracing = false
        var fillerRunStart: CGFloat? = nil

        @inline(__always) func xFor(_ i: Int) -> CGFloat {
            lastSampleX - CGFloat(lastIndex - i) * xScale
        }

        for i in 0..<samples.count {
            let x = xFor(i)
            if let f = fillerSentinel, samples[i] == f {
                if tracing { tracing = false }
                if fillerRunStart == nil { fillerRunStart = x }
            } else {
                if let start = fillerRunStart {
                    fillerPath.move(to: CGPoint(x: start, y: midY))
                    fillerPath.addLine(to: CGPoint(x: x, y: midY))
                    fillerRunStart = nil
                }
                let y = yFor(samples[i])
                if tracing {
                    tracePath.addLine(to: CGPoint(x: x, y: y))
                } else {
                    tracePath.move(to: CGPoint(x: x, y: y))
                    tracing = true
                }
            }
        }
        if let start = fillerRunStart {
            fillerPath.move(to: CGPoint(x: start, y: midY))
            fillerPath.addLine(to: CGPoint(x: lastSampleX, y: midY))
        }

        if !fillerPath.isEmpty {
            ctx.stroke(fillerPath, with: .color(Color.gray.opacity(0.55)), lineWidth: 1.0)
        }
        ctx.stroke(tracePath, with: .color(lineColor), lineWidth: 1.5)
    }

    private func extent() -> (Int16, Int16) {
        var lo: Int16 = .max
        var hi: Int16 = .min
        for s in samples {
            if let f = fillerSentinel, s == f { continue }
            if s < lo { lo = s }
            if s > hi { hi = s }
        }
        if lo == .max { lo = -500; hi = 500 }
        return (lo, hi)
    }
}
