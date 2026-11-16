import Foundation
import AVFoundation
import AppKit

/// `--slideplugintest`: renders slides through the installed Vital AU and reads the pitch back, for diagnosing plug-in bend ranges.
@MainActor enum SlidePluginTest {
    static func vital() -> PluginSpec {
        func cc(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
        return PluginSpec(format: .au, name: "Vital", vendor: "Vital Audio", isInstrument: true, auType: cc("aumu"), auSubtype: 1449751649, auManufacturer: 1417245797)
    }

    static func run() -> Int32 {
        _ = NSApplication.shared
        let engine = AudioEngine()
        engine.onError = { print("ENGINE ERROR:", $0) }
        var fails = 0
        func power(_ x: [Float], sr: Double, from t0: Double, len: Double, at hz: Double) -> Double {
            let a = Int(t0 * sr), n = min(Int(len * sr), x.count - a)
            guard n > 100 else { return 0 }
            var re = 0.0, im = 0.0
            for i in 0..<n { let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n)); let ph = 2 * Double.pi * hz * Double(i) / sr; re += Double(x[a + i]) * w * cos(ph); im += Double(x[a + i]) * w * sin(ph) }
            return (re * re + im * im) / Double(n * n)
        }
        func hz(_ pitch: Int) -> Double { 440 * pow(2, Double(pitch - 69) / 12) }
        func case_(_ label: String, to target: Int, bend: Int) {
            var q = Project(); q.tempo = 120
            var t = Track(name: "V", colorIndex: 0); t.bendRange = bend
            t.instrument = InstrumentSpec(plugin: vital())
            var c = Clip(name: "c", start: 0, length: 8)
            c.notes = [Note(pitch: 60, start: 0, length: 3), Note(pitch: target, start: 0.5, length: 1, isSlide: true)]
            t.clips = [c]; q.tracks = [t]
            engine.syncTracks(q.tracks)
            SelfTest.pump(20) { engine.strips[t.id]?.instrument != nil && engine.strips[t.id]?.loading == false }
            let o = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macband-vital.wav")
            try? FileManager.default.removeItem(at: o)
            try? engine.bounce(q, to: o) { _ in }
            let a = SelfTest.analyze(o)
            let atTarget = power(a.samples, sr: a.sr, from: 1.2, len: 0.4, at: hz(target)), atStart = power(a.samples, sr: a.sr, from: 1.2, len: 0.4, at: hz(60))
            let ok = atTarget > atStart * 5
            print(ok ? "  ok    " : "  FAIL  ", label, String(format: "(energy at the target %.1f× the energy at the start pitch)", atTarget / max(atStart, 1e-12)))
            if !ok { fails += 1 }
            engine.syncTracks([])
        }
        case_("Vital: a slide up a fifth reaches its note (track range 2)", to: 67, bend: 2)
        case_("Vital: a slide up an octave reaches its note (track range 12)", to: 72, bend: 12)
        case_("Vital: a slide up two octaves reaches its note (track range 2)", to: 84, bend: 2)
        print(fails == 0 ? "ALL PLUG-IN SLIDE CHECKS PASSED" : "\(fails) PLUG-IN SLIDE CHECK(S) FAILED")
        return fails == 0 ? 0 : 1
    }
}
