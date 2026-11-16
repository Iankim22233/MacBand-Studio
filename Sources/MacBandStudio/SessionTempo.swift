import Foundation

/// Finding the tempo of what was played, and putting the notes on that tempo's beat grid.
extension Session {
    /// What `detectTempo` did, for the tests.
    struct TempoOutcome { var estimate: TempoEstimate; var applied: Bool }

    /// Listens to the notes of the selected track (only `ids` if given, else the selected pattern) and works out the tempo they were played at.
    ///
    /// When the song has nothing else in it (no other notes or audio, no tempo changes) the song is set to that tempo and the notes are
    /// moved onto its beat grid, so quantizing to eighths or triplets then lines up with how it was played. Otherwise the song's tempo
    /// is left alone and the tempo is only reported. One undo step.
    @discardableResult
    func detectTempo(of ids: Set<UUID>?) -> TempoOutcome? {
        guard let ti = project.tracks.firstIndex(where: { $0.id == selectedTrackID }), project.tracks[ti].kind == .instrument else { return nil }
        let p0 = project
        // the notes to listen to, with where they sound in seconds
        struct Hit { var clip: Int; var note: Int; var start: Double; var end: Double; var vel: Int }
        var hits: [Hit] = []
        for (ci, c) in p0.tracks[ti].clips.enumerated() {
            if ids == nil, selectedClipLocation.map({ $0.track != ti || $0.clip != ci }) == true { continue }
            for (ni, n) in c.notes.enumerated() where !n.isSlide && (ids == nil || ids!.contains(n.id)) {
                hits.append(Hit(clip: ci, note: ni, start: p0.seconds(atBeat: c.start + n.start), end: p0.seconds(atBeat: c.start + n.end), vel: n.velocity))
            }
        }
        guard let est = TempoDetect.estimate(onsets: hits.map { $0.start }, weights: hits.map { 0.5 + 0.5 * Double($0.vel) / 127 }, beatsPerBar: p0.beatsPerBar) else {
            showToast("Not enough notes to hear a tempo (it needs at least \(TempoDetect.minimumNotes), spread over \(Int(TempoDetect.minimumSpan)) seconds)")
            return nil
        }
        let bpm = (est.bpm * 10).rounded() / 10
        let others = p0.tracks.enumerated().contains { (i, t) in
            !t.audioClips.isEmpty || t.clips.contains { c in c.notes.contains { n in !(i == ti && hits.contains { h in p0.tracks[ti].clips[h.clip].notes[h.note].id == n.id }) } }
        }
        let alt = est.alsoFits.isEmpty ? "" : " (or \(est.alsoFits.map { String(format: "%g", $0) }.joined(separator: " / ")))"
        if others || !p0.tempoPoints.isEmpty {
            showToast("This was played at about \(String(format: "%g", bpm)) BPM\(alt); the song is at \(String(format: "%g", p0.tempo)), so its tempo was left alone")
            return TempoOutcome(estimate: est, applied: false)
        }

        // Put the song on that tempo and every note on its grid
        let grid = TempoEstimate(bpm: bpm, offset: est.offset, confidence: est.confidence)
        edit { proj in
            proj.tempo = bpm
            let bar = proj.beatsPerBar
            var byClip: [Int: [(note: Int, start: Double, end: Double)]] = [:]
            for h in hits { byClip[h.clip, default: []].append((h.note, grid.beat(atSeconds: h.start), grid.beat(atSeconds: h.end))) }
            for (ci, list) in byClip {
                var clip = proj.tracks[ti].clips[ci]
                // a clip starts on a bar line at or before its first note
                let first = max(0, list.map { $0.start }.min() ?? 0)
                let clipStart = (first / bar).rounded(.down) * bar
                for item in list {
                    clip.notes[item.note].start = max(0, item.start - clipStart)
                    clip.notes[item.note].length = max(0.0625, item.end - item.start)
                }
                clip.start = clipStart
                clip.fitLengthToNotes(minBeats: bar, quantum: bar)
                proj.tracks[ti].clips[ci] = clip
            }
        }
        showToast("Played at \(String(format: "%g", bpm)) BPM\(alt): the song is set to it and the notes are on its beat grid")
        return TempoOutcome(estimate: est, applied: true)
    }
}
