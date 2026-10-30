import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import CoreGraphics

enum VisualMode: String, CaseIterable, Identifiable {
    case notes = "All Notes", bars = "Bars", mirror = "Mirror", circle = "Circle", wave = "Wave", mountains = "Mountains", dots = "Dots", rings = "Rings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .notes: return "pianokeys"
        case .bars: return "chart.bar.fill"
        case .mirror: return "arrow.up.and.down.square"
        case .circle: return "circle.dotted"
        case .wave: return "waveform.path"
        case .mountains: return "mountain.2.fill"
        case .dots: return "circle.grid.3x3.fill"
        case .rings: return "circle.circle"
        }
    }
}

enum VisualPalette: String, CaseIterable, Identifiable {
    case accent = "Accent", rainbow = "Rainbow", fire = "Fire", ice = "Ice"
    var id: String { rawValue }

    /// Colour for position `t` (0 = low / quiet end, 1 = high / loud end).
    func color(_ t: Double, accent: NSColor, alpha: CGFloat = 1) -> NSColor {
        let t = min(1, max(0, t))
        let c: NSColor
        switch self {
        case .accent: c = accent.mixed(.black, 0.45 * (1 - t)).mixed(.white, 0.5 * t * t)
        case .rainbow: c = NSColor(hue: CGFloat(0.0 + 0.82 * t), saturation: 0.82, brightness: 1, alpha: 1)
        case .fire:
            let dark = NSColor(red: 0.55, green: 0.04, blue: 0.02, alpha: 1), mid = NSColor(red: 1, green: 0.42, blue: 0.05, alpha: 1), hot = NSColor(red: 1, green: 0.95, blue: 0.55, alpha: 1)
            c = t < 0.5 ? dark.mixed(mid, CGFloat(t * 2)) : mid.mixed(hot, CGFloat((t - 0.5) * 2))
        case .ice:
            let deep = NSColor(red: 0.05, green: 0.2, blue: 0.7, alpha: 1), cyan = NSColor(red: 0.2, green: 0.8, blue: 1, alpha: 1), white = NSColor(red: 0.92, green: 0.98, blue: 1, alpha: 1)
            c = t < 0.55 ? deep.mixed(cyan, CGFloat(t / 0.55)) : cyan.mixed(white, CGFloat((t - 0.55) / 0.45))
        }
        return c.withAlphaComponent(alpha)
    }
}

/// What the spectrum shapes draw: smoothed frequency bands plus the waveform and overall levels.
struct SpectrumFrame {
    var bands: [Float]
    var peaks: [Float]
    var wave: [Float]
    var level: Float
    var bass: Float
    var time: Double
    var scroll: WaveHistory? = nil          // the scrolling waveform (Wave mode); nil draws the latest snapshot instead
    var scrollWindow = 0.1                  // seconds of sound across the picture
    var waveformOnLayers = false            // true: the scrolling line is drawn by Core Animation layers, not here
}

/// The spectrum shapes. All of them draw into a flipped (y down) context of the given size.
enum VisualizerShapes {
    /// The dark fade and soft glow behind everything. (In the app these are Core Animation layers; this is the software version.)
    static func background(_ ctx: CGContext, _ size: CGSize, level: Float) {
        let space = CGColorSpaceCreateDeviceRGB()
        let top = NSColor(red: 0.04, green: 0.045, blue: 0.075, alpha: 1), bottom = NSColor(red: 0.01, green: 0.012, blue: 0.022, alpha: 1)
        if let g = CGGradient(colorsSpace: space, colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
        // a faint glow in the middle that follows the loudness
        if let g = CGGradient(colorsSpace: space, colors: [NSColor(white: 1, alpha: CGFloat(0.05 + 0.1 * level)).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: size.width / 2, y: size.height / 2), startRadius: 0,
                                   endCenter: CGPoint(x: size.width / 2, y: size.height / 2), endRadius: max(size.width, size.height) * 0.6, options: [])
        }
    }

    static func draw(_ mode: VisualMode, ctx: CGContext, size: CGSize, frame f: SpectrumFrame, palette: VisualPalette, accent: NSColor) {
        switch mode {
        case .notes: break
        case .bars: bars(ctx, size, f, palette, accent)
        case .mirror: mirror(ctx, size, f, palette, accent)
        case .circle: circle(ctx, size, f, palette, accent)
        case .wave: wave(ctx, size, f, palette, accent)
        case .mountains: mountains(ctx, size, f, palette, accent)
        case .dots: dots(ctx, size, f, palette, accent)
        case .rings: rings(ctx, size, f, palette, accent)
        }
    }

    private static func gradient(_ colors: [NSColor]) -> CGGradient? {
        CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map { $0.cgColor } as CFArray, locations: nil)
    }

    // MARK: Bars

    private static func bars(_ ctx: CGContext, _ s: CGSize, _ f: SpectrumFrame, _ p: VisualPalette, _ accent: NSColor) {
        let n = f.bands.count, margin = s.width * 0.04
        let gap = max(1.5, s.width * 0.004)
        let bw = (s.width - margin * 2 - gap * CGFloat(n - 1)) / CGFloat(n)
        let base = s.height * 0.86, maxH = s.height * 0.76
        for i in 0..<n {
            let v = CGFloat(f.bands[i]), x = margin + CGFloat(i) * (bw + gap)
            let h = max(2, v * maxH)
            let rect = CGRect(x: x, y: base - h, width: bw, height: h)
            if let g = gradient([p.color(0.05 + 0.25 * Double(i) / Double(n), accent: accent), p.color(Double(0.35 + 0.65 * v), accent: accent)]) {
                ctx.saveGState(); ctx.clip(to: rect)
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: base), end: CGPoint(x: 0, y: base - maxH), options: [.drawsAfterEndLocation])
                ctx.restoreGState()
            }
            // reflection
            if let g = gradient([p.color(Double(0.35 + 0.65 * v), accent: accent, alpha: 0.22), p.color(0.2, accent: accent, alpha: 0)]) {
                let r2 = CGRect(x: x, y: base + 3, width: bw, height: h * 0.32)
                ctx.saveGState(); ctx.clip(to: r2)
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: base + 3), end: CGPoint(x: 0, y: base + 3 + h * 0.32), options: [])
                ctx.restoreGState()
            }
            let pk = CGFloat(f.peaks[i]) * maxH
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            ctx.fill(CGRect(x: x, y: base - pk - 5, width: bw, height: 2.5))
        }
    }

    // MARK: Mirror

    private static func mirror(_ ctx: CGContext, _ s: CGSize, _ f: SpectrumFrame, _ p: VisualPalette, _ accent: NSColor) {
        let n = f.bands.count
        let cx = s.width / 2, cy = s.height / 2
        let half = s.width / 2 - s.width * 0.04
        let gap = max(1.2, s.width * 0.003), bw = (half - gap * CGFloat(n - 1)) / CGFloat(n)
        let maxH = s.height * 0.4
        for i in 0..<n {
            let v = CGFloat(f.bands[i])
            let h = max(1.5, v * maxH)
            let col = p.color(Double(i) / Double(n) * 0.7 + Double(v) * 0.3, accent: accent)
            ctx.setFillColor(col.cgColor)
            for side in [-1.0, 1.0] as [CGFloat] {
                let x = side < 0 ? cx - CGFloat(i + 1) * (bw + gap) + gap : cx + CGFloat(i) * (bw + gap)
                ctx.fill(CGRect(x: x, y: cy - h, width: bw, height: h))                   // up
                ctx.setFillColor(col.withAlphaComponent(0.45).cgColor)
                ctx.fill(CGRect(x: x, y: cy + 2, width: bw, height: h * 0.9))            // down, dimmer
                ctx.setFillColor(col.cgColor)
            }
        }
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        ctx.fill(CGRect(x: s.width * 0.04, y: cy, width: s.width * 0.92, height: 1.5))
    }

    // MARK: Circle

    private static func circle(_ ctx: CGContext, _ s: CGSize, _ f: SpectrumFrame, _ p: VisualPalette, _ accent: NSColor) {
        let n = f.bands.count, cx = s.width / 2, cy = s.height / 2
        let m = min(s.width, s.height)
        let r0 = m * 0.2 * (1 + 0.12 * CGFloat(f.bass)), maxLen = m * 0.3
        let rot = f.time * 0.25
        // pulsing core
        if let g = gradient([p.color(0.8, accent: accent, alpha: CGFloat(0.25 + 0.5 * f.level)), p.color(0.4, accent: accent, alpha: 0)]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: cx, y: cy), startRadius: 0, endCenter: CGPoint(x: cx, y: cy), endRadius: r0 * 1.15, options: [])
        }
        let total = n * 2
        ctx.setLineCap(.round)
        for j in 0..<total {
            let i = j < n ? j : total - 1 - j
            let v = CGFloat(f.bands[i])
            let a = rot + 2 * Double.pi * Double(j) / Double(total) - Double.pi / 2
            let len = v * maxLen + 3
            let p0 = CGPoint(x: cx + cos(a) * r0, y: cy + sin(a) * r0)
            let p1 = CGPoint(x: cx + cos(a) * (r0 + len), y: cy + sin(a) * (r0 + len))
            ctx.setStrokeColor(p.color(Double(i) / Double(n) * 0.75 + Double(v) * 0.25, accent: accent).cgColor)
            ctx.setLineWidth(max(2, 2 * Double.pi * Double(r0) / Double(total) * 0.62))
            ctx.move(to: p0); ctx.addLine(to: p1); ctx.strokePath()
        }
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor); ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: CGRect(x: cx - r0, y: cy - r0, width: r0 * 2, height: r0 * 2))
    }

    // MARK: Wave

    private static func smoothPath(_ pts: [CGPoint]) -> CGMutablePath {
        let path = CGMutablePath()
        guard pts.count > 2 else { return path }
        path.move(to: pts[0])
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts.last!)
        return path
    }

    private static func wave(_ ctx: CGContext, _ s: CGSize, _ f: SpectrumFrame, _ p: VisualPalette, _ accent: NSColor) {
        // spectrum curve filled along the bottom
        let n = f.bands.count, base = s.height * 0.94, maxH = s.height * 0.32
        var pts: [CGPoint] = []
        for i in 0..<n { pts.append(CGPoint(x: s.width * CGFloat(i) / CGFloat(n - 1), y: base - CGFloat(f.bands[i]) * maxH)) }
        let curve = smoothPath(pts)
        let fill = CGMutablePath(); fill.addPath(curve); fill.addLine(to: CGPoint(x: s.width, y: base)); fill.addLine(to: CGPoint(x: 0, y: base)); fill.closeSubpath()
        if let g = gradient([p.color(0.7, accent: accent, alpha: 0.5), p.color(0.2, accent: accent, alpha: 0.02)]) {
            ctx.saveGState(); ctx.addPath(fill); ctx.clip()
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: base - maxH), end: CGPoint(x: 0, y: base), options: [])
            ctx.restoreGState()
        }
        ctx.setStrokeColor(p.color(0.8, accent: accent, alpha: 0.9).cgColor); ctx.setLineWidth(1.5)
        ctx.addPath(curve); ctx.strokePath()

        // the waveform: scrolling left like an audio editor's, or (without history) a snapshot of the latest samples
        if f.waveformOnLayers { return }
        if let h = f.scroll {
            WaveScrollDraw.draw(ctx, s, history: h, window: f.scrollWindow, level: f.level) { t, a in p.color(t, accent: accent, alpha: a) }
            return
        }
        let cy = s.height * 0.42, amp = s.height * 0.3
        let count = min(f.wave.count, max(64, Int(s.width / 2)))
        var line: [CGPoint] = []
        let stride = Double(f.wave.count - 1) / Double(max(1, count - 1))
        for i in 0..<count {
            let v = CGFloat(f.wave[Int(Double(i) * stride)])
            line.append(CGPoint(x: s.width * CGFloat(i) / CGFloat(count - 1), y: cy - max(-1, min(1, v * 2.2)) * amp))
        }
        let path = smoothPath(line)
        ctx.setLineJoin(.round); ctx.setLineCap(.round)
        for (w, a) in [(12.0, 0.07), (7.0, 0.14), (3.5, 0.3), (1.8, 1.0)] as [(CGFloat, CGFloat)] {
            ctx.setStrokeColor(p.color(0.55 + 0.45 * Double(f.level), accent: accent, alpha: a).cgColor)
            ctx.setLineWidth(w); ctx.addPath(path); ctx.strokePath()
        }
    }

    // MARK: Mountains

    private static func mountains(_ ctx: CGContext, _ s: CGSize, _ f: SpectrumFrame, _ p: VisualPalette, _ accent: NSColor) {
        let n = f.bands.count, base = s.height * 0.92, maxH = s.height * 0.78
        func layer(_ values: [Float], alpha: CGFloat, lift: CGFloat, tint: Double) {
            var pts: [CGPoint] = []
            for i in 0..<n { pts.append(CGPoint(x: s.width * CGFloat(i) / CGFloat(n - 1), y: base - CGFloat(values[i]) * maxH * lift)) }
            let curve = smoothPath(pts)
            let fill = CGMutablePath(); fill.addPath(curve); fill.addLine(to: CGPoint(x: s.width, y: base)); fill.addLine(to: CGPoint(x: 0, y: base)); fill.closeSubpath()
            if let g = gradient([p.color(tint + 0.35, accent: accent, alpha: alpha), p.color(tint, accent: accent, alpha: alpha * 0.08)]) {
                ctx.saveGState(); ctx.addPath(fill); ctx.clip()
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: base - maxH), end: CGPoint(x: 0, y: base), options: [])
                ctx.restoreGState()
            }
            ctx.setStrokeColor(p.color(tint + 0.5, accent: accent, alpha: min(1, alpha + 0.3)).cgColor)
            ctx.setLineWidth(1.6); ctx.addPath(curve); ctx.strokePath()
        }
        layer(f.peaks, alpha: 0.32, lift: 1.0, tint: 0.1)                 // slow-falling peak ridge behind
        layer(f.bands.map { $0 * 0.8 }, alpha: 0.7, lift: 1.0, tint: 0.3)  // the live spectrum in front
    }

    // MARK: Dots

    private static func dots(_ ctx: CGContext, _ s: CGSize, _ f: SpectrumFrame, _ p: VisualPalette, _ accent: NSColor) {
        let cols = 48, rows = 18
        let cell = min(s.width * 0.92 / CGFloat(cols), s.height * 0.8 / CGFloat(rows))
        let ox = (s.width - cell * CGFloat(cols)) / 2, oy = (s.height - cell * CGFloat(rows)) / 2
        let n = f.bands.count
        for c in 0..<cols {
            let src = min(n - 1, Int(Double(c) / Double(cols) * Double(n)))
            let v = CGFloat(f.bands[src]) * CGFloat(rows), pk = Int(CGFloat(f.peaks[src]) * CGFloat(rows))
            for r in 0..<rows {
                let cx = ox + (CGFloat(c) + 0.5) * cell, cy = oy + (CGFloat(rows - 1 - r) + 0.5) * cell
                let lit = CGFloat(r) < v
                let rad = cell * (lit ? 0.38 : 0.2)
                if lit {
                    ctx.setFillColor(p.color(Double(r) / Double(rows), accent: accent).cgColor)
                } else if r == pk && pk > 0 {
                    ctx.setFillColor(NSColor.white.withAlphaComponent(0.8).cgColor)
                } else {
                    ctx.setFillColor(NSColor.white.withAlphaComponent(0.07).cgColor)
                }
                ctx.fillEllipse(in: CGRect(x: cx - rad, y: cy - rad, width: rad * 2, height: rad * 2))
            }
        }
    }

    // MARK: Rings

    private static func rings(_ ctx: CGContext, _ s: CGSize, _ f: SpectrumFrame, _ p: VisualPalette, _ accent: NSColor) {
        let cx = s.width / 2, cy = s.height / 2, rMax = min(s.width, s.height) * 0.46
        let groups = 8, per = f.bands.count / groups
        for g in 0..<groups {
            let lv = CGFloat(f.bands[(g * per)..<((g + 1) * per)].reduce(0, +) / Float(per))
            let r = rMax * (0.16 + 0.84 * CGFloat(g + 1) / CGFloat(groups)) * (0.9 + 0.22 * lv)
            ctx.setStrokeColor(p.color(Double(g) / Double(groups - 1), accent: accent, alpha: 0.28 + 0.72 * lv).cgColor)
            ctx.setLineWidth(2 + 15 * lv)
            ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            // a dot orbiting each ring
            let a = f.time * (0.5 + Double(g) * 0.22) + Double(g)
            let dr = 3 + 5 * lv
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.4 + 0.6 * lv).cgColor)
            ctx.fillEllipse(in: CGRect(x: cx + CGFloat(cos(a)) * r - dr, y: cy + CGFloat(sin(a)) * r - dr, width: dr * 2, height: dr * 2))
        }
        let core = rMax * 0.09 * (1 + 1.6 * CGFloat(f.bass))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - core, y: cy - core, width: core * 2, height: core * 2))
    }
}

// MARK: - All tracks in one piano roll

struct VNote { var start: Double; var end: Double; var pitch: Int; var vel: Int; var track: Int }

/// Every note of every track, flattened and sorted by start time, with each track's colour.
final class NoteCache {
    private(set) var notes: [VNote] = []
    private(set) var colors: [NSColor] = []
    private(set) var names: [String] = []
    private(set) var isDrums: [Bool] = []
    private(set) var minPitch = 48, maxPitch = 84
    private(set) var endBeat = 8.0
    private(set) var beatsPerBar = 4.0
    private(set) var maxLength = 1.0
    private(set) var trackHasNotes: [Bool] = []

    func rebuild(_ project: Project) {
        notes = []; colors = []; names = []; isDrums = []
        beatsPerBar = project.beatsPerBar
        for (ti, t) in project.tracks.enumerated() {
            colors.append(Palette.nsColor(t.colorIndex)); names.append(t.name); isDrums.append(t.instrument.isDrums)
            for c in t.clips {
                for n in c.notes { notes.append(VNote(start: c.start + n.start, end: c.start + n.end, pitch: n.pitch, vel: n.velocity, track: ti)) }
            }
        }
        notes.sort { $0.start < $1.start }
        maxLength = max(1, notes.map { $0.end - $0.start }.max() ?? 1)
        trackHasNotes = project.tracks.indices.map { ti in notes.contains { $0.track == ti } }
        minPitch = notes.map { $0.pitch }.min() ?? 48
        maxPitch = notes.map { $0.pitch }.max() ?? 84
        endBeat = max(8, notes.map { $0.end }.max() ?? 8)
    }

    /// The notes sounding at `beat` and those that ended up to `tail` beats ago (so they can fade), with how long ago each began.
    func sounding(at beat: Double, tail: Double) -> [VNote] {
        var hi = notes.count
        var lo = 0
        while lo < hi { let mid = (lo + hi) / 2; if notes[mid].start <= beat { lo = mid + 1 } else { hi = mid } }
        var out: [VNote] = []
        var i = lo - 1
        while i >= 0 && notes[i].start >= beat - maxLength - tail {
            if notes[i].end + tail > beat { out.append(notes[i]) }
            i -= 1
        }
        return out
    }
}

enum NotesRoll {
    /// Draws all tracks' notes in one roll. `follow` scrolls the notes past a fixed playhead; otherwise the whole song is shown.
    static func draw(_ ctx: CGContext, _ size: CGSize, cache: NoteCache, beat: Double, playing: Bool, windowBeats: Double, follow: Bool, accent: NSColor, soloTrack: Int? = nil) {
        let pad: CGFloat = 14, legendH: CGFloat = 26
        let x0 = pad + 34, x1 = size.width - pad, y0 = pad + legendH, y1 = size.height - pad
        let plotW = x1 - x0, plotH = y1 - y0
        guard plotW > 20, plotH > 20 else { return }

        // pitch range
        var lo = cache.minPitch - 2, hi = cache.maxPitch + 2
        if hi - lo < 24 { let mid = (hi + lo) / 2; lo = mid - 12; hi = mid + 12 }
        let span = CGFloat(hi - lo + 1)
        let rowH = plotH / span
        func yOf(_ pitch: Int) -> CGFloat { y1 - CGFloat(pitch - lo + 1) * rowH }

        // time mapping
        let ppb: CGFloat, playheadX: CGFloat
        if follow { ppb = plotW / CGFloat(windowBeats); playheadX = x0 + plotW * 0.25 } else { ppb = plotW / CGFloat(cache.endBeat); playheadX = x0 + CGFloat(beat) * ppb }
        func xOf(_ b: Double) -> CGFloat { follow ? playheadX + CGFloat(b - beat) * ppb : x0 + CGFloat(b) * ppb }
        let leftBeat = follow ? beat - Double(playheadX - x0) / Double(ppb) : 0
        let rightBeat = follow ? beat + Double(x1 - playheadX) / Double(ppb) : cache.endBeat

        // plot background, rows for the black keys, octave lines
        ctx.saveGState()
        ctx.clip(to: CGRect(x: x0, y: y0, width: plotW, height: plotH))
        ctx.setFillColor(NSColor(white: 1, alpha: 0.025).cgColor); ctx.fill(CGRect(x: x0, y: y0, width: plotW, height: plotH))
        for p in lo...hi {
            if Pitch.isBlack(p) { ctx.setFillColor(NSColor(white: 0, alpha: 0.22).cgColor); ctx.fill(CGRect(x: x0, y: yOf(p), width: plotW, height: rowH)) }
            if p % 12 == 0 { ctx.setFillColor(NSColor(white: 1, alpha: 0.12).cgColor); ctx.fill(CGRect(x: x0, y: yOf(p) + rowH - 0.5, width: plotW, height: 1)) }
        }
        // bar and beat lines
        var b = (leftBeat / 1).rounded(.down)
        while b <= rightBeat {
            let isBar = b.truncatingRemainder(dividingBy: cache.beatsPerBar) == 0
            if follow || isBar {
                ctx.setFillColor(NSColor(white: 1, alpha: isBar ? 0.16 : 0.05).cgColor)
                ctx.fill(CGRect(x: xOf(b), y: y0, width: 1, height: plotH))
            }
            b += follow ? 1 : cache.beatsPerBar
        }

        // notes
        let minW: CGFloat = 2.5
        for n in cache.notes {
            if n.start > rightBeat { break }
            if n.end < leftBeat { continue }
            if let s = soloTrack, s != n.track { continue }
            let rect = CGRect(x: xOf(n.start), y: yOf(n.pitch) + 0.5, width: max(minW, CGFloat(n.end - n.start) * ppb - 1), height: max(2, rowH - 1))
            let base = cache.colors[n.track]
            let sounding = playing && n.start <= beat && n.end > beat
            let passed = follow && n.end <= beat
            let vel = CGFloat(n.vel) / 127
            if sounding {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 16, color: base.withAlphaComponent(0.95).cgColor)
                ctx.setFillColor(base.mixed(.white, 0.45).cgColor); ctx.fill(rect)
                ctx.restoreGState()
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor); ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: min(rect.width, 3), height: rect.height))
            } else {
                let a: CGFloat = (passed ? 0.32 : 0.62) + 0.3 * vel * (passed ? 0.5 : 1)
                ctx.setFillColor(base.withAlphaComponent(min(1, a)).cgColor); ctx.fill(rect)
                if !passed { ctx.setStrokeColor(base.mixed(.white, 0.35).withAlphaComponent(0.7).cgColor); ctx.setLineWidth(0.75); ctx.stroke(rect.insetBy(dx: 0.4, dy: 0.4)) }
            }
            // a flash that fades just after a note starts
            let since = beat - n.start
            if playing && since >= 0 && since < 0.3 {
                ctx.setFillColor(NSColor.white.withAlphaComponent(CGFloat(0.55 * (1 - since / 0.3))).cgColor)
                ctx.fill(rect)
            }
        }
        ctx.restoreGState()

        // playhead
        if playheadX >= x0 && playheadX <= x1 {
            let col = accent.mixed(.white, 0.5)
            ctx.setFillColor(col.withAlphaComponent(0.95).cgColor); ctx.fill(CGRect(x: playheadX - 1, y: y0, width: 2, height: plotH))
            ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 12, color: col.cgColor)
            ctx.setFillColor(col.cgColor); ctx.fill(CGRect(x: playheadX - 3, y: y0 - 4, width: 6, height: 4)); ctx.restoreGState()
        }

        // octave labels on the left
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.4)]
        for p in lo...hi where p % 12 == 0 { ("C\(p / 12 - 1)" as NSString).draw(at: CGPoint(x: pad, y: yOf(p) + rowH / 2 - 6), withAttributes: attrs) }

        // legend: a coloured chip and the name of every track
        var lx = x0
        let lattrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor(white: 1, alpha: 0.85)]
        for (i, name) in cache.names.enumerated() {
            let w = (name as NSString).size(withAttributes: lattrs).width
            if lx + w + 30 > x1 { break }
            ctx.setFillColor(cache.colors[i].cgColor); ctx.fill(CGRect(x: lx, y: pad + 3, width: 10, height: 10))
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor); ctx.setLineWidth(0.75); ctx.stroke(CGRect(x: lx + 0.4, y: pad + 3.4, width: 9.2, height: 9.2))
            (name as NSString).draw(at: CGPoint(x: lx + 15, y: pad + 1), withAttributes: lattrs)
            lx += w + 34
        }
    }
}
