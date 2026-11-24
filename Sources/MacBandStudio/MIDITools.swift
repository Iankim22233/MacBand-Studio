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

    /// Links the chosen notes into one slide, or takes a linked slide apart again.
    ///
    /// A slide note glides the note that is sounding when it starts to its own pitch, so a run of glides needs one long note
    /// underneath. Linking turns the first chosen note into that long note (it is stretched to the end of the last one) and the
    /// rest into slide notes, in time order, each starting where it already was: the pitch then travels from note to note.
    /// Of notes that start together (a chord) only the highest is used. Notes that overlap the next one are shortened so each
    /// glide ends where the next begins.
    ///
    /// If every chosen note starts at the same moment (for example a note with a slide placed on top of it), the one that was
    /// drawn first is the note that sounds, and the second glides from it to its own pitch.
    /// Returns true when linked, false when unlinked, nil when fewer than two notes can be linked.
    @discardableResult
    static func toggleSlideLink(_ notes: inout [Note], ids: Set<UUID>) -> Bool? {
        let inOrder = notes.indices.filter { ids.contains(notes[$0].id) }                 // the order they were drawn in
        guard inOrder.count >= 2 else { return nil }
        let sameStart = inOrder.allSatisfy { abs(notes[$0].start - notes[inOrder[0]].start) < 1e-6 }
        var chain: [Int]
        if sameStart {
            chain = Array(inOrder.prefix(2))
        } else {
            chain = []
            let byTime = inOrder.sorted { (notes[$0].start, -notes[$0].pitch) < (notes[$1].start, -notes[$1].pitch) }
            for i in byTime where chain.last.map({ notes[i].start > notes[$0].start + 1e-6 }) ?? true { chain.append(i) }
        }
        guard chain.count >= 2 else { return nil }
        let anchor = chain[0], rest = Array(chain.dropFirst())

        if rest.allSatisfy({ notes[$0].isSlide }) {                       // already linked: take it apart
            for i in rest { notes[i].isSlide = false }
            let firstSlideStart = notes[rest[0]].start
            if notes[anchor].end > firstSlideStart + 1e-6, firstSlideStart > notes[anchor].start + 1e-6 {
                notes[anchor].length = max(0.0625, firstSlideStart - notes[anchor].start)
            }
            return false
        }
        notes[anchor].isSlide = false
        for (k, i) in rest.enumerated() {
            notes[i].isSlide = true
            let nextStart = k + 1 < rest.count ? notes[rest[k + 1]].start : Double.infinity
            if notes[i].end > nextStart - 1e-6 { notes[i].length = max(0.0625, nextStart - notes[i].start) }
        }
        let last = notes[rest[rest.count - 1]]
        notes[anchor].length = max(notes[anchor].length, last.end - notes[anchor].start)
        return true
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

    /// Transitions between notes, picked by pitch: of the notes within `window` beats, the ones whose pitch is closest to a chosen
    /// note's (a note of the very same pitch has nothing to glide, so it is passed over; of several notes of one pitch the nearest
    /// in time is used). Each glide is a slide note over the tail of the note that does the gliding, `glide` beats long, reaching
    /// the other note's pitch just as that note ends or the next begins. The slide is tied to the note it glides, so it still
    /// glides that one when other notes sound at the same time.
    ///
    /// `after == false` ("Slide to Note"): the closest notes before the chosen one slide into it; when two are equally close (one
    /// above and one below, say) both slide to it. `after == true` ("Slide After Note"): the chosen note slides on to the closest note
    /// after it; when two are equally close the earlier one is used (one note can only glide one way at a time).
    /// A note that already has a slide is left as it is. Returns how many slides were added.
    @discardableResult
    static func transition(_ notes: inout [Note], ids: Set<UUID>, after: Bool, glide: Double, window: Double = 4) -> Int {
        let chosen = notes.filter { ids.contains($0.id) && !$0.isSlide }.sorted { $0.start < $1.start }
        var added: [Note] = []
        func hasSlide(_ n: Note) -> Bool {
            (notes + added).contains { $0.isSlide && $0.start >= n.start - 1e-6 && $0.start < n.end - 1e-6 && ($0.slideBase == nil || $0.slideBase == n.id) }
        }
        func slide(on base: Note, to pitch: Int, before limit: Double) {
            let end = min(base.end, limit)
            guard end > base.start + 1e-6, !hasSlide(base) else { return }
            let g = max(1.0 / 32, min(glide, (end - base.start) / 2))
            var s = Note(pitch: pitch, start: end - g, length: g, velocity: base.velocity, isSlide: true)
            s.slideBase = base.id
            added.append(s)
        }
        /// One note for each pitch: the nearest in time to the chosen note (`later` picks the earliest after it, else the latest before it).
        func onePerPitch(_ ns: [Note], later: Bool) -> [Note] {
            var best: [Int: Note] = [:]
            for n in ns {
                if let cur = best[n.pitch], later ? cur.start <= n.start : cur.start >= n.start { continue }
                best[n.pitch] = n
            }
            return Array(best.values)
        }
        for t in chosen {
            let others = notes.filter { !$0.isSlide && $0.id != t.id && $0.pitch != t.pitch }
            if after {
                let later = onePerPitch(others.filter { $0.start > t.start + 1e-6 && $0.start <= t.start + window }, later: true)
                guard let d = later.map({ abs($0.pitch - t.pitch) }).min() else { continue }
                let u = later.filter { abs($0.pitch - t.pitch) == d }.min { ($0.start, $0.pitch) < ($1.start, $1.pitch) }!
                slide(on: t, to: u.pitch, before: u.start)
            } else {
                let earlier = onePerPitch(others.filter { $0.start < t.start - 1e-6 && $0.start >= t.start - window }, later: false)
                guard let d = earlier.map({ abs($0.pitch - t.pitch) }).min() else { continue }
                for src in earlier where abs(src.pitch - t.pitch) == d { slide(on: src, to: t.pitch, before: t.start) }
            }
        }
        notes += added
        return added.count
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
    /// The Slide button and the S key. Two or more notes selected: link them into one slide (or unlink them again). One selected
    /// note: make it a slide note or a normal note. Nothing selected: new notes are drawn as slide notes (or not).
    func slideAction() {
        guard !selectedNoteIDs.isEmpty, let loc = selectedClipLocation else { slideMode.toggle(); return }
        let ids = selectedNoteIDs
        var notes = project.tracks[loc.track].clips[loc.clip].notes
        if ids.count == 1 {
            for i in notes.indices where ids.contains(notes[i].id) { notes[i].isSlide.toggle() }
            edit { $0.tracks[loc.track].clips[loc.clip].notes = notes }
            return
        }
        switch MIDITools.toggleSlideLink(&notes, ids: ids) {
        case .none: showToast("Select two or more notes to link them into a slide")
        case .some(let linked):
            edit { p in
                p.tracks[loc.track].clips[loc.clip].notes = notes
                p.tracks[loc.track].clips[loc.clip].fitLengthToNotes(minBeats: p.beatsPerBar, quantum: p.beatsPerBar)
            }
            showToast(linked ? "Linked \(ids.count) notes into a slide" : "Unlinked the slide")
        }
    }

    /// The Slide transition panel in the Inspector: makes the glide into (`after == false`) or out of (`after == true`) each selected
    /// note, `beats` long.
    func transitionAction(after: Bool, beats: Double) {
        guard let loc = selectedClipLocation, !selectedNoteIDs.isEmpty else { showToast("Select a note in the piano roll first"); return }
        var notes = project.tracks[loc.track].clips[loc.clip].notes
        let made = MIDITools.transition(&notes, ids: selectedNoteIDs, after: after, glide: beats)
        guard made > 0 else {
            showToast(after ? "No other note within 4 beats after it to slide to (or it already slides)" : "No other note within 4 beats before it to slide from (or it already slides)")
            return
        }
        edit { $0.tracks[loc.track].clips[loc.clip].notes = notes }
        showToast(after ? "The note slides on to the nearest note by pitch" : (made == 1 ? "The nearest note by pitch slides into it" : "\(made) equally near notes slide into it"))
    }

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

        // transitions picked by pitch
        do {
            func slides(_ n: [Note]) -> [Note] { n.filter { $0.isSlide }.sorted { $0.start < $1.start } }
            let lo = N(60, 0, 1), hi = N(64, 1, 1), far = N(80, 2, 1), target = N(62, 3, 1)
            var tie = [lo, hi, far, target]
            let made = MIDITools.transition(&tie, ids: [target.id], after: false, glide: 0.25)
            let sl = slides(tie)
            check(made == 2 && sl.count == 2 && sl.allSatisfy { $0.pitch == 62 }, "slide to note: two notes equally near in pitch (60 and 64 → 62) both slide to it")
            check(abs(sl[0].end - 1) < 1e-9 && abs(sl[1].end - 2) < 1e-9 && sl[0].start >= 0 && sl[1].start >= 1, "…each over the tail of its own note, arriving as that note ends")
            var one = [N(60, 0, 1), N(67, 1, 1), N(62, 3, 1)]
            let t1 = one[2].id
            check(MIDITools.transition(&one, ids: [t1], after: false, glide: 0.25) == 1 && slides(one).first?.pitch == 62 && slides(one).first!.end <= 1 + 1e-9, "slide to note: only the nearest in pitch slides (60, not 67)")
            var again = one
            check(MIDITools.transition(&again, ids: [t1], after: false, glide: 0.25) == 0, "…and a note that already slides is left alone")
            var nxt = [N(64, 0, 1), N(80, 1, 1), N(62, 2, 1), N(66, 3, 1)]
            let src = nxt[0].id
            check(MIDITools.transition(&nxt, ids: [src], after: true, glide: 0.25) == 1, "slide after note: the note gets one slide")
            let got = slides(nxt)
            check(got.first?.pitch == 62 && abs((got.first?.end ?? 0) - 1) < 1e-9, "…to the nearest in pitch after it (62 and 66 tie; the earlier one, 62, wins), over its tail")
            // chords: the slide glides the note it was made for, not whichever note sounds at the time
            var chord = [N(48, 0, 4), N(72, 0, 4), N(50, 4, 1)]
            check(MIDITools.transition(&chord, ids: [chord[2].id], after: false, glide: 0.25) == 1, "slide to note under a chord: one slide (from the 48, the nearest to 50)")
            let cs = chord.first { $0.isSlide }!
            let normalsC = chord.filter { !$0.isSlide }.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
            check(Note.source(of: cs, normals: normalsC)?.pitch == 48, "…and it glides the 48, even though the 72 sounds then too")
            var loose = cs; loose.slideBase = nil
            check(Note.source(of: loose, normals: normalsC)?.pitch == 72, "(without that tie the slide would have picked the 72 and gone from the top)")
            var ctr = Track(name: "t", colorIndex: 0); var ccl = Clip(name: "c", start: 0, length: 16); ccl.notes = chord; ctr.clips = [ccl]; ctr.bendRange = 12
            let cev = MIDIFile.trackEvents(ctr, channel: 0, forExport: false).filter { $0.bytes.first == 0xE0 }
            let cpeak = cev.map { (Double(Int($0.bytes[1]) | (Int($0.bytes[2]) << 7)) - 8192) / 8192 * 12 }.max() ?? 0
            let clow = cev.map { (Double(Int($0.bytes[1]) | (Int($0.bytes[2]) << 7)) - 8192) / 8192 * 12 }.min() ?? 0
            check(abs(cpeak - 2) < 0.05 && clow > -0.05, String(format: "played back, the glide goes up 2 semitones from the 48 to 50, not down from the 72 (%.2f / %.2f)", cpeak, clow))
            var dup = [N(60, 0, 0.75), N(60, 1, 0.75), N(62, 1.75, 0.25)]
            check(MIDITools.transition(&dup, ids: [dup[2].id], after: false, glide: 0.25) == 1, "two notes of the same pitch count as one: the nearer in time slides")
            var distant = [N(60, 0, 1), N(62, 20, 1)]
            check(MIDITools.transition(&distant, ids: [distant[1].id], after: false, glide: 0.25) == 0, "a note more than 4 beats away is out of reach")
            check(abs(SlideTransitionPanel.beats(forSpeed: 0) - 1) < 1e-9 && abs(SlideTransitionPanel.beats(forSpeed: 1) - 1.0 / 32) < 1e-9, "the speed slider runs from a whole beat to a 32nd")
            var same = [N(60, 0, 1), N(60, 1, 1)]
            check(MIDITools.transition(&same, ids: [same[1].id], after: false, glide: 0.25) == 0, "a note of the same pitch has nothing to glide")
            var lonely = [N(60, 0, 1)]
            check(MIDITools.transition(&lonely, ids: [lonely[0].id], after: true, glide: 0.25) == 0, "nothing after it, nothing happens")
        }

        var ar = [N(60, 0, 2), N(64, 0, 2), N(67, 0, 2)]
        MIDITools.arpeggiate(&ar, ids: nil, step: 0.5)
        check(ar.sorted { $0.pitch < $1.pitch }.map { $0.start } == [0, 0.5, 1.0], "arpeggiate spreads a chord upward")

        var r = [N(60, 0, 1), N(62, 1, 1), N(64, 2, 2)]
        MIDITools.reverse(&r, ids: nil)
        check(r.first { $0.pitch == 64 }!.start == 0 && r.first { $0.pitch == 60 }!.start == 3, "reverse mirrors the notes in time")
 // (slide linking is checked just below)
        // linking notes into one slide
        func S(_ p: Int, _ s: Double, _ l: Double) -> Note { Note(pitch: p, start: s, length: l) }
        var sl = [S(60, 0, 1), S(62, 1, 1), S(64, 2, 1), S(65, 3, 1), S(72, 8, 1)]
        let picked = Set(sl.prefix(4).map { $0.id })
        let linked = MIDITools.toggleSlideLink(&sl, ids: picked)
        check(linked == true, "linking four notes into a slide works")
        check(!sl[0].isSlide && sl[1...3].allSatisfy { $0.isSlide } && !sl[4].isSlide, "the first stays a normal note, the next three become slide notes, others are left alone")
        check(abs(sl[0].length - 4) < 1e-9, "the first note is stretched to cover the whole run (\(sl[0].length) beats)")
        check(sl[1...3].map { $0.start } == [1, 2, 3] && sl[1...3].allSatisfy { $0.length == 1 } && sl.map { $0.pitch } == [60, 62, 64, 65, 72], "the slides keep their place, length and pitch")
        // played back: one note, and the pitch bend travels 0 → +2 → +4 → +5 semitones
        var tr = Track(name: "t", colorIndex: 0); var cl = Clip(name: "c", start: 0, length: 16); cl.notes = sl; tr.clips = [cl]; tr.bendRange = 12
        let evs = MIDIFile.trackEvents(tr, channel: 0, forExport: false)
        let ons = evs.filter { $0.bytes.first == 0x90 }
        check(ons.count == 2 && ons.map { Int($0.bytes[1]) }.sorted() == [60, 72], "played back, the run is a single note (60) plus the separate one")
        let bends = evs.filter { $0.bytes.first == 0xE0 }.sorted { $0.tick < $1.tick }
        func semis(_ e: MIDIFile.Ev) -> Double { (Double(Int(e.bytes[1]) | (Int(e.bytes[2]) << 7)) - 8192) / 8192 * 12 }
        let peak = bends.map { semis($0) }.max() ?? 0
        check(abs(peak - 5) < 0.05, String(format: "the pitch glides from note to note up to +5 semitones (%.2f)", peak))
        let at2 = bends.filter { Double($0.tick) / 480 <= 3.0 + 1e-6 }.last.map { semis($0) } ?? -99
        check(abs(at2 - 4) < 0.05, String(format: "…reaching +4 as the third note ends (%.2f)", at2))
        let unlinked = MIDITools.toggleSlideLink(&sl, ids: picked)
        check(unlinked == false && sl.allSatisfy { !$0.isSlide } && abs(sl[0].length - 1) < 1e-9, "doing it again unlinks them and gives the first note its own length back")
        var one = [S(60, 0, 1)]
        check(MIDITools.toggleSlideLink(&one, ids: Set(one.map { $0.id })) == nil, "one note alone can't be linked")
        var chord = [S(60, 0, 1), S(67, 0, 1), S(62, 1, 1), S(64, 2, 1)]
        MIDITools.toggleSlideLink(&chord, ids: Set(chord.map { $0.id }))
        check(chord[1].pitch == 67 && !chord[1].isSlide && abs(chord[1].length - 3) < 1e-9 && chord[2].isSlide && chord[3].isSlide
              && chord[0].pitch == 60 && !chord[0].isSlide && chord[0].length == 1, "of notes that start together only the highest takes part; the other keeps its own place and length")
        // two notes on the same beat (a slide placed on top of its note): the first drawn sounds, the second glides from it
        var stacked = [S(60, 0, 1), S(67, 0, 2)]
        check(MIDITools.toggleSlideLink(&stacked, ids: Set(stacked.map { $0.id })) == true, "two notes that start together link too")
        check(!stacked[0].isSlide && stacked[1].isSlide && abs(stacked[0].length - 2) < 1e-9 && stacked[1].start == 0 && stacked[1].length == 2, "the first drawn stays the sounding note (stretched under the glide), the second glides to its pitch")
        var stackedTrack = Track(name: "t", colorIndex: 0); var stackedClip = Clip(name: "c", start: 0, length: 8); stackedClip.notes = stacked; stackedTrack.clips = [stackedClip]; stackedTrack.bendRange = 12
        let stackedEvs = MIDIFile.trackEvents(stackedTrack, channel: 0, forExport: false)
        check(stackedEvs.filter { $0.bytes.first == 0x90 }.count == 1 && (stackedEvs.filter { $0.bytes.first == 0xE0 }.map { semis($0) }.max() ?? 0) > 6.9, "…and plays as one note gliding up seven semitones")
        check(MIDITools.toggleSlideLink(&stacked, ids: Set(stacked.map { $0.id })) == false && stacked.allSatisfy { !$0.isSlide } && stacked[1].length == 2, "…and unlinks again (both normal notes, nothing else changed)")
        var over = [S(60, 0, 3), S(62, 1, 3), S(64, 2, 3)]
        MIDITools.toggleSlideLink(&over, ids: Set(over.map { $0.id }))
        check(over[1].length == 1 && abs(over[0].length - 5) < 1e-9, "a note that runs over the next one is shortened so each glide ends where the next begins")
        // Slides reach their notes even when they travel further than the track's slide range.
        do {
            var tr = Track(name: "t", colorIndex: 0); tr.bendRange = 2
            var cl = Clip(name: "c", start: 0, length: 8)
            cl.notes = [Note(pitch: 60, start: 0, length: 4), Note(pitch: 67, start: 1, length: 1, isSlide: true), Note(pitch: 84, start: 2, length: 1, isSlide: true)]
            tr.clips = [cl]
            let range = MIDIFile.effectiveBendRange(tr)
            check(range == 24, "a slide of 24 semitones widens a range of 2 to 24 (got \(range))")
            let evs = MIDIFile.trackEvents(tr, channel: 0, forExport: false)
            let bends = evs.filter { $0.bytes.first == 0xE0 }.sorted { $0.tick < $1.tick }
            func semis(_ e: MIDIFile.Ev) -> Double { Double((Int(e.bytes[2]) << 7 | Int(e.bytes[1])) - 8192) / 8192 * Double(range) }
            let atEnd = bends.last { $0.tick <= MIDIFile.ticks(3) }
            check(atEnd != nil && abs(semis(atEnd!) - 24) < 0.05, "the last slide ends on its note (+24 semitones)")
            let rpn = evs.first { $0.bytes.count == 3 && $0.bytes[1] == 6 }
            check(rpn?.bytes[2] == 24, "the bend range sent to the instrument is the widened one")
            tr.bendRange = 12
            check(MIDIFile.effectiveBendRange(tr) == 24 && { var t2 = tr; t2.clips[0].notes.removeLast(); return MIDIFile.effectiveBendRange(t2) == 12 }(), "the range is only widened when a slide needs it")
        }

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
