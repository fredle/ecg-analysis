#!/usr/bin/env swift

// Generates a 1024x1024 app icon PNG with an ECG waveform.
// Usage: swift tools/make-icon.swift <out.png>

import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <out.png>\n".data(using: .utf8)!)
    exit(2)
}
let outPath = CommandLine.arguments[1]

let side: CGFloat = 1024
let size = CGSize(width: side, height: side)

guard
    let space = CGColorSpace(name: CGColorSpace.sRGB),
    let ctx = CGContext(
        data: nil,
        width: Int(side),
        height: Int(side),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
else { exit(1) }

// Flip to top-left origin so y grows downward.
ctx.translateBy(x: 0, y: side)
ctx.scaleBy(x: 1, y: -1)

// Background: deep-red radial gradient.
let inner = CGColor(red: 0.96, green: 0.28, blue: 0.33, alpha: 1)
let outer = CGColor(red: 0.56, green: 0.07, blue: 0.16, alpha: 1)
if let grad = CGGradient(
    colorsSpace: space,
    colors: [inner, outer] as CFArray,
    locations: [0, 1]
) {
    ctx.drawRadialGradient(
        grad,
        startCenter: CGPoint(x: side * 0.42, y: side * 0.38),
        startRadius: 0,
        endCenter: CGPoint(x: side / 2, y: side / 2),
        endRadius: side * 0.75,
        options: [.drawsAfterEndLocation]
    )
} else {
    ctx.setFillColor(inner)
    ctx.fill(CGRect(origin: .zero, size: size))
}

// Subtle grid — faint horizontal baseline marks.
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
ctx.setLineWidth(3)
for i in 1..<8 {
    let y = side * CGFloat(i) / 8
    ctx.move(to: CGPoint(x: side * 0.08, y: y))
    ctx.addLine(to: CGPoint(x: side * 0.92, y: y))
}
ctx.strokePath()

// ECG trace — one PQRST heartbeat, roughly centered.
let mid = side / 2
let baseY = mid + side * 0.02
let trace: [(CGFloat, CGFloat)] = [
    (0.06, 0),
    (0.22, 0),            // flat baseline
    (0.28, -0.06),        // P
    (0.32, -0.02),
    (0.36, 0),
    (0.40, 0.11),         // Q
    (0.44, -0.36),        // R spike
    (0.48, 0.20),         // S
    (0.52, 0),
    (0.62, -0.12),        // T
    (0.70, 0),
    (0.94, 0),            // baseline
]
let points = trace.map { (fx, fy) in
    CGPoint(x: side * fx, y: baseY + side * fy)
}

// Glow under the trace.
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setShadow(
    offset: .zero,
    blur: 24,
    color: CGColor(red: 1, green: 1, blue: 1, alpha: 0.4)
)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.setLineWidth(46)

let path = CGMutablePath()
path.move(to: points[0])
for p in points.dropFirst() { path.addLine(to: p) }
ctx.addPath(path)
ctx.strokePath()

// Encode.
guard let cgImage = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath) — \(data.count) bytes")
