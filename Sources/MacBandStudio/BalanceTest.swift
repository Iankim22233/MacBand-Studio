import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import AVFoundation

/// `--balancetest`: very different sounds end up at similar loudness after Auto Balance.
@MainActor enum BalanceTest {
    static var failures = 0
    static func check(_ ok: Bool, _ m: String) { print(ok ? "  ok    \(m)" : "  FAIL  \(m)"); if !ok { failures += 1 } }

    static func run() -> Int32 {
        _ = NSApplication.shared
        print("== Auto Balance test ==")
        let s = Session()
        var p = Project(); p.tempo = 120
        func track(_ name: String, _ inst: InstrumentSpec, _ notes: [Note]) -> Track {
            var t = Track(name: name, colorIndex: p.tracks.count); t.instrument = inst
            var c = Clip(name: name, start: 0, length: 16); c.notes = notes; t.clips = [c]
            return t
        }
        var chords: [Note] = [], singles: [Note] = [], hits: [Note] = [], low: [Note] = []
        for i in 0..<8 { for pitch in [48, 55, 60, 64, 67] { chords.append(Note(pitch: pitch + (i % 2) * 2, start: Double(i) * 2, length: 1.8, velocity: 112)) } }
        for i in 0..<16 { singles.append(Note(pitch: 60 + [0, 4, 7, 12][i % 4], start: Double(i), length: 0.8, velocity: 90)) }
        for i in 0..<32 { hits.append(Note(pitch: [36, 42, 38, 42][i % 4], start: Double(i) * 0.5, length: 0.25, velocity: 100)) }
        for i in 0..<16 { low.append(Note(pitch: [36, 43, 38, 41][i % 4], start: Double(i), length: 0.9, velocity: 100)) }
        p.tracks = [
            track("Piano chords", InstrumentSpec(gmProgram: 0), chords),
            track("Marimba", InstrumentSpec(gmProgram: 12), singles),
            track("Bassoon", InstrumentSpec(gmProgram: 70), singles),
            track("Flute", InstrumentSpec(gmProgram: 73), singles),
            track("Bass", InstrumentSpec(gmProgram: 33), low),
            track("Drums", InstrumentSpec(isDrums: true), hits),
        ]
        s.project = p
        s.engine.syncTracks(p.tracks)
        SelfTest.pump(60) { s.engine.strips.count == p.tracks.count && s.engine.strips.values.allSatisfy { $0.instrument != nil && !$0.loading } }

        let before = try! s.engine.measureLoudness(s.project, seconds: 10)
        func show(_ title: String, _ m: [UUID: Double]) {
            print("   \(title):", p.tracks.map { t in String(format: "%@ %.1f", t.name as NSString, m[t.id] ?? -99) }.joined(separator: " | "))
        }
        show("before", before)
        let melodic = p.tracks.filter { !$0.instrument.isDrums }.map { $0.id }
        let spreadBefore = (melodic.compactMap { before[$0] }.max() ?? 0) - (melodic.compactMap { before[$0] }.min() ?? 0)
        check(before.count == p.tracks.count, "every track was measured (\(before.count)/\(p.tracks.count))")
        check(spreadBefore > 6, String(format: "the sounds really differ in loudness (%.1f dB apart)", spreadBefore))

        let n = try! s.balanceLevels(seconds: 10)
        check(n == p.tracks.count, "every track got a trim (\(n))")
        let trims = s.project.tracks.map { $0.trim }
        print("   trims (dB):", zip(p.tracks, trims).map { String(format: "%@ %+.1f", $0.0.name as NSString, $0.1) }.joined(separator: " | "))
        check(trims.contains { $0 < -0.5 } && trims.contains { $0 > 0.5 }, "loud tracks are brought down and quiet ones lifted")

        let after = try! s.engine.measureLoudness(s.project, seconds: 10, keepTrims: true)
        show("after ", after)
        let spreadAfter = (melodic.compactMap { after[$0] }.max() ?? 0) - (melodic.compactMap { after[$0] }.min() ?? 0)
        check(spreadAfter < 3.0, String(format: "afterwards the tracks are within %.1f dB of each other (was %.1f)", spreadAfter, spreadBefore))
        check(spreadAfter < spreadBefore / 2, "the spread more than halved")
        let mixAfter = try! s.engine.measureMix(s.project, seconds: 10, keepTrims: true).master ?? -99
        check(abs(mixAfter - AutoBalance.mixTarget) < 1.5, String(format: "the whole mix measures %.1f dB (target %.0f)", mixAfter, AutoBalance.mixTarget))

        // The trim reaches the audio: a +12 dB trim makes the strip louder than the fader alone can
        var q = s.project
        q.tracks[1].trim = 12; q.tracks[1].volume = 0.8
        s.project = q; s.applyMix()
        let g = s.engine.strips[q.tracks[1].id]!.mixer.outputVolume
        check(abs(Double(g) - pow(10, 12.0 / 20)) < 0.05, String(format: "trim +12 dB gives a gain of %.2f", g))

        // Undo restores the old trims; reset clears them
        s.project = q
        s.resetTrims()
        check(s.project.tracks.allSatisfy { $0.trim == 0 }, "reset sets every trim back to 0")

        // Pure rule: every track aims at (mix target − 10·log10(count)), drums 2 dB above; clamped
        let ids = (0..<4).map { _ in UUID() }
        let t = AutoBalance.trims(loudness: [ids[0]: -20, ids[1]: -30, ids[2]: -25, ids[3]: -80], drums: [ids[1]])
        let aim = AutoBalance.mixTarget - 10 * log10(4.0)
        check(abs(t[ids[0]]! - ((aim + 20) * 2).rounded() / 2) < 0.01 && abs(t[ids[2]]! - ((aim + 25) * 2).rounded() / 2) < 0.01, String(format: "four tracks each aim at %.1f dB", aim))
        check(abs(t[ids[1]]! - ((aim + AutoBalance.drumOffset + 30) * 2).rounded() / 2) < 0.01, "a drum track aims at the same level as the rest")
        check(t[ids[3]]! == AutoBalance.maxBoost, "a nearly silent track is boosted at most \(AutoBalance.maxBoost) dB")
        let rel = AutoBalance.relativeTrims(loudness: [ids[0]: -20, ids[1]: -30, ids[2]: -25], drums: [])
        check(abs(rel[ids[0]]! - (-5)) < 0.01 && abs(rel[ids[1]]! - 5) < 0.01 && abs(rel[ids[2]]!) < 0.01, "relative trims bring every track to the median")
        let outlier = AutoBalance.relativeTrims(loudness: [ids[0]: -30, ids[1]: -30, ids[2]: -30, ids[3]: -60], drums: [])
        check(outlier[ids[3]]! == AutoBalance.maxRelativeBoost && outlier[ids[0]]! == 0, "a track 30 dB below the rest is only lifted \(AutoBalance.maxRelativeBoost) dB relative to the others")
        let fin = AutoBalance.finalTrims(relative: rel, measuredMix: AutoBalance.mixTarget - 12)
        check(abs(fin[ids[2]]! - 12) < 0.01, "a mix measured 12 dB under target lifts everything 12 dB")
        let quiet = AutoBalance.trims(loudness: [ids[0]: -46, ids[1]: -48], drums: [])
        check(quiet[ids[0]]! > 18 && quiet[ids[1]]! > 18, "a very quiet (low-velocity) file is lifted a lot (\(quiet[ids[0]]!) / \(quiet[ids[1]]!) dB)")
        // The master Bass control: -12 dB on the low shelf takes a lot out of a low note
        var one = p; one.tracks = [p.tracks[4]]; one.masterBass = 0
        s.project = one
        let flat = try! s.engine.measureMix(one, seconds: 6).master ?? -99
        one.masterBass = -12
        let cut = try! s.engine.measureMix(one, seconds: 6).master ?? -99
        check(flat - cut > 4, String(format: "Bass at -12 dB makes the bass track %.1f dB quieter", flat - cut))
        let loaded = try? JSONDecoder().decode(Project.self, from: JSONEncoder().encode(one))
        check(loaded?.masterBass == -12, "the Bass setting is saved with the project")
        print(failures == 0 ? "ALL BALANCE CHECKS PASSED" : "\(failures) BALANCE CHECK(S) FAILED")
        return failures == 0 ? 0 : 1
    }
}
