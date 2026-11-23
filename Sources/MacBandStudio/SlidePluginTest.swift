import Foundation
import AVFoundation
import AppKit
#if canImport(CVST3Host)
import CVST3Host
#endif

/// `--slideplugintest`: renders slides through Vital (AU and VST3) and the SF2 Player VST3 a project uses, and reads the pitch back.
@MainActor enum SlidePluginTest {
    static func vital() -> PluginSpec {
        func cc(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
        return PluginSpec(format: .au, name: "Vital", vendor: "Vital Audio", isInstrument: true, auType: cc("aumu"), auSubtype: 1449751649, auManufacturer: 1417245797)
    }

    static func sf2Spec() -> PluginSpec? {
        let dir = (FileManager.default.homeDirectoryForCurrentUser).appendingPathComponent("Music/MacBand")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        for f in files.filter({ $0.pathExtension == "macband" }).sorted(by: { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }) {
            guard let data = try? Data(contentsOf: f), let p = try? JSONDecoder().decode(Project.self, from: data) else { continue }
            for t in p.tracks { if let pl = t.instrument.plugin, pl.format == .vst3, pl.name == "SF2 Player" { return pl } }
        }
        return nil
    }

    static func run() -> Int32 {
        _ = NSApplication.shared
        let engine = AudioEngine()
        engine.onError = { print("ENGINE ERROR:", $0) }
        var fails = 0
        /// The strongest frequency (Hz) in a stretch of the render: a coarse scan, then a fine one around the best.
        func peak(_ x: [Float], sr: Double, from t0: Double, len: Double) -> Double {
            let a = Int(t0 * sr), n = min(Int(len * sr), x.count - a)
            guard n > 1000 else { return 0 }
            func power(_ hz: Double) -> Double {
                var re = 0.0, im = 0.0
                let w = 2 * Double.pi * hz / sr
                for i in 0..<n { let win = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n)); let v = Double(x[a + i]) * win; re += v * cos(w * Double(i)); im += v * sin(w * Double(i)) }
                return re * re + im * im
            }
            var best = (hz: 0.0, p: -1.0)
            var f = 100.0
            while f <= 2200 { let p = power(f); if p > best.p { best = (f, p) }; f += 3 }
            var g = best.hz - 3
            var fine = best
            while g <= best.hz + 3 { let p = power(g); if p > fine.p { fine = (g, p) }; g += 0.5 }
            return fine.hz
        }
        func case_(_ label: String, to target: Int, bend: Int, spec: PluginSpec? = nil) {
            var q = Project(); q.tempo = 120
            var t = Track(name: "V", colorIndex: 0); t.bendRange = bend
            t.instrument = InstrumentSpec(plugin: spec ?? vital())
            var c = Clip(name: "c", start: 0, length: 8)
            c.notes = [Note(pitch: 60, start: 0, length: 3), Note(pitch: target, start: 0.5, length: 1, isSlide: true)]
            t.clips = [c]; q.tracks = [t]
            engine.syncTracks(q.tracks)
            SelfTest.pump(20) { engine.strips[t.id]?.instrument != nil && engine.strips[t.id]?.loading == false }
            let o = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macband-vital.wav")
            try? FileManager.default.removeItem(at: o)
            try? engine.bounce(q, to: o) { _ in }
            if let keep = ProcessInfo.processInfo.environment["SLIDE_KEEP"] { try? FileManager.default.removeItem(atPath: keep + "-\(target).wav"); try? FileManager.default.copyItem(at: o, to: URL(fileURLWithPath: keep + "-\(target).wav")) }
            let a = SelfTest.analyze(o)
            let f0 = peak(a.samples, sr: a.sr, from: 0.1, len: 0.25), f1 = peak(a.samples, sr: a.sr, from: 1.25, len: 0.25)
            let semis = f0 > 0 && f1 > 0 ? 12 * log2(f1 / f0) : -99
            let want = Double(target - 60)
            let ok = abs(semis - want) < 0.7
            print(ok ? "  ok    " : "  FAIL  ", label, String(format: "(pitch went from %.0f to %.0f Hz = %+.2f semitones; wanted %+.0f)", f0, f1, semis, want))
            if !ok { fails += 1 }
            engine.syncTracks([])
        }
        case_("Vital: a slide up a fifth reaches its note (track range 2)", to: 67, bend: 2)
        case_("Vital: a slide up an octave reaches its note (track range 12)", to: 72, bend: 12)
        case_("Vital: a slide up two octaves reaches its note (track range 2)", to: 84, bend: 2)
        // The SF2 Player VST3 a project uses (taken from the newest project that has one, with its saved state), when it is installed
        if let sf2 = sf2Spec() {
            case_("SF2 Player (VST3): a slide up a fifth reaches its note (track range 2)", to: 67, bend: 2, spec: sf2)
            case_("SF2 Player (VST3): a slide up an octave reaches its note (track range 12)", to: 72, bend: 12, spec: sf2)
        } else { print("(no SF2 Player VST3 found: skipped)") }
        // Vital as a VST3 (some projects use it that way)
        #if canImport(CVST3Host)
        let vitalPath = "/Library/Audio/Plug-Ins/VST3/Vital.vst3"
        if FileManager.default.fileExists(atPath: vitalPath), let cls = MBVST3AudioUnit.scanBundle(atPath: vitalPath).first(where: { ($0["instrument"] as? Bool) == true }), let cid = cls["classID"] as? String {
            var spec = PluginSpec(format: .vst3, name: "Vital", vendor: "Vital Audio", isInstrument: true)
            spec.vst3Path = vitalPath; spec.vst3ClassID = cid
            case_("Vital (VST3): a slide up a fifth reaches its note (track range 2)", to: 67, bend: 2, spec: spec)
            case_("Vital (VST3): a slide up two octaves reaches its note (track range 2)", to: 84, bend: 2, spec: spec)
        }
        #endif
        // A plug-in with no bend-range control to set: the user is told what to do instead of the slide silently stopping short
        do {
            func cc(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
            let synth = PluginSpec(format: .au, name: "AUMIDISynth", vendor: "Apple", isInstrument: true, auType: cc("aumu"), auSubtype: cc("msyn"), auManufacturer: cc("appl"))
            var t = Track(name: "M", colorIndex: 0); t.instrument = InstrumentSpec(plugin: synth); t.bendRange = 2
            var c = Clip(name: "c", start: 0, length: 4); c.notes = [Note(pitch: 60, start: 0, length: 3), Note(pitch: 67, start: 0.5, length: 1, isSlide: true)]
            t.clips = [c]
            var q = Project(); q.tracks = [t]
            var notices: [String] = []
            engine.onNotice = { notices.append($0) }
            engine.syncTracks(q.tracks)
            SelfTest.pump(25) { engine.strips[t.id]?.instrument != nil && engine.strips[t.id]?.loading == false }
            engine.reloadSequence(q, metronome: false)
            SelfTest.pump(0.3)
            let ok = notices.count == 1 && notices[0].contains("AUMIDISynth") && notices[0].contains("7")
            print(ok ? "  ok    " : "  FAIL  ", "a plug-in with no bend-range setting gets a message saying what to set (\(notices.first ?? "no message"))")
            if !ok { fails += 1 }
            engine.reloadSequence(q, metronome: false)
            SelfTest.pump(0.2)
            print(notices.count == 1 ? "  ok    " : "  FAIL  ", "…and only once")
            if notices.count != 1 { fails += 1 }
            engine.syncTracks([])
        }
        print(fails == 0 ? "ALL PLUG-IN SLIDE CHECKS PASSED" : "\(fails) PLUG-IN SLIDE CHECK(S) FAILED")
        return fails == 0 ? 0 : 1
    }
}
