import SwiftUI

struct PaperECGRow: View {
    let samples: [Int16]
    let startIndex: Int
    let sampleCount: Int
    let gaps: [ClosedRange<Int>]
    let sampleRate: Double
    let secondsPerRow: Double
    let ampGain: Double
    let valueMid: Double
    let valueHalfSpan: Double
    let startLabel: String

    private static let minorGrid = Color(red: 1.0, green: 0.87, blue: 0.87)
    private static let majorGrid = Color(red: 0.95, green: 0.55, blue: 0.55)
    private static let traceColor = Color(red: 0.85, green: 0.1, blue: 0.1)
    private static let paper = Color.white

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(Self.paper))
            drawGrid(ctx: ctx, size: size)
            drawGaps(ctx: ctx, size: size)
            drawTrace(ctx: ctx, size: size)

            let text = Text(startLabel)
                .font(.caption2.monospaced())
                .foregroundColor(.black.opacity(0.55))
            ctx.draw(text, at: CGPoint(x: 6, y: 4), anchor: .topLeading)
        }
    }

    private func drawGrid(ctx: GraphicsContext, size: CGSize) {
        var minor = Path()
        var major = Path()

        let minorSec = 0.04
        let minorStepX = size.width * minorSec / secondsPerRow
        if minorStepX >= 0.6 {
            var i = 0
            var x: CGFloat = 0
            while x <= size.width + 0.5 {
                if i % 5 == 0 {
                    major.move(to: CGPoint(x: x, y: 0))
                    major.addLine(to: CGPoint(x: x, y: size.height))
                } else {
                    minor.move(to: CGPoint(x: x, y: 0))
                    minor.addLine(to: CGPoint(x: x, y: size.height))
                }
                i += 1
                x = CGFloat(i) * minorStepX
            }
        } else {
            let majorStepX = size.width * 0.2 / secondsPerRow
            var x: CGFloat = 0
            while x <= size.width + 0.5 {
                major.move(to: CGPoint(x: x, y: 0))
                major.addLine(to: CGPoint(x: x, y: size.height))
                x += majorStepX
            }
        }

        let minorRows = 10
        for j in 0...minorRows {
            let y = CGFloat(j) * size.height / CGFloat(minorRows)
            if j % 5 == 0 {
                major.move(to: CGPoint(x: 0, y: y))
                major.addLine(to: CGPoint(x: size.width, y: y))
            } else {
                minor.move(to: CGPoint(x: 0, y: y))
                minor.addLine(to: CGPoint(x: size.width, y: y))
            }
        }

        ctx.stroke(minor, with: .color(Self.minorGrid), lineWidth: 0.3)
        ctx.stroke(major, with: .color(Self.majorGrid), lineWidth: 0.6)
    }

    private func drawGaps(ctx: GraphicsContext, size: CGSize) {
        guard !gaps.isEmpty, sampleCount > 1 else { return }
        let xScale = size.width / CGFloat(sampleCount - 1)
        for g in gaps {
            let x0 = CGFloat(g.lowerBound) * xScale
            let x1 = CGFloat(g.upperBound) * xScale
            let rect = CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: size.height)
            ctx.fill(Path(rect), with: .color(Color.gray.opacity(0.25)))
        }
    }

    private func drawTrace(ctx: GraphicsContext, size: CGSize) {
        guard sampleCount > 1,
              startIndex >= 0,
              startIndex + sampleCount <= samples.count else { return }

        let halfRange = max(valueHalfSpan / max(ampGain, 0.01), 1.0)
        let h = size.height
        let xScale = size.width / CGFloat(sampleCount - 1)

        @inline(__always) func yFor(_ v: Int16) -> CGFloat {
            let norm = (Double(v) - valueMid) / halfRange
            var y = h / 2 - CGFloat(norm) * (h / 2)
            if y < 0 { y = 0 }
            if y > h { y = h }
            return y
        }

        var path = Path()
        var drawing = false
        var gapIdx = 0

        for i in 0..<sampleCount {
            while gapIdx < gaps.count && gaps[gapIdx].upperBound < i { gapIdx += 1 }
            let inGap = gapIdx < gaps.count && gaps[gapIdx].contains(i)
            if inGap {
                drawing = false
                continue
            }
            let x = CGFloat(i) * xScale
            let y = yFor(samples[startIndex + i])
            if drawing {
                path.addLine(to: CGPoint(x: x, y: y))
            } else {
                path.move(to: CGPoint(x: x, y: y))
                drawing = true
            }
        }

        ctx.stroke(path, with: .color(Self.traceColor), lineWidth: 1.3)
    }
}
