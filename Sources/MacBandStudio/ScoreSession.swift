import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum ScoreTool: String, CaseIterable, Identifiable {
    case select = "Select", draw = "Note", erase = "Erase"
    var id: String { rawValue }
    var icon: String {
        switch self { case .select: return "cursorarrow"; case .draw: return "music.note"; case .erase: return "eraser" }
    }
}

extension Session {
    /// Key signature in use: the override, or the one that matches the project's key.
    var scoreFifths: Int { scoreKey ?? Notation.fifths(root: project.keyRoot, scale: project.scale) }

    /// Written length of a newly drawn note.
    var scoreLength: Double { scoreNoteLength * (scoreDotted ? 1.5 : 1) }

    /// The score of the selected pattern.
    func currentScore() -> (score: NScore, track: Track, clip: Clip)? {
        guard let loc = selectedClipLocation else { return nil }
        let t = project.tracks[loc.track], c = t.clips[loc.clip]
        let sc = Notation.build(notes: c.notes, length: c.length, num: project.timeSigNum, den: project.timeSigDen,
                                fifths: scoreFifths, clefMode: scoreClef, drums: t.instrument.isDrums, resolution: scoreResolution)
        return (sc, t, c)
    }

    private func editClip(_ body: (inout Clip) -> Void) {
        guard let loc = selectedClipLocation else { return }
        modify { p in
            body(&p.tracks[loc.track].clips[loc.clip])
            p.tracks[loc.track].clips[loc.clip].fitLengthToNotes(minBeats: p.beatsPerBar, quantum: p.beatsPerBar)
        }
    }

    /// Adds a note at `start` (pattern-relative beats) and selects it.
    @discardableResult
    func scoreAddNote(pitch: Int, start: Double, length: Double) -> UUID? {
        guard selectedClipLocation != nil, (0...127).contains(pitch) else { return nil }
        let n = Note(pitch: pitch, start: max(0, start), length: length, velocity: lastVelocity)
        pushUndo()
        editClip { $0.notes.append(n) }
        selectedNoteIDs = [n.id]
        return n.id
    }

    func scoreDeleteSelected() {
        guard !selectedNoteIDs.isEmpty else { return }
        let sel = selectedNoteIDs
        pushUndo()
        editClip { $0.notes.removeAll { sel.contains($0.id) } }
        selectedNoteIDs = []
    }

    func scoreTransposeSelected(semitones: Int, pushUndoFirst: Bool = true) {
        guard !selectedNoteIDs.isEmpty else { return }
        let sel = selectedNoteIDs
        if pushUndoFirst { pushUndo() }
        editClip { c in for i in c.notes.indices where sel.contains(c.notes[i].id) { c.notes[i].pitch = min(127, max(0, c.notes[i].pitch + semitones)) } }
    }

    func scoreMoveSelected(by beats: Double) {
        guard !selectedNoteIDs.isEmpty else { return }
        let sel = selectedNoteIDs
        pushUndo()
        editClip { c in for i in c.notes.indices where sel.contains(c.notes[i].id) { c.notes[i].start = max(0, c.notes[i].start + beats) } }
    }

    func scoreSetLength(_ beats: Double) {
        let sel = selectedNoteIDs
        guard !sel.isEmpty else { return }
        pushUndo()
        editClip { c in for i in c.notes.indices where sel.contains(c.notes[i].id) { c.notes[i].length = beats } }
    }

    /// Applies a drag: every selected note goes back to its original value shifted by the given steps / beats.
    func scoreApplyDrag(originals: [UUID: Note], stepDelta: Int, beatDelta: Double, fifths: Int, drums: Bool) {
        editClip { c in
            for i in c.notes.indices {
                guard let o = originals[c.notes[i].id] else { continue }
                var n = o
                if stepDelta != 0 {
                    if drums {
                        let step = Notation.drumPosition(o.pitch).step + stepDelta
                        if let p = Notation.drumPitch(forStep: step) { n.pitch = p }
                    } else {
                        let sp = Notation.spell(o.pitch, fifths: fifths)
                        let alter = sp.acc - Notation.signature(fifths)[sp.letter]
                        n.pitch = min(127, max(0, Notation.midi(forStep: sp.step + stepDelta, fifths: fifths, alter: alter)))
                    }
                }
                n.start = max(0, o.start + beatDelta)
                c.notes[i] = n
            }
        }
    }
}
