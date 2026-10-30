import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Headless checks for the notation engine (`MacBandStudio --scoretest`).
@MainActor enum ScoreTest {
    static var failures = 0
    static func check(_ ok: Bool, _ msg: String) { print(ok ? "  ok    \(msg)" : "  FAIL  \(msg)"); if !ok { failures += 1 } }

    static func note(_ p: Int, _ s: Double, _ l: Double) -> Note { Note(pitch: p, start: s, length: l, velocity: 100) }

    static func build(_ notes: [Note], len: Double = 4, num: Int = 4, den: Int = 4, fifths: Int = 0, clef: ScoreClefMode = .treble, drums: Bool = false, res: Double = 0.25) -> NScore {
        Notation.build(notes: notes, length: len, num: num, den: den, fifths: fifths, clefMode: clef, drums: drums, resolution: res)
    }
    static func total(_ events: [NEvent], voice: Int = 0) -> Double { events.filter { $0.voice == voice }.reduce(0) { $0 + $1.dur } }

    static func run() {
        print("== Notation test ==")
        // durations
        func split(_ pos: Double, _ len: Double, g: Double = 1) -> String {
            Notation.splitDuration(pos: pos, length: len, group: g).map { "\($0.dur)" }.joined(separator: "+")
        }
        check(split(0, 4) == "4.0", "a whole bar is one whole note")
        check(split(0, 3) == "3.0", "three beats from the downbeat is a dotted half")
        check(split(1, 3) == "3.0", "three beats from beat 2 is a dotted half (ends the bar)")
        check(split(0.5, 1) == "0.5+0.5", "a beat starting on the 'and' is two tied eighths")
        check(split(0, 1.5) == "1.5", "a dotted quarter from the beat")
        check(split(0.5, 1.5) == "0.5+1.0", "off-beat dotted quarter splits at the beat")
        check(split(0.25, 0.75) == "0.75", "a dotted eighth from the 'e' fills the rest of a beat")
        check(split(0.25, 0.5) == "0.5", "sixteenth – eighth – sixteenth: the middle eighth stays whole")
        check(split(0.5, 0.75) == "0.5+0.25", "a dotted eighth starting on the 'and' can't fit the beat: eighth + sixteenth")
        check(split(0.5, 1, g: 1.5) == "1.0", "6/8: a quarter on the second eighth is allowed")
        check(split(0, 0.75) == "0.75", "dotted eighth from the beat")
        check(split(0, 3, g: 1.5) == "3.0", "compound 6/8 bar = one dotted half")

        // spelling
        func spell(_ m: Int, _ f: Int) -> String {
            let s = Notation.spell(m, fifths: f)
            return "\(Notation.letters[s.letter])\(s.acc == 1 ? "#" : s.acc == -1 ? "b" : "")\(s.step / 7)"
        }
        check(spell(60, 0) == "C4", "60 is C4")
        check(spell(61, 0) == "C#4", "61 in C major is C♯4")
        check(spell(63, 0) == "Eb4", "63 in C major is E♭4")
        check(spell(66, 1) == "F#4", "66 in G major is F♯4 (in the key)")
        check(spell(65, 1) == "F4", "65 in G major is F natural")
        check(spell(70, -1) == "Bb4", "70 in F major is B♭4")
        check(spell(61, -2) == "Db4", "61 in B♭ major is D♭4 (flat key spells flats)")
        check(spell(71, 0) == "B4", "71 is B4")
        check(spell(59, 0) == "B3", "59 is B3")
        check(Notation.fifths(root: 9, scale: .minor) == 0, "A minor has no accidentals")
        check(Notation.fifths(root: 7, scale: .major) == 1, "G major has one sharp")
        check(Notation.fifths(root: 2, scale: .minor) == -1, "D minor has one flat")
        check(Notation.midi(forStep: 4 * 7 + 3, fifths: 1) == 66, "clicking F5-ish line in G major gives F♯")
        check(Notation.keyName(1).hasPrefix("G major"), "key name for one sharp")

        // measures fill exactly
        let s1 = build([note(60, 0, 1), note(62, 1, 0.5), note(64, 1.5, 0.5), note(65, 2.5, 1.25)], len: 8)
        check(s1.measureCount == 2, "8 beats of 4/4 = 2 measures")
        check(abs(total(s1.staves[0].events) - 8) < 1e-9, "events add up to the whole pattern (\(total(s1.staves[0].events)))")
        for m in 0..<2 {
            let sum = s1.staves[0].events.filter { $0.measure == m }.reduce(0) { $0 + $1.dur }
            check(abs(sum - 4) < 1e-9, "measure \(m + 1) holds exactly one bar")
        }
        let empty = build([], len: 4)
        check(empty.staves[0].events.count == 1 && empty.staves[0].events[0].fullBar, "an empty bar is a single whole-bar rest")

        // ties across the barline
        let s2 = build([note(60, 3, 2)], len: 8)
        let tied = s2.staves[0].events.filter { !$0.isRest }
        check(tied.count == 2 && tied[0].pitches[0].tieNext && tied[1].pitches[0].tiePrev, "a note over the barline is tied")
        check(tied[0].measure == 0 && tied[1].measure == 1, "…with one half in each measure")
        check(s2.staves[0].events.first { $0.isRest && $0.measure == 0 }.map { $0.start } == 0, "rest before it starts the bar")

        // chords, overlap
        let s3 = build([note(60, 0, 2), note(64, 0, 1), note(67, 0, 1)], len: 4)
        let ev3 = s3.staves[0].events
        check(ev3[0].pitches.count == 3 && ev3[0].dur == 1, "three notes starting together make a chord")
        check(ev3[1].pitches.count == 1 && ev3[1].pitches[0].midi == 60 && ev3[1].pitches[0].tiePrev, "the held note carries on, tied")
        check(ev3[0].pitches.map { $0.midi } == [60, 64, 67], "chord heads are ordered low to high")

        // accidentals
        let s4 = build([note(61, 0, 1), note(61, 1, 1), note(62, 2, 1), note(61, 3, 1)], len: 4)
        let a4 = s4.staves[0].events.filter { !$0.isRest }.map { $0.pitches[0].showAcc }
        check(a4 == [true, false, false, false], "a sharp is shown once and holds for the rest of the bar (\(a4))")
        let s5 = build([note(61, 3.5, 1), note(61, 4.5, 1)], len: 8)
        let a5 = s5.staves[0].events.filter { !$0.isRest && !$0.pitches[0].tiePrev }.map { $0.pitches[0].showAcc }
        check(a5 == [true, true], "accidentals reset at the next barline (\(a5))")
        let s6 = build([note(66, 0, 1), note(65, 1, 1)], len: 4, fifths: 1)
        let a6 = s6.staves[0].events.filter { !$0.isRest }.map { $0.pitches[0].showAcc }
        check(a6 == [false, true], "G major: F♯ needs no sign, F natural gets one (\(a6))")

        // beams
        let s7 = build((0..<8).map { note(60 + $0, Double($0) * 0.5, 0.5) }, len: 4)
        let beams = s7.staves[0].events.compactMap { $0.beamID }
        check(Set(beams).count == 4 && beams.count == 8, "eight eighths beam in four pairs (\(Set(beams).count) groups)")
        let s8 = build([note(60, 0, 1), note(62, 1, 0.5), note(64, 1.5, 0.5)], len: 4)
        check(s8.staves[0].events.filter { $0.beamID != nil }.count == 2, "a quarter isn't beamed, the two eighths are")
        let c68 = build((0..<6).map { note(60, Double($0) * 0.5, 0.5) }, len: 3, num: 6, den: 8)
        check(Set(c68.staves[0].events.compactMap { $0.beamID }).count == 2, "6/8: eighths beam in two groups of three")

        // stems
        let hi = build([note(79, 0, 1)], len: 4).staves[0].events[0]
        let lo = build([note(60, 0, 1)], len: 4).staves[0].events[0]
        check(!hi.stemUp && lo.stemUp, "high notes stem down, low notes stem up")

        // clefs
        let piano = build([note(48, 0, 1), note(72, 0, 1)], len: 4, clef: .auto)
        check(piano.staves.count == 2 && piano.staves[0].clef == .treble && piano.staves[1].clef == .bass, "wide range → grand staff")
        check(piano.staves[0].events.first { !$0.isRest }?.pitches[0].midi == 72 && piano.staves[1].events.first { !$0.isRest }?.pitches[0].midi == 48, "notes split between the staves at middle C")
        check(build([note(36, 0, 1), note(40, 1, 1)], clef: .auto).staves[0].clef == .bass, "low line → bass clef")
        check(build([note(72, 0, 1), note(76, 1, 1)], clef: .auto).staves[0].clef == .treble, "high line → treble clef")
        for st in piano.staves { check(abs(total(st.events) - 4) < 1e-9, "each staff of the grand staff is complete") }

        // drums
        var drum: [Note] = []
        for i in 0..<8 { drum.append(note(42, Double(i) * 0.5, 0.25)) }
        drum += [note(36, 0, 0.25), note(38, 1, 0.25), note(36, 2, 0.25), note(38, 3, 0.25)]
        let d = build(drum, len: 4, clef: .auto, drums: true)
        check(d.staves.count == 1 && d.staves[0].clef == .percussion, "drums use a percussion staff")
        let hands = d.staves[0].events.filter { $0.voice == 0 }, feet = d.staves[0].events.filter { $0.voice == 1 && !$0.isRest }
        check(abs(total(d.staves[0].events, voice: 0) - 4) < 1e-9, "the hands voice fills the bar")
        check(feet.count == 2 && feet.allSatisfy { !$0.stemUp }, "kick drum is its own voice with stems down")
        check(hands.contains { $0.pitches.contains { $0.head == .x } }, "hi-hat uses × noteheads")
        check(Notation.drumPosition(38).step == 35 && Notation.drumPosition(36).step == 31, "snare on the third space, kick on the bottom space")

        // robustness: random notes always fill every bar of every staff
        var rng = SystemRandomNumberGenerator()
        var bad = 0
        for trial in 0..<200 {
            var ns: [Note] = []
            for _ in 0..<Int.random(in: 1...24, using: &rng) {
                let s = Double(Int.random(in: 0..<60, using: &rng)) * 0.25, l = Double(Int.random(in: 1...12, using: &rng)) * 0.25
                ns.append(note(Int.random(in: 36...84, using: &rng), s, l))
            }
            let sig = [(4, 4), (3, 4), (6, 8), (5, 4), (7, 8)][trial % 5]
            let sc = build(ns, len: 16, num: sig.0, den: sig.1, fifths: Int.random(in: -3...3, using: &rng), clef: .grand)
            for st in sc.staves {
                for m in 0..<sc.measureCount {
                    let sum = st.events.filter { $0.measure == m && $0.voice == 0 }.reduce(0) { $0 + $1.dur }
                    if abs(sum - sc.beatsPerBar) > 1e-6 {
                        bad += 1
                        if bad == 1 { print("   sample failure: \(sig) measure \(m + 1) sum \(sum)  events: \(st.events.filter { $0.measure == m }.map { "\($0.start)+\($0.dur)" }) notes: \(ns.map { "\($0.start)+\($0.length)" })") }
                    }
                }
            }
        }
        check(bad == 0, "200 random patterns: every measure of every staff adds up exactly (\(bad) bad)")

        print(failures == 0 ? "ALL NOTATION CHECKS PASSED" : "\(failures) NOTATION CHECK(S) FAILED")
    }

    /// `--scoreshots <dir>`: renders a set of test scores to PNG so the engraving can be looked at.
    static func shots(_ dir: String) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func out(_ name: String, _ sc: NScore, title: String = "", width: CGFloat = 900, space: CGFloat = 9) {
            let lay = ScoreLayout(score: sc, width: width, space: space, title: title, subtitle: "MacBand Studio")
            var style = ScoreStyle(); style.ink = NSColor.white; style.staffLine = NSColor(white: 0.7, alpha: 1)
            lay.writePNG(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"), style: style)
            print("wrote \(name).png  systems=\(lay.systems.count) height=\(Int(lay.height))")
        }
        let demo = DemoSong.make()
        func notes(_ i: Int) -> [Note] { demo.tracks[i].clips[0].notes }
        out("piano", Notation.build(notes: notes(0), length: 16, num: 4, den: 4, fifths: 0, clefMode: .auto, drums: false, resolution: 0.25), title: "Piano")
        out("bass", Notation.build(notes: notes(1), length: 16, num: 4, den: 4, fifths: 0, clefMode: .auto, drums: false, resolution: 0.25), title: "Bass")
        out("drums", Notation.build(notes: notes(2), length: 16, num: 4, den: 4, fifths: 0, clefMode: .auto, drums: true, resolution: 0.25), title: "Drums")
        // rhythm torture test
        var r: [Note] = []
        var t = 0.0
        for (len, p) in [(4.0, 60), (2.0, 62), (2.0, 64), (3.0, 65), (1.0, 67), (1.5, 69), (0.5, 71), (1.0, 72), (1.0, 71), (0.5, 69), (0.5, 67), (0.25, 65), (0.25, 64), (0.25, 62), (0.25, 60), (0.75, 62), (0.25, 64), (1.0, 65), (1.5, 67), (6.0, 69)] {
            r.append(note(p, t, len)); t += len
        }
        r.append(note(52, 0, 4)); r.append(note(55, 0, 4)); r.append(note(48, 8, 1)); r.append(note(50, 9, 1))
        out("rhythms", Notation.build(notes: r, length: 28, num: 4, den: 4, fifths: 0, clefMode: .grand, drums: false, resolution: 0.25), title: "Rhythms and ties")
        // keys
        let scaleG: [Int] = [67, 69, 71, 72, 74, 76, 78, 79, 77, 76, 74, 73, 72, 71, 69, 67]
        out("key-g", Notation.build(notes: scaleG.enumerated().map { note($1, Double($0) * 0.5, 0.5) }, length: 8, num: 4, den: 4, fifths: 1, clefMode: .treble, drums: false, resolution: 0.25), title: "G major (one sharp)")
        let scaleEb: [Int] = [63, 65, 67, 68, 70, 72, 74, 75, 74, 73, 72, 70, 68, 66, 63, 62]
        out("key-eb", Notation.build(notes: scaleEb.enumerated().map { note($1, Double($0) * 0.5, 0.5) }, length: 8, num: 4, den: 4, fifths: -3, clefMode: .treble, drums: false, resolution: 0.25), title: "E♭ major (three flats)")
        out("six-eight", Notation.build(notes: (0..<12).map { note(60 + [0, 2, 4, 5, 7, 9][$0 % 6], Double($0) * 0.5, 0.5) } + [note(72, 6, 1.5), note(67, 7.5, 0.5), note(64, 8, 1)], length: 9, num: 6, den: 8, fifths: 0, clefMode: .treble, drums: false, resolution: 0.25), title: "6/8")
        out("three-four", Notation.build(notes: [note(60, 0, 1), note(64, 1, 1), note(67, 2, 1), note(72, 3, 3), note(60, 3, 3), note(64, 3, 3), note(55, 6, 0.5), note(57, 6.5, 0.5), note(59, 7, 0.5), note(60, 7.5, 0.5), note(62, 8, 1)], length: 12, num: 3, den: 4, fifths: -1, clefMode: .grand, drums: false, resolution: 0.25), title: "3/4 in F major")
        // wide narrow zoom
        out("narrow", Notation.build(notes: notes(0), length: 16, num: 4, den: 4, fifths: 0, clefMode: .auto, drums: false, resolution: 0.25), title: "Narrow window", width: 520, space: 8)
    }

    /// `--scoreexport <dir>`: writes a PDF and a MusicXML file for a demo score and checks them.
    static func export(_ dir: String) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let demo = DemoSong.make()
        var all: [Note] = []
        for k in 0..<3 { all += demo.tracks[0].clips[0].notes.map { var n = $0; n.id = UUID(); n.start += Double(k) * 16; return n } }
        let sc = Notation.build(notes: all, length: 48, num: 4, den: 4, fifths: 0, clefMode: .auto, drums: false, resolution: 0.25)
        let pdf = ScorePDF.data(score: sc, title: "Demo Piano", subtitle: "MacBand Studio", firstMeasure: 1)
        try? pdf.write(to: URL(fileURLWithPath: dir + "/demo.pdf"))
        let xml = MusicXML.build(score: sc, title: "Demo Piano", partName: "Piano", tempo: 104)
        try? xml.write(toFile: dir + "/demo.musicxml", atomically: true, encoding: .utf8)
        let drums = Notation.build(notes: demo.tracks[2].clips[0].notes, length: 16, num: 4, den: 4, fifths: 0, clefMode: .auto, drums: true, resolution: 0.25)
        try? MusicXML.build(score: drums, title: "Demo Drums", partName: "Drums", tempo: 104).write(toFile: dir + "/drums.musicxml", atomically: true, encoding: .utf8)
        print("pdf bytes:", pdf.count, " xml bytes:", xml.count, " measures:", sc.measureCount)
    }

    // MARK: Editor interaction

    /// `--scoreuitest`: drives the score view with synthesized mouse and key events.
    static func ui() {
        _ = NSApplication.shared
        print("== Score editor UI test ==")
        let sess = Session()
        var p = Project(); p.tempo = 120
        var t = Track(name: "Lead", colorIndex: 0)
        t.clips = [Clip(name: "Pattern", start: 0, length: 8)]
        var drumT = Track(name: "Kit", colorIndex: 1); drumT.instrument = InstrumentSpec(isDrums: true)
        drumT.clips = [Clip(name: "Beat", start: 0, length: 8)]
        p.tracks = [t, drumT]
        sess.project = p
        sess.selectedTrackID = t.id; sess.selectedClipID = t.clips[0].id
        sess.bottomPanel = .score
        sess.scoreClef = .treble; sess.scoreKey = 0

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let canvas = ScoreCanvas(session: sess)
        canvas.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        win.contentView = canvas
        canvas.refresh()
        func pump() { SelfTest.pump(0.05) }

        func notes() -> [Note] { sess.project.tracks.first { $0.id == sess.selectedTrackID }!.clips.first { $0.id == sess.selectedClipID }!.notes }
        func pt(measure: Int, beat: Double, step: Int) -> CGPoint {
            let lay = canvas.layoutBox!
            let pos = lay.position(forBeat: Double(measure) * 4 + beat)!
            let sys = lay.systems[pos.system]
            let clef = lay.score.staves[0].clef
            let y = sys.staffTop[0] + 4 * lay.s - CGFloat(step - clef.bottomStep) * lay.s / 2
            return CGPoint(x: pos.x, y: y)
        }
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func click(_ p: CGPoint, flags: NSEvent.ModifierFlags = []) { canvas.mouseDown(with: mouse(.leftMouseDown, p, flags: flags)); canvas.mouseUp(with: mouse(.leftMouseUp, p, flags: flags)); pump() }
        func key(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
            canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!)
            pump()
        }

        // draw tool places a note where you click
        sess.scoreTool = .draw; sess.scoreNoteLength = 1; sess.scoreDotted = false
        let c4: Int = 4 * 7 + 0, e4 = c4 + 2, g4 = c4 + 4
        click(pt(measure: 0, beat: 0, step: c4)); pump()
        check(notes().count == 1, "clicking on the staff adds a note")
        check(notes().first?.pitch == 60 && notes().first?.start == 0 && notes().first?.length == 1, "…C4 at beat 1, a quarter note long")
        click(pt(measure: 0, beat: 1, step: e4))
        click(pt(measure: 0, beat: 2, step: g4))
        check(notes().map { $0.pitch }.sorted() == [60, 64, 67], "three clicks → C, E, G")
        check(abs((notes().first { $0.pitch == 64 }?.start ?? -1) - 1) < 1e-9, "E lands on beat 2")
        check(canvas.layoutBox!.heads.count == 3, "all three notes are drawn")

        // note length from the palette
        sess.scoreNoteLength = 0.5; sess.scoreDotted = true
        click(pt(measure: 1, beat: 0, step: c4 + 7))
        check(abs((notes().first { $0.pitch == 72 }?.length ?? 0) - 0.75) < 1e-9, "a dotted eighth is 0.75 beats")
        check(sess.selectedNoteIDs.count == 1, "the new note is selected")

        // key-signature aware pitch: in G major the F line is F sharp
        sess.scoreKey = 1; canvas.refresh()
        let f5 = 5 * 7 + 3
        let before = notes().count
        sess.scoreNoteLength = 1; sess.scoreDotted = false
        click(pt(measure: 1, beat: 2, step: f5))
        check(notes().count == before + 1 && notes().last?.pitch == 78, "in G major a note on the F line is F♯ (78)")
        sess.scoreKey = 0; canvas.refresh()

        // select by clicking a head, then arrow keys
        sess.scoreTool = .select
        click(pt(measure: 0, beat: 1, step: e4))
        check(sess.selectedNoteIDs == [notes().first { $0.pitch == 64 }!.id], "clicking a notehead selects it")
        key("\u{F700}", code: 126)
        check(notes().contains { $0.pitch == 65 } && !notes().contains { $0.pitch == 64 }, "↑ raises it a semitone")
        key("\u{F701}", code: 125, flags: .shift)
        check(notes().contains { $0.pitch == 53 }, "⇧↓ lowers it an octave")
        key("\u{F700}", code: 126, flags: .shift)
        // length keys
        key("4", code: 21)
        check(abs((notes().first { $0.pitch == 65 }?.length ?? 0) - 0.5) < 1e-9, "key 4 makes the selected note an eighth")
        key(".", code: 47)
        check(abs((notes().first { $0.pitch == 65 }?.length ?? 0) - 0.75) < 1e-9, "'.' dots it")
        sess.scoreDotted = false; key("3", code: 20)
        // move in time
        let start0 = notes().first { $0.pitch == 65 }!.start
        key("\u{F703}", code: 124)
        check(abs((notes().first { $0.pitch == 65 }?.start ?? 0) - (start0 + 0.25)) < 1e-9, "→ moves it one grid step later")

        // drag a note up two steps: C4 → E4 (diatonic)
        click(pt(measure: 0, beat: 0, step: c4))
        let from = pt(measure: 0, beat: 0, step: c4), to = CGPoint(x: from.x, y: from.y - canvas.layoutBox!.s)
        canvas.mouseDown(with: mouse(.leftMouseDown, from))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: from.x, y: from.y - canvas.layoutBox!.s / 2)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, to))
        canvas.mouseUp(with: mouse(.leftMouseUp, to)); pump()
        check(notes().contains { $0.pitch == 64 && $0.start == 0 }, "dragging C4 up two staff steps gives E4")

        // undo restores
        sess.undo(); pump()
        check(notes().contains { $0.pitch == 60 && $0.start == 0 }, "undo puts the dragged note back")

        // erase tool
        sess.scoreTool = .erase
        let n0 = notes().count
        click(pt(measure: 0, beat: 0, step: c4))
        check(notes().count == n0 - 1 && !notes().contains { $0.pitch == 60 && $0.start == 0 }, "erase tool removes the clicked note")

        // marquee selects several
        sess.scoreTool = .select
        sess.selectedNoteIDs = []
        let a = pt(measure: 0, beat: 0, step: 20), b = pt(measure: 1, beat: 3.5, step: 40)
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: a.x - 20, y: b.y - 10)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: b.x + 20, y: a.y + 10)))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: b.x + 20, y: a.y + 10))); pump()
        check(sess.selectedNoteIDs.count == notes().count && !notes().isEmpty, "a rubber band selects the notes inside it (\(sess.selectedNoteIDs.count)/\(notes().count))")
        key("\u{7F}", code: 51)
        check(notes().isEmpty, "delete removes the selected notes")

        // ties and long notes show up
        sess.scoreTool = .draw; sess.scoreNoteLength = 4
        click(pt(measure: 0, beat: 2, step: c4))
        check(canvas.layoutBox!.score.staves[0].events.filter { !$0.isRest }.count == 2, "a whole note from beat 3 is written as two tied notes")

        // drum track: the percussion staff
        sess.selectedTrackID = drumT.id; sess.selectedClipID = drumT.clips[0].id
        sess.scoreClef = .auto
        canvas.refresh()
        check(canvas.layoutBox?.score.staves[0].clef == .percussion, "a drum track shows the percussion staff")
        sess.scoreTool = .draw; sess.scoreNoteLength = 1
        click(pt(measure: 0, beat: 0, step: Notation.drumPosition(36).step))
        click(pt(measure: 0, beat: 1, step: Notation.drumPosition(38).step))
        check(notes().map { $0.pitch }.sorted() == [36, 38], "clicking the bottom space adds a kick, the third space a snare")

        // playhead mapping
        let pos0 = canvas.layoutBox!.position(forBeat: 0)!, pos2 = canvas.layoutBox!.position(forBeat: 2)!
        check(pos2.x > pos0.x && pos0.system == pos2.system, "later beats are further right")

        print(failures == 0 ? "ALL SCORE UI CHECKS PASSED" : "\(failures) SCORE UI CHECK(S) FAILED")
    }
}
