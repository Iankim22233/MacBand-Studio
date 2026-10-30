import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import AVFoundation

/// `--instchange file.mid`: imports a file, then changes each track's instrument and checks that its sound really changes,
/// both in a render and in what live playback is connected to.
@MainActor
enum InstrumentChangeTest {
    /// `--tempochange file.mid`: changes the tempo and checks the sequencer's own clock follows it, stopped and while playing.
    static func tempoRun(_ path: String) {
        _ = NSApplication.shared
        let s = Session()
        func pump(_ sec: Double, until: () -> Bool = { false }) { let e = Date().addingTimeInterval(sec); while Date() < e && !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } }
        pump(1)
        if path.hasSuffix(".macband") { s.openProject(url: URL(fileURLWithPath: path)) } else { s.importMIDI(url: URL(fileURLWithPath: path), tempo: .useFile) }
        pump(0.5)
        let n = s.project.tracks.count
        pump(40) { s.engine.strips.values.allSatisfy { !$0.loading && $0.instrument != nil } && s.engine.strips.count == n }
        print("project: \(n) tracks, tempo \(s.project.tempo), tempo points \(s.project.tempoPoints.count), loop \(s.project.loopEnabled)")
        func secs() -> Double { s.engine.sequencer.seconds(forBeats: 100) }
        s.flushSequence()
        print(String(format: "project tempo %g: 100 beats take %.2f s (expect %.2f)", s.project.tempo, secs(), 6000 / s.project.tempo))
        s.setTempo(200); pump(1)
        print(String(format: "after setTempo(200), stopped: project %g, 100 beats take %.2f s (expect 30.00)", s.project.tempo, secs()))
        s.setTempo(90); pump(1)
        print(String(format: "after setTempo(90), stopped: 100 beats take %.2f s (expect 66.67)", secs()))
        s.setTempo(200); pump(0.5)
        s.play(); pump(1.5)
        let b1 = s.engine.position; pump(2); let b2 = s.engine.position
        print(String(format: "playing at 200: %.2f beats in 2 s = %.0f BPM (expect ~200); sequencer says 100 beats = %.2f s", b2 - b1, (b2 - b1) * 30, secs()))
        s.setTempo(120); pump(1.5)
        let c1 = s.engine.position; pump(2); let c2 = s.engine.position
        print(String(format: "changed to 120 while playing: %.2f beats in 2 s = %.0f BPM (expect ~120); 100 beats = %.2f s", c2 - c1, (c2 - c1) * 30, secs()))
        s.stop(); pump(0.5)

        // your flow: play at the file's tempo, stop, type a new tempo, play again, and watch the speed second by second
        s.setTempo(162); pump(0.5); s.rewind(); pump(0.3)
        s.play(); pump(2); s.stop(); pump(0.5)
        s.setTempo(200); pump(0.5); s.rewind(); pump(0.3)
        s.play()
        var last = s.engine.position, speeds: [String] = []
        for _ in 0..<12 { pump(1); let b = s.engine.position; speeds.append(String(format: "%.0f", (b - last) * 60)); last = b }
        print("second by second after play at 200 (BPM):", speeds.joined(separator: " "))
        s.stop()
    }

    /// `--livetempo file`: plays for real at 200 BPM, records the drum track's actual output, and checks which tempo the hits line up with over time.
    static func liveTempo(_ path: String) {
        _ = NSApplication.shared
        let s = Session()
        func pump(_ sec: Double, until: () -> Bool = { false }) { let e = Date().addingTimeInterval(sec); while Date() < e && !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } }
        pump(1)
        if path.hasSuffix(".macband") { s.openProject(url: URL(fileURLWithPath: path)) } else { s.importMIDI(url: URL(fileURLWithPath: path), tempo: .useFile) }
        let n = s.project.tracks.count
        pump(40) { s.engine.strips.values.allSatisfy { !$0.loading && $0.instrument != nil } && s.engine.strips.count == n }
        guard let drum = s.project.tracks.first(where: { $0.instrument.isDrums && !$0.clips.isEmpty }), let strip = s.engine.strips[drum.id] else { print("no drum track"); return }
        let whilePlaying = CommandLine.arguments.contains("--while-playing")
        if !whilePlaying { s.setTempo(200); pump(0.5) }
        final class Box: @unchecked Sendable { let lock = NSLock(); var data: [Float] = []; var rate = 44100.0 }
        let box = Box()
        strip.instrument!.installTap(onBus: 0, bufferSize: 1024, format: nil) { buf, _ in
            guard let ch = buf.floatChannelData else { return }
            let m = Int(buf.frameLength)
            box.lock.lock(); box.rate = buf.format.sampleRate
            for i in 0..<m { box.data.append(abs(ch[0][i])) }
            box.lock.unlock()
        }
        s.rewind(); pump(0.3)
        s.play()
        if whilePlaying { pump(3); s.setTempo(200); print("typed 200 while playing, at beat \(String(format: "%.1f", s.engine.position))"); pump(12.5) } else { pump(15) }
        s.stop()
        strip.instrument!.removeTap(onBus: 0)
        box.lock.lock(); let env = box.data; let rate = box.rate; box.lock.unlock()
        // onset strength per 2 ms
        let blk = Int(rate * 0.002)
        var e: [Double] = []
        var i = 0
        while i + blk <= env.count { var m: Float = 0; for k in i..<(i + blk) { m = max(m, env[k]) }; e.append(Double(m)); i += blk }
        var onset = [Double](repeating: 0, count: e.count)
        for k in 3..<e.count { onset[k] = max(0, e[k] - (e[k - 1] + e[k - 2] + e[k - 3]) / 3) }
        let beats = drum.clips.flatMap { c in c.notes.map { c.start + $0.start } }.sorted()
        print(String(format: "captured %.1f s of the drum track; %d drum hits in the song", Double(env.count) / rate, beats.count))
        func score(_ bpm: Double, _ w0: Double, _ w1: Double) -> Double {
            let ts = beats.map { 60 * $0 / bpm }.filter { $0 >= w0 && $0 < w1 }
            guard ts.count > 3 else { return 0 }
            var best = 0.0
            for lagMs in stride(from: -250, through: 250, by: 4) {
                var sum = 0.0
                for t in ts {
                    let idx = Int((t + Double(lagMs) / 1000) / 0.002)
                    if idx >= 1 && idx + 1 < onset.count { sum += max(onset[idx - 1], onset[idx], onset[idx + 1]) }
                }
                best = max(best, sum / Double(ts.count))
            }
            return best
        }
        for (a, b) in [(2.4, 5.0), (5.0, 7.5), (7.5, 10.0), (10.0, 12.5), (12.5, 15.0)] {
            let sc = [200.0, 162.0, 117.0].map { ($0, score($0, a, b)) }
            let top = sc.max { $0.1 < $1.1 }!
            print(String(format: "  %4.1f–%4.1f s: fit to 200 BPM %.4f | 162 BPM %.4f | 117 BPM %.4f → plays at %g BPM", a, b, sc[0].1, sc[1].1, sc[2].1, top.0))
        }
    }

    /// `--tempofuzz file`: many edits in a row; after each the sequencer's tempo map must still be one constant tempo.
    static func tempoFuzz(_ path: String) {
        _ = NSApplication.shared
        let s = Session()
        func pump(_ sec: Double, until: () -> Bool = { false }) { let e = Date().addingTimeInterval(sec); while Date() < e && !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } }
        pump(1)
        s.openProject(url: URL(fileURLWithPath: path))
        pump(0.5)
        let n = s.project.tracks.count
        pump(40) { s.engine.strips.values.allSatisfy { !$0.loading && $0.instrument != nil } && s.engine.strips.count == n }
        var rng = SystemRandomNumberGenerator()
        var bad = 0
        let ids = s.project.tracks.filter { $0.kind == .instrument && !$0.instrument.isDrums }.map { $0.id }
        for step in 0..<40 {
            let what = Int.random(in: 0..<6, using: &rng)
            var label = ""
            switch what {
            case 0: let t = Double(Int.random(in: 60...240, using: &rng)); s.setTempo(t); label = "tempo \(Int(t))"
            case 1: s.play(); pump(Double.random(in: 0.3...2, using: &rng)); label = "play"
            case 2: s.stop(); label = "stop"
            case 3: let id = ids.randomElement(using: &rng)!; s.setInstrument(trackID: id, InstrumentSpec(gmProgram: Int.random(in: 0..<100, using: &rng))); label = "instrument"
            case 4: s.seek(to: Double(Int.random(in: 0...60, using: &rng))); label = "seek"
            default: s.undo(); label = "undo"
            }
            pump(Double.random(in: 0.2...1.2, using: &rng))
            if s.engine.isPlaying { pump(0.5) } else { s.flushSequence() }
            pump(0.3)
            let t = s.project.tempo
            let checks: [Double] = [1, 3, 8, 20, 50, 100]
            let off = checks.map { abs(s.engine.sequencer.seconds(forBeats: $0) - 60 * $0 / t) }.max() ?? 0
            let ok = off < 0.02
            if !ok { bad += 1 }
            print(String(format: "  %@ step %2d %-12@ project %3.0f BPM | sequencer tempo map off by %.3f s", ok ? "ok  " : "FAIL", step, label as NSString, t, off))
        }
        s.stop()
        print(bad == 0 ? "TEMPO MAP STAYED CLEAN" : "\(bad) STEP(S) LEFT A WRONG TEMPO MAP")
    }

    /// `--looptempo file`: the same check with the loop switched on.
    static func loopTempo(_ path: String) {
        _ = NSApplication.shared
        let s = Session()
        func pump(_ sec: Double, until: () -> Bool = { false }) { let e = Date().addingTimeInterval(sec); while Date() < e && !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } }
        pump(1)
        s.openProject(url: URL(fileURLWithPath: path))
        let n = s.project.tracks.count
        pump(40) { s.engine.strips.values.allSatisfy { !$0.loading && $0.instrument != nil } && s.engine.strips.count == n }
        s.setTempo(200)
        s.edit { $0.loopEnabled = true; $0.loopStart = 0; $0.loopEnd = 8 }
        s.play(); pump(1)
        var last = s.engine.position, speeds: [String] = []
        for _ in 0..<12 { pump(0.5); let b = s.engine.position; speeds.append(String(format: "%.0f", (b - last) * 120)); last = b }
        print("loop 0–8 at 200: BPM each half second:", speeds.joined(separator: " "))
        for b in [4.0, 9, 17, 33, 100, 400] { print(String(format: "  sequencer: %5.0f beats at %.2f s (200 BPM expects %.2f)", b, s.engine.sequencer.seconds(forBeats: b + MIDIFile.playbackLead), 60 * b / 200)) }
        s.stop()
    }

    /// `--balancerace file.mid`: import, then straight away set 200 BPM and press play while Auto Balance is still waiting to start.
    static func balanceRace(_ path: String) {
        _ = NSApplication.shared
        let s = Session()
        func pump(_ sec: Double, until: () -> Bool = { false }) { let e = Date().addingTimeInterval(sec); while Date() < e && !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } }
        pump(1)
        s.importMIDI(url: URL(fileURLWithPath: path), tempo: .useFile)
        s.setTempo(200)
        s.play()
        let t0 = Date()
        var lastPos = s.engine.position, lastT = Date()
        for _ in 0..<70 {
            pump(1)
            let now = Date(), b = s.engine.position
            let bpm = (b - lastPos) / now.timeIntervalSince(lastT) * 60
            lastPos = b; lastT = now
            print(String(format: "  t=%4.1f s  playing %@  project %.0f BPM  sequencer 100 beats = %.1f s  moving at %4.0f BPM  busy: %@", now.timeIntervalSince(t0), s.engine.isPlaying ? "yes" : "no ", s.project.tempo, s.engine.sequencer.seconds(forBeats: 100), bpm, s.busyMessage ?? "-"))
            if s.busyMessage == nil && Date().timeIntervalSince(t0) > 30 && !s.engine.isPlaying { break }
        }
        s.stop()
    }

    /// `--tempodelete`: add a tempo change, delete it again, and check the sequencer really forgets it.
    static func tempoDelete() {
        _ = NSApplication.shared
        let s = Session()
        func pump(_ sec: Double) { let e = Date().addingTimeInterval(sec); while Date() < e { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } }
        pump(1)
        s.setTempo(120); pump(0.3)
        func report(_ label: String) -> Bool {
            s.flushSequence(); pump(0.3)
            let spans = [(0.0, 8.0), (8.0, 16.0), (16.0, 40.0)].map { s.engine.sequencer.seconds(forBeats: $0.1 + MIDIFile.playbackLead) - s.engine.sequencer.seconds(forBeats: $0.0 + MIDIFile.playbackLead) }
            let expect = s.project.seconds(atBeat: 8) - s.project.seconds(atBeat: 0)
            let bpms = zip(spans, [8.0, 8.0, 24.0]).map { String(format: "%.0f", $1 * 60 / $0) }
            let ok = abs(spans[0] - expect) < 0.03 && abs(spans[1] - (s.project.seconds(atBeat: 16) - s.project.seconds(atBeat: 8))) < 0.03 && abs(spans[2] - (s.project.seconds(atBeat: 40) - s.project.seconds(atBeat: 16))) < 0.03
            print("  \(ok ? "ok  " : "FAIL") \(label): sequencer tempo over beats 0–8, 8–16, 16–40 = \(bpms.joined(separator: " / ")) BPM; project says \(s.project.tempoPoints.map { "\(Int($0.bpm)) at \(Int($0.beat))" }.joined(separator: ", ").isEmpty ? "120 throughout" : s.project.tempoPoints.map { "\(Int($0.bpm)) at beat \(Int($0.beat))" }.joined(separator: ", "))")
            return ok
        }
        var good = report("start")
        s.edit { $0.tempoPoints = [TempoPoint(beat: 8, bpm: 200)] }
        good = report("a change to 200 at beat 8") && good
        s.edit { $0.tempoPoints = [] }
        good = report("after deleting it") && good
        s.edit { $0.tempoPoints = [TempoPoint(beat: 4, bpm: 90), TempoPoint(beat: 16, bpm: 180)] }
        good = report("two changes") && good
        s.edit { $0.tempoPoints.removeAll { $0.bpm == 90 } }
        good = report("after deleting one") && good
        s.setTempo(150)
        good = report("then the base tempo set to 150") && good
        s.edit { $0.tempoPoints = [] }
        good = report("after clearing all") && good
        print(good ? "TEMPO CHANGES ARE REALLY GONE WHEN DELETED" : "DELETED TEMPO CHANGES STILL SOUND")
    }

    static func run(_ path: String) {
        _ = NSApplication.shared
        let s = Session()
        func pump(_ sec: Double, until: () -> Bool = { false }) { let e = Date().addingTimeInterval(sec); while Date() < e && !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } }
        pump(1)
        s.importMIDI(url: URL(fileURLWithPath: path), tempo: .useFile)
        pump(0.2)
        let n = s.project.tracks.count
        pump(40) { s.engine.strips.values.allSatisfy { !$0.loading && $0.instrument != nil } && s.engine.strips.count == n }
        print("tracks:", n, "loaded:", s.engine.strips.values.filter { $0.instrument != nil }.count)

        func renderSolo(_ id: UUID) -> [Float] {
            var p = s.project
            for i in p.tracks.indices { p.tracks[i].mute = p.tracks[i].id != id; p.tracks[i].solo = false }
            let wav = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macband-instchange.wav")
            try? s.engine.bounce(p, to: wav, testSeconds: 14) { _ in }
            defer { try? FileManager.default.removeItem(at: wav) }
            return SelfTest.analyze(wav).samples
        }
        func difference(_ a: [Float], _ b: [Float]) -> Double {
            let m = min(a.count, b.count); guard m > 0 else { return 0 }
            var d = 0.0, e = 0.0
            for i in 0..<m { let x = Double(a[i]), y = Double(b[i]); d += (x - y) * (x - y); e += x * x + y * y }
            return e > 0 ? sqrt(d / e) : 0
        }
        var bad = 0
        for t in s.project.tracks where t.kind == .instrument {
            let before = renderSolo(t.id)
            let wasDrums = t.instrument.isDrums
            let target = wasDrums ? InstrumentSpec(gmProgram: 0, isDrums: true) : InstrumentSpec(gmProgram: t.instrument.gmProgram == 0 ? 73 : 0, isDrums: false)
            s.setInstrument(trackID: t.id, target)
            pump(20) { let st = s.engine.strips[t.id]; return st != nil && !st!.loading && st!.instrumentKey == AudioEngine.instrumentKey(target) }
            pump(0.3)
            let st = s.engine.strips[t.id]
            let keyOK = st?.instrumentKey == AudioEngine.instrumentKey(target)
            // live playback has to be connected to the new sampler
            let live = s.engine.sequencer.tracks.contains { $0.destinationAudioUnit === st?.instrument }
            let after = renderSolo(t.id)
            let diff = difference(before, after)
            let rmsBefore = sqrt(before.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, before.count)))
            let ok = keyOK && live && (wasDrums || diff > 0.25)
            if !ok { bad += 1 }
            print(String(format: "  %@ %@ gm %d → %d | strip %@ | live %@ | sound changed by %.0f%% (level %.3f)", ok ? "ok  " : "FAIL", t.name, t.instrument.gmProgram, target.gmProgram, keyOK ? "updated" : "NOT updated", live ? "connected" : "NOT connected", diff * 100, rmsBefore))
        }
        print(bad == 0 ? "ALL INSTRUMENT CHANGES TOOK EFFECT" : "\(bad) TRACK(S) DID NOT CHANGE")
    }
}
