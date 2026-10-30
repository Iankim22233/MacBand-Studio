import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The two round visualizers, driven by the notes that are playing: every sounding note is a circle in its track's colour.
enum NoteCircles {
    /// How a note looks at `beat`: brightness (held notes stay lit, released ones fade), a pop at the moment it starts, and its age.
    struct Look { var glow: Double; var pop: Double; var age: Double }

    static func look(_ n: VNote, beat: Double, secPerBeat: Double) -> Look? {
        let age = max(0, (beat - n.start) * secPerBeat)
        if beat < n.end {
            return Look(glow: 0.55 + 0.45 * exp(-age * 4), pop: exp(-age * 9), age: age)
        }
        let released = (beat - n.end) * secPerBeat
        if released > 0.6 { return nil }
        return Look(glow: 0.55 * exp(-released * 7), pop: 0, age: age)
    }

    private static let tail = 0.6                      // seconds a released note keeps fading

    private static func glowDot(_ ctx: CGContext, _ c: CGPoint, radius: CGFloat, core: CGFloat, color: NSColor, glow: Double) {
        let space = CGColorSpaceCreateDeviceRGB()
        if let g = CGGradient(colorsSpace: space, colors: [color.withAlphaComponent(CGFloat(0.85 * glow)).cgColor, color.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
        }
        ctx.setFillColor(color.mixed(.white, 0.35).withAlphaComponent(CGFloat(min(1, 0.35 + glow))).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - core, y: c.y - core, width: core * 2, height: core * 2))
    }

    private static func ripple(_ ctx: CGContext, _ c: CGPoint, from r: CGFloat, color: NSColor, age: Double, vel: CGFloat, scale: CGFloat) {
        guard age < 0.9 else { return }
        let f = CGFloat(age / 0.9)
        let rad = r + f * 70 * scale
        ctx.setStrokeColor(color.withAlphaComponent((1 - f) * (0.25 + 0.4 * vel)).cgColor)
        ctx.setLineWidth(1 + 2 * (1 - f))
        ctx.strokeEllipse(in: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
    }

    // MARK: Circle: a pitch wheel

    /// The twelve notes of the scale around a ring (C at the top), higher octaves further out.
    static func wheel(_ ctx: CGContext, _ s: CGSize, cache: NoteCache, beat: Double, secPerBeat: Double, frame f: SpectrumFrame, accent: NSColor) {
        let cx = s.width / 2, cy = s.height / 2, m = min(s.width, s.height)
        let rMin = m * 0.12, rMax = m * 0.40, scale = m / 520
        let lo = cache.minPitch, hi = max(cache.maxPitch, lo + 12)
        func point(_ pitch: Int) -> CGPoint {
            let a = -Double.pi / 2 + 2 * Double.pi * Double(pitch % 12) / 12
            let t = CGFloat(min(1, max(0, Double(pitch - lo) / Double(hi - lo))))
            let r = rMin + t * (rMax - rMin)
            return CGPoint(x: cx + CGFloat(cos(a)) * r, y: cy + CGFloat(sin(a)) * r)
        }
        // guides: one spoke per note name, a ring at each C
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        ctx.setLineWidth(1)
        for k in 0..<12 {
            let a = -Double.pi / 2 + 2 * Double.pi * Double(k) / 12
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(k % 12 == 0 ? 0.16 : 0.07).cgColor)
            ctx.move(to: CGPoint(x: cx + CGFloat(cos(a)) * rMin * 0.6, y: cy + CGFloat(sin(a)) * rMin * 0.6))
            ctx.addLine(to: CGPoint(x: cx + CGFloat(cos(a)) * rMax, y: cy + CGFloat(sin(a)) * rMax)); ctx.strokePath()
            let label = names[k] as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: max(9, 11 * scale + 3), weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.5)]
            let sz = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: cx + CGFloat(cos(a)) * (rMax + 22 * scale + 8) - sz.width / 2, y: cy + CGFloat(sin(a)) * (rMax + 22 * scale + 8) - sz.height / 2), withAttributes: attrs)
        }
        var p = (lo / 12) * 12
        while p <= hi {
            if p >= lo {
                let t = CGFloat(Double(p - lo) / Double(hi - lo)), r = rMin + t * (rMax - rMin)
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
                ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            }
            p += 12
        }
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.1).cgColor)
        ctx.strokeEllipse(in: CGRect(x: cx - rMin, y: cy - rMin, width: rMin * 2, height: rMin * 2))

        // the notes sounding now
        let sounding = cache.sounding(at: beat, tail: tail / max(0.05, secPerBeat))
        var drawn: [(VNote, Look)] = []
        for n in sounding { if let l = look(n, beat: beat, secPerBeat: secPerBeat) { drawn.append((n, l)) } }
        drawn.sort { $0.0.track < $1.0.track }
        // a chord shows as a shape joining its notes
        let held = drawn.filter { beat < $0.0.end && !cache.isDrums[$0.0.track] }.map { point($0.0.pitch) }
        if held.count >= 2 {
            let sorted = held.sorted { atan2($0.y - cy, $0.x - cx) < atan2($1.y - cy, $1.x - cx) }
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor); ctx.setLineWidth(1.2)
            ctx.move(to: sorted[0]); for q in sorted.dropFirst() { ctx.addLine(to: q) }; ctx.closePath(); ctx.strokePath()
        }
        for (n, l) in drawn.prefix(220) {
            let c = point(n.pitch), color = cache.colors[n.track], v = CGFloat(0.35 + 0.65 * Double(n.vel) / 127)
            ripple(ctx, c, from: 6 * scale, color: color, age: l.age, vel: v, scale: scale)
            let pop = CGFloat(1 + 0.9 * l.pop)
            glowDot(ctx, c, radius: (14 + 30 * v) * scale * pop, core: (3.5 + 8 * v) * scale * pop, color: color, glow: l.glow)
        }
        // the middle breathes with the music
        let live = min(1, Double(f.level) * 1.2 + Double(drawn.count) * 0.04)
        let space = CGColorSpaceCreateDeviceRGB()
        if let g = CGGradient(colorsSpace: space, colors: [accent.withAlphaComponent(CGFloat(0.12 + 0.4 * live)).cgColor, accent.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: cx, y: cy), startRadius: 0, endCenter: CGPoint(x: cx, y: cy), endRadius: rMin * 1.3, options: [])
        }
    }

    // MARK: Rings: one ring per track

    /// Each track is a ring (the first track innermost). A sounding note is a circle on its ring at its pitch, low to high around the ring.
    static func rings(_ ctx: CGContext, _ s: CGSize, cache: NoteCache, beat: Double, secPerBeat: Double, frame f: SpectrumFrame, accent: NSColor) {
        let cx = s.width / 2, cy = s.height / 2, m = min(s.width, s.height)
        let rMax = m * 0.44, scale = m / 520
        let tracks = cache.trackHasNotes.enumerated().filter { $0.element }.map { $0.offset }
        guard !tracks.isEmpty else { return }
        let lo = cache.minPitch, hi = max(cache.maxPitch, lo + 12)
        func radius(_ rank: Int) -> CGFloat { rMax * (0.2 + 0.8 * CGFloat(rank + 1) / CGFloat(tracks.count)) }
        func angle(_ pitch: Int) -> Double { -Double.pi / 2 + 2 * Double.pi * Double(pitch - lo) / Double(hi - lo + 1) }
        let rank = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($1, $0) })

        let sounding = cache.sounding(at: beat, tail: tail / max(0.05, secPerBeat))
        var drawn: [(VNote, Look)] = []
        for n in sounding { if let l = look(n, beat: beat, secPerBeat: secPerBeat) { drawn.append((n, l)) } }
        var activity = [Int: Double]()
        for (n, l) in drawn { activity[n.track, default: 0] += l.glow * (0.35 + 0.65 * Double(n.vel) / 127) }

        for t in tracks {
            let r = radius(rank[t]!), a = min(1, activity[t] ?? 0), color = cache.colors[t]
            let rr = r * CGFloat(1 + 0.025 * a)
            ctx.setStrokeColor(color.withAlphaComponent(CGFloat(0.16 + 0.7 * a)).cgColor)
            ctx.setLineWidth(CGFloat(1.5 + 8 * a) * max(0.7, scale))
            ctx.strokeEllipse(in: CGRect(x: cx - rr, y: cy - rr, width: rr * 2, height: rr * 2))
        }
        for (n, l) in drawn.sorted(by: { $0.0.track < $1.0.track }).prefix(220) {
            guard let k = rank[n.track] else { continue }
            let r = radius(k), a = angle(n.pitch), color = cache.colors[n.track], v = CGFloat(0.35 + 0.65 * Double(n.vel) / 127)
            let c = CGPoint(x: cx + CGFloat(cos(a)) * r, y: cy + CGFloat(sin(a)) * r)
            ripple(ctx, c, from: 5 * scale, color: color, age: l.age, vel: v, scale: scale)
            let pop = CGFloat(1 + 0.8 * l.pop)
            glowDot(ctx, c, radius: (12 + 26 * v) * scale * pop, core: (3 + 7 * v) * scale * pop, color: color, glow: l.glow)
        }
        // what each ring is
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]
        var y: CGFloat = 14
        for t in tracks.prefix(14) {
            let a = min(1, activity[t] ?? 0)
            ctx.setFillColor(cache.colors[t].withAlphaComponent(CGFloat(0.45 + 0.55 * a)).cgColor)
            ctx.fillEllipse(in: CGRect(x: 14, y: y + 2, width: 9, height: 9))
            var at = attrs; at[.foregroundColor] = NSColor.white.withAlphaComponent(CGFloat(0.5 + 0.5 * a))
            (cache.names[t] as NSString).draw(at: CGPoint(x: 30, y: y - 1), withAttributes: at)
            y += 17
        }
        // a small core that follows the bass
        let core = m * 0.025 * (1 + 1.4 * CGFloat(f.bass))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - core, y: cy - core, width: core * 2, height: core * 2))
    }
}
