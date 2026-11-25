import Foundation

/// AVAudioSequencer's own loop support drops passes, so looping is done by unrolling the loop
/// region into the playback sequence: pass 0 is the song up to the loop end, later passes repeat the region.
extension Project {
    /// Number of repeated passes appended after the first.
    private func loopPasses() -> Int {
        let len = loopEnd - loopStart
        let secs = max(0.2, seconds(atBeat: loopEnd) - seconds(atBeat: loopStart))
        var k = Int((20 * 60 / secs).rounded(.up))
        let notesInWindow = tracks.reduce(0) { $0 + $1.clips.reduce(0) { $0 + $1.notes.count } }
        if notesInWindow > 0 { k = min(k, max(2, 60_000 / notesInWindow)) }
        _ = len
        return min(2000, max(2, k))
    }

    func loopUnrolled() -> Project {
        guard loopEnabled, loopEnd > loopStart else { return self }
        let L = loopEnd - loopStart
        let finite = loopCount > 0                         // plays a set number of times, then the song goes on after the loop
        let K = finite ? loopCount - 1 : loopPasses()
        var q = self
        q.loopEnabled = false

        // Clips
        for ti in tracks.indices {
            var out: [Clip] = []
            for c in tracks[ti].clips {
                for pass in 0...(K + (finite ? 1 : 0)) {          // pass K + 1 of a finite loop is the rest of the song after it
                    let isTail = finite && pass == K + 1
                    let ws = pass == 0 ? 0 : (isTail ? loopEnd : loopStart)
                    let we = isTail ? Double.infinity : loopEnd
                    let shift = Double(min(pass, K)) * L
                    let s = max(c.start, ws), e = min(c.end, we)
                    if e <= s { continue }
                    var nc = Clip(name: c.name, start: s + shift, length: e - s)
                    nc.id = pass == 0 ? c.id : UUID()
                    var notes: [Note] = []
                    for n in c.notes {
                        let abs = c.start + n.start
                        if abs < s - 1e-9 && !(pass == 0) { continue }
                        if abs >= e - 1e-9 { continue }
                        var m = n
                        m.start = abs - s
                        m.length = min(n.length, e - abs)
                        notes.append(m)
                    }
                    if pass > 0 {
                        let normals = notes.filter { !$0.isSlide }
                        notes.removeAll { n in n.isSlide && !normals.contains { $0.start <= n.start + 1e-6 && $0.end > n.start + 1e-6 } }
                    }
                    nc.notes = notes
                    out.append(nc)
                }
            }
            q.tracks[ti].clips = out
        }

        // Tempo map
        var pts: [TempoPoint] = tempoPoints.filter { $0.beat < loopEnd }
        let startBPM = bpm(at: loopStart)
        let inside = tempoPoints.filter { $0.beat > loopStart && $0.beat < loopEnd }
        if K >= 1 {
            for pass in 1...K {
                let shift = Double(pass) * L
                pts.append(TempoPoint(beat: loopStart + shift, bpm: startBPM, ramp: false))
                for p in inside { pts.append(TempoPoint(beat: p.beat + shift, bpm: p.bpm, ramp: p.ramp)) }
            }
        }
        if finite {                                              // the song after the loop, later by the repeats
            let shift = Double(K) * L
            if shift > 0 {
                pts.append(TempoPoint(beat: loopEnd + shift, bpm: bpm(at: loopEnd), ramp: false))
                for p in tempoPoints where p.beat > loopEnd { pts.append(TempoPoint(beat: p.beat + shift, bpm: p.bpm, ramp: p.ramp)) }
            } else {
                pts += tempoPoints.filter { $0.beat >= loopEnd }
            }
        }
        q.tempoPoints = pts
        return q
    }

    /// Map a raw sequence beat back onto the song while looping.
    func loopWrapped(_ raw: Double) -> Double {
        guard loopEnabled, loopEnd > loopStart, raw >= loopEnd else { return raw }
        let L = loopEnd - loopStart
        if loopCount > 0, raw >= loopEnd + Double(loopCount - 1) * L { return raw - Double(loopCount - 1) * L }      // past the last pass: the song goes on
        return loopStart + (raw - loopStart).truncatingRemainder(dividingBy: L)
    }

    /// The other way round: where in the sequence a beat of the song is. After a loop that plays a set number of times, the song
    /// goes on later in the sequence by the repeats; for ever-looping (or inside the loop) it is the same beat.
    func loopRaw(_ song: Double) -> Double {
        guard loopEnabled, loopCount > 1, loopEnd > loopStart, song >= loopEnd else { return song }
        return song + Double(loopCount - 1) * (loopEnd - loopStart)
    }
}
