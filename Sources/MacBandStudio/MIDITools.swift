import Foundation
import SwiftUI

/// Editing operations on a pattern's notes. `ids == nil` means every note; otherwise only those notes change.
enum MIDITools {
    private static func applies(_ n: Note, _ ids: Set<UUID>?) -> Bool { ids == nil || ids!.contains(n.id) }

    /// Moves note starts toward the grid. `strength` 1 snaps fully, 0.5 goes halfway.
    static func quantize(_ notes: inout [Note], ids: Set<UUID>?, grid: Double, strength: Double, lengths: Bool) {
        guard grid > 0 else { return }
        for i in notes.indices where applies(notes[i], ids) {
            let snapped = max(0, (notes[i].start / grid).rounded() * grid)
            notes[i].start = notes[i].start + (snapped - notes[i].start) * strength
            if lengths {
                let l = max(grid, (notes[i].length / grid).rounded() * grid)
                notes[i].length = notes[i].length + (l - notes[i].length) * strength
            }
        }
    }

    /// Swing: notes on the off-beat grid positions are delayed. `amount` 1 = triplet feel (a third of the grid).
    static func swing(_ notes: inout [Note], ids: Set<UUID>?, grid: Double, amount: Double) {
        guard grid > 0 else { return }
        for i in notes.indices where applies(notes[i], ids) {
            let k = (notes[i].start / grid).rounded()
            guard abs(notes[i].start - k * grid) < grid * 0.25, Int(k) % 2 == 1 else { continue }
            notes[i].start += grid * amount / 3
        }
    }

    /// Random small shifts of timing and velocity so programmed parts feel played.
    static func humanize(_ notes: inout [Note], ids: Set<UUID>?, timing: Double, velocity: Int, seed: UInt64 = 0) {
        var rng = SeededRNG(seed: seed == 0 ? UInt64(Date().timeIntervalSince1970 * 1000) : seed)
        for i in notes.indices where applies(notes[i], ids) {
            notes[i].start = max(0, notes[i].start + Double.random(in: -timing...timing, using: &rng))
            notes[i].velocity = min(127, max(1, notes[i].velocity + Int.random(in: -velocity...velocity, using: &rng)))
        }
    }

    /// Each note lasts until the next note starts (chords stay together).
    static func legato(_ notes: inout [Note], ids: Set<UUID>?) {
        let starts = Array(Set(notes.map { ($0.start * 1e6).rounded() / 1e6 })).sorted()
        for i in notes.indices where applies(notes[i], ids) {
            if let next = starts.first(where: { $0 > notes[i].start + 1e-6 }) { notes[i].length = next - notes[i].start }
        }
    }

    static func transpose(_ notes: inout [Note], ids: Set<UUID>?, semitones: Int) {
        for i in notes.indices where applies(notes[i], ids) { notes[i].pitch = min(127, max(0, notes[i].pitch + semitones)) }
    }

    /// Multiplies velocities (and clamps), or sets them all when `set` is given.
    static func velocity(_ notes: inout [Note], ids: Set<UUID>?, factor: Double = 1, set: Int? = nil) {
        for i in notes.indices where applies(notes[i], ids) {
            notes[i].velocity = min(127, max(1, set ?? Int((Double(notes[i].velocity) * factor).rounded())))
        }
    }

    /// Moves every note that isn't in the scale to the nearest note that is.
    static func fitToScale(_ notes: inout [Note], ids: Set<UUID>?, root: Int, scale: ScaleKind) {
        let allowed = scale.intervals
        for i in notes.indices where applies(notes[i], ids) {
            for d in 0...6 {
                if allowed.contains((((notes[i].pitch + d - root) % 12) + 12) % 12) { notes[i].pitch += d; break }
                if allowed.contains((((notes[i].pitch - d - root) % 12) + 12) % 12) { notes[i].pitch -= d; break }
            }
        }
    }

    /// Stacks extra notes above each selected note (e.g. [4, 7] makes a major triad).
    static func addChord(_ notes: inout [Note], ids: Set<UUID>?, intervals: [Int]) {
        var added: [Note] = []
        for n in notes where applies(n, ids) {
            for iv in intervals where n.pitch + iv <= 127 {
                var c = n; c.id = UUID(); c.pitch = n.pitch + iv; added.append(c)
            }
        }
        notes += added
    }

    /// Spreads each chord (notes starting together) into a run from the bottom up, one note per `step` beats.
    static func arpeggiate(_ notes: inout [Note], ids: Set<UUID>?, step: Double) {
        let groups = Dictionary(grouping: notes.indices.filter { applies(notes[$0], ids) }) { Int((notes[$0].start * 1000).rounded()) }
        for (_, idx) in groups where idx.count > 1 {
            let sorted = idx.sorted { notes[$0].pitch < notes[$1].pitch }
            let start = notes[sorted[0]].start
            let total = sorted.map { notes[$0].length }.max() ?? step
            for (k, i) in sorted.enumerated() {
                notes[i].start = start + Double(k) * step
                notes[i].length = max(step, total - Double(k) * step)
            }
        }
    }

    /// Plays the selection backwards in time.
    static func reverse(_ notes: inout [Note], ids: Set<UUID>?) {
        let sel = notes.indices.filter { applies(notes[$0], ids) }
        guard let lo = sel.map({ notes[$0].start }).min(), let hi = sel.map({ notes[$0].end }).max() else { return }
        for i in sel { notes[i].start = lo + (hi - notes[i].end) }
    }
}

struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

extension Session {
    /// Runs a note tool on the selected notes, or on the whole pattern when nothing is selected.
    func midiTool(_ body: (inout [Note], Set<UUID>?) -> Void) {
        guard let loc = selectedClipLocation else { return }
        let ids: Set<UUID>? = selectedNoteIDs.isEmpty ? nil : selectedNoteIDs
        edit { p in
            body(&p.tracks[loc.track].clips[loc.clip].notes, ids)
            p.tracks[loc.track].clips[loc.clip].fitLengthToNotes(minBeats: p.beatsPerBar, quantum: p.beatsPerBar)
        }
    }
}

enum MIDIToolsTest {
    static func run() -> Int32 {
        print("== MIDI tools test ==")
        var fails = 0
        func check(_ ok: Bool, _ m: String) { print(ok ? "  ok    \(m)" : "  FAIL  \(m)"); if !ok { fails += 1 } }
        func N(_ p: Int, _ s: Double, _ l: Double = 0.25, _ v: Int = 100) -> Note { Note(pitch: p, start: s, length: l, velocity: v) }

        var a = [N(60, 0.1), N(62, 0.6), N(64, 1.13)]
        MIDITools.quantize(&a, ids: nil, grid: 0.25, strength: 1, lengths: false)
        check(a.map { $0.start } == [0, 0.5, 1.25], "quantize snaps to the grid")
        var b = [N(60, 0.1)]
        MIDITools.quantize(&b, ids: nil, grid: 0.5, strength: 0.5, lengths: false)
        check(abs(b[0].start - 0.05) < 1e-9, "quantize at 50% goes halfway")
        var only = [N(60, 0.1), N(62, 0.1)]
        MIDITools.quantize(&only, ids: [only[0].id], grid: 0.5, strength: 1, lengths: false)
        check(only[0].start == 0 && only[1].start == 0.1, "only the selected notes change")

        var s = (0..<8).map { N(60, Double($0) * 0.5, 0.5) }
        MIDITools.swing(&s, ids: nil, grid: 0.5, amount: 1)
        check(abs(s[1].start - (0.5 + 0.5 / 3)) < 1e-9 && s[2].start == 1.0 && abs(s[3].start - (1.5 + 0.5 / 3)) < 1e-9, "swing delays the off-beat eighths a third of an eighth")
        var s0 = (0..<4).map { N(60, Double($0) * 0.5, 0.5) }
        MIDITools.swing(&s0, ids: nil, grid: 0.5, amount: 0)
        check(s0.map { $0.start } == [0, 0.5, 1, 1.5], "0% swing changes nothing")

        var h = (0..<20).map { N(60, Double($0)) }
        MIDITools.humanize(&h, ids: nil, timing: 0.05, velocity: 10, seed: 42)
        check(h.allSatisfy { abs($0.start - $0.start.rounded()) <= 0.0501 || $0.start == 0 } && h.contains { $0.start != $0.start.rounded() }, "humanize nudges timing within the limit")
        check(h.allSatisfy { (90...110).contains($0.velocity) } && Set(h.map { $0.velocity }).count > 3, "…and velocity within ±10")

        var l = [N(60, 0), N(64, 0), N(62, 1.5), N(65, 3)]
        MIDITools.legato(&l, ids: nil)
        check(l[0].length == 1.5 && l[1].length == 1.5 && l[2].length == 1.5, "legato stretches notes (and chords) to the next onset")
        check(l[3].length == 0.25, "the last note keeps its length")

        var t = [N(60, 0), N(127, 1)]
        MIDITools.transpose(&t, ids: nil, semitones: 12)
        check(t[0].pitch == 72 && t[1].pitch == 127, "transpose clamps at 127")

        var v = [N(60, 0, 0.25, 100), N(62, 1, 0.25, 50)]
        MIDITools.velocity(&v, ids: nil, factor: 1.5)
        check(v[0].velocity == 127 && v[1].velocity == 75, "velocity ×1.5 clamps at 127")
        MIDITools.velocity(&v, ids: nil, set: 90)
        check(v.allSatisfy { $0.velocity == 90 }, "set every velocity")

        var f = [N(61, 0), N(63, 1), N(66, 2), N(60, 3)]
        MIDITools.fitToScale(&f, ids: nil, root: 0, scale: .major)
        check(f.allSatisfy { ScaleKind.major.intervals.contains($0.pitch % 12) } && f[3].pitch == 60, "fit to scale moves stray notes into C major")

        var c = [N(60, 0)]
        MIDITools.addChord(&c, ids: nil, intervals: [4, 7])
        check(c.map { $0.pitch }.sorted() == [60, 64, 67] && Set(c.map { $0.id }).count == 3, "add a major chord on a note")

        var ar = [N(60, 0, 2), N(64, 0, 2), N(67, 0, 2)]
        MIDITools.arpeggiate(&ar, ids: nil, step: 0.5)
        check(ar.sorted { $0.pitch < $1.pitch }.map { $0.start } == [0, 0.5, 1.0], "arpeggiate spreads a chord upward")

        var r = [N(60, 0, 1), N(62, 1, 1), N(64, 2, 2)]
        MIDITools.reverse(&r, ids: nil)
        check(r.first { $0.pitch == 64 }!.start == 0 && r.first { $0.pitch == 60 }!.start == 3, "reverse mirrors the notes in time")
        print(fails == 0 ? "ALL MIDI TOOL CHECKS PASSED" : "\(fails) MIDI TOOL CHECK(S) FAILED")
        return fails == 0 ? 0 : 1
    }
}

/// The piano roll's Tools menu: edits the selected notes, or the whole pattern when nothing is selected.
struct RollToolsMenu: View {
    @EnvironmentObject var session: Session
    private var grid: Double { session.snap > 0 ? session.snap : 0.25 }
    private var swingGrid: Double { min(0.5, max(grid, 0.25) * 2) }
    private var scale: ScaleKind { session.project.scale == .chromatic ? .major : session.project.scale }

    var body: some View {
        Menu {
            timing
            pitch
            chords
            velocity
        } label: {
            HStack(spacing: 4) { Text("Tools"); Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
                .font(Theme.vista(11)).foregroundStyle(.white).padding(.horizontal, 8).frame(height: 24).vistaBackground()
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Edit the selected notes (or the whole pattern when nothing is selected): quantize, swing, humanize, chords, velocity…")
    }

    private func run(_ f: @escaping (inout [Note], Set<UUID>?) -> Void) { session.midiTool(f) }

    @ViewBuilder private var timing: some View {
        Section("Timing") {
            Button("Quantize 100%") { let g = grid; run { MIDITools.quantize(&$0, ids: $1, grid: g, strength: 1, lengths: false) } }
            Button("Quantize 50%") { let g = grid; run { MIDITools.quantize(&$0, ids: $1, grid: g, strength: 0.5, lengths: false) } }
            Button("Quantize Notes and Lengths") { let g = grid; run { MIDITools.quantize(&$0, ids: $1, grid: g, strength: 1, lengths: true) } }
            Button("Swing 33%") { let g = swingGrid; run { MIDITools.swing(&$0, ids: $1, grid: g, amount: 0.5) } }
            Button("Swing 66% (triplet feel)") { let g = swingGrid; run { MIDITools.swing(&$0, ids: $1, grid: g, amount: 1) } }
            Button("Humanize") { run { MIDITools.humanize(&$0, ids: $1, timing: 0.03, velocity: 8) } }
            Button("Legato") { run { MIDITools.legato(&$0, ids: $1) } }
            Button("Reverse") { run { MIDITools.reverse(&$0, ids: $1) } }
        }
    }

    @ViewBuilder private var pitch: some View {
        Section("Pitch") {
            Button("Transpose Up a Semitone") { run { MIDITools.transpose(&$0, ids: $1, semitones: 1) } }
            Button("Transpose Down a Semitone") { run { MIDITools.transpose(&$0, ids: $1, semitones: -1) } }
            Button("Transpose Up an Octave") { run { MIDITools.transpose(&$0, ids: $1, semitones: 12) } }
            Button("Transpose Down an Octave") { run { MIDITools.transpose(&$0, ids: $1, semitones: -12) } }
            Button("Fit Notes to the Scale") { let r = session.project.keyRoot, sc = scale; run { MIDITools.fitToScale(&$0, ids: $1, root: r, scale: sc) } }
        }
    }

    @ViewBuilder private var chords: some View {
        Section("Chords") {
            Button("Add Major Chord") { run { MIDITools.addChord(&$0, ids: $1, intervals: [4, 7]) } }
            Button("Add Minor Chord") { run { MIDITools.addChord(&$0, ids: $1, intervals: [3, 7]) } }
            Button("Add Seventh Chord") { run { MIDITools.addChord(&$0, ids: $1, intervals: [4, 7, 10]) } }
            Button("Add Octave") { run { MIDITools.addChord(&$0, ids: $1, intervals: [12]) } }
            Button("Arpeggiate Chords") { let g = max(0.125, grid); run { MIDITools.arpeggiate(&$0, ids: $1, step: g) } }
        }
    }

    @ViewBuilder private var velocity: some View {
        Section("Velocity") {
            Button("Louder (×1.15)") { run { MIDITools.velocity(&$0, ids: $1, factor: 1.15) } }
            Button("Softer (×0.85)") { run { MIDITools.velocity(&$0, ids: $1, factor: 0.85) } }
            Button("Set All to 100") { run { MIDITools.velocity(&$0, ids: $1, set: 100) } }
        }
    }
}
