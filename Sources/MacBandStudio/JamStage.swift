#if os(macOS)
import Foundation
import AppKit
import SceneKit
import simd

// A 3D stage with an instrument for every track, in the spirit of midis2jam2: keys go down, strings are fretted and plucked,
// drummers hit the drums, horns blow. When exactly two instruments (drums not counted) are playing, a spotlight picks them out.

private func V(_ x: Double, _ y: Double, _ z: Double) -> SCNVector3 { SCNVector3(x: CGFloat(x), y: CGFloat(y), z: CGFloat(z)) }

/// What one instrument is told every frame.
struct JamFrame {
    var beat: Double
    var spb: Double                // seconds per beat
    var time: Double               // seconds since the stage was built
    var dt: Double
    var playing: Bool
    var sounding: [VNote]          // held down right now
    var recent: [VNote]            // started within the last second
    var upcoming: [VNote]          // sounding now or starting soon (the piano's falling notes)

    func age(_ n: VNote) -> Double { max(0, (beat - n.start) * spb) }
}

enum JamStyle {
    static func material(_ c: NSColor, shine: CGFloat = 0.35) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = c
        m.specular.contents = NSColor(white: shine, alpha: 1)
        m.shininess = 0.4
        return m
    }
    /// A glow colour: black at 0, the tint at 1.
    static func lit(_ tint: NSColor, _ k: Double) -> NSColor { NSColor.black.mixed(tint, CGFloat(min(1, max(0, k)))) }

    static func part(_ g: SCNGeometry, _ m: SCNMaterial, _ x: Double = 0, _ y: Double = 0, _ z: Double = 0) -> SCNNode {
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.position = V(x, y, z)
        return n
    }
    static func box(_ w: Double, _ h: Double, _ d: Double, _ m: SCNMaterial, _ x: Double = 0, _ y: Double = 0, _ z: Double = 0, chamfer: Double = 0.02) -> SCNNode {
        part(SCNBox(width: CGFloat(w), height: CGFloat(h), length: CGFloat(d), chamferRadius: CGFloat(chamfer)), m, x, y, z)
    }
    static func cyl(_ r: Double, _ h: Double, _ m: SCNMaterial, _ x: Double = 0, _ y: Double = 0, _ z: Double = 0) -> SCNNode {
        part(SCNCylinder(radius: CGFloat(r), height: CGFloat(h)), m, x, y, z)
    }
    static func ball(_ r: Double, _ m: SCNMaterial, _ x: Double = 0, _ y: Double = 0, _ z: Double = 0) -> SCNNode {
        part(SCNSphere(radius: CGFloat(r)), m, x, y, z)
    }
    static let brass = NSColor(red: 0.92, green: 0.72, blue: 0.25, alpha: 1)
    static let steel = NSColor(red: 0.78, green: 0.8, blue: 0.84, alpha: 1)
    static let wood = NSColor(red: 0.5, green: 0.28, blue: 0.14, alpha: 1)
    static let ink = NSColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
}

/// One instrument on the stage. `size` is its natural width and height; the stage scales it to fit its place.
class JamInstrument {
    let node = SCNNode()
    let kind: JamKind
    let tint: NSColor
    var size: (w: Double, h: Double) = (4, 3)
    init(kind: JamKind, tint: NSColor) { self.kind = kind; self.tint = tint }
    func update(_ f: JamFrame) {}
}

// MARK: - Piano (also organs and mallets: anything with keys)

final class JamPiano: JamInstrument {
    private final class Key {
        let hinge: SCNNode, mat: SCNMaterial, black: Bool, base: NSColor, x: Double
        var amount = 0.0, shown = -1.0
        init(hinge: SCNNode, mat: SCNMaterial, black: Bool, base: NSColor, x: Double) { self.hinge = hinge; self.mat = mat; self.black = black; self.base = base; self.x = x }
    }
    private var keys: [Int: Key] = [:]
    private var bars: [SCNNode] = []
    let lo: Int, hi: Int
    private static let inOctave = [0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6]
    private static func isBlack(_ p: Int) -> Bool { [1, 3, 6, 8, 10].contains(p % 12) }
    private static func whiteIndex(_ p: Int) -> Int { (p / 12) * 7 + inOctave[p % 12] }

    /// The keyboard spans whole octaves around the notes, at least three of them.
    static func keyRange(for range: ClosedRange<Int>) -> (Int, Int) {
        var lo = max(24, range.lowerBound / 12 * 12), hi = min(107, range.upperBound / 12 * 12 + 11)
        if hi < lo { hi = lo + 35 }
        var low = false
        while hi - lo + 1 < 36 {
            if low, lo - 12 >= 24 { lo -= 12 } else if hi + 12 <= 107 { hi += 12 } else if lo - 12 >= 24 { lo -= 12 } else { break }
            low.toggle()
        }
        return (lo, hi)
    }

    init(tint: NSColor, range: ClosedRange<Int>) {
        (lo, hi) = Self.keyRange(for: range)
        super.init(kind: .piano, tint: tint)
        let w0 = Self.whiteIndex(lo), whites = Self.whiteIndex(hi) - w0 + 1
        let ww = 0.22, width = Double(whites) * ww
        let rig = SCNNode()
        rig.position = V(-width / 2, 1.36, 0)
        node.addChildNode(rig)
        let ivory = NSColor(white: 0.95, alpha: 1), ebony = NSColor(white: 0.07, alpha: 1)
        for p in lo...hi {
            let black = Self.isBlack(p)
            let wx = Double(Self.whiteIndex(p) - w0) * ww + ww / 2
            let x = black ? wx + ww * 0.5 : wx
            let m = JamStyle.material(black ? ebony : ivory, shine: 0.5)
            let hinge = SCNNode()
            hinge.position = V(x, 0, -0.55)
            let key = black ? JamStyle.box(0.125, 0.16, 0.7, m, 0, 0.01, 0.35, chamfer: 0.015) : JamStyle.box(ww - 0.02, 0.16, 1.1, m, 0, -0.08, 0.55, chamfer: 0.015)
            hinge.addChildNode(key)
            if black { hinge.position.y = 0.09 }
            rig.addChildNode(hinge)
            keys[p] = Key(hinge: hinge, mat: m, black: black, base: black ? ebony : ivory, x: x)
        }
        let cab = JamStyle.material(NSColor(white: 0.04, alpha: 1), shine: 0.7)
        rig.addChildNode(JamStyle.box(width + 0.4, 1.2, 1.3, cab, width / 2, -0.76, 0.0, chamfer: 0.04))
        rig.addChildNode(JamStyle.box(width + 0.4, 1.0, 0.22, cab, width / 2, 0.45, -0.72, chamfer: 0.04))
        let strip = SCNMaterial(); strip.lightingModel = .constant; strip.diffuse.contents = tint
        rig.addChildNode(JamStyle.box(width + 0.3, 0.04, 0.04, strip, width / 2, 0.97, -0.6, chamfer: 0))
        // falling notes, like a piano-roll tutorial
        let barMat = SCNMaterial(); barMat.lightingModel = .constant; barMat.diffuse.contents = tint.withAlphaComponent(0.85); barMat.emission.contents = JamStyle.lit(tint, 0.5)
        for _ in 0..<48 {
            let b = JamStyle.box(1, 1, 1, barMat, chamfer: 0.1)
            b.isHidden = true
            rig.addChildNode(b)
            bars.append(b)
        }
        size = (width + 0.4, 2.4)
    }

    /// How far down the key for `pitch` is, 0...1.
    func pressed(_ pitch: Int) -> Double { keys[fold(pitch)]?.amount ?? 0 }

    private func fold(_ p: Int) -> Int { var q = p; while q < lo { q += 12 }; while q > hi { q -= 12 }; return q }

    override func update(_ f: JamFrame) {
        var target: [Int: Double] = [:]
        for n in f.sounding { let p = fold(n.pitch); target[p] = max(target[p] ?? 0, 0.6 + 0.4 * Double(n.vel) / 127) }
        for (p, k) in keys {
            let t = target[p] ?? 0
            k.amount += (t - k.amount) * min(1, f.dt * (t > k.amount ? 40 : 14))
            if t == 0 && k.amount < 0.01 { k.amount = 0 }
            if k.amount == k.shown || (abs(k.amount - k.shown) < 0.01 && k.amount > 0) { continue }
            k.shown = k.amount
            k.hinge.eulerAngles.x = CGFloat(k.amount * (k.black ? 0.05 : 0.075))
            k.mat.emission.contents = JamStyle.lit(tint, k.amount * 0.85)
            k.mat.diffuse.contents = k.base.mixed(tint, CGFloat(k.amount * 0.6))
        }
        let speed = 1.5, look = 2.4
        var used = 0
        for n in f.upcoming where used < bars.count {
            let t0 = max(0, (n.start - f.beat) * f.spb), t1 = min(look, (n.end - f.beat) * f.spb)
            guard t1 > t0, let k = keys[fold(n.pitch)] else { continue }
            let y0 = 0.3 + t0 * speed, h = max(0.06, (t1 - t0) * speed)
            let b = bars[used]; used += 1
            b.isHidden = false
            b.scale = V(k.black ? 0.1 : 0.16, h, 0.1)
            b.position = V(k.x, y0 + h / 2, -0.25)
        }
        for i in used..<bars.count where !bars[i].isHidden { bars[i].isHidden = true }
    }
}

// MARK: - Drums

final class JamDrums: JamInstrument {
    private final class Piece {
        let node: SCNNode, rest: SCNVector3, cymbal: Bool, x: Double, top: Double
        var head: SCNMaterial?
        init(node: SCNNode, cymbal: Bool, x: Double, top: Double) { self.node = node; rest = node.position; self.cymbal = cymbal; self.x = x; self.top = top }
    }
    private var pieces: [String: Piece] = [:]
    private var hatTop: SCNNode?
    private var sticks: [SCNNode] = []
    private var stickPiece = ["snare", "tom2"]
    private let hands = [V(-0.8, 2.7, 2.0), V(0.8, 2.7, 2.0)]

    /// Which drum a General MIDI percussion note hits.
    static func piece(for pitch: Int) -> String {
        switch pitch {
        case 35, 36: return "kick"
        case 37, 38, 39, 40: return "snare"
        case 41, 43: return "floor"
        case 45, 47: return "tom2"
        case 48, 50: return "tom1"
        case 42, 44, 46: return "hat"
        case 49, 52, 55, 57: return "crash"
        case 51, 53, 59: return "ride"
        default: return "aux"
        }
    }

    init(tint: NSColor) {
        super.init(kind: .drums, tint: tint)
        let shell = JamStyle.material(tint.mixed(.black, 0.45), shine: 0.6)
        let metal = JamStyle.material(JamStyle.steel, shine: 0.8)
        func head(_ c: NSColor = NSColor(white: 0.92, alpha: 1)) -> SCNMaterial { JamStyle.material(c, shine: 0.3) }
        func drum(_ name: String, r: Double, h: Double, at p: SCNVector3, tiltX: Double = 0, poleTo floor: Bool = true) {
            let n = SCNNode()
            n.position = p
            n.eulerAngles.x = CGFloat(tiltX)
            n.addChildNode(JamStyle.cyl(r, h, shell))
            let hm = head()
            n.addChildNode(JamStyle.cyl(r * 0.96, 0.02, hm, 0, h / 2 + 0.005, 0))
            n.addChildNode(JamStyle.cyl(r * 1.02, 0.03, metal, 0, h / 2 - 0.005, 0))      // the rim
            node.addChildNode(n)
            let piece = Piece(node: n, cymbal: false, x: Double(p.x), top: h / 2)
            piece.head = hm
            pieces[name] = piece
            if floor, Double(p.y) - h / 2 > 0.05 {                                     // a stand
                node.addChildNode(JamStyle.cyl(0.03, Double(p.y) - h / 2, metal, Double(p.x), (Double(p.y) - h / 2) / 2, Double(p.z)))
            }
        }
        func cymbal(_ name: String, r: Double, at p: SCNVector3, tilt: Double) {
            let n = SCNNode()
            n.position = p
            n.eulerAngles.z = CGFloat(tilt)
            let m = JamStyle.material(JamStyle.brass, shine: 0.9)
            n.addChildNode(JamStyle.cyl(r, 0.025, m))
            n.addChildNode(JamStyle.ball(r * 0.14, m, 0, 0.02, 0))
            node.addChildNode(n)
            pieces[name] = Piece(node: n, cymbal: true, x: Double(p.x), top: 0.02)
            pieces[name]?.head = m
            node.addChildNode(JamStyle.cyl(0.025, Double(p.y), metal, Double(p.x), Double(p.y) / 2, Double(p.z)))
        }
        // kick drum faces the audience
        let kick = SCNNode()
        kick.position = V(0, 0.7, -0.2)
        kick.eulerAngles.x = .pi / 2
        kick.addChildNode(JamStyle.cyl(0.7, 0.75, shell))
        let kh = head(tint.mixed(.white, 0.15))
        kick.addChildNode(JamStyle.cyl(0.66, 0.02, kh, 0, 0.385, 0))
        kick.addChildNode(JamStyle.cyl(0.72, 0.04, metal, 0, 0.37, 0))
        node.addChildNode(kick)
        let kp = Piece(node: kick, cymbal: false, x: 0, top: 0)
        kp.head = kh
        pieces["kick"] = kp
        drum("snare", r: 0.42, h: 0.24, at: V(-1.0, 1.05, 1.0), tiltX: 0.08)
        drum("tom1", r: 0.33, h: 0.3, at: V(-0.42, 1.65, 0.15), tiltX: 0.3)
        drum("tom2", r: 0.36, h: 0.32, at: V(0.45, 1.65, 0.15), tiltX: 0.3)
        drum("floor", r: 0.52, h: 0.62, at: V(1.45, 1.0, 0.75), tiltX: 0.04)
        drum("aux", r: 0.2, h: 0.28, at: V(0.3, 0.8, 1.45), tiltX: 0.2)
        cymbal("crash", r: 0.58, at: V(-1.35, 2.55, -0.55), tilt: 0.12)
        cymbal("ride", r: 0.68, at: V(2.05, 2.2, -0.35), tilt: -0.1)
        // hi-hat: two cymbals, the top one moves
        let hatNode = SCNNode(); hatNode.position = V(-2.0, 1.4, 0.55)
        let hm = JamStyle.material(JamStyle.brass, shine: 0.9)
        hatNode.addChildNode(JamStyle.cyl(0.38, 0.02, hm, 0, -0.04, 0))
        let top = SCNNode(); top.position = V(0, 0.02, 0)
        top.addChildNode(JamStyle.cyl(0.38, 0.02, hm))
        hatNode.addChildNode(top)
        node.addChildNode(hatNode)
        node.addChildNode(JamStyle.cyl(0.025, 1.4, metal, -2.0, 0.7, 0.55))
        hatTop = top
        let hp = Piece(node: hatNode, cymbal: true, x: -2.0, top: 0.04)
        hp.head = hm
        pieces["hat"] = hp
        // a stool and the sticks
        node.addChildNode(JamStyle.cyl(0.35, 0.14, JamStyle.material(JamStyle.ink), 0, 1.0, 2.4))
        node.addChildNode(JamStyle.cyl(0.04, 1.0, metal, 0, 0.5, 2.4))
        let stickMat = JamStyle.material(NSColor(red: 0.85, green: 0.7, blue: 0.5, alpha: 1))
        for _ in 0..<2 {
            let s = JamStyle.cyl(0.028, 1, stickMat)
            s.pivot = SCNMatrix4MakeTranslation(0, -0.5, 0)
            node.addChildNode(s)
            sticks.append(s)
        }
        size = (5.2, 3.0)
    }

    func hitPoint(_ name: String) -> SCNVector3 {
        guard let p = pieces[name] else { return V(0, 1, 0) }
        return SCNVector3(x: p.rest.x, y: p.rest.y + CGFloat(p.top), z: p.rest.z)
    }

    override func update(_ f: JamFrame) {
        var age: [String: Double] = [:]
        var open = false
        for n in f.recent {
            let name = Self.piece(for: n.pitch), a = f.age(n)
            if a < (age[name] ?? 9) { age[name] = a; if name == "hat" { open = n.pitch == 46 } }
        }
        for (name, p) in pieces {
            let a = age[name] ?? 9, e = exp(-a * 14), glow = exp(-a * 7)
            var pos = p.rest
            if name == "kick" {
                p.node.scale = V(1 + 0.05 * e, 1 + 0.05 * e, 1 + 0.05 * e)
            } else if p.cymbal {
                let wob = exp(-a * 4) * cos(a * 34)
                p.node.eulerAngles.x = CGFloat(0.16 * wob)
                if name != "hat" { p.node.eulerAngles.z = CGFloat((name == "crash" ? 0.12 : -0.1) + 0.08 * wob) }
                pos.y -= CGFloat(0.03 * e)
            } else {
                pos.y -= CGFloat(0.05 * e)
            }
            p.node.position = pos
            p.head?.emission.contents = JamStyle.lit(tint.mixed(.white, 0.25), glow * (p.cymbal ? 0.45 : 0.8))
        }
        if let t = hatTop {
            let a = age["hat"] ?? 9
            t.position.y = CGFloat(0.02 + (open ? 0.12 * exp(-a * 3) : -0.03 * exp(-a * 16)))
        }
        // each stick works the drums on its own side
        for i in 0..<2 {
            var best = 9.0
            for (name, p) in pieces where name != "kick" && (age[name] ?? 9) < 0.6 {
                let left = (name == "snare" || name == "tom1" || name == "hat" || name == "crash")
                if left == (i == 0), (age[name] ?? 9) < best { best = age[name] ?? 9; stickPiece[i] = name }
            }
            let hit = hitPoint(stickPiece[i])
            let lift = 1 - exp(-best * 7)
            let tip = SCNVector3(x: hit.x, y: hit.y + CGFloat(0.55 * lift), z: hit.z)
            let hand = hands[i]
            let dx = Double(tip.x - hand.x), dy = Double(tip.y - hand.y), dz = Double(tip.z - hand.z)
            let s = sticks[i]
            s.position = hand
            s.scale = V(1, sqrt(dx * dx + dy * dy + dz * dz), 1)
            let d = SIMD3<Float>(Float(dx), Float(dy), Float(dz))
            if simd_length(d) > 1e-4 { s.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(d)) }
        }
    }
}

// MARK: - Guitar, bass, violin family

final class JamStringed: JamInstrument {
    private let opens: [Int]
    private let spacing: Double
    private var strings: [SCNNode] = [], stringMats: [SCNMaterial] = [], markers: [SCNNode] = [], markerMats: [SCNMaterial] = []
    private var pluck: [Double] = []
    private let nutY: Double, bridgeY: Double, scaleLen: Double
    private var bow: SCNNode?
    private var bowAmount = 0.0

    static func tuning(_ kind: JamKind, program: Int) -> (opens: [Int], neck: Double) {
        switch kind {
        case .guitar: return ([40, 45, 50, 55, 59, 64], 2.3)
        case .bass: return ([28, 33, 38, 43], 2.8)
        default:
            switch program {
            case 41: return ([48, 55, 62, 69], 1.6)
            case 42: return ([36, 43, 50, 57], 2.0)
            case 43: return ([28, 33, 38, 43], 2.3)
            default: return ([55, 62, 69, 76], 1.5)
            }
        }
    }

    init(kind: JamKind, tint: NSColor, program: Int) {
        let t = Self.tuning(kind, program: program)
        opens = t.opens
        spacing = kind == .bass ? 0.14 : (kind == .guitar ? 0.1 : 0.12)
        bridgeY = -0.5
        nutY = 0.9 + t.neck
        scaleLen = nutY + 0.5
        super.init(kind: kind, tint: tint)
        let rig = SCNNode()
        node.addChildNode(rig)
        let bodyColor = kind == .strings ? JamStyle.wood.mixed(tint, 0.25) : tint.mixed(.black, 0.12)
        let body = JamStyle.material(bodyColor, shine: 0.7)
        let dark = JamStyle.material(JamStyle.ink, shine: 0.4)
        let s: Double = kind == .strings ? (program == 42 || program == 43 ? 1.3 : 0.95) : 1.15
        let lower = JamStyle.ball(1, body, 0, -0.4 * s, 0); lower.scale = V(0.9 * s, 0.95 * s, 0.3 * s)
        let upper = JamStyle.ball(1, body, 0, 0.35 * s, 0); upper.scale = V(0.65 * s, 0.6 * s, 0.3 * s)
        rig.addChildNode(lower); rig.addChildNode(upper)
        let hole = JamStyle.cyl(0.2 * s, 0.02, dark, 0, -0.05, 0.3 * s); hole.eulerAngles.x = .pi / 2
        rig.addChildNode(hole)
        let neckW = Double(opens.count) * spacing + 0.14
        rig.addChildNode(JamStyle.box(neckW, nutY - 0.55, 0.12, JamStyle.material(JamStyle.ink.mixed(JamStyle.wood, 0.3)), 0, (nutY + 0.55) / 2, 0.02, chamfer: 0.03))
        rig.addChildNode(JamStyle.box(neckW + 0.1, 0.45, 0.1, dark, 0, nutY + 0.2, 0.0, chamfer: 0.04))       // headstock
        rig.addChildNode(JamStyle.box(neckW + 0.1, 0.05, 0.14, JamStyle.material(NSColor(white: 0.9, alpha: 1)), 0, nutY, 0.04, chamfer: 0.01))     // nut
        rig.addChildNode(JamStyle.box(neckW + 0.1, 0.07, 0.16, JamStyle.material(NSColor(white: 0.85, alpha: 1)), 0, bridgeY, 0.1 * s + 0.05, chamfer: 0.01))     // bridge
        let fretMat = JamStyle.material(JamStyle.steel, shine: 0.9)
        for f in 1...19 {
            let y = nutY - scaleLen * (1 - pow(2, -Double(f) / 12))
            if y > 0.8 { rig.addChildNode(JamStyle.box(neckW, 0.015, 0.02, fretMat, 0, y, 0.09, chamfer: 0)) }
        }
        let n = opens.count
        for i in 0..<n {
            let x = (Double(i) - Double(n - 1) / 2) * spacing
            let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = NSColor(white: 0.85, alpha: 1)
            let str = JamStyle.cyl(0.008 + 0.004 * Double(n - 1 - i) / Double(n), nutY - bridgeY, m, x, (nutY + bridgeY) / 2, 0.12)
            rig.addChildNode(str)
            strings.append(str); stringMats.append(m); pluck.append(9)
            let mm = SCNMaterial(); mm.lightingModel = .constant; mm.diffuse.contents = tint.mixed(.white, 0.35); mm.emission.contents = tint
            let mk = JamStyle.ball(0.075, mm, x, nutY, 0.16); mk.scale = V(1, 1.25, 0.6)
            mk.isHidden = true
            rig.addChildNode(mk)
            markers.append(mk); markerMats.append(mm)
        }
        if kind == .strings {
            let b = SCNNode()
            b.addChildNode(JamStyle.cyl(0.018, 2.6, JamStyle.material(JamStyle.wood), 0, 0, 0))
            b.addChildNode(JamStyle.box(2.4, 0.05, 0.01, JamStyle.material(NSColor(white: 0.95, alpha: 1)), 0, -0.03, 0))
            b.eulerAngles.z = .pi / 2
            b.position = V(2.0, bridgeY + 0.55, 0.3)
            rig.addChildNode(b)
            bow = b
        }
        let lift = 1.4 * s
        rig.position = V(0, lift, 0)
        node.addChildNode(JamStyle.cyl(0.05, lift, JamStyle.material(JamStyle.steel, shine: 0.8), 0, lift / 2, -0.25))      // a stand
        node.addChildNode(JamStyle.cyl(0.55, 0.05, JamStyle.material(JamStyle.ink), 0, 0.03, -0.25))
        size = (max(1.9 * s, neckW + 0.5) + (kind == .strings ? 1.6 : 0), lift + nutY + 0.65)
    }

    /// Where the fingers go: each sounding note on its own string, as low a fret as it allows.
    func fingering(_ notes: [VNote]) -> [Int: (fret: Int, vel: Int, start: Double)] {
        var out: [Int: (fret: Int, vel: Int, start: Double)] = [:]
        for n in notes.sorted(by: { $0.pitch > $1.pitch }) {
            var chosen: Int?
            for s in stride(from: opens.count - 1, through: 0, by: -1) where out[s] == nil {
                let fret = n.pitch - opens[s]
                if fret >= 0 && fret <= 21 { chosen = s; break }
            }
            if chosen == nil { chosen = (0..<opens.count).first { out[$0] == nil } }       // out of range: squeeze it in anyway
            guard let s = chosen else { continue }
            out[s] = (min(21, max(0, n.pitch - opens[s])), n.vel, n.start)
        }
        return out
    }

    override func update(_ f: JamFrame) {
        let fingers = fingering(f.sounding)
        for i in 0..<opens.count {
            let x = (Double(i) - Double(opens.count - 1) / 2) * spacing
            if let fg = fingers[i] {
                let y = fg.fret == 0 ? nutY - 0.08 : nutY - scaleLen * (1 - pow(2, -(Double(fg.fret) - 0.5) / 12))
                markers[i].isHidden = false
                markers[i].position = V(x, y, 0.16)
                let a = max(0, (f.beat - fg.start) * f.spb)
                let k = 1 + 0.5 * exp(-a * 9)
                markers[i].scale = V(k, 1.25 * k, 0.6)
                pluck[i] = a
            } else if !markers[i].isHidden {
                markers[i].isHidden = true
            }
            // the string buzzes as it is played, and rings out a little after
            let a = pluck[i]
            let amp = fingers[i] != nil || a < 1.2 ? exp(-a * 2.2) : 0
            strings[i].position.x = CGFloat(x + 0.018 * amp * sin(f.time * 95 + Double(i)))
            stringMats[i].diffuse.contents = JamStyle.lit(tint.mixed(.white, 0.5), 0.35 + 0.65 * amp)
            if fingers[i] == nil { pluck[i] += f.dt }
        }
        if let b = bow {
            let t = fingers.isEmpty ? 0.0 : 1.0
            bowAmount += (t - bowAmount) * min(1, f.dt * 10)
            let sweep = sin(f.time * 3.2) * 0.55
            b.position.x = CGFloat(2.0 * (1 - bowAmount) + sweep * bowAmount)
            b.position.y = CGFloat(bridgeY + 0.55 + 0.4 * (1 - bowAmount))
        }
    }
}

// MARK: - Horns and woodwinds

/// Dots that drift out of an instrument for every note, like the music coming out of it.
final class JamPuffs {
    let node = SCNNode()
    private var dots: [SCNNode] = []
    init(count: Int, tint: NSColor) {
        let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = tint.mixed(.white, 0.4); m.emission.contents = tint
        for _ in 0..<count {
            let d = JamStyle.ball(0.07, m)
            d.isHidden = true
            node.addChildNode(d)
            dots.append(d)
        }
    }
    func update(_ f: JamFrame, dir: SCNVector3, speed: Double, life: Double = 1.0) {
        for d in dots where !d.isHidden { d.isHidden = true }
        for n in f.recent {
            let a = f.age(n)
            guard a < life else { continue }
            let d = dots[abs(Int(n.start * 8) &+ n.pitch) % dots.count]
            d.isHidden = false
            let wob = 0.12 * sin(a * 7 + Double(n.pitch))
            d.position = V(Double(dir.x) * a * speed + wob, Double(dir.y) * a * speed, Double(dir.z) * a * speed)
            d.opacity = CGFloat(1 - a / life)
            let s = 1 - 0.5 * a / life
            d.scale = V(s, s, s)
        }
    }
}

final class JamHorn: JamInstrument {
    private var valves: [SCNNode] = []
    private let bell: SCNNode
    private let bellMat: SCNMaterial
    private let puffs: JamPuffs
    private var amount = 0.0

    override init(kind: JamKind, tint: NSColor) {
        let gold = kind == .reed ? NSColor(red: 0.85, green: 0.62, blue: 0.2, alpha: 1) : JamStyle.brass
        let m = JamStyle.material(gold, shine: 0.95)
        bellMat = JamStyle.material(gold.mixed(tint, 0.1), shine: 0.95)
        bell = SCNNode()
        puffs = JamPuffs(count: 6, tint: tint)
        super.init(kind: kind, tint: tint)
        let rig = SCNNode()
        node.addChildNode(rig)
        rig.addChildNode(JamStyle.part(SCNCylinder(radius: 0.07, height: 2.6), m, 0, 0, 0).rotatedZ(.pi / 2))
        let loop = JamStyle.part(SCNTorus(ringRadius: 0.5, pipeRadius: 0.06), m, -0.3, 0, 0); loop.eulerAngles.x = .pi / 2
        rig.addChildNode(loop)
        rig.addChildNode(JamStyle.part(SCNCylinder(radius: 0.1, height: 0.2), m, -1.35, 0, 0).rotatedZ(.pi / 2))      // mouthpiece
        // the bell is a flare of open rings, so you can look into it
        bellMat.isDoubleSided = true
        for (i, r) in [0.09, 0.14, 0.21, 0.3, 0.42, 0.57, 0.74].enumerated() {
            let ring = SCNTube(innerRadius: CGFloat(r - 0.035), outerRadius: CGFloat(r), height: 0.17)
            ring.materials = [bellMat]
            let n = SCNNode(geometry: ring)
            n.position = V(0, Double(i) * 0.15 - 0.45, 0)
            bell.addChildNode(n)
        }
        bell.eulerAngles.x = .pi / 2
        bell.position = V(1.3, 0, 0.55)
        rig.addChildNode(bell)
        for i in 0..<3 {
            let v = SCNNode()
            v.position = V(-0.75 + Double(i) * 0.28, 0.1, 0)
            v.addChildNode(JamStyle.cyl(0.06, 0.4, m, 0, 0.2, 0))
            v.addChildNode(JamStyle.cyl(0.1, 0.07, JamStyle.material(NSColor(white: 0.9, alpha: 1), shine: 0.9), 0, 0.45, 0))
            rig.addChildNode(v)
            valves.append(v)
        }
        if kind == .reed {                           // a saxophone stands up
            rig.eulerAngles.z = .pi / 2 - 0.35
            rig.position = V(0, 1.3, 0)
        } else {
            rig.position = V(0, 0.9, 0)
            rig.eulerAngles.y = -0.35
        }
        node.addChildNode(puffs.node)
        node.addChildNode(JamStyle.cyl(0.04, kind == .reed ? 1.0 : 0.85, JamStyle.material(JamStyle.steel, shine: 0.8), kind == .reed ? 0.1 : -0.3, kind == .reed ? 0.5 : 0.42, -0.1))
        puffs.node.position = kind == .reed ? V(0.45, 2.6, 1.2) : V(0.85, 0.9, 1.6)
        size = kind == .reed ? (2.4, 3.2) : (3.4, 2.4)
    }

    override func update(_ f: JamFrame) {
        let held = f.sounding.sorted { $0.pitch < $1.pitch }.first
        let target = held == nil ? 0.0 : 1.0
        amount += (target - amount) * min(1, f.dt * 14)
        let mask = held.map { ($0.pitch * 3) % 8 } ?? 0
        for (i, v) in valves.enumerated() { v.position.y = CGFloat(0.1 - (mask >> i & 1 == 1 ? 0.12 : 0)) }
        let pulse = 1 + amount * (0.06 + 0.04 * sin(f.time * 38))
        bell.scale = V(pulse, 1, pulse)
        bellMat.emission.contents = JamStyle.lit(tint, amount * 0.4)
        puffs.update(f, dir: kind == .reed ? V(0.1, 1, 0.3) : V(0.25, 0.35, 1), speed: 1.3)
    }
}

private extension SCNNode {
    func rotatedZ(_ a: Double) -> SCNNode { eulerAngles.z = CGFloat(a); return self }
}

final class JamFlute: JamInstrument {
    private var keysDown: [SCNNode] = []
    private let tube: SCNMaterial
    private let puffs: JamPuffs
    private var amount = 0.0

    init(tint: NSColor) {
        tube = JamStyle.material(JamStyle.steel, shine: 0.95)
        puffs = JamPuffs(count: 6, tint: tint)
        super.init(kind: .pipe, tint: tint)
        let rig = SCNNode()
        rig.eulerAngles.z = 0.12
        rig.position = V(0, 1.4, 0)
        node.addChildNode(rig)
        rig.addChildNode(JamStyle.part(SCNCylinder(radius: 0.075, height: 3.4), tube, 0, 0, 0).rotatedZ(.pi / 2))
        rig.addChildNode(JamStyle.cyl(0.1, 0.1, JamStyle.material(JamStyle.ink), -1.6, 0, 0.0))
        for i in 0..<7 {
            let k = JamStyle.cyl(0.075, 0.06, JamStyle.material(NSColor(white: 0.9, alpha: 1), shine: 0.9), -0.9 + Double(i) * 0.38, 0.1, 0.0)
            rig.addChildNode(k)
            keysDown.append(k)
        }
        puffs.node.position = V(1.9, 1.5, 0.2)
        node.addChildNode(puffs.node)
        node.addChildNode(JamStyle.cyl(0.04, 1.4, JamStyle.material(JamStyle.steel, shine: 0.8), 0, 0.7, -0.2))
        node.addChildNode(JamStyle.cyl(0.5, 0.05, JamStyle.material(JamStyle.ink), 0, 0.03, -0.2))
        size = (3.6, 1.6)
    }

    override func update(_ f: JamFrame) {
        let held = f.sounding.sorted { $0.pitch < $1.pitch }.last
        amount += ((held == nil ? 0 : 1) - amount) * min(1, f.dt * 14)
        let mask = held.map { ($0.pitch * 5) % 128 } ?? 0
        for (i, k) in keysDown.enumerated() {
            let down = mask >> i & 1 == 1
            k.position.y = CGFloat(down ? 0.04 : 0.1)
            k.geometry?.firstMaterial?.emission.contents = JamStyle.lit(tint, down && held != nil ? 0.7 : 0)
        }
        tube.emission.contents = JamStyle.lit(tint, amount * 0.25)
        puffs.update(f, dir: V(1, 0.3, 0.3), speed: 1.2)
    }
}

// MARK: - Synths and everything else: pillars of light

final class JamSynth: JamInstrument {
    private var pillars: [SCNNode] = [], mats: [SCNMaterial] = [], amounts: [Double] = []
    private let lo: Int, span: Double
    private let count = 16

    init(tint: NSColor, range: ClosedRange<Int>) {
        lo = range.lowerBound
        span = Double(max(12, range.upperBound - range.lowerBound + 1))
        super.init(kind: .synth, tint: tint)
        let base = JamStyle.material(NSColor(white: 0.05, alpha: 1), shine: 0.8)
        node.addChildNode(JamStyle.box(4.4, 0.3, 1.0, base, 0, 0.15, 0, chamfer: 0.06))
        for i in 0..<count {
            let m = JamStyle.material(tint.mixed(.black, 0.5), shine: 0.8)
            let p = JamStyle.part(SCNCapsule(capRadius: 0.11, height: 1), m, -2.0 + Double(i) * (4.0 / Double(count - 1)), 0.3, 0)
            p.pivot = SCNMatrix4MakeTranslation(0, -0.5, 0)
            node.addChildNode(p)
            pillars.append(p); mats.append(m); amounts.append(0)
        }
        size = (4.4, 2.6)
    }

    override func update(_ f: JamFrame) {
        var target = [Double](repeating: 0, count: count)
        for n in f.sounding {
            let i = min(count - 1, max(0, Int(Double(n.pitch - lo) / span * Double(count))))
            target[i] = max(target[i], 0.5 + 0.5 * Double(n.vel) / 127)
            if i > 0 { target[i - 1] = max(target[i - 1], 0.3 * target[i]) }
            if i < count - 1 { target[i + 1] = max(target[i + 1], 0.3 * target[i]) }
        }
        for i in 0..<count {
            amounts[i] += (target[i] - amounts[i]) * min(1, f.dt * (target[i] > amounts[i] ? 30 : 6))
            let a = amounts[i]
            pillars[i].scale = V(1, 0.5 + a * 1.9, 1)
            mats[i].emission.contents = JamStyle.lit(tint, a)
            mats[i].diffuse.contents = tint.mixed(.black, CGFloat(0.55 - 0.4 * a))
        }
    }
}

// MARK: - The stage

final class JamStage {
    final class Slot {
        let track: Int, inst: JamInstrument, spot: SCNNode?, beam: SCNMaterial?, pad: SCNMaterial, name: String
        var level = 0.0, glow = 0.0
        init(track: Int, inst: JamInstrument, spot: SCNNode?, beam: SCNMaterial?, pad: SCNMaterial, name: String) { self.track = track; self.inst = inst; self.spot = spot; self.beam = beam; self.pad = pad; self.name = name }
    }

    let scene = SCNScene()
    let cameraNode = SCNNode()
    private let world = SCNNode()
    private let ambient = SCNNode(), key = SCNNode()
    private(set) var slots: [Slot] = []
    private(set) var timeline = JamTimeline()
    private var spotState = JamSpot()
    private var drumFlags: [Bool] = []
    private(set) var spotTargets: [Int] = []          // the tracks in the spotlight right now
    private(set) var dim = 0.0                        // 0 = house lights, 1 = only the spotlights
    private var time = 0.0
    private var signature = 0
    private var extent = (halfWidth: 4.0, centerZ: 0.0, depth: 6.0)
    static let spotIntensity = 2700.0, ambientIntensity = 650.0, keyIntensity = 1150.0

    init() {
        scene.background.contents = Self.sky()
        scene.rootNode.addChildNode(world)
        let floor = SCNFloor()
        floor.reflectivity = 0.14; floor.reflectionFalloffEnd = 2.5
        floor.firstMaterial?.diffuse.contents = NSColor(red: 0.03, green: 0.032, blue: 0.05, alpha: 1)
        let fn = SCNNode(geometry: floor); fn.position = V(0, -0.22, 0)
        scene.rootNode.addChildNode(fn)
        let a = SCNLight(); a.type = .ambient; a.color = NSColor(red: 0.8, green: 0.85, blue: 1, alpha: 1); a.intensity = CGFloat(Self.ambientIntensity)
        ambient.light = a; scene.rootNode.addChildNode(ambient)
        let k = SCNLight(); k.type = .directional; k.color = NSColor(white: 1, alpha: 1); k.intensity = CGFloat(Self.keyIntensity)
        key.light = k; key.position = V(0, 10, 10); key.eulerAngles = V(-0.9, 0, 0)
        scene.rootNode.addChildNode(key)
        let cam = SCNCamera(); cam.fieldOfView = 42; cam.zNear = 0.1; cam.zFar = 300
        cam.wantsHDR = true; cam.wantsExposureAdaptation = false; cam.exposureOffset = 0; cam.bloomIntensity = 0.8; cam.bloomThreshold = 0.78; cam.bloomBlurRadius = 9
        cameraNode.camera = cam
        scene.rootNode.addChildNode(cameraNode)
        frameCamera(aspect: 1.6)
    }

    private static func sky() -> NSImage {
        let img = NSImage(size: NSSize(width: 4, height: 256))
        img.lockFocus()
        NSGradient(colors: [NSColor(red: 0.06, green: 0.065, blue: 0.12, alpha: 1), NSColor(red: 0.008, green: 0.01, blue: 0.022, alpha: 1)])?.draw(in: NSRect(x: 0, y: 0, width: 4, height: 256), angle: 90)
        img.unlockFocus()
        return img
    }

    /// A number that changes whenever the song or its instruments do.
    static func signature(_ project: Project) -> Int {
        var h = Hasher()
        for t in project.tracks {
            h.combine(t.id); h.combine(t.colorIndex); h.combine(t.name); h.combine(t.kind == .audio)
            h.combine(t.instrument.gmProgram); h.combine(t.instrument.isDrums); h.combine(t.instrument.sampler?.program); h.combine(t.instrument.sampler?.bank)
            h.combine(t.instrument.plugin?.name); h.combine(t.instrument.sampler?.name)
            for c in t.clips {
                h.combine(c.start)
                for n in c.notes { h.combine(n.pitch); h.combine(n.start); h.combine(n.length); h.combine(n.velocity) }
            }
        }
        return h.finalize()
    }

    /// Rebuilds the stage if the song changed; returns whether it did.
    @discardableResult
    func sync(_ project: Project, force: Bool = false) -> Bool {
        let s = Self.signature(project)
        guard force || s != signature else { return false }
        signature = s
        rebuild(project)
        return true
    }

    static func instrument(for t: Track, range: ClosedRange<Int>) -> JamInstrument {
        let tint = Palette.nsColor(t.colorIndex)
        let kind = JamKind.of(t)
        let program = t.instrument.sampler?.program ?? t.instrument.gmProgram
        switch kind {
        case .drums: return JamDrums(tint: tint)
        case .piano: return JamPiano(tint: tint, range: range)
        case .guitar, .bass, .strings: return JamStringed(kind: kind, tint: tint, program: program)
        case .brass, .reed: return JamHorn(kind: kind, tint: tint)
        case .pipe: return JamFlute(tint: tint)
        case .synth: return JamSynth(tint: tint, range: range)
        }
    }

    private func rebuild(_ project: Project) {
        for c in world.childNodes { c.removeFromParentNode() }
        slots = []; spotState.reset(); spotTargets = []; time = 0
        timeline = JamTimeline(project)
        drumFlags = project.tracks.map { JamKind.of($0) == .drums && $0.kind == .instrument }
        var melodic: [Int] = [], drums: [Int] = []
        for (ti, t) in project.tracks.enumerated() where t.kind == .instrument && timeline.hasNotes(ti) {
            if drumFlags[ti] { drums.append(ti) } else { melodic.append(ti) }
        }
        melodic = Array(melodic.prefix(24)); drums = Array(drums.prefix(4))

        // places: rows of up to six, drums at the back
        let rowCap = 6, rowGap = 5.4, spacing = 4.8
        let rows = max(1, (melodic.count + rowCap - 1) / rowCap)
        var spots: [(track: Int, x: Double, z: Double)] = []
        var index = 0
        for r in 0..<rows {
            let left = melodic.count - index, remainingRows = rows - r
            let n = (left + remainingRows - 1) / remainingRows
            for i in 0..<n {
                let x = (Double(i) - Double(n - 1) / 2) * spacing
                spots.append((melodic[index + i], x, -Double(r) * rowGap + 0.04 * x * x))
            }
            index += n
        }
        let drumZ = -Double(melodic.isEmpty ? 0 : rows) * rowGap - (melodic.isEmpty ? 0 : 3.4)
        for (i, ti) in drums.enumerated() { spots.append((ti, (Double(i) - Double(drums.count - 1) / 2) * 6.4, drumZ)) }

        for sp in spots {
            let t = project.tracks[sp.track]
            let inst = Self.instrument(for: t, range: timeline.pitchRange(sp.track))
            let tint = Palette.nsColor(t.colorIndex)
            let fit = min(1.5, 4.4 / inst.size.w, 4.3 / inst.size.h)
            inst.node.scale = V(fit, fit, fit)
            inst.node.position = V(sp.x, 0, sp.z)
            inst.node.eulerAngles.y = CGFloat(-sp.x * 0.035)
            world.addChildNode(inst.node)
            let padMat = JamStyle.material(NSColor(white: 0.07, alpha: 1), shine: 0.6)
            let pad = JamStyle.cyl(2.3, 0.05, padMat, sp.x, 0.02, sp.z)
            world.addChildNode(pad)
            world.addChildNode(Self.label(t.name, tint: tint, at: V(sp.x, 0.28, sp.z + 2.7)))
            var spot: SCNNode?, beam: SCNMaterial?
            if inst.kind != .drums {
                let target = V(sp.x, 1.5, sp.z)
                let from = V(sp.x, 11, sp.z + 5)
                let l = SCNLight(); l.type = .spot; l.color = NSColor(red: 1, green: 0.95, blue: 0.82, alpha: 1)
                l.spotInnerAngle = 16; l.spotOuterAngle = 40; l.intensity = 0
                let sn = SCNNode(); sn.light = l; sn.position = from
                let aim = SCNNode(); aim.position = target; world.addChildNode(aim)
                let c = SCNLookAtConstraint(target: aim)
                c.isGimbalLockEnabled = true
                sn.constraints = [c]
                sn.isHidden = true
                world.addChildNode(sn)
                let dist = sqrt(pow(Double(from.x - target.x), 2) + pow(Double(from.y - target.y), 2) + pow(Double(from.z - target.z), 2))
                let cone = SCNCone(topRadius: 2.6, bottomRadius: 0.15, height: CGFloat(dist))
                let bm = SCNMaterial(); bm.lightingModel = .constant; bm.diffuse.contents = NSColor.black
                bm.blendMode = .add; bm.writesToDepthBuffer = false; bm.isDoubleSided = true
                cone.materials = [bm]
                let bn = SCNNode(geometry: cone)
                bn.eulerAngles.x = -.pi / 2                  // the spotlight looks down its −z; the cone's wide end points at the player
                bn.position = V(0, 0, -dist / 2)
                                sn.addChildNode(bn)
                spot = sn; beam = bm
            }
            slots.append(Slot(track: sp.track, inst: inst, spot: spot, beam: beam, pad: padMat, name: t.name))
        }
        let minZ = spots.map { $0.z }.min() ?? 0, maxZ = spots.map { $0.z }.max() ?? 0, maxX = spots.map { abs($0.x) }.max() ?? 0
        let midZ = (minZ + maxZ) / 2
        extent = (maxX + 3.0, midZ + 0.8, (maxZ - minZ) + 6.0)
        let w = (maxX + 4.5) * 2, d = (maxZ - minZ) + 9.0
        let platform = JamStyle.box(w, 0.2, d, JamStyle.material(NSColor(white: 0.075, alpha: 1), shine: 0.6), 0, -0.1, midZ + 0.6, chamfer: 0.08)
        world.addChildNode(platform)
        let edge = SCNMaterial(); edge.lightingModel = .constant; edge.diffuse.contents = NSColor(white: 0.2, alpha: 1)
        world.addChildNode(JamStyle.box(w + 0.1, 0.03, 0.05, edge, 0, 0.005, midZ + 0.6 + d / 2, chamfer: 0))
        frameCamera(aspect: lastAspect)
    }

    private static func label(_ text: String, tint: NSColor, at p: SCNVector3) -> SCNNode {
        let t = SCNText(string: text, extrusionDepth: 0.03)
        t.font = NSFont.systemFont(ofSize: 0.42, weight: .semibold)
        t.flatness = 0.15
        let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = NSColor(white: 0.92, alpha: 1)
        t.materials = [m]
        let n = SCNNode(geometry: t)
        let (mn, mx) = t.boundingBox
        n.pivot = SCNMatrix4MakeTranslation((mn.x + mx.x) / 2, mn.y, 0)
        let holder = SCNNode()
        holder.position = p
        holder.addChildNode(n)
        let b = SCNBillboardConstraint(); b.freeAxes = .Y
        holder.constraints = [b]
        return holder
    }

    private var lastAspect = 1.6
    /// Puts the camera where the whole stage fits, a little above and in front.
    func frameCamera(aspect: Double) {
        lastAspect = aspect
        let vHalf = 42.0 / 2 * .pi / 180
        let hHalf = atan(tan(vHalf) * aspect)
        let fitW = extent.halfWidth / tan(hHalf)
        let fitH = 2.7 / tan(vHalf)
        let dist = max(fitW, fitH) + extent.depth * 0.5 + 2.5
        let el = 0.5
        let target = V(0, 1.0, extent.centerZ)
        cameraNode.position = V(0, 1.0 + dist * sin(el), extent.centerZ + dist * cos(el))
        cameraNode.look(at: target)
    }

    /// Moves the stage on: instruments animate to what is sounding at `beat`, and the spotlights decide who is lit.
    func update(beat: Double, playing: Bool, secondsPerBeat spb: Double, dt: Double) {
        time += dt
        let recentBeats = 1.0 / spb
        var sounding: [Int] = []
        for s in slots {
            let snd = playing ? timeline.sounding(s.track, at: beat) : []
            let recent = playing ? timeline.started(s.track, from: beat - recentBeats, to: beat) : []
            var upcoming: [VNote] = []
            if s.inst.kind == .piano {                       // the falling notes are the notes about to be played
                upcoming = timeline.started(s.track, from: playing ? beat + 1e-6 : beat, to: beat + 2.6 / spb) + snd
            }
            s.inst.update(JamFrame(beat: beat, spb: spb, time: time, dt: dt, playing: playing, sounding: snd, recent: recent, upcoming: upcoming))
            if !snd.isEmpty || (s.inst.kind == .drums && !recent.isEmpty) { sounding.append(s.track) }
            let active = (!snd.isEmpty || !recent.isEmpty) ? 1.0 : 0.0
            s.glow += (active - s.glow) * min(1, dt * (active > s.glow ? 20 : 4))
            s.pad.emission.contents = JamStyle.lit(s.inst.tint, s.glow * 0.2)
        }
        spotState.update(sounding: sounding, now: time)
        spotTargets = JamSpot.targets(spotState.playing(now: time), drums: drumFlags)
        for s in slots {
            guard let sp = s.spot, let beam = s.beam else { continue }
            let want = spotTargets.contains(s.track) ? 1.0 : 0.0
            s.level += (want - s.level) * min(1, dt * 7)
            if want == 0 && s.level < 0.01 { s.level = 0 }
            sp.isHidden = s.level <= 0
            sp.light?.intensity = CGFloat(Self.spotIntensity * s.level)
            beam.diffuse.contents = NSColor(red: 0.075 * s.level, green: 0.07 * s.level, blue: 0.055 * s.level, alpha: 1)
        }
        let wantDim = spotTargets.isEmpty ? 0.0 : 1.0
        dim += (wantDim - dim) * min(1, dt * 5)
        if wantDim == 0 && dim < 0.005 { dim = 0 }
        ambient.light?.intensity = CGFloat(Self.ambientIntensity * (1 - 0.9 * dim))
        key.light?.intensity = CGFloat(Self.keyIntensity * (1 - 0.93 * dim))
    }
}
#endif
