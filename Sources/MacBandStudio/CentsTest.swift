import Foundation
import AppKit
import AVFoundation

/// `--centstest`: the fine tuning (cents) of each instrument and of the whole mix, checked on the pitch that comes out.
@MainActor
enum CentsTest {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { failures += 1 } }

    /// The strongest frequency between `lo` and `hi` Hz in a stretch of the render.
    static func peakHz(_ x: [Float], sr: Double, from t0: Double, len: Double, lo: Double, hi: Double) -> Double {
        let a = Int(t0 * sr), n = min(Int(len * sr), x.count - a)
        guard n > 1000 else { return 0 }
        var best = (hz: 0.0, power: -1.0)
        var f = lo
        while f <= hi {
            var re = 0.0, im = 0.0
            let w = 2 * Double.pi * f / sr
            for i in 0..<n {
                let win = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n))
                let v = Double(x[a + i]) * win
                re += v * cos(w * Double(i)); im += v * sin(w * Double(i))
            }
            let p = re * re + im * im
            if p > best.power { best = (f, p) }
            f += 0.1
        }
        return best.hz
    }
    static func cents(_ f: Double, relativeTo base: Double) -> Double { 1200 * log2(f / base) }

    static func project(_ spec: InstrumentSpec, tune: Double = 0, master: Double = 0) -> Project {
        var p = Project(); p.tempo = 120; p.masterCents = master
        var t = Track(name: "T", colorIndex: 0); t.instrument = spec; t.tuneCents = tune
        var c = Clip(name: "c", start: 0, length: 8); c.notes = [Note(pitch: 69, start: 0, length: 4)]   // A4 = 440 Hz
        t.clips = [c]; p.tracks = [t]
        return p
    }

    static func run() -> Int32 {
        _ = NSApplication.shared
        print("== Cents (fine tuning) test ==")

        // saving
        var p0 = project(InstrumentSpec(gmProgram: 19), tune: -17, master: 12)
        let enc = try! JSONEncoder().encode(p0)
        let back = try! JSONDecoder().decode(Project.self, from: enc)
        check(back.tracks[0].tuneCents == -17 && back.masterCents == 12, "the tuning of a track and of the mix is kept when the project is saved and opened")
        var legacy = (try! JSONSerialization.jsonObject(with: enc)) as! [String: Any]
        legacy.removeValue(forKey: "masterCents")
        var lt = legacy["tracks"] as! [[String: Any]]; lt[0].removeValue(forKey: "tuneCents"); legacy["tracks"] = lt
        let old = try? JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(old?.masterCents == 0 && old?.tracks[0].tuneCents == 0, "projects saved before it existed open untuned")

        // plug-ins: a bend ahead of every note
        var pt = Track(name: "Synth", colorIndex: 0); pt.instrument = InstrumentSpec(plugin: SlidePluginTest.vital()); pt.tuneCents = 40; pt.bendRange = 2
        var pc = Clip(name: "c", start: 0, length: 8)
        pc.notes = [Note(pitch: 60, start: 0, length: 1), Note(pitch: 64, start: 0, length: 1), Note(pitch: 62, start: 2, length: 1)]
        pt.clips = [pc]
        let evs = MIDIFile.trackEvents(pt, channel: 0, forExport: false)
        let bends = evs.filter { $0.bytes.first == 0xE0 }.sorted { $0.tick < $1.tick }
        let want = MIDIFile.bendValue(0.40, range: 2)
        func value(_ e: MIDIFile.Ev) -> Int { Int(e.bytes[2]) << 7 | Int(e.bytes[1]) }
        check(bends.count == 2 && bends.allSatisfy { value($0) == want } && bends.map { $0.tick } == [0, MIDIFile.ticks(2)], "a plug-in track sends its detune as a pitch bend before each place notes start (chords once): \(bends.count) bends, value \(bends.first.map { value($0) } ?? 0) vs \(want)")
        check(abs(Double(want - 8192) / 8192 * 2 * 100 - 40) < 0.5, "and that bend is 40 cents of the plug-in's 2-semitone range")
        pt.tuneCents = 0
        check(!MIDIFile.trackEvents(pt, channel: 0, forExport: false).contains { $0.bytes.first == 0xE0 }, "no bends at all at 0 cents")
        var st = pt; st.instrument = InstrumentSpec(gmProgram: 19); st.tuneCents = 40
        check(!MIDIFile.trackEvents(st, channel: 0, forExport: false).contains { $0.bytes.first == 0xE0 }, "the built-in sampler tunes itself instead: no bends")
        var wide = pt; wide.tuneCents = 100
        wide.bendRange = 1
        check(MIDIFile.effectiveBendRange(wide) == 1 && { var w = wide; w.tuneCents = -100; return MIDIFile.effectiveBendRange(w) == 1 }(), "100 cents fits a 1-semitone range")
        var sl = pt; sl.tuneCents = 30
        sl.clips[0].notes = [Note(pitch: 60, start: 0, length: 3), Note(pitch: 62, start: 1, length: 1, isSlide: true)]
        let slevs = MIDIFile.trackEvents(sl, channel: 0, forExport: false).filter { $0.bytes.first == 0xE0 }.sorted { $0.tick < $1.tick }
        let last = slevs.last!, atEnd = slevs.last { $0.tick <= MIDIFile.ticks(2) }!
        func semis(_ e: MIDIFile.Ev, _ r: Int) -> Double { Double(value(e) - 8192) / 8192 * Double(r) }
        let r2 = MIDIFile.effectiveBendRange(sl)
        check(abs(semis(atEnd, r2) - 2.30) < 0.03 && abs(semis(last, r2) - 0.30) < 0.03, "slides ride on top of the detune (end of the slide at +2.30 semitones, back to +0.30 afterwards)")

        // the sound
        let engine = AudioEngine()
        engine.onError = { print("ENGINE ERROR:", $0) }
        func render(_ p: Project) -> (x: [Float], sr: Double)? {
            engine.syncTracks(p.tracks)
            SelfTest.pump(25) { p.tracks.allSatisfy { engine.strips[$0.id]?.instrument != nil && engine.strips[$0.id]?.loading == false } }
            let o = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macband-cents.wav")
            try? FileManager.default.removeItem(at: o)
            engine.applyMix(p, beat: nil)
            do { try engine.bounce(p, to: o) { _ in } } catch { print("bounce failed:", error); return nil }
            let a = SelfTest.analyze(o)
            engine.syncTracks([])
            return (a.samples, a.sr)
        }
        let organ = InstrumentSpec(gmProgram: 19)
        guard let flat = render(project(organ)) else { return 1 }
        let f0 = peakHz(flat.x, sr: flat.sr, from: 0.5, len: 1, lo: 400, hi: 480)
        check(abs(cents(f0, relativeTo: 440)) < 8, "untuned, A4 comes out at \(String(format: "%.1f", f0)) Hz")
        for c in [50.0, -32, 100] {
            if let r = render(project(organ, tune: c)) {
                let f = peakHz(r.x, sr: r.sr, from: 0.5, len: 1, lo: 400, hi: 480)
                check(abs(cents(f, relativeTo: f0) - c) < 5, "an instrument tuned \(Int(c)) cents sounds \(String(format: "%+.1f", cents(f, relativeTo: f0))) cents from the untuned one (\(String(format: "%.1f", f)) Hz)")
            }
        }
        for c in [-32.0, 40] {
            if let r = render(project(organ, master: c)) {
                let f = peakHz(r.x, sr: r.sr, from: 0.5, len: 1, lo: 400, hi: 480)
                check(abs(cents(f, relativeTo: f0) - c) < 5, "the whole mix tuned \(Int(c)) cents sounds \(String(format: "%+.1f", cents(f, relativeTo: f0))) cents from untuned (\(String(format: "%.1f", f)) Hz)")
            }
        }
        if let both = render(project(organ, tune: 30, master: -20)) {
            let f = peakHz(both.x, sr: both.sr, from: 0.5, len: 1, lo: 400, hi: 480)
            check(abs(cents(f, relativeTo: f0) - 10) < 5, "instrument +30 and mix −20 add up to +10 (\(String(format: "%+.1f", cents(f, relativeTo: f0))))")
        }
        // at 0 the master tune doesn't touch the sound
        if let again = render(project(organ, master: 0)) {
            let n = min(again.x.count, flat.x.count)
            var diff = 0.0, ref = 0.0
            for i in 0..<n { let d = Double(again.x[i] - flat.x[i]); diff += d * d; ref += Double(flat.x[i] * flat.x[i]) }
            check(ref > 0 && diff / ref < 1e-4, "with the master tune at 0 the sound is identical (difference \(String(format: "%.2e", diff / max(ref, 1e-12))) of the signal's energy)")
        }

        // a plug-in
        if FileManager.default.fileExists(atPath: "/Library/Audio/Plug-Ins/Components/Vital.component") {
            let vital = InstrumentSpec(plugin: SlidePluginTest.vital())
            if let v0 = render(project(vital)), let v1 = render(project(vital, tune: 50)), let v2 = render(project(vital, tune: -30)) {
                let a = peakHz(v0.x, sr: v0.sr, from: 0.5, len: 1, lo: 400, hi: 480), b = peakHz(v1.x, sr: v1.sr, from: 0.5, len: 1, lo: 400, hi: 480), c = peakHz(v2.x, sr: v2.sr, from: 0.5, len: 1, lo: 400, hi: 480)
                check(abs(cents(b, relativeTo: a) - 50) < 5 && abs(cents(c, relativeTo: a) + 30) < 5, "Vital tuned +50 and −30 cents: \(String(format: "%+.1f", cents(b, relativeTo: a))) and \(String(format: "%+.1f", cents(c, relativeTo: a))) cents from untuned")
            }
        } else { print("(Vital isn't installed: the plug-in check was skipped)") }
        _ = p0; p0.masterCents = 0

        print(failures == 0 ? "ALL CENTS CHECKS PASSED" : "\(failures) CENTS CHECK(S) FAILED")
        return failures == 0 ? 0 : 1
    }
}
