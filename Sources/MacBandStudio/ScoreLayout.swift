import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import CoreText

struct ScoreStyle {
    var selected: Set<UUID> = []
    var accent: NSColor = NSColor.controlAccentColor
    var ink: NSColor = NSColor(white: 0.93, alpha: 1)
    var dim: NSColor = NSColor(white: 0.55, alpha: 1)
    var staffLine: NSColor = NSColor(white: 0.62, alpha: 1)
    var ghost: NSColor = NSColor(white: 0.45, alpha: 1)
}

/// Turns a `NScore` into systems of measures sized to a width, draws them with Core Graphics,
/// and answers hit-test / playhead questions. Used both by the on-screen view and PDF export.
final class ScoreLayout {
    struct MeasureBox {
        var index: Int
        var x0: CGFloat, x1: CGFloat
        var onsets: [Double]            // beats from the measure start
        var onsetX: [CGFloat]           // absolute x of each onset
    }
    struct TieSeg { var x1: CGFloat, x2: CGFloat, y: CGFloat, up: Bool }
    struct SystemBox {
        var y: CGFloat, height: CGFloat
        var staffTop: [CGFloat]
        var x0: CGFloat, x1: CGFloat, contentX: CGFloat
        var measures: [MeasureBox]
        var first: Bool
        var ties: [TieSeg] = []
    }
    struct HeadHit { var rect: CGRect; var id: UUID?; var staff: Int; var system: Int; var midi: Int }

    let score: NScore
    let s: CGFloat
    let width: CGFloat
    var title = ""
    var subtitle = ""
    var firstMeasureNumber = 1
    private(set) var systems: [SystemBox] = []
    private(set) var height: CGFloat = 0
    private(set) var heads: [HeadHit] = []
    /// For each staff and event: which system it landed in and its x.
    private var eventPos: [[(system: Int, x: CGFloat)]] = []

    static let hwFactor: CGFloat = 1.3
    private var hw: CGFloat { s * Self.hwFactor }

    // MARK: Layout

    init(score: NScore, width: CGFloat, space: CGFloat, title: String = "", subtitle: String = "", firstMeasureNumber: Int = 1) {
        self.score = score; self.width = width; self.s = space
        self.title = title; self.subtitle = subtitle; self.firstMeasureNumber = firstMeasureNumber
        layout()
    }

    private func gap(_ dt: Double) -> CGFloat { s * (1.7 + 2.9 * CGFloat(sqrt(max(0, dt)))) }

    private var keySigCount: Int { abs(score.fifths) }
    private var grand: Bool { score.staves.count == 2 }
    private var staffGap: CGFloat { 9 * s }

    private func headerWidth(first: Bool) -> CGFloat {
        var w = 4.0 * s                                        // clef
        if keySigCount > 0 { w += CGFloat(keySigCount) * 1.15 * s + 0.8 * s }
        if first { w += 3.0 * s }                              // time signature
        return w + 0.6 * s
    }

    private func layout() {
        let bpb = score.beatsPerBar
        // natural measure layouts
        var natural: [MeasureBox] = []
        for m in 0..<score.measureCount {
            var times = Set<Double>()
            var accPad: [Double: Int] = [:]
            for st in score.staves {
                for e in st.events where e.measure == m {
                    let t = ((e.start - Double(m) * bpb) * 1e6).rounded() / 1e6
                    times.insert(t)
                    let n = e.pitches.filter { $0.showAcc }.count
                    if n > 0 { accPad[t] = max(accPad[t] ?? 0, min(3, n)) }
                }
            }
            if times.isEmpty { times.insert(0) }
            let ons = times.sorted()
            var xs: [CGFloat] = []
            var x = 1.1 * s
            for (i, t) in ons.enumerated() {
                if i > 0 { x += gap(t - ons[i - 1]) }
                x += CGFloat(accPad[t] ?? 0) * 1.0 * s
                xs.append(x)
            }
            let tail = max(gap(bpb - (ons.last ?? 0)) * 0.85, 2.4 * s)
            let w = max(8 * s, (xs.last ?? 0) + tail)
            natural.append(MeasureBox(index: m, x0: 0, x1: w, onsets: ons, onsetX: xs))
        }

        // break into systems
        let margin = 3.0 * s
        let rightMargin = 2.0 * s
        let braceW = grand ? 2.2 * s : 0
        var groups: [[Int]] = []
        var cur: [Int] = [], sum: CGFloat = 0
        for (i, mb) in natural.enumerated() {
            let avail = width - margin - rightMargin - braceW - headerWidth(first: groups.isEmpty)
            if !cur.isEmpty && sum + mb.x1 > avail { groups.append(cur); cur = []; sum = 0 }
            cur.append(i); sum += mb.x1
        }
        if !cur.isEmpty { groups.append(cur) }

        // vertical metrics
        let staffH = 4 * s
        let topPad = 7 * s
        let bottomPad = 6 * s
        let stackH = CGFloat(score.staves.count) * staffH + CGFloat(score.staves.count - 1) * staffGap
        var y: CGFloat = (title.isEmpty ? 1.5 : 5.5) * s
        systems = []
        eventPos = score.staves.map { st in [(Int, CGFloat)](repeating: (0, 0), count: st.events.count) }
        for (gi, g) in groups.enumerated() {
            let first = gi == 0
            let x0 = margin + braceW
            let contentX = x0 + headerWidth(first: first)
            let avail = width - rightMargin - contentX
            let natW = g.reduce(0) { $0 + natural[$1].x1 }
            var f = avail / natW
            if gi == groups.count - 1 { f = natW / avail < 0.6 ? min(f, 1.25) : f }
            var boxes: [MeasureBox] = []
            var x = contentX
            for i in g {
                let n = natural[i]
                let w = n.x1 * f
                boxes.append(MeasureBox(index: n.index, x0: x, x1: x + w, onsets: n.onsets, onsetX: n.onsetX.map { x + $0 * f }))
                x += w
            }
            let sysTop = y + topPad
            var tops: [CGFloat] = []
            for k in 0..<score.staves.count { tops.append(sysTop + CGFloat(k) * (staffH + staffGap)) }
            var box = SystemBox(y: y, height: topPad + stackH + bottomPad, staffTop: tops, x0: x0, x1: x, contentX: contentX, measures: boxes, first: first)
            // event positions
            for (si, st) in score.staves.enumerated() {
                for (ei, e) in st.events.enumerated() {
                    guard let mb = boxes.first(where: { $0.index == e.measure }) else { continue }
                    let t = ((e.start - Double(e.measure) * bpb) * 1e6).rounded() / 1e6
                    let oi = mb.onsets.firstIndex { abs($0 - t) < 1e-5 } ?? 0
                    var ex = mb.onsetX[oi]
                    if e.fullBar { ex = (mb.x0 + mb.x1) / 2 }
                    eventPos[si][ei] = (gi, ex)
                }
            }
            systems.append(box)
            y += box.height + 1.5 * s
            _ = box.ties
            box.ties = []
        }
        height = y + 2 * s
        buildHeadsAndTies()
    }

    // MARK: Geometry helpers

    private func staffY(_ system: Int, _ staff: Int, step: Int) -> CGFloat {
        let clef = score.staves[staff].clef
        let bottom = systems[system].staffTop[staff] + 4 * s
        return bottom - CGFloat(step - clef.bottomStep) * s / 2
    }

    /// Displaced (second) notehead offsets for a chord.
    private func headOffsets(_ e: NEvent) -> [CGFloat] {
        let n = e.pitches.count
        var off = [CGFloat](repeating: 0, count: n)
        guard n > 1 else { return off }
        if e.stemUp || e.base == 0 {
            for j in 1..<n where e.pitches[j].step - e.pitches[j - 1].step == 1 && off[j - 1] == 0 { off[j] = hw * 0.93 }
        } else {
            for j in stride(from: n - 2, through: 0, by: -1) where e.pitches[j + 1].step - e.pitches[j].step == 1 && off[j + 1] == 0 { off[j] = -hw * 0.93 }
        }
        return off
    }

    private func buildHeadsAndTies() {
        heads = []
        for (gi, _) in systems.enumerated() {
            for (si, st) in score.staves.enumerated() {
                for (ei, e) in st.events.enumerated() where eventPos[si][ei].system == gi && !e.isRest {
                    let x = eventPos[si][ei].x
                    let off = headOffsets(e)
                    for (pi, p) in e.pitches.enumerated() {
                        let yy = staffY(gi, si, step: p.step)
                        heads.append(HeadHit(rect: CGRect(x: x + off[pi] - hw * 0.7, y: yy - s * 0.65, width: hw * 1.4, height: s * 1.3), id: p.noteID, staff: si, system: gi, midi: p.midi))
                    }
                }
            }
        }
        // ties
        for gi in systems.indices { systems[gi].ties = [] }
        for (si, st) in score.staves.enumerated() {
            for (ei, e) in st.events.enumerated() where !e.isRest {
                for p in e.pitches where p.tieNext {
                    guard let ni = st.events[(ei + 1)...].firstIndex(where: { $0.voice == e.voice && !$0.isRest && $0.pitches.contains { $0.midi == p.midi && $0.tiePrev } }) else { continue }
                    let a = eventPos[si][ei], b = eventPos[si][ni]
                    let up = !e.stemUp
                    let yy = staffY(a.system, si, step: p.step) + (up ? -0.55 : 0.55) * s
                    if a.system == b.system {
                        systems[a.system].ties.append(TieSeg(x1: a.x + hw * 0.6, x2: b.x - hw * 0.6, y: yy, up: up))
                    } else {
                        systems[a.system].ties.append(TieSeg(x1: a.x + hw * 0.6, x2: systems[a.system].x1 - 0.2 * s, y: yy, up: up))
                        let y2 = staffY(b.system, si, step: p.step) + (up ? -0.55 : 0.55) * s
                        systems[b.system].ties.append(TieSeg(x1: systems[b.system].contentX - 0.2 * s, x2: b.x - hw * 0.6, y: y2, up: up))
                    }
                }
            }
        }
    }

    // MARK: Queries

    func systemIndex(atY y: CGFloat) -> Int? {
        systems.indices.first { y >= systems[$0].y && y < systems[$0].y + systems[$0].height + 1.5 * s }
    }

    /// Points (beat in measure, x) that pin the horizontal spacing of a measure; positions between them are interpolated.
    private func knots(_ mb: MeasureBox) -> [(t: Double, x: CGFloat)] {
        var k = zip(mb.onsets, mb.onsetX).map { (t: $0, x: $1) }
        if k.isEmpty || k[0].t > 1e-6 { k.insert((t: 0, x: mb.x0 + 1.1 * s), at: 0) }
        k.append((t: score.beatsPerBar, x: max(k.last!.x + 1, mb.x1 - 0.8 * s)))
        return k
    }

    /// x of a beat (pattern-relative) and the system it's in.
    func position(forBeat beat: Double) -> (system: Int, x: CGFloat)? {
        let bpb = score.beatsPerBar
        let m = min(score.measureCount - 1, max(0, Int(beat / bpb + 1e-9)))
        for (gi, sys) in systems.enumerated() {
            guard let mb = sys.measures.first(where: { $0.index == m }) else { continue }
            let t = min(bpb, max(0, beat - Double(m) * bpb))
            let k = knots(mb)
            var x = k.last!.x
            for i in 0..<(k.count - 1) where t <= k[i + 1].t + 1e-9 {
                let f = k[i + 1].t > k[i].t ? CGFloat((t - k[i].t) / (k[i + 1].t - k[i].t)) : 0
                x = k[i].x + f * (k[i + 1].x - k[i].x); break
            }
            return (gi, x)
        }
        return nil
    }

    struct StaffHit { var system: Int; var staff: Int; var measure: Int; var beat: Double; var step: Int }

    /// What a click at `p` means in music terms: the staff, the measure, the beat position and the diatonic step.
    func staffHit(_ p: CGPoint) -> StaffHit? {
        guard let gi = systemIndex(atY: p.y) else { return nil }
        let sys = systems[gi]
        guard p.x >= sys.contentX - s, p.x <= sys.x1 + s else { return nil }
        var best = 0; var bestD = CGFloat.greatestFiniteMagnitude
        for (k, top) in sys.staffTop.enumerated() {
            let d = abs(p.y - (top + 2 * s))
            if d < bestD { bestD = d; best = k }
        }
        guard bestD < 7 * s else { return nil }
        guard let mb = sys.measures.first(where: { p.x >= $0.x0 && p.x < $0.x1 }) ?? (p.x >= sys.x1 ? sys.measures.last : sys.measures.first) else { return nil }
        let k = knots(mb)
        var beat = p.x <= k[0].x ? 0 : score.beatsPerBar
        for i in 0..<(k.count - 1) where p.x <= k[i + 1].x {
            let f = k[i + 1].x > k[i].x ? Double((p.x - k[i].x) / (k[i + 1].x - k[i].x)) : 0
            beat = k[i].t + max(0, f) * (k[i + 1].t - k[i].t); break
        }
        let clef = score.staves[best].clef
        let bottom = sys.staffTop[best] + 4 * s
        let step = clef.bottomStep + Int(((bottom - p.y) / (s / 2)).rounded())
        return StaffHit(system: gi, staff: best, measure: mb.index, beat: max(0, beat), step: step)
    }

    func head(at p: CGPoint) -> HeadHit? {
        heads.first { $0.rect.insetBy(dx: -2, dy: -2).contains(p) }
    }

    // MARK: Drawing

    /// Draws one system. `dy` shifts it (PDF pages draw systems at different offsets).
    func draw(system gi: Int, ctx: CGContext, style: ScoreStyle, dy: CGFloat = 0) {
        let sys = systems[gi]
        ctx.saveGState()
        ctx.translateBy(x: 0, y: dy)
        let lw = max(0.8, s * 0.09)

        // title on the first system
        if gi == 0 && !title.isEmpty {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: s * 1.9, weight: .semibold), .foregroundColor: style.ink]
            let size = (title as NSString).size(withAttributes: a)
            (title as NSString).draw(at: CGPoint(x: (width - size.width) / 2, y: sys.y - 4.5 * s), withAttributes: a)
            if !subtitle.isEmpty {
                let b: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: s * 1.0), .foregroundColor: style.dim]
                let sz = (subtitle as NSString).size(withAttributes: b)
                (subtitle as NSString).draw(at: CGPoint(x: (width - sz.width) / 2, y: sys.y - 2.2 * s), withAttributes: b)
            }
        }

        // staff lines
        ctx.setStrokeColor(style.staffLine.cgColor); ctx.setLineWidth(lw)
        for top in sys.staffTop {
            for k in 0..<5 { let yy = top + CGFloat(k) * s; ctx.move(to: CGPoint(x: sys.x0, y: yy)); ctx.addLine(to: CGPoint(x: sys.x1, y: yy)) }
            ctx.strokePath()
        }
        // system start line, brace, barlines
        let topY = sys.staffTop.first!, botY = sys.staffTop.last! + 4 * s
        ctx.setStrokeColor(style.ink.withAlphaComponent(0.85).cgColor); ctx.setLineWidth(lw * 1.3)
        ctx.move(to: CGPoint(x: sys.x0, y: topY)); ctx.addLine(to: CGPoint(x: sys.x0, y: botY)); ctx.strokePath()
        if grand { drawBrace(ctx, x: sys.x0 - 0.5 * s, top: topY, bottom: botY, color: style.ink) }
        ctx.setLineWidth(lw * 1.1)
        for (mi, mb) in sys.measures.enumerated() {
            let isLast = mi == sys.measures.count - 1 && mb.index == score.measureCount - 1
            if isLast {
                ctx.setLineWidth(lw * 1.1); ctx.move(to: CGPoint(x: mb.x1 - 0.45 * s, y: topY)); ctx.addLine(to: CGPoint(x: mb.x1 - 0.45 * s, y: botY)); ctx.strokePath()
                ctx.setLineWidth(s * 0.4); ctx.move(to: CGPoint(x: mb.x1 - 0.2 * s, y: topY)); ctx.addLine(to: CGPoint(x: mb.x1 - 0.2 * s, y: botY)); ctx.strokePath()
            } else {
                ctx.move(to: CGPoint(x: mb.x1, y: topY)); ctx.addLine(to: CGPoint(x: mb.x1, y: botY)); ctx.strokePath()
            }
            // measure number on the first measure of the system
            if mi == 0 {
                let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: s * 1.0, weight: .medium), .foregroundColor: style.dim]
                ("\(mb.index + firstMeasureNumber)" as NSString).draw(at: CGPoint(x: mb.x0 + 0.2 * s, y: topY - 2.4 * s), withAttributes: a)
            }
        }

        // clefs, key and time signatures
        for (si, st) in score.staves.enumerated() {
            let top = sys.staffTop[si]
            drawClef(ctx, st.clef, x: sys.x0 + 0.7 * s, top: top, color: style.ink)
            drawKeySignature(ctx, x: sys.x0 + 4.0 * s, top: top, clef: st.clef, color: style.ink)
            if sys.first {
                let kx = sys.x0 + 4.0 * s + (keySigCount > 0 ? CGFloat(keySigCount) * 1.15 * s + 0.8 * s : 0)
                drawTimeSignature(ctx, x: kx + 0.2 * s, top: top, color: style.ink)
            }
        }

        // events
        for (si, st) in score.staves.enumerated() {
            drawStaffEvents(ctx, system: gi, staff: si, st: st, style: style, lw: lw)
        }

        // ties
        ctx.setFillColor(style.ink.cgColor)
        for t in sys.ties {
            let mid = (t.x1 + t.x2) / 2, dir: CGFloat = t.up ? -1 : 1
            let h = min(1.4 * s, max(0.6 * s, (t.x2 - t.x1) * 0.12))
            let path = CGMutablePath()
            path.move(to: CGPoint(x: t.x1, y: t.y))
            path.addQuadCurve(to: CGPoint(x: t.x2, y: t.y), control: CGPoint(x: mid, y: t.y + dir * h * 2))
            path.addQuadCurve(to: CGPoint(x: t.x1, y: t.y), control: CGPoint(x: mid, y: t.y + dir * (h * 2 - 0.35 * s)))
            ctx.addPath(path); ctx.fillPath()
        }
        ctx.restoreGState()
    }

    private func drawBrace(_ ctx: CGContext, x: CGFloat, top: CGFloat, bottom: CGFloat, color: NSColor) {
        let mid = (top + bottom) / 2, w = 1.5 * s
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x, y: top))
        p.addCurve(to: CGPoint(x: x - w, y: mid), control1: CGPoint(x: x - w * 1.1, y: top + (mid - top) * 0.35), control2: CGPoint(x: x + w * 0.1, y: mid - (mid - top) * 0.25))
        p.addCurve(to: CGPoint(x: x, y: bottom), control1: CGPoint(x: x + w * 0.1, y: mid + (bottom - mid) * 0.25), control2: CGPoint(x: x - w * 1.1, y: bottom - (bottom - mid) * 0.35))
        p.addCurve(to: CGPoint(x: x - w + 0.45 * s, y: mid), control1: CGPoint(x: x - w * 0.9, y: bottom - (bottom - mid) * 0.35), control2: CGPoint(x: x - w * 0.2, y: mid + (bottom - mid) * 0.25))
        p.addCurve(to: CGPoint(x: x, y: top), control1: CGPoint(x: x - w * 0.2, y: mid - (mid - top) * 0.25), control2: CGPoint(x: x - w * 0.9, y: top + (mid - top) * 0.35))
        ctx.setFillColor(color.withAlphaComponent(0.85).cgColor); ctx.addPath(p); ctx.fillPath()
    }

    // MARK: Glyph helpers

    private static let symbolFont = CTFontCreateWithName("Apple Symbols" as CFString, 100, nil)

    /// Fills a font glyph scaled to a target height with its top-left at (x, topY).
    private func fillGlyph(_ ctx: CGContext, _ ch: String, x: CGFloat, topY: CGFloat, height: CGFloat, color: NSColor, alignRightTo: CGFloat? = nil) {
        var chars = Array(ch.utf16); var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        guard CTFontGetGlyphsForCharacters(Self.symbolFont, &chars, &glyphs, chars.count), let path = CTFontCreatePathForGlyph(Self.symbolFont, glyphs[0], nil) else { return }
        let bb = path.boundingBoxOfPath
        guard bb.height > 0 else { return }
        let k = height / bb.height
        var t = CGAffineTransform(translationX: -bb.minX, y: -bb.minY).concatenating(CGAffineTransform(scaleX: k, y: -k)).concatenating(CGAffineTransform(translationX: alignRightTo.map { $0 - bb.width * k } ?? x, y: topY + height))
        guard let moved = path.copy(using: &t) else { return }
        ctx.setFillColor(color.cgColor); ctx.addPath(moved); ctx.fillPath()
    }

    private func glyphWidth(_ ch: String, height: CGFloat) -> CGFloat {
        var chars = Array(ch.utf16); var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        guard CTFontGetGlyphsForCharacters(Self.symbolFont, &chars, &glyphs, chars.count), let path = CTFontCreatePathForGlyph(Self.symbolFont, glyphs[0], nil) else { return height * 0.5 }
        let bb = path.boundingBoxOfPath
        return bb.height > 0 ? bb.width * height / bb.height : height * 0.5
    }

    private func drawClef(_ ctx: CGContext, _ clef: Clef, x: CGFloat, top: CGFloat, color: NSColor) {
        switch clef {
        case .treble: fillGlyph(ctx, "\u{1D11E}", x: x, topY: top - 1.75 * s, height: 7.4 * s, color: color)
        case .bass: fillGlyph(ctx, "\u{1D122}", x: x, topY: top + 0.0 * s, height: 3.9 * s, color: color)
        case .percussion:
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: x + 0.7 * s, y: top + 1.0 * s, width: 0.55 * s, height: 2.0 * s))
            ctx.fill(CGRect(x: x + 1.7 * s, y: top + 1.0 * s, width: 0.55 * s, height: 2.0 * s))
        }
    }

    private static let sharpIdx = [8, 5, 9, 6, 3, 7, 4]       // staff line positions (0 = bottom line, half-spaces) for F C G D A E B sharps on treble
    private static let flatIdx = [4, 7, 3, 6, 2, 5, 1]

    private func drawKeySignature(_ ctx: CGContext, x: CGFloat, top: CGFloat, clef: Clef, color: NSColor) {
        let n = score.fifths
        guard n != 0, clef != .percussion else { return }
        let positions = n > 0 ? Self.sharpIdx : Self.flatIdx
        let shift = clef == .bass ? -2 : 0
        for i in 0..<abs(n) {
            let idx = positions[i] + shift
            let yLine = top + 4 * s - CGFloat(idx) * s / 2
            drawAccidental(ctx, n > 0 ? 1 : -1, x: x + CGFloat(i) * 1.15 * s, yLine: yLine, color: color)
        }
    }

    /// Draws a sharp/flat/natural with its reference line at `yLine`, left edge at x.
    private func drawAccidental(_ ctx: CGContext, _ acc: Int, x: CGFloat, yLine: CGFloat, color: NSColor) {
        switch acc {
        case 1: fillGlyph(ctx, "\u{266F}", x: x, topY: yLine - 1.45 * s, height: 2.9 * s, color: color)
        case -1: fillGlyph(ctx, "\u{266D}", x: x, topY: yLine - 2.0 * s, height: 2.7 * s, color: color)
        default: fillGlyph(ctx, "\u{266E}", x: x, topY: yLine - 1.45 * s, height: 2.9 * s, color: color)
        }
    }

    private func drawTimeSignature(_ ctx: CGContext, x: CGFloat, top: CGFloat, color: NSColor) {
        let f = NSFont(name: "Times New Roman Bold", size: s * 2.75) ?? NSFont.boldSystemFont(ofSize: s * 2.75)
        let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color]
        for (i, txt) in ["\(score.timeNum)", "\(score.timeDen)"].enumerated() {
            let sz = (txt as NSString).size(withAttributes: a)
            let cap = f.capHeight
            let cy = top + (i == 0 ? 1 : 3) * s
            (txt as NSString).draw(at: CGPoint(x: x + (2.0 * s - sz.width) / 2, y: cy - cap / 2 - (sz.height - cap) / 2 - (f.descender) * 0 ), withAttributes: a)
        }
        for score in score.staves.indices where score > 0 {}
    }

    // MARK: Events

    private func drawStaffEvents(_ ctx: CGContext, system gi: Int, staff si: Int, st: NStaff, style: ScoreStyle, lw: CGFloat) {
        let sys = systems[gi]
        let clef = st.clef
        let top = sys.staffTop[si]
        let mid = top + 2 * s
        let indices = st.events.indices.filter { eventPos[si][$0].system == gi }
        func y(_ step: Int) -> CGFloat { top + 4 * s - CGFloat(step - clef.bottomStep) * s / 2 }

        struct Geo { var idx: Int; var x: CGFloat; var ys: [CGFloat]; var off: [CGFloat]; var stemX: CGFloat; var baseY: CGFloat; var tipY: CGFloat }
        var geo: [Int: Geo] = [:]
        for ei in indices {
            let e = st.events[ei]
            guard !e.isRest else { continue }
            let x = eventPos[si][ei].x
            let off = headOffsets(e)
            let ys = e.pitches.map { y($0.step) }
            let topHead = ys.min()!, botHead = ys.max()!
            let stemX = e.stemUp ? x + hw / 2 - lw * 0.6 : x - hw / 2 + lw * 0.6
            var base = e.stemUp ? botHead : topHead
            var tip = e.stemUp ? topHead - 3.5 * s : botHead + 3.5 * s
            if e.base >= 3 && e.beamID == nil || e.base == 2 || e.base == 1 {
                if e.stemUp { tip = min(tip, mid) } else { tip = max(tip, mid) }
            }
            if e.base == 0 { base = topHead; tip = topHead }
            geo[ei] = Geo(idx: ei, x: x, ys: ys, off: off, stemX: stemX, baseY: base, tipY: tip)
        }

        // beam groups: choose a (sloped) beam line, extend stems to it
        var beamLines: [Int: (x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat, up: Bool, members: [Int])] = [:]
        var byBeam: [Int: [Int]] = [:]
        for ei in indices { if let b = st.events[ei].beamID, geo[ei] != nil { byBeam[b * 100 + st.events[ei].voice, default: []].append(ei) } }
        for (key, members) in byBeam {
            guard let f = geo[members.first!], let l = geo[members.last!] else { continue }
            let up = st.events[members.first!].stemUp
            var y1 = f.tipY, y2 = l.tipY
            let dx = l.stemX - f.stemX
            let maxDrop = min(1.5 * s, 0.25 * dx)
            if y2 - y1 > maxDrop { let ex = (y2 - y1 - maxDrop) / 2; y1 += ex; y2 -= ex }
            if y1 - y2 > maxDrop { let ex = (y1 - y2 - maxDrop) / 2; y1 -= ex; y2 += ex }
            // every stem at least 2.6 spaces
            var shift: CGFloat = 0
            for m in members {
                guard let g = geo[m] else { continue }
                let t = dx > 0 ? (g.stemX - f.stemX) / dx : 0
                let by = y1 + (y2 - y1) * t
                let lengthNeeded = 2.6 * s
                if up { shift = min(shift, (g.baseY - lengthNeeded) - by) } else { shift = max(shift, (g.baseY + lengthNeeded) - by) }
            }
            y1 += shift; y2 += shift
            beamLines[key] = (f.stemX, y1, l.stemX, y2, up, members)
        }

        // ledger lines, heads, stems, accidentals, dots, flags, rests
        for ei in indices {
            let e = st.events[ei]
            let x = eventPos[si][ei].x
            if e.isRest { drawRest(ctx, e, x: x, top: top, color: style.ink); continue }
            guard let g = geo[ei] else { continue }
            // ledger lines
            ctx.setStrokeColor(style.staffLine.cgColor); ctx.setLineWidth(lw)
            let bottomIdx = e.pitches.map { $0.step - clef.bottomStep }.min()!, topIdx = e.pitches.map { $0.step - clef.bottomStep }.max()!
            if bottomIdx < 0 { for k in stride(from: -2, through: bottomIdx, by: -2) { let yy = top + 4 * s - CGFloat(k) * s / 2; ctx.move(to: CGPoint(x: x - hw * 0.95, y: yy)); ctx.addLine(to: CGPoint(x: x + hw * 0.95, y: yy)) } }
            if topIdx > 8 { for k in stride(from: 10, through: topIdx, by: 2) { let yy = top + 4 * s - CGFloat(k) * s / 2; ctx.move(to: CGPoint(x: x - hw * 0.95, y: yy)); ctx.addLine(to: CGPoint(x: x + hw * 0.95, y: yy)) } }
            ctx.strokePath()

            // stem
            var tip = g.tipY
            var stemBase = g.baseY
            if let b = e.beamID, let line = beamLines[b * 100 + e.voice] {
                let t = line.x2 > line.x1 ? (g.stemX - line.x1) / (line.x2 - line.x1) : 0
                tip = line.y1 + (line.y2 - line.y1) * t
            }
            if e.base >= 1 {
                ctx.setStrokeColor(style.ink.cgColor); ctx.setLineWidth(max(1, s * 0.11))
                ctx.move(to: CGPoint(x: g.stemX, y: stemBase)); ctx.addLine(to: CGPoint(x: g.stemX, y: tip)); ctx.strokePath()
            }
            stemBase = 0
            // heads
            for (pi, p) in e.pitches.enumerated() {
                let selected = p.noteID.map { style.selected.contains($0) } ?? false
                let color = selected ? style.accent : style.ink
                drawHead(ctx, p.head, base: e.base, x: x + g.off[pi], y: g.ys[pi], color: color)
                if p.head == .x || p.head == .diamond, e.base >= 1 { }
            }
            // flags
            if e.base >= 3 && e.beamID == nil {
                for k in 0..<(e.base - 2) {
                    drawFlag(ctx, x: g.stemX, tipY: tip, up: e.stemUp, level: k, color: style.ink)
                }
            }
            // accidentals (stacked leftwards)
            var columns: [(lastY: CGFloat, x: CGFloat)] = []
            let sorted = e.pitches.enumerated().filter { $0.element.showAcc }.sorted { $0.offset > $1.offset }
            for (pi, p) in sorted {
                let yy = g.ys[pi]
                var col = 0
                while col < columns.count && abs(columns[col].lastY - yy) < 2.6 * s { col += 1 }
                if col == columns.count { columns.append((yy, 0)) } else { columns[col].lastY = yy }
                let w = glyphWidth(p.acc == 1 ? "\u{266F}" : p.acc == -1 ? "\u{266D}" : "\u{266E}", height: p.acc == -1 ? 2.7 * s : 2.9 * s)
                let ax = x + min(0, g.off.min() ?? 0) - hw * 0.62 - 0.35 * s - w - CGFloat(col) * 1.15 * s
                let selected = p.noteID.map { style.selected.contains($0) } ?? false
                drawAccidental(ctx, p.acc, x: ax, yLine: yy, color: selected ? style.accent : style.ink)
            }
            // dots
            if e.dots > 0 {
                ctx.setFillColor(style.ink.cgColor)
                for (pi, _) in e.pitches.enumerated() {
                    var dy = g.ys[pi]
                    let idx = e.pitches[pi].step - clef.bottomStep
                    if idx % 2 == 0 { dy -= s / 2 }               // on a line → dot in the space above
                    for d in 0..<e.dots {
                        let dx = x + max(0, g.off.max() ?? 0) + hw * 0.5 + 0.55 * s + CGFloat(d) * 0.6 * s
                        ctx.fillEllipse(in: CGRect(x: dx - 0.2 * s, y: dy - 0.2 * s, width: 0.4 * s, height: 0.4 * s))
                    }
                }
            }
        }

        // beams
        ctx.setFillColor(style.ink.cgColor)
        for (_, line) in beamLines {
            let thick = 0.52 * s, step = 0.78 * s
            let dir: CGFloat = line.up ? 1 : -1        // secondary beams grow toward the noteheads
            func yAt(_ x: CGFloat) -> CGFloat { line.x2 > line.x1 ? line.y1 + (line.y2 - line.y1) * (x - line.x1) / (line.x2 - line.x1) : line.y1 }
            func beam(_ xa: CGFloat, _ xb: CGFloat, level: Int) {
                let o = CGFloat(level) * step * dir
                let ya = yAt(xa) + o, yb = yAt(xb) + o
                let p = CGMutablePath()
                if line.up {
                    p.move(to: CGPoint(x: xa, y: ya)); p.addLine(to: CGPoint(x: xb, y: yb)); p.addLine(to: CGPoint(x: xb, y: yb + thick)); p.addLine(to: CGPoint(x: xa, y: ya + thick))
                } else {
                    p.move(to: CGPoint(x: xa, y: ya)); p.addLine(to: CGPoint(x: xb, y: yb)); p.addLine(to: CGPoint(x: xb, y: yb - thick)); p.addLine(to: CGPoint(x: xa, y: ya - thick))
                }
                p.closeSubpath(); ctx.addPath(p); ctx.fillPath()
            }
            let members = line.members
            let sw = max(1, s * 0.11)
            beam(line.x1 - sw / 2, line.x2 + sw / 2, level: 0)
            for level in 1...2 {
                var i = 0
                while i < members.count {
                    let e = st.events[members[i]]
                    guard e.base >= 3 + level, let g = geo[members[i]] else { i += 1; continue }
                    var j = i
                    while j + 1 < members.count, st.events[members[j + 1]].base >= 3 + level { j += 1 }
                    if j > i { beam(geo[members[i]]!.stemX - sw / 2, geo[members[j]]!.stemX + sw / 2, level: level) }
                    else {
                        // a lone short note among longer ones gets a stub pointing at its neighbour
                        let toRight = i == 0 || (i < members.count - 1 && Int((e.start * 4).rounded()) % 2 == 0)
                        let len = 1.0 * s
                        if toRight && i < members.count - 1 { beam(g.stemX - sw / 2, g.stemX + len, level: level) } else { beam(g.stemX - len, g.stemX + sw / 2, level: level) }
                    }
                    i = j + 1
                }
            }
        }
    }

    private func drawHead(_ ctx: CGContext, _ head: NoteHead, base: Int, x: CGFloat, y: CGFloat, color: NSColor) {
        ctx.saveGState()
        ctx.translateBy(x: x, y: y)
        switch head {
        case .x:
            ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(max(1.2, s * 0.17)); ctx.setLineCap(.butt)
            let r = s * 0.5
            ctx.move(to: CGPoint(x: -r, y: -r)); ctx.addLine(to: CGPoint(x: r, y: r)); ctx.move(to: CGPoint(x: -r, y: r)); ctx.addLine(to: CGPoint(x: r, y: -r)); ctx.strokePath()
        case .diamond:
            let r = s * 0.62
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: -r)); p.addLine(to: CGPoint(x: r, y: 0)); p.addLine(to: CGPoint(x: 0, y: r)); p.addLine(to: CGPoint(x: -r, y: 0)); p.closeSubpath()
            ctx.setFillColor(color.cgColor); ctx.addPath(p); ctx.fillPath()
        case .normal:
            let w = base == 0 ? hw * 1.18 : hw, h = s * 0.97
            ctx.rotate(by: base == 0 ? 0 : -0.42)
            let outer = CGPath(ellipseIn: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), transform: nil)
            if base <= 1 {
                let inner = CGMutablePath()
                var t = CGAffineTransform(rotationAngle: base == 0 ? 0.95 : 0.0)
                inner.addPath(CGPath(ellipseIn: CGRect(x: -w * 0.30, y: -h * 0.40, width: w * 0.60, height: h * 0.80), transform: &t))
                let both = CGMutablePath(); both.addPath(outer); both.addPath(inner)
                ctx.setFillColor(color.cgColor); ctx.addPath(both); ctx.fillPath(using: .evenOdd)
            } else {
                ctx.setFillColor(color.cgColor); ctx.addPath(outer); ctx.fillPath()
            }
        }
        ctx.restoreGState()
    }

    private func drawFlag(_ ctx: CGContext, x: CGFloat, tipY: CGFloat, up: Bool, level: Int, color: NSColor) {
        let d: CGFloat = up ? 1 : -1
        let y0 = tipY + CGFloat(level) * 0.95 * s * d
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x, y: y0))
        p.addCurve(to: CGPoint(x: x + 1.05 * s, y: y0 + 2.1 * s * d), control1: CGPoint(x: x + 0.25 * s, y: y0 + 0.9 * s * d), control2: CGPoint(x: x + 1.25 * s, y: y0 + 1.15 * s * d))
        p.addCurve(to: CGPoint(x: x, y: y0 + 1.0 * s * d), control1: CGPoint(x: x + 1.0 * s, y: y0 + 1.35 * s * d), control2: CGPoint(x: x + 0.35 * s, y: y0 + 1.45 * s * d))
        p.closeSubpath()
        ctx.setFillColor(color.cgColor); ctx.addPath(p); ctx.fillPath()
    }

    private func drawRest(_ ctx: CGContext, _ e: NEvent, x: CGFloat, top: CGFloat, color: NSColor) {
        ctx.setFillColor(color.cgColor); ctx.setStrokeColor(color.cgColor)
        let cx = x
        switch e.base {
        case 0:
            let w = 1.35 * s
            ctx.fill(CGRect(x: cx - w / 2, y: top + s, width: w, height: 0.5 * s))
        case 1:
            let w = 1.35 * s
            ctx.fill(CGRect(x: cx - w / 2, y: top + 2 * s - 0.5 * s, width: w, height: 0.5 * s))
        case 2:
            // quarter rest: a zig-zag with a hook
            let p = CGMutablePath()
            let y0 = top + 0.7 * s
            p.move(to: CGPoint(x: cx + 0.25 * s, y: y0))
            p.addLine(to: CGPoint(x: cx - 0.45 * s, y: y0 + 0.95 * s))
            p.addLine(to: CGPoint(x: cx + 0.45 * s, y: y0 + 1.85 * s))
            p.addLine(to: CGPoint(x: cx - 0.3 * s, y: y0 + 2.6 * s))
            p.addCurve(to: CGPoint(x: cx + 0.35 * s, y: y0 + 3.2 * s), control1: CGPoint(x: cx - 0.9 * s, y: y0 + 2.6 * s), control2: CGPoint(x: cx - 0.7 * s, y: y0 + 3.4 * s))
            ctx.addPath(p); ctx.setLineWidth(0.46 * s); ctx.setLineJoin(.miter); ctx.setLineCap(.butt); ctx.strokePath()
        default:
            // eighth, sixteenth, thirty-second: a stem with one dot-and-flag per level
            let levels = e.base - 2
            let topY = top + 1.0 * s - CGFloat(levels - 1) * 0.0
            let bottomY = top + (2.9 + CGFloat(levels - 1) * 0.9) * s
            ctx.setLineWidth(0.14 * s)
            ctx.move(to: CGPoint(x: cx + 0.45 * s, y: topY + 0.1 * s)); ctx.addLine(to: CGPoint(x: cx - 0.25 * s, y: bottomY)); ctx.strokePath()
            for k in 0..<levels {
                let yy = topY + 0.35 * s + CGFloat(k) * 0.95 * s
                let xx = cx + 0.45 * s - (yy - topY) * 0.34
                ctx.fillEllipse(in: CGRect(x: xx - 0.62 * s, y: yy - 0.28 * s, width: 0.56 * s, height: 0.56 * s))
                ctx.setLineWidth(0.14 * s)
                ctx.move(to: CGPoint(x: xx - 0.3 * s, y: yy + 0.05 * s)); ctx.addQuadCurve(to: CGPoint(x: xx + 0.42 * s, y: yy - 0.2 * s), control: CGPoint(x: xx + 0.08 * s, y: yy + 0.38 * s)); ctx.strokePath()
            }
        }
        if e.dots > 0 {
            ctx.fillEllipse(in: CGRect(x: cx + 0.95 * s, y: top + 1.5 * s - 0.2 * s, width: 0.4 * s, height: 0.4 * s))
        }
    }
}

#if os(macOS)
// MARK: - Rendering to bitmaps and PDF

extension ScoreLayout {
    /// Renders the whole score to a PNG (headless check) at `scale` pixels per point.
    func writePNG(to url: URL, scale: CGFloat = 1.5, style: ScoreStyle = ScoreStyle(), background: NSColor = NSColor(white: 0.10, alpha: 1)) {
        let w = Int(width * scale), h = Int(height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let cg = gc.cgContext
        cg.setFillColor(background.cgColor); cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
        cg.translateBy(x: 0, y: CGFloat(h)); cg.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        for i in systems.indices { draw(system: i, ctx: cg, style: style) }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
