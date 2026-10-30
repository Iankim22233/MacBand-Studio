import SwiftUI
import UIKit

/// A piano keyboard for playing the selected instrument with your fingers (several keys at once, and sliding from key to key).
/// While recording, what you play is recorded, exactly as with a MIDI keyboard.
final class PianoKeysView: UIView {
    var firstPitch = 48 { didSet { setNeedsDisplay() } }              // C of the lowest octave shown
    var whiteKeys = 15
    var onDown: ((Int, Int) -> Void)?
    var onUp: ((Int) -> Void)?
    private var held: [UITouch: Int] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }

    private static let whiteOffsets = [0, 2, 4, 5, 7, 9, 11]
    private static let blackAfter: [Int: Int] = [0: 1, 1: 3, 3: 6, 4: 8, 5: 10]       // white index in the octave → semitone of the black key after it

    private var keyW: CGFloat { bounds.width / CGFloat(whiteKeys) }

    private func pitch(forWhite i: Int) -> Int { firstPitch + (i / 7) * 12 + Self.whiteOffsets[i % 7] }

    /// The pitch under a point: black keys (the top part) first, then the white key below.
    private func pitchAt(_ p: CGPoint) -> (pitch: Int, velocity: Int)? {
        guard bounds.contains(p) else { return nil }
        let w = keyW, blackH = bounds.height * 0.6
        let vel = Int(60 + 60 * min(1, max(0, p.y / bounds.height)))
        if p.y < blackH {
            for i in 0..<whiteKeys {
                guard let semi = Self.blackAfter[i % 7] else { continue }
                let cx = CGFloat(i + 1) * w
                if abs(p.x - cx) < w * 0.3 { return (firstPitch + (i / 7) * 12 + semi, vel) }
            }
        }
        let i = min(whiteKeys - 1, max(0, Int(p.x / w)))
        return (pitch(forWhite: i), vel)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let w = keyW, blackH = bounds.height * 0.6
        let pressed = Set(held.values)
        for i in 0..<whiteKeys {
            let r = CGRect(x: CGFloat(i) * w, y: 0, width: w, height: bounds.height)
            ctx.setFillColor((pressed.contains(pitch(forWhite: i)) ? Theme.ns.accent.mixed(.white, 0.35) : UIColor(white: 0.93, alpha: 1)).cgColor)
            ctx.fill(r.insetBy(dx: 0.5, dy: 0))
            if i % 7 == 0 {
                ("C\(pitch(forWhite: i) / 12 - 1)" as NSString).draw(at: CGPoint(x: r.minX + 4, y: bounds.height - 18),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: UIColor(white: 0.35, alpha: 1)])
            }
        }
        for i in 0..<whiteKeys {
            guard let semi = Self.blackAfter[i % 7], i + 1 < whiteKeys else { continue }
            let p = firstPitch + (i / 7) * 12 + semi
            let r = CGRect(x: CGFloat(i + 1) * w - w * 0.3, y: 0, width: w * 0.6, height: blackH)
            ctx.setFillColor((pressed.contains(p) ? Theme.ns.accent : UIColor(white: 0.1, alpha: 1)).cgColor)
            ctx.fill(r)
        }
    }

    private func press(_ t: UITouch) {
        guard let hit = pitchAt(t.location(in: self)) else { return }
        if held[t] == hit.pitch { return }
        if let old = held[t] { onUp?(old) }
        held[t] = hit.pitch
        onDown?(hit.pitch, hit.velocity)
        setNeedsDisplay()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { touches.forEach(press) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { touches.forEach(press) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }
    private func release(_ touches: Set<UITouch>) {
        for t in touches { if let p = held.removeValue(forKey: t) { onUp?(p) } }
        setNeedsDisplay()
    }
}

struct PianoKeys: UIViewRepresentable {
    @EnvironmentObject var session: Session
    let firstPitch: Int
    func makeUIView(context: Context) -> PianoKeysView {
        let v = PianoKeysView()
        v.firstPitch = firstPitch
        v.onDown = { [weak session] p, vel in session?.liveNoteOn(p, vel) }
        v.onUp = { [weak session] p in session?.liveNoteOff(p) }
        return v
    }
    func updateUIView(_ v: PianoKeysView, context: Context) { v.firstPitch = firstPitch }
}

/// The keyboard drawer above the page tabs: octave buttons and the keys.
struct IOSKeyboardDrawer: View {
    @EnvironmentObject var session: Session
    @State private var octave = 3                                    // C3 is MIDI 48

    var body: some View {
        HStack(spacing: 6) {
            VStack(spacing: 6) {
                IconButton(symbol: "chevron.up", size: 34) { octave = min(6, octave + 1) }
                Text("C\(octave)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.dim)
                IconButton(symbol: "chevron.down", size: 34) { octave = max(0, octave - 1) }
            }
            PianoKeys(firstPitch: (octave + 1) * 12)
        }
        .padding(6).frame(height: 128).background(Theme.panel)
    }
}
