#if os(macOS)
import Foundation
import AppKit

/// `--countdowntest`: pressing Record counts the bar down ("4/4", "3/4", "2/4", "1/4", one per beat) and only then starts recording.
@MainActor
enum CountdownTest {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { failures += 1 } }

    static func pump(_ seconds: Double, until: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }

    /// What the count shows over time, as (label, seconds since pressing Record), until recording starts or `limit` seconds pass.
    static func watch(_ s: Session, limit: Double) -> (seen: [(String, Double)], recordedAt: Double?) {
        var seen: [(String, Double)] = []
        var recordedAt: Double?
        let t0 = Date()
        pump(limit) {
            let t = Date().timeIntervalSince(t0)
            if let c = s.countdown, seen.last?.0 != c { seen.append((c, t)) }
            if s.transport.isRecording { recordedAt = t; return true }
            return false
        }
        return (seen, recordedAt)
    }

    static func run() -> Int32 {
        _ = NSApplication.shared
        print("== Count-in test ==")
        check(Countdown.labels(beats: 4) == ["4/4", "3/4", "2/4", "1/4"], "a bar of four counts 4/4, 3/4, 2/4, 1/4")
        check(Countdown.labels(beats: 3) == ["3/3", "2/3", "1/3"] && Countdown.labels(beats: 0) == ["1/1"], "other bars count their own beats")

        let s = Session()
        var p = DemoSong.make(); p.tempo = 120                       // half a second a beat
        s.project = p
        s.engine.syncTracks(p.tracks)
        s.selectedTrackID = p.tracks[0].id
        pump(1.5)

        // Record from a stopped song: the count, then recording
        s.seek(to: 0)
        s.toggleRecord()
        check(s.countdown == "4/4" && !s.transport.isRecording && !s.engine.isPlaying, "pressing Record shows 4/4 and doesn't record yet")
        let r = watch(s, limit: 4)
        check(r.seen.map { $0.0 } == ["4/4", "3/4", "2/4", "1/4"], "the count goes 4/4, 3/4, 2/4, 1/4 in order (saw \(r.seen.map { $0.0 }))")
        let gaps = zip(r.seen.dropFirst(), r.seen).map { $0.1 - $1.1 }
        check(gaps.allSatisfy { abs($0 - 0.5) < 0.12 }, "one beat apart at 120 bpm (gaps \(gaps.map { String(format: "%.2f", $0) }))")
        check(r.recordedAt.map { abs($0 - 2.0) < 0.2 } == true, "recording starts after the whole bar, about 2 s in (\(r.recordedAt.map { String(format: "%.2f", $0) } ?? "never") s)")
        check(s.countdown == nil && s.engine.isPlaying, "the count disappears and the song runs")
        s.toggleRecord(); s.stop(); pump(0.3)

        // Slower tempo, three-beat bar
        s.project.tempo = 60; s.project.timeSigNum = 3; s.project.timeSigDen = 4
        s.seek(to: 0)
        s.toggleRecord()
        let r3 = watch(s, limit: 5)
        check(r3.seen.map { $0.0 } == ["3/3", "2/3", "1/3"] && r3.recordedAt.map { abs($0 - 3.0) < 0.25 } == true, "at 60 bpm in 3/4 it counts 3/3, 2/3, 1/3 over three seconds")
        s.toggleRecord(); s.stop(); pump(0.3)
        s.project.tempo = 120; s.project.timeSigNum = 4

        // Calling it off
        s.seek(to: 0)
        s.toggleRecord()
        pump(0.7)
        check(s.countdown != nil, "mid-count the count is showing")
        s.toggleRecord()
        check(s.countdown == nil && !s.transport.isRecording && !s.engine.isPlaying, "Record again during the count calls it off")
        pump(2.5)
        check(!s.transport.isRecording && !s.engine.isPlaying, "and nothing starts afterwards")
        s.toggleRecord(); pump(0.4); s.togglePlay()
        check(s.countdown == nil, "Space during the count calls it off too")
        pump(2.5)
        check(!s.transport.isRecording, "and nothing starts afterwards (Space)")

        // Already playing: no count
        s.play()
        s.toggleRecord()
        check(s.countdown == nil && s.transport.isRecording, "with the song already running, Record starts right away")
        s.stop()

        print(failures == 0 ? "ALL COUNTDOWN CHECKS PASSED" : "\(failures) COUNTDOWN CHECK(S) FAILED")
        return failures == 0 ? 0 : 1
    }
}
#endif
