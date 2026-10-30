import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// `--wavebench`: how long one frame of the Wave shape takes to draw at a large retina size.
@MainActor
enum WaveBench {
    static func run() {
        _ = NSApplication.shared
        let sr = 44100.0
        let ring = SampleRing(), hist = WaveHistory()
        hist.update(from: ring, dt: 1.0 / 60)
        // a few seconds of busy, music-like sound
        var phase = 0.0
        for _ in 0..<400 {
            let block = (0..<1024).map { i -> Float in
                let t = (phase + Double(i)) / sr
                return Float(0.3 * sin(2 * .pi * 110 * t) + 0.2 * sin(2 * .pi * 660 * t) + 0.1 * sin(2 * .pi * 2300 * t) + 0.05 * Double.random(in: -1...1))
            }
            phase += 1024; ring.write(block, sampleRate: sr); hist.update(from: ring, dt: 1.0 / 43)
        }
        let w = 2800, h = 1000
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let ctx = gc.cgContext
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        let size = CGSize(width: w, height: h)
        let analyzer = SpectrumAnalyzer()
        // the individual steps, so the slow ones are obvious
        func time(_ label: String, _ body: () -> Void) {
            body()
            let t0 = CFAbsoluteTimeGetCurrent()
            for _ in 0..<20 { body() }
            print(String(format: "    %-46@ %6.2f ms", label as NSString, (CFAbsoluteTimeGetCurrent() - t0) / 20 * 1000))
        }
        let nPts = 1400
        func zig(_ closed: Bool) -> CGMutablePath {
            let p = CGMutablePath()
            for i in 0..<nPts {
                let x = CGFloat(i) * CGFloat(w) / CGFloat(nPts)
                let a = CGPoint(x: x, y: 400 - CGFloat.random(in: 0...200)), b = CGPoint(x: x + 1, y: 400 + CGFloat.random(in: 0...200))
                if i == 0 { p.move(to: a) } else { p.addLine(to: a) }
                p.addLine(to: b)
            }
            if closed { p.addLine(to: CGPoint(x: CGFloat(w), y: 400)); p.addLine(to: CGPoint(x: 0, y: 400)); p.closeSubpath() }
            return p
        }
        let zp = zig(false), zf = zig(true)
        ctx.setStrokeColor(NSColor.systemRed.cgColor); ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.3).cgColor)
        time("stroke zigzag 1.5 px, round joins") { ctx.setLineJoin(.round); ctx.setLineWidth(1.5); ctx.addPath(zp); ctx.strokePath() }
        time("stroke zigzag 1.5 px, miter joins") { ctx.setLineJoin(.miter); ctx.setLineWidth(1.5); ctx.addPath(zp); ctx.strokePath() }
        time("stroke zigzag 7 px, round joins") { ctx.setLineJoin(.round); ctx.setLineWidth(7); ctx.addPath(zp); ctx.strokePath() }
        time("fill zigzag polygon") { ctx.addPath(zf); ctx.fillPath() }
        let space = CGColorSpaceCreateDeviceRGB()
        let grad = CGGradient(colorsSpace: space, colors: [NSColor.red.cgColor, NSColor.blue.cgColor] as CFArray, locations: [0, 1])!
        time("linear gradient over 2800x320") { ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: 600, width: w, height: 320)); ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 600), end: CGPoint(x: 0, y: 920), options: []); ctx.restoreGState() }
        time("fill a 2800x1000 rectangle, solid") { ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        time("full-size radial gradient") { ctx.drawRadialGradient(grad, startCenter: CGPoint(x: 1400, y: 500), startRadius: 0, endCenter: CGPoint(x: 1400, y: 500), endRadius: 1700, options: []) }
        time("columns (extents) for the wave, window 1 s") { _ = WaveScrollDraw.columns(hist, window: 1.0, count: 1400) }
        for window in [0.02, 0.1, 1.0, 3.0] {
            time(String(format: "wave path for Core Animation, window %.2f s", window)) { _ = WaveScrollDraw.path(CGSize(width: 1400, height: 500), history: hist, window: window) }
        }
        for window in [0.1, 3.0] {
            var g = SpectrumFrame(bands: [Float](repeating: 0.3, count: 72), peaks: [Float](repeating: 0.3, count: 72), wave: [Float](repeating: 0, count: 1024), level: 0.4, bass: 0.3, time: 0, scroll: hist, scrollWindow: window)
            g.waveformOnLayers = true
            time("what is still drawn by the CPU in Wave mode (spectrum curve)") { VisualizerShapes.draw(.wave, ctx: ctx, size: size, frame: g, palette: .accent, accent: .systemRed) }
        }
        for window in [0.02, 0.1, 1.0, 3.0] {
            let f = SpectrumFrame(bands: [Float](repeating: 0.3, count: 72), peaks: [Float](repeating: 0.3, count: 72), wave: [Float](repeating: 0, count: 1024), level: 0.4, bass: 0.3, time: 0, scroll: hist, scrollWindow: window)
            for _ in 0..<5 { VisualizerShapes.draw(.wave, ctx: ctx, size: size, frame: f, palette: .accent, accent: .systemRed) }
            let t0 = CFAbsoluteTimeGetCurrent()
            let frames = 40
            for _ in 0..<frames {
                VisualizerShapes.background(ctx, size, level: 0.4)
                VisualizerShapes.draw(.wave, ctx: ctx, size: size, frame: f, palette: .accent, accent: .systemRed)
            }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) / Double(frames) * 1000
            print(String(format: "  window %.2f s: %.1f ms per frame (background + wave)", window, ms))
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<60 { ring.write((0..<735).map { _ in Float.random(in: -0.5...0.5) }, sampleRate: sr); analyzer.update(from: ring, dt: 1.0 / 60); hist.update(from: ring, dt: 1.0 / 60) }
        print(String(format: "  analyzer + history update: %.2f ms per frame", (CFAbsoluteTimeGetCurrent() - t0) / 60 * 1000))
        let t1 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<40 { VisualizerShapes.background(ctx, size, level: 0.4) }
        print(String(format: "  background alone: %.1f ms per frame", (CFAbsoluteTimeGetCurrent() - t1) / 40 * 1000))
    }
}
