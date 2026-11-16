import Foundation
import AppKit

/// `--tempotest`: the tempo is found whatever mix of quarter notes, eighths, triplets and sixteenths is played, and a recording is re-timed to it.
@MainActor
enum TempoTest {
    static var failures = 0
    static func pump(_ seconds: Double, until: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.004)) }
    }
    static func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { failures += 1 } }

    /// A small repeatable random source, so a "sloppy player" is the same every run.
    struct Rng { var s: UInt64 = 12345; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 33) / Double(1 << 31) } }

    /// Note times in seconds for a rhythm (positions in beats within a bar of 4) played for `bars` bars at `bpm`, with timing wobble of ±`wobble` seconds.
    static func play(_ pattern: [Double], bpm: Double, bars: Int, start: Double = 0, wobble: Double = 0.015, seed: UInt64 = 1) -> [Double] {
        var r = Rng(s: seed)
        var out: [Double] = []
        for b in 0..<bars { for p in pattern { out.append(start + (Double(b) * 4 + p) * 60 / bpm + (r.next() * 2 - 1) * wobble) } }
        return out
    }

    static func detected(_ times: [Double]) -> Double? { TempoDetect.estimate(onsets: times)?.bpm }
    static func near(_ got: Double?, _ want: Double, tol: Double = 1.5) -> Bool { got.map { abs($0 - want) <= tol } ?? false }
    static func fmt(_ x: Double?) -> String { x.map { String(format: "%.1f", $0) } ?? "none" }

    /// A song with one track whose pattern holds a performance (`times` in seconds, as if recorded while the song ran at `songTempo`).
    static func session(_ times: [Double], songTempo: Double = 120) -> (Session, [UUID]) {
        let s = Session()
        var p = Project(); p.tempo = songTempo
        var t = Track(name: "Keys", colorIndex: 0)
        var c = Clip(name: "Recording", start: 0, length: 16)
        c.notes = times.map { Note(pitch: 60, start: $0 * songTempo / 60, length: 0.2) }
        t.clips = [c]; p.tracks = [t]
        s.project = p
        s.selectedTrackID = t.id; s.selectedClipID = c.id
        return (s, c.notes.map { $0.id })
    }

    /// Two beats of quarters, then two beats of triplets.
    static let tripletBar: [Double] = {
        var out: [Double] = [0, 1, 2]
        out.append(2 + 1.0 / 3); out.append(2 + 2.0 / 3); out.append(3)
        out.append(3 + 1.0 / 3); out.append(3 + 2.0 / 3)
        return out
    }()

    static func sessionChecks() {
        let bar: [Double] = tripletBar
        var meant: [Double] = []
        for b in 0..<4 { for p in bar { meant.append(Double(b) * 4 + p) } }
        let performance = play(bar, bpm: 90, bars: 4, start: 0.1)
        let (s, ids) = session(performance)
        let before = s.project
        let out = s.detectTempo(of: Set(ids))
        check(out?.applied == true && abs(s.project.tempo - 90) < 1.5, "a take played at 90 against a 120 song sets the song to \(s.project.tempo) BPM")
        let notes = s.project.tracks[0].clips.flatMap { c in c.notes.map { (c.start + $0.start, $0.length) } }.sorted { $0.0 < $1.0 }
        let worst = zip(notes, meant).map { abs($0.0.0 - $0.1) }.max() ?? 9
        check(notes.count == meant.count && worst < 0.12, "and every note sits on its beat, eighth or triplet place (worst \(String(format: "%.3f", worst)) beats off)")
        check(abs((notes.first?.1 ?? 0) - 0.2 * 90 / 120) < 0.03, "note lengths follow (a 0.2-beat note at 120 is 0.15 beats at 90: \(String(format: "%.3f", notes.first?.1 ?? 0)))")
        s.undo()
        check(s.project.tempo == 120 && s.project.tracks[0].clips[0].notes.map { $0.start } == before.tracks[0].clips[0].notes.map { $0.start }, "one undo puts the tempo and the notes back")

        // something else in the song: the tempo is reported, nothing changes
        let (s2, ids2) = session(performance)
        var other = Track(name: "Bass", colorIndex: 1)
        var oc = Clip(name: "B", start: 0, length: 4); oc.notes = [Note(pitch: 40, start: 0, length: 1)]; other.clips = [oc]
        s2.project.tracks.append(other)
        let out2 = s2.detectTempo(of: Set(ids2))
        check(out2?.applied == false && s2.project.tempo == 120 && near(out2?.estimate.bpm, 90), "with another track in the song its tempo is left alone and only the played tempo is reported (\(fmt(out2?.estimate.bpm)))")
        check(s2.toast?.contains("90") == true && s2.toast?.contains("120") == true, "and the message says both")

        // too few notes
        let (s3, ids3) = session([0, 0.5, 1, 1.5])
        check(s3.detectTempo(of: Set(ids3)) == nil && s3.toast?.contains("Not enough") == true, "too few notes: it says so and changes nothing")

        // the whole path: play along live while recording, with the setting on
        let live = Session()
        var lp = Project(); lp.tempo = 120
        var lt = Track(name: "Keys", colorIndex: 0)
        lt.clips = []
        lp.tracks = [lt]
        live.project = lp
        live.modify { _ in }                                  // as any edit does: the sequence is built from the song when it next plays
        live.engine.syncTracks(lp.tracks)
        pump(15) { live.engine.strips[lt.id]?.instrument != nil && live.engine.strips[lt.id]?.loading == false }
        live.selectedTrackID = lt.id
        live.detectTempoOnRecord = true
        live.seek(to: 0)
        live.toggleRecord()
        for barNo in 0..<2 {
            for pos in tripletBar {
                let at = (Double(barNo) * 4 + pos) * 60 / 90 + 0.15
                pump(10) { live.engine.position / 2 >= at }              // against the song's own clock (beats at 120 → seconds)
                live.liveNoteOn(60, 100)
                pump(10) { live.engine.position / 2 >= at + 0.08 }
                live.liveNoteOff(60)
            }
        }
        pump(0.2)
        live.toggleRecord()
        pump(0.3)
        live.detectTempoOnRecord = false
        let n = live.project.tracks[0].clips.reduce(0) { $0 + $1.notes.count }
        check(n == 16 && near(live.project.tempo, 90, tol: 3), "recording 16 notes live at about 90 BPM leaves the song at \(String(format: "%.1f", live.project.tempo)) BPM")
        UserDefaults.standard.removeObject(forKey: "detectTempoOnRecord")
    }

    static func run() -> Int32 {
        _ = NSApplication.shared
        print("== Tempo detection test ==")
        let quarters: [Double] = [0, 1, 2, 3]
        let eighths: [Double] = (0..<8).map { Double($0) * 0.5 }
        let triplets: [Double] = [0, 1, 2, 2 + 1.0 / 3, 2 + 2.0 / 3, 3, 3 + 1.0 / 3, 3 + 2.0 / 3]            // two beats of quarters, then triplets
        let everything: [Double] = [0, 1, 1.5, 2, 2 + 1.0 / 3, 2 + 2.0 / 3, 3, 3.25, 3.5, 3.75]                 // quarters, an eighth, a triplet and sixteenths in one bar
        let swung: [Double] = [0, 2.0 / 3, 1, 1 + 2.0 / 3, 2, 2 + 2.0 / 3, 3, 3 + 2.0 / 3]

        for bpm in [84.0, 100, 120, 133] {
            check(near(detected(play(quarters, bpm: bpm, bars: 4)), bpm), "quarter notes at \(Int(bpm)) → \(fmt(detected(play(quarters, bpm: bpm, bars: 4))))")
        }
        check(near(detected(play(eighths, bpm: 100, bars: 3)), 100), "straight eighth notes at 100 → \(fmt(detected(play(eighths, bpm: 100, bars: 3))))")
        // Notes that are all evenly spaced fit a tempo and its double equally well; either may be right, and the other is offered
        for (what, times, bpm) in [("quarter notes at 70", play(quarters, bpm: 70, bars: 4), 70.0), ("eighth notes at 76", play(eighths, bpm: 76, bars: 3), 76.0)] {
            let e = TempoDetect.estimate(onsets: times)
            let other = e.map { abs($0.bpm - bpm) < 1.5 ? bpm * 2 : bpm }
            let right = e.map { near($0.bpm, bpm) || near($0.bpm, bpm * 2) } ?? false
            let offered = e.map { x in x.alsoFits.contains { abs($0 - (other ?? 0)) < 1.5 } } ?? false
            check(right && offered, "\(what) read as \(fmt(e?.bpm)), with \(fmt(other)) offered as the other possibility")
        }
        check(near(detected(play(triplets, bpm: 90, bars: 4)), 90), "quarters with triplet runs at 90 → \(fmt(detected(play(triplets, bpm: 90, bars: 4))))")
        check(near(detected(play(triplets, bpm: 126, bars: 4)), 126), "quarters with triplet runs at 126 → \(fmt(detected(play(triplets, bpm: 126, bars: 4))))")
        check(near(detected(play(everything, bpm: 120, bars: 4)), 120), "quarters, eighths, triplets and sixteenths mixed at 120 → \(fmt(detected(play(everything, bpm: 120, bars: 4))))")
        check(near(detected(play(everything, bpm: 96, bars: 4, wobble: 0.025)), 96, tol: 2.5), "the same, played sloppily (±25 ms) at 96 → \(fmt(detected(play(everything, bpm: 96, bars: 4, wobble: 0.025))))")
        check(near(detected(play(swung, bpm: 110, bars: 4)), 110), "swung eighths at 110 → \(fmt(detected(play(swung, bpm: 110, bars: 4))))")
        check(near(detected(play(quarters, bpm: 100, bars: 4, start: 0.37)), 100), "a late start doesn't matter (0.37 s in)")
        check(near(detected(play(everything, bpm: 133, bars: 6, seed: 7)), 133), "133 with a different wobble → \(fmt(detected(play(everything, bpm: 133, bars: 6, seed: 7))))")

        // The grid it finds puts the notes on the beats
        let take = play(everything, bpm: 100, bars: 4, start: 0.2)
        if let e = TempoDetect.estimate(onsets: take) {
            let beats = take.map { e.beat(atSeconds: $0) }
            let errors = zip(beats, (0..<4).flatMap { b in everything.map { Double(b) * 4 + $0 } }).map { abs($0 - $1) }
            // the whole take may sit a whole number of beats away from where it was meant to be: compare the fractional part
            let frac = zip(beats, (0..<4).flatMap { b in everything.map { Double(b) * 4 + $0 } }).map { x -> Double in let d = x.0 - x.1; return abs(d - d.rounded()) }
            _ = errors
            check(frac.max()! < 0.12 && e.confidence > 0.6, "re-timed to the found grid every note is within 0.12 of a beat of where it was meant to be (worst \(String(format: "%.3f", frac.max()!)), confidence \(String(format: "%.2f", e.confidence)))")
        } else { check(false, "the mixed take has a tempo") }

        // Short, sloppy takes: two bars of quarters and triplets, wobbling ±30 ms, from twenty different "players"
        var right = 0
        for seed in 1...20 { if near(detected(play(tripletBar, bpm: 90, bars: 2, wobble: 0.03, seed: UInt64(seed))), 90, tol: 3) { right += 1 } }
        check(right >= 18, "two sloppy bars of quarters and triplets read right for \(right) of 20 players")
        var right4 = 0
        for seed in 1...20 { if near(detected(play(everything, bpm: 104, bars: 2, wobble: 0.03, seed: UInt64(seed))), 104, tol: 3) { right4 += 1 } }
        check(right4 >= 18, "two sloppy bars of mixed rhythms read right for \(right4) of 20 players")

        // Too little to go on
        check(TempoDetect.estimate(onsets: [0, 0.5, 1.0, 1.5]) == nil, "four notes aren't enough")
        check(TempoDetect.estimate(onsets: [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6]) == nil, "notes within a second aren't enough")
        // Chords count once
        var chordy: [Double] = []
        for t in play(quarters, bpm: 100, bars: 4) { chordy += [t, t + 0.004, t + 0.011] }
        check(near(detected(chordy), 100), "chords (notes a few ms apart) count as one hit")

        sessionChecks()
        print(failures == 0 ? "ALL TEMPO CHECKS PASSED" : "\(failures) TEMPO CHECK(S) FAILED")
        return failures == 0 ? 0 : 1
    }
}
