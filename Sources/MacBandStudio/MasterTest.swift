import Foundation
import AppKit
import AVFoundation

/// `--mastertest`: effects on the Master track change what you hear, can be bypassed and removed, and are saved with the project.
@MainActor
enum MasterTest {
    static var failures = 0
    static func check(_ ok: Bool, _ m: String) { print(ok ? "  ok    \(m)" : "  FAIL  \(m)"); if !ok { failures += 1 } }

    static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    /// Apple's own delay: a clear echo one second after a sound.
    static func delay() -> PluginSpec {
        PluginSpec(format: .au, name: "AUDelay", vendor: "Apple", isInstrument: false, auType: fourCC("aufx"), auSubtype: fourCC("dely"), auManufacturer: fourCC("appl"))
    }

    static func rms(_ x: [Float], sr: Double, from a: Double, to b: Double) -> Double {
        let i0 = max(0, Int(a * sr)), i1 = min(x.count, Int(b * sr))
        guard i1 > i0 else { return 0 }
        return sqrt(x[i0..<i1].reduce(0.0) { $0 + Double($1 * $1) } / Double(i1 - i0))
    }

    static func run() -> Int32 {
        _ = NSApplication.shared
        print("== Master track test ==")
        func pump(_ sec: Double, until: () -> Bool = { false }) { SelfTest.pump(sec, until: until) }

        // one snare hit at the start of a song, then silence
        let engine = AudioEngine()
        engine.onError = { print("ENGINE ERROR:", $0) }
        var p = Project(); p.tempo = 120
        var t = Track(name: "Drums", colorIndex: 0)
        t.instrument = InstrumentSpec(gmProgram: 0, isDrums: true)
        var c = Clip(name: "hit", start: 0, length: 4)
        c.notes = [Note(pitch: 38, start: 0, length: 0.25, velocity: 120)]
        t.clips = [c]
        p.tracks = [t]
        engine.syncTracks(p.tracks, master: [])
        pump(30) { engine.strips[t.id]?.instrument != nil && engine.strips[t.id]?.loading == false }
        pump(0.5)

        func render() -> (samples: [Float], sr: Double) {
            let wav = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macband-master-\(UUID().uuidString.prefix(6)).wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            try? engine.bounce(p, to: wav, testSeconds: 3) { _ in }
            let r = SelfTest.analyze(wav)
            return (r.samples, r.sr)
        }
        let plain = render()
        let hit = rms(plain.samples, sr: plain.sr, from: 0, to: 0.3), tailPlain = rms(plain.samples, sr: plain.sr, from: 0.8, to: 1.6)
        check(hit > 0.01 && tailPlain < hit * 0.1, String(format: "without effects the snare is heard, then silence (%.4f, then %.5f)", hit, tailPlain))

        // a delay on the master: an echo a second later
        var fx = delay()
        engine.syncMaster([fx])
        pump(30) { !engine.masterLoading && engine.masterUnits.count == 1 }
        check(engine.masterEffects.count == 1, "the effect is loaded on the master")
        let echo = render()
        let tailEcho = rms(echo.samples, sr: echo.sr, from: 0.8, to: 1.6)
        check(tailEcho > max(0.004, tailPlain * 20), String(format: "the effect changes what you hear: an echo appears a second later (%.4f vs %.5f)", tailEcho, tailPlain))
        check(rms(echo.samples, sr: echo.sr, from: 0, to: 0.3) > 0.01, "…and the sound itself still plays")

        // bypass
        fx.bypassed = true
        engine.syncMaster([fx])
        let bypassed = render()
        check(rms(bypassed.samples, sr: bypassed.sr, from: 0.8, to: 1.6) < tailEcho * 0.2, "bypassing the effect takes the echo away")
        fx.bypassed = false
        engine.syncMaster([fx])
        check(rms(render().samples, sr: 44100, from: 0.8, to: 1.6) > tailPlain * 20, "…and switching it on again brings it back")

        // removal puts the mix straight back
        engine.syncMaster([])
        pump(10) { engine.masterEffects.isEmpty && !engine.masterLoading }
        let removed = render()
        check(engine.masterEffects.isEmpty && rms(removed.samples, sr: removed.sr, from: 0.8, to: 1.6) < tailEcho * 0.2, "removing the effect puts the mix back as it was")
        check(rms(removed.samples, sr: removed.sr, from: 0, to: 0.3) > 0.01, "…with the sound still playing")
        // two effects in a row
        engine.syncMaster([delay(), delay()])
        pump(30) { !engine.masterLoading && engine.masterEffects.count == 2 }
        check(engine.masterEffects.count == 2 && rms(render().samples, sr: 44100, from: 0.8, to: 1.6) > tailPlain * 20, "several effects can sit one after another")
        engine.syncMaster([])
        pump(10) { engine.masterEffects.isEmpty && !engine.masterLoading }

        // live playback: the instruments must keep their own sound when effects come and go (a sampler that is re-initialised
        // falls back to a plain sine tone). Offline renders reload the samplers, so this is checked on the live output.
        var lastWide = 0, lastStrongest = 0.0
        func liveSpread(_ label: String) -> Int {
            let an = SpectrumAnalyzer()
            engine.noteOn(trackID: piano.id, pitch: 60, velocity: 110)
            var most = 0
            for _ in 0..<25 { pump(0.03); an.update(from: engine.sampleRing, dt: 0.03); most = max(most, an.bands.filter { $0 > 0.25 }.count) }
            engine.noteOff(trackID: piano.id, pitch: 60)
            pump(1.5)
            lastWide = an.bands.filter { $0 > 0.1 }.count; lastStrongest = Double(an.bands.max() ?? 0)
            print("   \(label): \(most) frequency bands lit by one note; bands above 0.1: \(lastWide), strongest \(String(format: "%.2f", lastStrongest))")
            return most
        }
        var piano = Track(name: "Piano", colorIndex: 1)
        piano.instrument = InstrumentSpec(gmProgram: 0)
        var p2 = Project(); p2.tracks = [piano]
        engine.syncTracks(p2.tracks, master: [])
        pump(30) { engine.strips[piano.id]?.instrument != nil && engine.strips[piano.id]?.loading == false }
        pump(0.5)
        let before = liveSpread("before any master effect")
        let beforeWide = lastWide, beforeStrongest = lastStrongest
        engine.syncMaster([delay()])
        pump(30) { !engine.masterLoading && engine.masterEffects.count == 1 }
        pump(10) { engine.samplersReloading == 0 }
        pump(0.5)
        let withFx = liveSpread("with a master effect")
        engine.syncMaster([])
        pump(10) { engine.masterEffects.isEmpty && !engine.masterLoading }
        pump(10) { engine.samplersReloading == 0 }
        pump(0.5)
        let after = liveSpread("after removing it")
        let afterWide = lastWide, afterStrongest = lastStrongest
        check(before >= 4, "a piano note lights several frequency bands, not just one (\(before)): it is not a sine tone")
        check(abs(afterStrongest - beforeStrongest) < 0.2 && afterWide >= beforeWide - 4, String(format: "after the effect is removed the piano still sounds like a piano, not a sine (strongest band %.2f then %.2f, wide bands %d then %d)", beforeStrongest, afterStrongest, beforeWide, afterWide))
        _ = (withFx, after)

        // adding another instrument (the graph changes shape again) must not turn the others into sine tones either
        var bass = Track(name: "Strings", colorIndex: 2)
        bass.instrument = InstrumentSpec(gmProgram: 48)
        p2.tracks.append(bass)
        engine.syncTracks(p2.tracks, master: [])
        pump(30) { engine.strips[bass.id]?.instrument != nil && engine.strips[bass.id]?.loading == false }
        pump(0.5)
        _ = liveSpread("after adding another track")
        check(abs(lastStrongest - beforeStrongest) < 0.2 && lastWide >= beforeWide - 4, String(format: "…and after adding another track (strongest band %.2f, wide bands %d)", lastStrongest, lastWide))

        // the project keeps them
        let s = Session()
        pump(1)
        s.addMasterInsert(delay())
        check(s.project.masterInserts.count == 1 && s.project.masterInserts[0].name == "AUDelay", "adding an effect puts it on the project's master")
        pump(30) { s.engine.masterUnit(s.project.masterInserts[0].id) != nil }
        check(s.engine.masterUnit(s.project.masterInserts[0].id) != nil, "…and it is loaded live")
        s.toggleMasterBypass(specID: s.project.masterInserts[0].id)
        check(s.project.masterInserts[0].bypassed && s.engine.masterUnit(s.project.masterInserts[0].id)?.auAudioUnit.shouldBypassEffect == true, "bypass switches the live effect")
        s.toggleMasterBypass(specID: s.project.masterInserts[0].id)
        let id = s.project.masterInserts[0].id
        let data = (try? s.encodeProject()) ?? Data()
        let back = try? JSONDecoder().decode(Project.self, from: data)
        check(back?.masterInserts.map { $0.id } == [id] && back?.masterInserts.first?.state != nil, "saved with the project, with the effect's own settings")
        s.undo(); s.undo(); s.undo()                      // the two bypass switches, then the adding
        check(s.project.masterInserts.isEmpty, "undo takes it off again")
        pump(10) { s.engine.masterEffects.isEmpty && !s.engine.masterLoading }
        check(s.engine.masterEffects.isEmpty, "…and out of the sound")
        let old = try? JSONDecoder().decode(Project.self, from: Data(#"{"name":"Old","tempo":100,"tracks":[]}"#.utf8))
        check(old?.masterInserts.isEmpty == true, "projects saved before the Master track existed still open")

        // selection
        s.selectedTrackID = s.project.tracks.first?.id
        s.selectMaster()
        check(s.masterSelected, "the Master track can be selected")
        s.selectedTrackID = s.project.tracks.first?.id
        check(!s.masterSelected, "picking a track leaves it")

        print(failures == 0 ? "ALL MASTER TRACK CHECKS PASSED" : "\(failures) MASTER TRACK CHECK(S) FAILED")
        return failures == 0 ? 0 : 1
    }
}
