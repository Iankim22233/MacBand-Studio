import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct IntroPage {
    let title: String
    let text: String
    let points: [String]
}

enum Intro {
    static let seenKey = "introSeen"
    static var seen: Bool {
        get { UserDefaults.standard.bool(forKey: seenKey) }
        set { UserDefaults.standard.set(newValue, forKey: seenKey) }
    }

    static var folderText: String { ProjectsFolder.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    static var pages: [IntroPage] {
        #if os(iOS)
        return phonePages
        #else
        return macPages
        #endif
    }

    /// The introduction as it reads on a touch screen.
    static var phonePages: [IntroPage] {
        [
            IntroPage(title: "Welcome to MacBand Studio",
                      text: "A clean place to make music: real instruments, a piano roll, a drum sequencer and sheet music, in your pocket.",
                      points: ["Tap play to start and stop", "Replay this from the project menu ▸ Show Introduction"]),
            IntroPage(title: "Draw your music",
                      text: "Double-tap a track to make a pattern, then draw notes in the piano roll. Drag them around, stretch them, slide them.",
                      points: ["Two fingers scroll, a pinch zooms", "The Hand tool scrolls with one finger", "Tempo changes and volume automation have their own lanes"]),
            IntroPage(title: "Hundreds of sounds",
                      text: "All 128 General MIDI sounds and drum kits are built in, and you can add your own SoundFonts from the Files app.",
                      points: ["Tap a sound to hear it, then Use Sound", "Every preset inside a SoundFont is listed", "The piano button plays the selected sound with your fingers"]),
            IntroPage(title: "Beats in a few taps",
                      text: "The Steps page turns a drum track into a grid. Tap or drag to paint hits, and switch on Accent for louder ones.",
                      points: ["Drum tracks show the drum names beside the piano roll", "One-tap patterns to start from", "Hits show as real drum notation on the Score page"]),
            IntroPage(title: "See it as sheet music",
                      text: "The Score page shows any pattern as notation and edits the same notes. Tap the staff to add notes.",
                      points: ["Grand staff, key signatures, ties, beams and rests", "Share a printable PDF or MusicXML for other apps", "Drums use the percussion staff"]),
            IntroPage(title: "Mix it, then watch it",
                      text: "Auto Balance measures every track and levels them. The Visual page shows your music as moving shapes.",
                      points: ["Auto Balance is on the Mixer page", "Bars, circles, rings and one big piano roll with every instrument", "Turn the phone sideways for more room"]),
            IntroPage(title: "Your work is safe",
                      text: "MacBand saves for you. Projects live in the MacBand Studio folder, which you can also see in the Files app.",
                      points: ["Folder: Files ▸ On My iPhone ▸ MacBand Studio", "Auto Save keeps backups of what it overwrites", "Unsaved projects come back after a crash"]),
        ]
    }

    static var macPages: [IntroPage] {
        [
            IntroPage(title: "Welcome to MacBand Studio",
                      text: "A clean place to make music: real instruments, a piano roll, a drum sequencer and sheet music in one window.",
                      points: ["Press Space to play and stop anywhere", "Everything you see here can be replayed from Help ▸ Show Introduction"]),
            IntroPage(title: "Draw your music",
                      text: "Double-click a track to make a pattern, then draw notes in the piano roll. Drag them around, stretch them, slide them.",
                      points: ["Slide notes glide from one pitch to the next", "Tempo changes and volume automation have their own lanes", "⌘-scroll makes the tracks taller"]),
            IntroPage(title: "Hundreds of sounds",
                      text: "General MIDI, the GarageBand and Logic sampler instruments, your SoundFonts and any AU or VST3 plugin.",
                      points: ["⌘B opens the Sound Library: click a sound to hear it", "Every preset inside a SoundFont is listed", "Over a hundred drum kits, from 808s to rock kits"]),
            IntroPage(title: "Beats in a few clicks",
                      text: "The Step Sequencer tab turns a drum track into a grid. Click or drag to paint hits, option-click for an accent.",
                      points: ["Drum tracks show the drum names beside the piano roll", "One-click patterns to start from", "Hits show as real drum notation in the Score tab"]),
            IntroPage(title: "See it as sheet music",
                      text: "The Score tab shows any pattern as notation and edits the same notes. Click the staff to add notes.",
                      points: ["Grand staff, key signatures, ties, beams and rests", "Export a printable PDF or MusicXML for other apps", "Drums use the percussion staff"]),
            IntroPage(title: "Mix it, then watch it",
                      text: "Auto Balance measures every track and levels them. The Visualizer shows your music as moving shapes.",
                      points: ["⇧⌘L levels all tracks; the Bass knob is on the master strip", "Bars, circles, rings and one big piano roll with every instrument", "Open it in its own window with ⌥⌘V, then go full screen"]),
            IntroPage(title: "Your work is safe",
                      text: "MacBand saves for you. Projects live in a MacBand folder next to your GarageBand projects, and a window lets you pick one when you open a file.",
                      points: ["Folder: \(folderText)", "Auto Save keeps backups of what it overwrites", "Unsaved projects come back after a crash"]),
        ]
    }
}

// MARK: - Animated pictures (pure functions of time, so they can be rendered to still images)

struct IntroArt: View {
    let page: Int
    let t: Double
    var accent: Color = Theme.accent

    var body: some View {
        Canvas { ctx, size in
            switch page {
            case 0: Self.welcome(ctx, size, t, accent)
            case 1: Self.pianoRoll(ctx, size, t, accent)
            case 2: Self.sounds(ctx, size, t, accent)
            case 3: Self.drums(ctx, size, t, accent)
            case 4: Self.sheet(ctx, size, t, accent)
            case 5: Self.mixer(ctx, size, t, accent)
            default: Self.safe(ctx, size, t, accent)
            }
        }
    }

    // helpers
    static func ease(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }
    static func hueColor(_ h: Double, _ b: Double = 1, _ a: Double = 1) -> Color { Color(hue: h.truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: b, opacity: a) }
    static func glow(_ ctx: GraphicsContext, radius: CGFloat, _ body: (inout GraphicsContext) -> Void) {
        ctx.drawLayer { l in l.addFilter(.blur(radius: radius)); body(&l) }
    }

    // MARK: 0 · welcome: an equalizer that breathes, rings, drifting notes

    static func welcome(_ ctx: GraphicsContext, _ s: CGSize, _ t: Double, _ accent: Color) {
        var ctx = ctx
        let n = 34, w = s.width * 0.84, x0 = s.width * 0.08, base = s.height * 0.86
        for k in 0..<3 {                                              // expanding rings
            let p = (t * 0.32 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
            let r = CGFloat(p) * s.width * 0.34
            ctx.stroke(Path(ellipseIn: CGRect(x: s.width / 2 - r, y: s.height * 0.42 - r * 0.62, width: r * 2, height: r * 1.24)), with: .color(accent.opacity((1 - p) * 0.55)), lineWidth: 2)
        }
        for i in 0..<n {
            let ph = t * 1.9 + Double(i) * 0.46
            let env = 0.62 + 0.38 * sin(t * 0.6 + Double(i) * 0.17)
            let v = (0.16 + 0.84 * abs(sin(ph)) * env) * (0.55 + 0.45 * sin(Double(i) / Double(n) * .pi))
            let h = CGFloat(v) * s.height * 0.7
            let bw = w / CGFloat(n) * 0.68
            let rect = CGRect(x: x0 + CGFloat(i) * w / CGFloat(n), y: base - h, width: bw, height: h)
            let c = hueColor(0.55 + Double(i) / Double(n) * 0.38 + t * 0.03, 0.95)
            glow(ctx, radius: 6) { $0.fill(Path(rect), with: .color(c.opacity(0.55))) }
            ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: [c, c.opacity(0.35)]), startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: base)))
            ctx.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: bw, height: 2.5)), with: .color(.white.opacity(0.9)))
        }
        for i in 0..<9 {                                              // floating notes
            let sp = 22 + Double(i % 4) * 7
            let y = s.height - CGFloat((t * sp + Double(i) * 41).truncatingRemainder(dividingBy: Double(s.height) + 50)) + 10
            let x = s.width * (0.08 + 0.105 * CGFloat(i)) + CGFloat(sin(t * 0.8 + Double(i))) * 16
            let a = min(1, Double(y) / 60) * 0.7
            ctx.draw(Text(i % 2 == 0 ? "♪" : "♫").font(.system(size: 22 + CGFloat(i % 3) * 6)).foregroundColor(hueColor(0.1 + Double(i) * 0.1, 1, a)), at: CGPoint(x: x, y: y))
        }
    }

    // MARK: 1 · piano roll: notes pop in, then a playhead lights them

    static func pianoRoll(_ ctx: GraphicsContext, _ s: CGSize, _ t: Double, _ accent: Color) {
        var ctx = ctx
        let cols = 24, rows = 10
        let gx = s.width * 0.06, gy = s.height * 0.06, gw = s.width * 0.88, gh = s.height * 0.88
        let cw = gw / CGFloat(cols), rh = gh / CGFloat(rows)
        for r in 0..<rows { if r % 2 == 1 { ctx.fill(Path(CGRect(x: gx, y: gy + CGFloat(r) * rh, width: gw, height: rh)), with: .color(.white.opacity(0.035))) } }
        for c in 0...cols { ctx.fill(Path(CGRect(x: gx + CGFloat(c) * cw, y: gy, width: c % 4 == 0 ? 1.5 : 0.6, height: gh)), with: .color(.white.opacity(c % 4 == 0 ? 0.22 : 0.08))) }
        let notes: [(Int, Int, Int, Int)] = [(0, 4, 3, 0), (3, 6, 2, 0), (5, 7, 3, 0), (8, 5, 2, 1), (10, 3, 3, 1), (13, 5, 2, 1), (15, 7, 3, 2), (18, 8, 2, 2), (20, 6, 3, 2),
                                             (0, 1, 6, 3), (6, 2, 6, 3), (12, 1, 6, 3), (18, 2, 6, 3)]
        let T = 9.0, p = t.truncatingRemainder(dividingBy: T)
        let play = ease((p - 4.4) / 4.2)                                 // 0…1 while the playhead sweeps
        let fade = 1 - ease((p - 8.5) / 0.5)
        for (i, n) in notes.enumerated() {
            let appear = ease((p - Double(i) * 0.26) / 0.3)
            guard appear > 0 else { continue }
            let rect = CGRect(x: gx + CGFloat(n.0) * cw, y: gy + CGFloat(rows - 1 - n.1) * rh + 1, width: CGFloat(n.2) * cw - 2, height: rh - 2)
            let scaled = rect.insetBy(dx: -(1 - appear) * 8, dy: -(1 - appear) * 4)
            let col = Palette.color([0, 1, 2, 4][n.3])
            let playX = gx + CGFloat(play) * gw
            let sounding = play > 0 && play < 1 && playX >= rect.minX && playX <= rect.maxX
            if sounding { glow(ctx, radius: 9) { $0.fill(Path(rect), with: .color(col)) } }
            ctx.opacity = appear * fade
            ctx.fill(Path(scaled), with: .color(sounding ? col.opacity(1) : col.opacity(0.72)))
            if sounding { ctx.fill(Path(scaled), with: .color(.white.opacity(0.45))) }
            ctx.stroke(Path(scaled), with: .color(.white.opacity(0.5)), lineWidth: 0.8)
            ctx.opacity = 1
        }
        if play > 0 && play < 1 {
            let x = gx + CGFloat(play) * gw
            glow(ctx, radius: 6) { $0.fill(Path(CGRect(x: x - 2, y: gy, width: 4, height: gh)), with: .color(.white)) }
            ctx.fill(Path(CGRect(x: x - 1, y: gy, width: 2, height: gh)), with: .color(.white))
        }
        // a pencil nibbing the next note while they appear
        if p < 4.4 { let k = min(notes.count - 1, Int(p / 0.26)); let n = notes[k]
            let px = gx + CGFloat(n.0 + n.2) * cw, py = gy + CGFloat(rows - 1 - n.1) * rh + rh / 2
            ctx.draw(Text("✎").font(.system(size: 20)).foregroundColor(.white.opacity(0.85)), at: CGPoint(x: px + 6, y: py - 8))
        }
    }

    // MARK: 2 · sounds: source tiles and a morphing waveform

    static func sounds(_ ctx: GraphicsContext, _ s: CGSize, _ t: Double, _ accent: Color) {
        var ctx = ctx
        let names = [("General MIDI", "137 sounds"), ("GarageBand", "50 sounds"), ("Logic Pro", "400 sounds"), ("SoundFonts", "every preset")]
        let tw = s.width * 0.205, th = s.height * 0.3, gap = s.width * 0.02, x0 = (s.width - (tw * 4 + gap * 3)) / 2
        for (i, n) in names.enumerated() {
            let a = ease((t - Double(i) * 0.25) / 0.6), loop = t.truncatingRemainder(dividingBy: 12)
            let bob = CGFloat(sin(t * 1.3 + Double(i) * 1.4)) * 4
            let rect = CGRect(x: x0 + CGFloat(i) * (tw + gap), y: s.height * 0.07 + (1 - CGFloat(a)) * 26 + bob, width: tw, height: th)
            let c = hueColor(0.08 + Double(i) * 0.2, 0.95)
            ctx.opacity = a
            glow(ctx, radius: 10) { $0.fill(Path(rect), with: .color(c.opacity(0.35))) }
            ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: [c.opacity(0.95), c.opacity(0.5)]), startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
            ctx.stroke(Path(rect), with: .color(.white.opacity(0.85)), lineWidth: 1.2)
            ctx.draw(Text(n.0).font(.system(size: 14, weight: .semibold)).foregroundColor(.white), at: CGPoint(x: rect.midX, y: rect.midY - 9))
            ctx.draw(Text(n.1).font(.system(size: 11)).foregroundColor(.white.opacity(0.8)), at: CGPoint(x: rect.midX, y: rect.midY + 11))
            ctx.opacity = 1
            _ = loop
        }
        // waveform that becomes sine → saw → square → triangle
        let shape = (t * 0.4).truncatingRemainder(dividingBy: 4), i0 = Int(shape), f = ease(shape - Double(i0) - 0.25) * 1.33
        func wave(_ k: Int, _ x: Double) -> Double {
            let u = x.truncatingRemainder(dividingBy: 1)
            switch k % 4 {
            case 0: return sin(u * 2 * .pi)
            case 1: return 2 * u - 1
            case 2: return u < 0.5 ? 0.8 : -0.8
            default: return 1 - 4 * abs(u - 0.5)
            }
        }
        var path = Path()
        let cy = s.height * 0.72, amp = s.height * 0.2
        for px in stride(from: 0.0, through: Double(s.width), by: 3) {
            let x = px / Double(s.width) * 3.0 + t * 0.35
            let v = wave(i0, x) * (1 - min(1, f)) + wave(i0 + 1, x) * min(1, f)
            let pt = CGPoint(x: px, y: cy - CGFloat(v) * amp)
            if px == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        glow(ctx, radius: 6) { $0.stroke(path, with: .color(accent), lineWidth: 5) }
        ctx.stroke(path, with: .color(.white), lineWidth: 2)
    }

    // MARK: 3 · drums: a step grid that plays itself

    static func drums(_ ctx: GraphicsContext, _ s: CGSize, _ t: Double, _ accent: Color) {
        var ctx = ctx
        let rows = [("Crash", [1,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0]), ("Hi-Hat", [1,0,1,0, 1,0,1,1, 1,0,1,0, 1,0,1,1]), ("Snare", [0,0,0,0, 1,0,0,0, 0,0,0,0, 1,0,0,1]),
                    ("Clap", [0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,1,0]), ("Kick", [1,0,0,1, 0,0,1,0, 1,0,0,0, 0,1,0,0])]
        let cols = 16, lw = s.width * 0.16, gx = s.width * 0.05 + lw, gy = s.height * 0.1, gw = s.width * 0.9 - lw, gh = s.height * 0.8
        let cw = gw / CGFloat(cols), rh = gh / CGFloat(rows.count)
        let stepF = t * 7.5, step = Int(stepF) % cols, within = stepF - floor(stepF)
        let colors = [Palette.color(5), Palette.color(2), Palette.color(0), Palette.color(3), Palette.color(7)]
        ctx.fill(Path(CGRect(x: gx + CGFloat(step) * cw, y: gy, width: cw, height: gh)), with: .color(.white.opacity(0.1)))
        for (ri, row) in rows.enumerated() {
            let y = gy + CGFloat(ri) * rh
            ctx.draw(Text(row.0).font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.85)), at: CGPoint(x: gx - 10, y: y + rh / 2), anchor: .trailing)
            ctx.fill(Path(CGRect(x: s.width * 0.05, y: y + 3, width: 4, height: rh - 6)), with: .color(colors[ri]))
            for c in 0..<cols {
                let on = row.1[c] == 1, hit = on && c == step
                var r = CGRect(x: gx + CGFloat(c) * cw + 2, y: y + 3, width: cw - 4, height: rh - 6)
                if hit { let g = CGFloat(1 - within) * 6; r = r.insetBy(dx: -g, dy: -g) }
                if on {
                    if hit { glow(ctx, radius: 8) { $0.fill(Path(r), with: .color(colors[ri])) } }
                    ctx.fill(Path(r), with: .color(colors[ri].opacity(hit ? 1 : 0.78)))
                    ctx.stroke(Path(r), with: .color(.white.opacity(hit ? 0.95 : 0.35)), lineWidth: hit ? 1.5 : 0.8)
                } else {
                    ctx.fill(Path(r), with: .color(.white.opacity(c % 4 == 0 ? 0.1 : 0.05)))
                }
            }
        }
    }

    // MARK: 4 · sheet music: a staff that fills with notes

    static func sheet(_ ctx: GraphicsContext, _ s: CGSize, _ t: Double, _ accent: Color) {
        var ctx = ctx
        let top = s.height * 0.3, sp = s.height * 0.095
        let x0 = s.width * 0.06, x1 = s.width * 0.94
        for k in 0..<5 { ctx.fill(Path(CGRect(x: x0, y: top + CGFloat(k) * sp, width: x1 - x0, height: 1.4)), with: .color(.white.opacity(0.55))) }
        ctx.fill(Path(CGRect(x: x0, y: top, width: 1.6, height: sp * 4)), with: .color(.white.opacity(0.8)))
        ctx.draw(Text("\u{1D11E}").font(.custom("Apple Symbols", size: sp * 6.2)).foregroundColor(.white.opacity(0.92)), at: CGPoint(x: x0 + sp * 1.8, y: top + sp * 2.0))
        // staff positions in half-spaces above the bottom line (0 = bottom line, 2 = second line …)
        let melody: [Int] = [2, 4, 5, 7, 5, 4, 2, 4, 7, 9, 7, 5, 4, 5, 2]
        let T = 9.0, p = t.truncatingRemainder(dividingBy: T), play = ease((p - 3.8) / 4.6)
        let startX = x0 + sp * 6.0, step = (x1 - startX - sp) / CGFloat(melody.count)
        for (i, pos) in melody.enumerated() {
            let appear = ease((p - Double(i) * 0.22) / 0.3) * (1 - ease((p - 8.6) / 0.4))
            guard appear > 0 else { continue }
            let x = startX + CGFloat(i) * step
            let y = top + sp * 4 - CGFloat(pos) * sp / 2
            let playX = x0 + CGFloat(play) * (x1 - x0)
            let passed = play > 0 && playX > x
            let col: Color = passed ? accent : .white
            ctx.opacity = appear
            if pos <= 0 || pos >= 10 { ctx.fill(Path(CGRect(x: x - sp * 0.85, y: y - 0.7, width: sp * 1.7, height: 1.4)), with: .color(.white.opacity(0.6))) }
            var head = Path(ellipseIn: CGRect(x: x - sp * 0.62, y: y - sp * 0.45, width: sp * 1.24, height: sp * 0.9))
            head = head.applying(CGAffineTransform(translationX: -x, y: -y).concatenating(CGAffineTransform(rotationAngle: -0.35)).concatenating(CGAffineTransform(translationX: x, y: y)))   // tilt about its own centre
            if passed { glow(ctx, radius: 6) { $0.fill(head, with: .color(accent)) } }
            ctx.fill(head, with: .color(col))
            let up = pos < 6
            let sx = up ? x + sp * 0.58 : x - sp * 0.58
            ctx.fill(Path(CGRect(x: sx - 0.7, y: up ? y - sp * 3 : y, width: 1.4, height: sp * 3)), with: .color(col))
            ctx.opacity = 1
        }
        if play > 0 && play < 1 {
            let x = x0 + CGFloat(play) * (x1 - x0)
            glow(ctx, radius: 5) { $0.fill(Path(CGRect(x: x - 1.5, y: top - sp * 3, width: 3, height: sp * 10)), with: .color(accent)) }
        }
        ctx.draw(Text("4").font(.system(size: sp * 2.1, weight: .bold)).foregroundColor(.white), at: CGPoint(x: x0 + sp * 3.4, y: top + sp))
        ctx.draw(Text("4").font(.system(size: sp * 2.1, weight: .bold)).foregroundColor(.white), at: CGPoint(x: x0 + sp * 3.4, y: top + sp * 3))
    }

    // MARK: 5 · mixer: faders settle to one level, next to a circular spectrum

    static func mixer(_ ctx: GraphicsContext, _ s: CGSize, _ t: Double, _ accent: Color) {
        var ctx = ctx
        // faders (left)
        let names = ["Piano", "Bass", "Drums", "Strings"], start: [Double] = [0.85, 0.3, 0.62, 0.15], target = 0.55
        let T = 7.0, p = t.truncatingRemainder(dividingBy: T)
        let mixP = ease((p - 1.0) / 2.0) * (1 - ease((p - 5.5) / 1.2))
        let fx = s.width * 0.04, fw = s.width * 0.42, fy = s.height * 0.1, fh = s.height * 0.72
        for i in 0..<4 {
            let x = fx + CGFloat(i) * fw / 4 + fw / 8
            let v = start[i] * (1 - mixP) + target * mixP
            ctx.fill(Path(CGRect(x: x - 3, y: fy, width: 6, height: fh)), with: .color(.white.opacity(0.14)))
            ctx.stroke(Path(CGRect(x: x - 3, y: fy, width: 6, height: fh)), with: .color(.white.opacity(0.4)), lineWidth: 0.8)
            let hy = fy + fh * CGFloat(1 - v)
            let col = Palette.color([0, 1, 2, 4][i])
            ctx.fill(Path(CGRect(x: x - 3, y: hy, width: 6, height: fy + fh - hy)), with: .color(col.opacity(0.7)))
            let knob = CGRect(x: x - 15, y: hy - 8, width: 30, height: 16)
            glow(ctx, radius: 6) { $0.fill(Path(knob), with: .color(col.opacity(mixP > 0.2 ? 0.9 : 0))) }
            ctx.fill(Path(knob), with: .linearGradient(Gradient(colors: [col.opacity(0.9), col]), startPoint: CGPoint(x: 0, y: knob.minY), endPoint: CGPoint(x: 0, y: knob.maxY)))
            ctx.stroke(Path(knob), with: .color(.white.opacity(0.95)), lineWidth: 1)
            ctx.draw(Text(names[i]).font(.system(size: 11)).foregroundColor(.white.opacity(0.75)), at: CGPoint(x: x, y: fy + fh + 14))
        }
        let ty = fy + fh * CGFloat(1 - target)
        ctx.fill(Path(CGRect(x: fx, y: ty, width: fw, height: 1)), with: .color(.white.opacity(0.3 * mixP)))
        ctx.draw(Text("Auto Balance").font(.system(size: 12, weight: .semibold)).foregroundColor(accent.opacity(mixP)), at: CGPoint(x: fx + fw / 2, y: fy - 2), anchor: .bottom)
        // circular spectrum (right)
        let cx = s.width * 0.73, cy = s.height * 0.5, r0 = s.height * 0.17, n = 60
        for i in 0..<(n * 2) {
            let j = i < n ? i : n * 2 - 1 - i
            let v = 0.2 + 0.8 * abs(sin(t * 2.1 + Double(j) * 0.42)) * (0.55 + 0.45 * sin(t * 0.9 + Double(j) * 0.13))
            let a = t * 0.3 + Double(i) / Double(n * 2) * 2 * .pi
            let len = CGFloat(v) * s.height * 0.26
            var line = Path()
            line.move(to: CGPoint(x: cx + CGFloat(cos(a)) * r0, y: cy + CGFloat(sin(a)) * r0))
            line.addLine(to: CGPoint(x: cx + CGFloat(cos(a)) * (r0 + len), y: cy + CGFloat(sin(a)) * (r0 + len)))
            ctx.stroke(line, with: .color(hueColor(Double(j) / Double(n) * 0.8 + t * 0.04, 1)), style: StrokeStyle(lineWidth: 3.4, lineCap: .round))
        }
        ctx.stroke(Path(ellipseIn: CGRect(x: cx - r0, y: cy - r0, width: r0 * 2, height: r0 * 2)), with: .color(.white.opacity(0.5)), lineWidth: 1.5)
    }

    // MARK: 6 · safe: a folder, a progress ring and stacked backups

    static func safe(_ ctx: GraphicsContext, _ s: CGSize, _ t: Double, _ accent: Color) {
        var ctx = ctx
        let cx = s.width * 0.3, cy = s.height * 0.52
        let fw = s.width * 0.3, fh = s.height * 0.5
        // folder
        let body = CGRect(x: cx - fw / 2, y: cy - fh / 2 + 12, width: fw, height: fh - 12)
        let tab = CGRect(x: body.minX, y: body.minY - 14, width: fw * 0.42, height: 16)
        let fc = Color(red: 0.95, green: 0.72, blue: 0.2)
        glow(ctx, radius: 14) { $0.fill(Path(body), with: .color(fc.opacity(0.35))) }
        ctx.fill(Path(tab), with: .color(fc.opacity(0.85)))
        ctx.fill(Path(body), with: .linearGradient(Gradient(colors: [fc, fc.opacity(0.65)]), startPoint: CGPoint(x: 0, y: body.minY), endPoint: CGPoint(x: 0, y: body.maxY)))
        ctx.stroke(Path(body), with: .color(.white.opacity(0.9)), lineWidth: 1.4)
        ctx.draw(Text("MacBand").font(.system(size: 17, weight: .bold)).foregroundColor(.black.opacity(0.7)), at: CGPoint(x: body.midX, y: body.midY))
        // project files dropping in
        for i in 0..<3 {
            let p = ((t * 0.35 + Double(i) / 3).truncatingRemainder(dividingBy: 1))
            let y = body.minY - 52 + CGFloat(ease(p / 0.7)) * 56
            ctx.opacity = 1 - ease((p - 0.65) / 0.3)
            let f = CGRect(x: body.midX - 22 + CGFloat(i - 1) * 24, y: y, width: 36, height: 44)
            ctx.fill(Path(f), with: .color(.white.opacity(0.92))); ctx.stroke(Path(f), with: .color(accent), lineWidth: 1.4)
            for l in 0..<3 { ctx.fill(Path(CGRect(x: f.minX + 6, y: f.minY + 8 + CGFloat(l) * 8, width: 24 - CGFloat(l) * 5, height: 2)), with: .color(accent.opacity(0.6))) }
            ctx.opacity = 1
        }
        // auto-save ring
        let rx = s.width * 0.7, ry = cy, rr = s.height * 0.26
        let p = t.truncatingRemainder(dividingBy: 4) / 3.2
        ctx.stroke(Path(ellipseIn: CGRect(x: rx - rr, y: ry - rr, width: rr * 2, height: rr * 2)), with: .color(.white.opacity(0.14)), lineWidth: 9)
        var arc = Path(); arc.addArc(center: CGPoint(x: rx, y: ry), radius: rr, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(1, p)), clockwise: false)
        glow(ctx, radius: 7) { $0.stroke(arc, with: .color(accent), style: StrokeStyle(lineWidth: 9, lineCap: .round)) }
        ctx.stroke(arc, with: .color(accent), style: StrokeStyle(lineWidth: 9, lineCap: .round))
        if p >= 1 {
            let a = ease((p - 1) / 0.12) * (1 - ease((t.truncatingRemainder(dividingBy: 4) - 3.7) / 0.3))
            var check = Path(); check.move(to: CGPoint(x: rx - rr * 0.34, y: ry + 2)); check.addLine(to: CGPoint(x: rx - rr * 0.08, y: ry + rr * 0.28)); check.addLine(to: CGPoint(x: rx + rr * 0.4, y: ry - rr * 0.28))
            ctx.opacity = a
            ctx.stroke(check, with: .color(.white), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            ctx.opacity = 1
        } else {
            ctx.draw(Text("Auto Save").font(.system(size: 14, weight: .semibold)).foregroundColor(.white.opacity(0.85)), at: CGPoint(x: rx, y: ry))
        }
    }
}

// MARK: - The introduction itself

private struct IntroBackdrop: View {
    let t0: Date
    var body: some View {
        SwiftUI.TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSince(t0)
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                    Gradient(colors: [Color(red: 0.03, green: 0.04, blue: 0.09), Color(red: 0.07, green: 0.03, blue: 0.12), Color(red: 0.02, green: 0.07, blue: 0.1)]),
                    startPoint: CGPoint(x: size.width * (0.5 + 0.5 * CGFloat(sin(t * 0.07))), y: 0), endPoint: CGPoint(x: size.width * (0.5 - 0.5 * CGFloat(sin(t * 0.07))), y: size.height)))
                for i in 0..<46 {
                    let d = 0.4 + Double(i % 5) * 0.2
                    let x = size.width * CGFloat((Double(i) * 0.137 + sin(t * 0.09 * d + Double(i)) * 0.03).truncatingRemainder(dividingBy: 1))
                    let y = size.height - CGFloat((t * 14 * d + Double(i) * 53).truncatingRemainder(dividingBy: Double(size.height) + 40)) + 20
                    let a = 0.06 + 0.12 * d * min(1, Double(y) / 120)
                    let g = ["♪", "♫", "♩", "♬"][i % 4]
                    ctx.draw(Text(g).font(.system(size: 14 + CGFloat(i % 4) * 8)).foregroundColor(IntroArt.hueColor(0.55 + Double(i) * 0.037, 1, a)), at: CGPoint(x: x, y: y))
                }
            }
        }
    }
}

struct IntroOverlay: View {
    @EnvironmentObject var session: Session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var forward = true
    @State private var t0 = Date()
    @FocusState private var focused: Bool
    private let pages = Intro.pages

    private func go(_ delta: Int) {
        let n = page + delta
        guard n >= 0 else { return }
        if n >= pages.count { session.finishIntro(); return }
        forward = delta > 0
        withAnimation(.easeInOut(duration: 0.5)) { page = n }
    }

    var body: some View {
        ZStack {
            IntroBackdrop(t0: t0).ignoresSafeArea()
            Color.black.opacity(0.25)
            card
        }
        .transition(.opacity)
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { t0 = Date(); focused = true; page = min(max(0, session.introStartPage), pages.count - 1); session.introStartPage = 0 }
        .onKeyPress(.rightArrow) { go(1); return .handled }
        .onKeyPress(.leftArrow) { go(-1); return .handled }
        .onKeyPress(.return) { go(1); return .handled }
        .onKeyPress(.space) { go(1); return .handled }
        .onKeyPress(.escape) { session.finishIntro(); return .handled }
    }

    /// A phone gets a smaller picture and smaller type so the whole page fits.
    private var compactIntro: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }
    private var artHeight: CGFloat {
        #if os(iOS)
        return max(100, min(280, UIScreen.main.bounds.height * 0.27))
        #else
        return 280
        #endif
    }

    private var card: some View {
        VStack(spacing: 0) {
            SwiftUI.TimelineView(.animation) { tl in
                IntroArt(page: page, t: reduceMotion ? 3.0 : tl.date.timeIntervalSince(t0))
                    .id(page)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96)), removal: .opacity))
            }
            .frame(height: artHeight)
            .background(Color.black.opacity(0.35))
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1) }
            .clipped()

            VStack(alignment: .leading, spacing: 10) {
                Text(pages[page].title).font(.system(size: compactIntro ? 21 : 26, weight: .bold)).foregroundStyle(.white)
                    .id("title\(page)").transition(.move(edge: forward ? .trailing : .leading).combined(with: .opacity))
                Text(pages[page].text).font(.system(size: compactIntro ? 13 : 14)).foregroundStyle(.white.opacity(0.82)).fixedSize(horizontal: false, vertical: true)
                    .id("text\(page)").transition(.opacity)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(pages[page].points.enumerated()), id: \.offset) { i, p in
                        HStack(alignment: .top, spacing: 8) {
                            Rectangle().fill(Theme.accent).frame(width: 7, height: 7).padding(.top, 5)
                            Text(p).font(.system(size: compactIntro ? 11.5 : 12.5)).foregroundStyle(.white.opacity(0.72))
                        }
                        .id("pt\(page)-\(i)").transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, compactIntro ? 18 : 30).padding(.top, compactIntro ? 12 : 20)
            .frame(maxWidth: .infinity, minHeight: compactIntro ? 0 : 190, alignment: .topLeading)

            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button("Skip") { session.finishIntro() }.opacity(page == pages.count - 1 ? 0 : 1)
                Spacer()
                HStack(spacing: 7) {
                    ForEach(0..<pages.count, id: \.self) { i in
                        Rectangle().fill(i == page ? Theme.accent : Color.white.opacity(0.25)).frame(width: i == page ? 22 : 8, height: 8)
                            .animation(.easeInOut(duration: 0.3), value: page)
                            .onTapGesture { forward = i > page; withAnimation(.easeInOut(duration: 0.5)) { page = i } }
                    }
                }
                Spacer()
                Button("Back") { go(-1) }.opacity(page == 0 ? 0 : 1).disabled(page == 0)
                Button { go(1) } label: { Text(page == pages.count - 1 ? "Get Started" : "Next").padding(.horizontal, 12) }
                    .buttonStyle(VistaButtonStyle(compact: false))
            }
            .buttonStyle(VistaButtonStyle())
            .padding(.horizontal, compactIntro ? 14 : 24).padding(.bottom, compactIntro ? 12 : 20).padding(.top, 8)
        }
        #if os(macOS)
        .frame(width: 760, height: 590)
        #else
        .frame(maxWidth: 760, maxHeight: 590)
        .padding(.horizontal, 10).padding(.vertical, 6)
        #endif
        .background(Rectangle().fill(Color(white: 0.09).opacity(0.94)))
        .overlay(Rectangle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 40)
    }
}

extension Session {
    var showBrowserAtLaunch: Bool {
        get { UserDefaults.standard.object(forKey: "showBrowserAtLaunch") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showBrowserAtLaunch"); objectWillChange.send() }
    }

    /// Plays the introduction (also from Help ▸ Show Introduction).
    func startIntro() { withAnimation(.easeInOut(duration: 0.4)) { showIntro = true } }

    func finishIntro() {
        Intro.seen = true
        withAnimation(.easeInOut(duration: 0.4)) { showIntro = false }
        // after the introduction, the project chooser (if there is anything to choose)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if self.pendingNotice != nil { self.showPendingNotice() } else { self.maybeShowBrowserAtLaunch() }
        }
    }

    func maybeShowBrowserAtLaunch() {
        guard showBrowserAtLaunch, fileURL == nil, !isDirty, !showIntro, !bandImportRunning, pendingNotice == nil else { return }
        let folderHasProjects = !ProjectScanner.projectFiles(in: ProjectsFolder.url).isEmpty
        if folderHasProjects || !RecentProjects.urls.isEmpty { showProjectBrowser = true }
    }

    /// What happens when MacBand starts: make the folder, offer a recovered project, the introduction the first time, then the chooser.
    func launchFlow() {
        let folder = ProjectsFolder.ensure()
        if folder.created, !Intro.seen { writeWelcomeProject(in: folder.url) }
        autoImportGarageBandProjects()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if self.offerRecovery() { return }
            self.continueLaunch()
        }
    }

    /// After the recovery question: the introduction the first time, otherwise the project chooser.
    func continueLaunch() {
        if !Intro.seen { startIntro() } else { maybeShowBrowserAtLaunch() }
    }

    /// A small song in the new folder so the chooser isn't empty the first time.
    func writeWelcomeProject(in folder: URL) {
        let url = folder.appendingPathComponent("Welcome to MacBand.macband")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        var p = DemoSong.make(); p.name = "Welcome to MacBand"
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(p) { try? data.write(to: url, options: .atomic) }
    }
}
