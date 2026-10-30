import Foundation

// MARK: - Notation model (pure logic: turns piano-roll notes into staff notation)

enum ScoreClefMode: String, CaseIterable, Identifiable {
    case auto = "Auto", treble = "Treble", bass = "Bass", grand = "Grand Staff"
    var id: String { rawValue }
}

enum Clef {
    case treble, bass, percussion
    /// Diatonic step (octave × 7 + letter, C = 0) of the bottom staff line.
    var bottomStep: Int { self == .bass ? 18 : 30 }
    var middleStep: Int { bottomStep + 4 }
}

enum NoteHead { case normal, x, diamond }

/// One notehead.
struct NPitch {
    var midi: Int
    var step: Int           // diatonic step: octave * 7 + letter (C = 0 … B = 6)
    var acc: Int            // spelled alteration: -1 flat, 0 natural, 1 sharp
    var showAcc = false     // draw an accidental sign in front of it
    var head: NoteHead = .normal
    var noteID: UUID?
    var tieNext = false
    var tiePrev = false
}

/// A chord, single note or rest with a standard written duration.
struct NEvent {
    var start: Double       // beats from the start of the pattern
    var dur: Double         // written duration in beats
    var base: Int           // 0 whole, 1 half, 2 quarter, 3 eighth, 4 sixteenth, 5 thirty-second
    var dots: Int
    var pitches: [NPitch]   // empty for a rest
    var voice: Int
    var measure: Int
    var fullBar = false     // a rest that fills the whole measure
    var stemUp = true
    var beamID: Int? = nil
    var isRest: Bool { pitches.isEmpty }
    var end: Double { start + dur }
}

struct NStaff {
    var clef: Clef
    var events: [NEvent]
}

struct NScore {
    var staves: [NStaff]
    var measureCount: Int
    var beatsPerBar: Double
    var timeNum: Int
    var timeDen: Int
    var fifths: Int
    var group: Double       // beats per beam / rhythm group
}

enum Notation {
    // MARK: Standard note values

    /// Written durations, longest first: (beats, base, dots).
    static let values: [(dur: Double, base: Int, dots: Int)] = [
        (4, 0, 0), (3, 1, 1), (2, 1, 0), (1.5, 2, 1), (1, 2, 0), (0.75, 3, 1), (0.5, 3, 0),
        (0.25, 4, 0), (0.125, 5, 0),
    ]

    static func beatsPerBar(num: Int, den: Int) -> Double { Double(num) * 4 / Double(den) }

    /// How the bar is grouped for reading and beaming: a beat in simple meters, a dotted beat in compound ones.
    static func group(num: Int, den: Int) -> Double {
        if den == 8 && num % 3 == 0 && num >= 6 { return 1.5 }
        if den == 2 { return 2 }
        if den == 8 { return 1 }
        return 1
    }

    private static func isMultiple(_ x: Double, of u: Double) -> Bool {
        let r = x.truncatingRemainder(dividingBy: u)
        return abs(r) < 1e-6 || abs(r - u) < 1e-6
    }

    private static func fits(_ v: (dur: Double, base: Int, dots: Int), at p: Double, group g: Double) -> Bool {
        if v.dur >= g - 1e-6 {
            if v.base == 0 && v.dots == 0 { return p < 1e-6 }          // a whole note starts the bar
            return isMultiple(p, of: g)
        }
        let o = p.truncatingRemainder(dividingBy: g)
        guard o + v.dur <= g + 1e-6 else { return false }              // short values don't cross a beat
        return isMultiple(o, of: min(v.dur, 0.25))
    }

    /// Splits `length` beats starting `pos` beats into a bar into standard, readable pieces.
    static func splitDuration(pos: Double, length: Double, group g: Double) -> [(pos: Double, dur: Double, base: Int, dots: Int)] {
        var out: [(Double, Double, Int, Int)] = []
        var p = pos, rem = length
        while rem > 1e-6 {
            let v = values.first { $0.dur <= rem + 1e-6 && fits($0, at: p, group: g) } ?? values.last!
            out.append((p, v.dur, v.base, v.dots))
            p += v.dur; rem -= v.dur
        }
        return out
    }

    // MARK: Key signatures and spelling

    static let majorFifths = [0, -5, 2, -3, 4, -1, 6, 1, -4, 3, -2, 5]       // C, Db, D, Eb, E, F, F#, G, Ab, A, Bb, B

    /// Key signature (number of sharps, negative for flats) for a project key.
    static func fifths(root: Int, scale: ScaleKind) -> Int {
        let r = ((root % 12) + 12) % 12
        switch scale {
        case .major, .pentatonicMajor, .chromatic: return majorFifths[r]
        case .minor, .pentatonicMinor, .blues: return majorFifths[(r + 3) % 12]
        case .dorian: return majorFifths[(r + 10) % 12]
        case .mixolydian: return majorFifths[(r + 5) % 12]
        }
    }

    static let letters = ["C", "D", "E", "F", "G", "A", "B"]
    static let naturalPC = [0, 2, 4, 5, 7, 9, 11]
    private static let sharpOrder = [3, 0, 4, 1, 5, 2, 6]     // F C G D A E B
    private static let flatOrder = [6, 2, 5, 1, 4, 0, 3]      // B E A D G C F

    /// Alteration each letter (C…B) carries in a key signature.
    static func signature(_ fifths: Int) -> [Int] {
        var sig = [Int](repeating: 0, count: 7)
        if fifths > 0 { for i in 0..<min(7, fifths) { sig[sharpOrder[i]] = 1 } }
        if fifths < 0 { for i in 0..<min(7, -fifths) { sig[flatOrder[i]] = -1 } }
        return sig
    }

    static func keyName(_ fifths: Int) -> String {
        let major = ["Cb", "Gb", "Db", "Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E", "B", "F♯", "C♯"]
        let minor = ["Ab", "Eb", "Bb", "F", "C", "G", "D", "A", "E", "B", "F♯", "C♯", "G♯", "D♯", "A♯"]
        let i = min(14, max(0, fifths + 7))
        func fix(_ s: String) -> String { s.replacingOccurrences(of: "b", with: "♭") }
        return "\(fix(major[i])) major / \(fix(minor[i])) minor"
    }

    /// Spells a MIDI pitch for a key: (letter 0…6, alteration, diatonic step).
    static func spell(_ midi: Int, fifths: Int) -> (letter: Int, acc: Int, step: Int) {
        let sig = signature(fifths)
        let pc = ((midi % 12) + 12) % 12
        var found: (Int, Int)?
        for l in 0..<7 where (naturalPC[l] + sig[l] + 12) % 12 == pc { found = (l, sig[l]); break }        // in the key
        if found == nil { for l in 0..<7 where naturalPC[l] == pc { found = (l, 0); break } }              // a natural the key alters
        if found == nil {
            let sharps: Bool
            if fifths == 0 { sharps = [1, 6].contains(pc) } else { sharps = fifths > 0 }
            if sharps { for l in 0..<7 where naturalPC[l] == (pc + 11) % 12 { found = (l, 1); break } }
            else { for l in 0..<7 where naturalPC[l] == (pc + 1) % 12 { found = (l, -1); break } }
        }
        let (l, a) = found ?? (0, 0)
        let natural = midi - a
        let octave = Int((Double(natural) / 12).rounded(.down)) - 1
        return (l, a, octave * 7 + l)
    }

    /// MIDI pitch for a diatonic step as written in a key (the key signature's alteration applies).
    static func midi(forStep step: Int, fifths: Int, alter: Int = 0) -> Int {
        let l = ((step % 7) + 7) % 7, octave = Int((Double(step) / 7).rounded(.down))
        return (octave + 1) * 12 + naturalPC[l] + signature(fifths)[l] + alter
    }

    // MARK: Drum staff

    /// Where a General MIDI drum sits on the five-line percussion staff, and what its notehead looks like.
    static func drumPosition(_ p: Int) -> (step: Int, head: NoteHead) {
        switch p {
        case 35, 36: return (31, .normal)            // kick: bottom space
        case 37: return (35, .x)                     // side stick
        case 38, 40: return (35, .normal)            // snare: third space
        case 39: return (35, .x)                     // clap
        case 41: return (32, .normal)                // low floor tom
        case 43: return (33, .normal)                // high floor tom
        case 45, 47: return (36, .normal)            // low toms
        case 48, 50: return (37, .normal)            // high toms
        case 42: return (39, .x)                     // closed hi-hat
        case 44: return (29, .x)                     // pedal hi-hat
        case 46: return (39, .diamond)               // open hi-hat
        case 49: return (40, .x)                     // crash
        case 57: return (41, .x)                     // crash 2
        case 51, 59: return (38, .x)                 // ride
        case 53: return (38, .diamond)               // ride bell
        case 52, 55: return (41, .x)                 // china, splash
        case 56: return (37, .diamond)               // cowbell
        case 54: return (36, .x)                     // tambourine
        default: return (28 + (p % 12) % 11, .x)
        }
    }
    static func drumPitch(forStep step: Int) -> Int? {
        let table = [31: 36, 35: 38, 32: 41, 33: 43, 36: 45, 37: 48, 39: 42, 29: 44, 40: 49, 38: 51]
        return table[step]
    }
    /// Feet voices (kick, pedal hat) get downward stems.
    static func isFootDrum(_ p: Int) -> Bool { p == 35 || p == 36 || p == 44 }

    // MARK: Building a score

    private struct Item { var id: UUID; var midi: Int; var qs: Double; var qe: Double }

    static func chooseClef(_ notes: [Note], mode: ScoreClefMode, drums: Bool) -> [Clef] {
        if drums { return [.percussion] }
        switch mode {
        case .treble: return [.treble]
        case .bass: return [.bass]
        case .grand: return [.treble, .bass]
        case .auto:
            guard let lo = notes.map({ $0.pitch }).min(), let hi = notes.map({ $0.pitch }).max() else { return [.treble] }
            if lo < 57 && hi >= 64 && hi - lo >= 12 { return [.treble, .bass] }
            let avg = Double(notes.map { $0.pitch }.reduce(0, +)) / Double(notes.count)
            return [avg < 55 ? .bass : .treble]
        }
    }

    static func build(notes: [Note], length: Double, num: Int, den: Int, fifths: Int,
                      clefMode: ScoreClefMode, drums: Bool, resolution res: Double) -> NScore {
        let bpb = beatsPerBar(num: num, den: den)
        let g = group(num: num, den: den)
        func q(_ x: Double) -> Double { (x / res).rounded() * res }
        var items: [Item] = notes.map { n in
            let s = max(0, q(n.start))
            return Item(id: n.id, midi: n.pitch, qs: s, qe: max(s + res, q(n.end)))
        }
        let maxEnd = max(length, items.map { $0.qe }.max() ?? 0)
        let measureCount = max(1, Int(ceil(maxEnd / bpb - 1e-6)))
        let clefs = chooseClef(notes, mode: clefMode, drums: drums)
        if drums { items = drumDurations(items, group: g, res: res) }

        var staves: [NStaff] = []
        for (ci, clef) in clefs.enumerated() {
            var staffItems = items
            if clefs.count == 2 { staffItems = items.filter { ci == 0 ? $0.midi >= 60 : $0.midi < 60 } }
            var events: [NEvent] = []
            if drums {
                let hands = staffItems.filter { !isFootDrum($0.midi) }, feet = staffItems.filter { isFootDrum($0.midi) }
                events += makeEvents(hands, voice: 0, measureCount: measureCount, bpb: bpb, group: g, fifths: fifths, drums: true, showRests: true)
                if !feet.isEmpty { events += makeEvents(feet, voice: 1, measureCount: measureCount, bpb: bpb, group: g, fifths: fifths, drums: true, showRests: false) }
            } else {
                events = makeEvents(staffItems, voice: 0, measureCount: measureCount, bpb: bpb, group: g, fifths: fifths, drums: false, showRests: true)
            }
            events.sort { ($0.start, $0.voice) < ($1.start, $1.voice) }
            staves.append(NStaff(clef: clef, events: finish(events, clef: clef, group: g, bpb: bpb)))
        }
        return NScore(staves: staves, measureCount: measureCount, beatsPerBar: bpb, timeNum: num, timeDen: den, fifths: fifths, group: g)
    }

    /// Drum hits are written as lasting until the next hit in their voice or the next beat line, whatever MIDI length they have.
    private static func drumDurations(_ items: [Item], group g: Double, res: Double) -> [Item] {
        func fix(_ list: [Item]) -> [Item] {
            let onsets = Array(Set(list.map { $0.qs })).sorted()
            return list.map { it in
                let next = onsets.first { $0 > it.qs + 1e-6 }
                var c = it
                let nextBeat = (it.qs / g + 1e-6).rounded(.down) * g + g        // a hit doesn't last past the next beat line
                c.qe = max(it.qs + res, min(next ?? .infinity, nextBeat))
                return c
            }
        }
        return fix(items.filter { !isFootDrum($0.midi) }) + fix(items.filter { isFootDrum($0.midi) })
    }

    /// Cuts time at every note edge and bar line, makes a chord (or rest) of what sounds in each slice,
    /// and splits long slices into standard values joined by ties.
    private static func makeEvents(_ items: [Item], voice: Int, measureCount: Int, bpb: Double, group g: Double,
                                   fifths: Int, drums: Bool, showRests: Bool) -> [NEvent] {
        var cuts = Set<Double>([0, Double(measureCount) * bpb])
        for i in items { cuts.insert(i.qs); cuts.insert(i.qe) }
        for m in 0...measureCount { cuts.insert(Double(m) * bpb) }
        let times = cuts.filter { $0 <= Double(measureCount) * bpb + 1e-6 }.sorted()
        let sig = signature(fifths)
        var events: [NEvent] = []
        var accState: [Int: Int] = [:]
        var stateMeasure = -1

        for k in 0..<(times.count - 1) {
            let a = times[k], b = times[k + 1]
            if b - a < 1e-6 { continue }
            let measure = Int((a + 1e-6) / bpb)
            let barStart = Double(measure) * bpb
            if measure != stateMeasure { accState = [:]; stateMeasure = measure }
            let active = items.filter { $0.qs <= a + 1e-6 && $0.qe >= b - 1e-6 }
            if active.isEmpty {
                if !showRests { continue }
                if abs(a - barStart) < 1e-6 && abs(b - (barStart + bpb)) < 1e-6 {
                    events.append(NEvent(start: a, dur: bpb, base: 0, dots: 0, pitches: [], voice: voice, measure: measure, fullBar: true))
                    continue
                }
                for p in splitDuration(pos: a - barStart, length: b - a, group: g) {
                    events.append(NEvent(start: barStart + p.pos, dur: p.dur, base: p.base, dots: p.dots, pitches: [], voice: voice, measure: measure))
                }
                continue
            }
            // one notehead per distinct pitch
            var seen = Set<Int>()
            let uniq = active.filter { seen.insert($0.midi).inserted }
            let pieces = splitDuration(pos: a - barStart, length: b - a, group: g)
            for (pi, p) in pieces.enumerated() {
                var heads: [NPitch] = []
                for it in uniq {
                    var np: NPitch
                    if drums {
                        let pos = drumPosition(it.midi)
                        np = NPitch(midi: it.midi, step: pos.step, acc: 0, head: pos.head, noteID: it.id)
                    } else {
                        let sp = spell(it.midi, fifths: fifths)
                        np = NPitch(midi: it.midi, step: sp.step, acc: sp.acc, noteID: it.id)
                    }
                    np.tiePrev = pi > 0 || it.qs < a - 1e-6
                    np.tieNext = pi < pieces.count - 1 || it.qe > b + 1e-6
                    heads.append(np)
                }
                heads.sort { $0.step < $1.step }
                if !drums {
                    for i in heads.indices {
                        let letter = ((heads[i].step % 7) + 7) % 7
                        let current = accState[heads[i].step] ?? sig[letter]
                        if heads[i].tiePrev { continue }          // a tied note keeps the sign it was written with
                        if heads[i].acc != current { heads[i].showAcc = true }
                        accState[heads[i].step] = heads[i].acc
                    }
                }
                events.append(NEvent(start: barStart + p.pos, dur: p.dur, base: p.base, dots: p.dots, pitches: heads, voice: voice, measure: measure))
            }
        }
        return events
    }

    /// Stem directions and beam groups.
    private static func finish(_ input: [NEvent], clef: Clef, group g: Double, bpb: Double) -> [NEvent] {
        var events = input
        // stems
        for i in events.indices where !events[i].isRest {
            if clef == .percussion && events[i].voice == 1 { events[i].stemUp = false; continue }
            if clef == .percussion { events[i].stemUp = true; continue }
            let mid = clef.middleStep
            let far = events[i].pitches.map { $0.step }.max { abs($0 - mid) < abs($1 - mid) } ?? mid
            events[i].stemUp = far < mid
        }
        // beams: runs of adjacent eighth-or-shorter notes inside one group, per voice
        var nextID = 0
        for voice in Set(events.map { $0.voice }) {
            let idx = events.indices.filter { events[$0].voice == voice }
            var run: [Int] = []
            func flush() {
                if run.count >= 2 {
                    let id = nextID; nextID += 1
                    for r in run { events[r].beamID = id }
                    // one direction per beam: follow the majority (the note farthest from the middle line)
                    if clef != .percussion {
                        let mid = clef.middleStep
                        let total = run.reduce(0) { acc, r in
                            let far = events[r].pitches.map { $0.step }.max { abs($0 - mid) < abs($1 - mid) } ?? mid
                            return acc + (far - mid)
                        }
                        for r in run { events[r].stemUp = total < 0 }
                    }
                }
                run = []
            }
            for i in idx {
                let e = events[i]
                let beamable = !e.isRest && e.base >= 3
                if !beamable { flush(); continue }
                if let last = run.last {
                    let prev = events[last]
                    let sameGroup = Int((prev.start - Double(prev.measure) * bpb + 1e-6) / g) == Int((e.start - Double(e.measure) * bpb + 1e-6) / g) && prev.measure == e.measure
                    if abs(prev.end - e.start) > 1e-6 || !sameGroup { flush() }
                }
                run.append(i)
            }
            flush()
        }
        return events
    }
}
