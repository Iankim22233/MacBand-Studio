import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import Accelerate

/// A scrolling waveform: the last seconds of the output are kept as raw samples, and the picture glides to the left at a steady
/// speed with the newest sound entering on the right, like the waveform of an audio editor while it records.
/// The columns are made from the samples when drawing, so the detail always matches the zoom: the fewer seconds across the picture,
/// the closer you look at the wave.
final class WaveHistory {
    static let cap = 1 << 19                           // samples kept (about 11 s)
    private static let mask = cap - 1
    private static let lagSeconds = 0.05               // the picture runs this far behind the audio, which evens out the way it arrives in blocks

    private let ring = UnsafeMutablePointer<Float>.allocate(capacity: WaveHistory.cap)
    private(set) var produced = 0                      // samples taken in so far
    private(set) var head = 0.0                        // the sample at the right edge of the picture (a fraction between samples)
    private(set) var sampleRate = 44100.0
    private var lastTotal = -1
    private var scratch = [Float]()
    private var idle = 0.0

    init() { ring.initialize(repeating: 0, count: Self.cap) }
    deinit { ring.deallocate() }

    /// Takes in the audio that arrived since the last call and moves the picture on by `dt` seconds.
    func update(from source: SampleRing, dt: Double) {
        sampleRate = max(8000, source.sampleRate)
        let total = source.newSamples(since: lastTotal, into: &scratch)
        let first = lastTotal < 0
        lastTotal = total
        if scratch.isEmpty { idle += dt } else { idle = 0 }
        if idle > 0.15 {                               // nothing is arriving (stopped): keep gliding over silence
            let n = Int(dt * sampleRate)
            if scratch.count != n { scratch = [Float](repeating: 0, count: n) } else { for i in scratch.indices { scratch[i] = 0 } }
        }
        append(scratch)
        let target = Double(produced) - Self.lagSeconds * sampleRate
        if first || head == 0 { head = max(0, target) }
        // follow the target smoothly: it moves in jumps (blocks of audio), the picture shouldn't
        head += (target - head) * (1 - exp(-dt * 10))
        head = min(head, Double(produced))
    }

    private func append(_ s: [Float]) {
        var w = produced & Self.mask
        for v in s { ring[w] = v; w = (w + 1) & Self.mask }
        produced += s.count
    }

    /// Lowest and highest sample of `count` samples starting at absolute index `start`; nil when they are not (or no longer) there.
    func extent(from start: Int, count: Int) -> (Float, Float)? {
        guard count > 0, start >= 0, start + count <= produced, start >= produced - Self.cap else { return nil }
        let i = start & Self.mask
        let first = min(count, Self.cap - i)
        var lo: Float = 0, hi: Float = 0
        if first == 1 { lo = ring[i]; hi = lo } else { vDSP_minv(ring + i, 1, &lo, vDSP_Length(first)); vDSP_maxv(ring + i, 1, &hi, vDSP_Length(first)) }
        if first < count {                              // the stretch wraps around the end of the buffer
            var lo2: Float = 0, hi2: Float = 0
            vDSP_minv(ring, 1, &lo2, vDSP_Length(count - first)); vDSP_maxv(ring, 1, &hi2, vDSP_Length(count - first))
            lo = min(lo, lo2); hi = max(hi, hi2)
        }
        return (lo, hi)
    }
}

enum WaveScrollDraw {
    /// How many columns the picture is made of for a given width (in points).
    static func columnCount(width: CGFloat) -> Int { max(16, Int(width / 2)) }

    /// The columns (lowest, highest sample) across the picture for `window` seconds of sound, newest last, and the sub-column shift
    /// (0…1 of a column) that makes it glide. Column edges sit on a fixed grid of samples, so a column doesn't change as it scrolls.
    static func columns(_ h: WaveHistory, window: Double, count n: Int) -> (cols: [(Float, Float)?], shift: Double) {
        let spp = max(1, Int((window * h.sampleRate / Double(n)).rounded()))
        let headCol = Int(floor(h.head / Double(spp)))
        let shift = h.head / Double(spp) - Double(headCol)
        var out = [(Float, Float)?](repeating: nil, count: n)
        for k in 0..<n {
            let c = headCol - (n - 1 - k)
            out[k] = h.extent(from: c * spp, count: spp)
        }
        return (out, shift)
    }

    /// The wave as one connected line through every column's lowest and highest point, so there are no gaps at any zoom: close up it
    /// is the wave itself, zoomed out it fills in as the outline of the sound. `window` is how many seconds of sound fit across the
    /// picture (the smaller, the faster it moves and the closer you look).
    static func path(_ s: CGSize, history h: WaveHistory, window: Double) -> CGPath {
        let cy = s.height * 0.42, amp = s.height * 0.3
        let n = columnCount(width: s.width)
        let colW = s.width / CGFloat(n)
        let (cols, shift) = columns(h, window: window, count: n)
        let line = CGMutablePath()
        let off = CGFloat(shift) * colW
        for (i, col) in cols.enumerated() {
            let (lo, hi) = col ?? (0, 0)
            let x = CGFloat(i) * colW - off
            // both ends are kept inside the picture: a very loud or one-sided sound (above full scale, or sitting above or below zero) must not poke out
            let top = CGPoint(x: x, y: cy - CGFloat(max(-1, min(1, hi * 1.9))) * amp)
            let bottom = CGPoint(x: x + colW * 0.5, y: cy - CGFloat(max(-1, min(1, lo * 1.9))) * amp)
            if i == 0 { line.move(to: top) } else { line.addLine(to: top) }
            line.addLine(to: bottom)
        }
        return line
    }

    /// Software drawing of the same picture (the app itself hands the path to Core Animation layers, which is far lighter).
    static func draw(_ ctx: CGContext, _ s: CGSize, history h: WaveHistory, window: Double, level: Float, color: (Double, CGFloat) -> NSColor) {
        let cy = s.height * 0.42, amp = s.height * 0.3
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.09).cgColor); ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: 0, y: cy)); ctx.addLine(to: CGPoint(x: s.width, y: cy)); ctx.strokePath()
        ctx.setLineJoin(.round); ctx.setLineCap(.round)
        ctx.setStrokeColor(color(0.62 + 0.38 * Double(level), 1).cgColor); ctx.setLineWidth(1.5)
        ctx.addPath(path(s, history: h, window: window)); ctx.strokePath()
        ctx.setStrokeColor(color(0.9, 0.5).cgColor)
        ctx.move(to: CGPoint(x: s.width - 1, y: cy - amp)); ctx.addLine(to: CGPoint(x: s.width - 1, y: cy + amp)); ctx.strokePath()
    }
}
