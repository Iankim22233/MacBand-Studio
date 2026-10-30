import Foundation

/// The song used for the welcome project and for pictures.
enum DemoSong {
    static func make() -> Project {
        var p = Project()
        p.name = "Demo Song"
        p.tempo = 104
        p.keyRoot = 0; p.scale = .major
        let bar = p.beatsPerBar

        // Piano: right-hand melody + left-hand chords over 4 bars (C – Am – F – G)
        var piano = Track(name: "Piano", colorIndex: 0)
        piano.instrument = InstrumentSpec(gmProgram: 0)
        var pc = Clip(name: "Piano", start: 0, length: bar * 4)
        let chords: [[Int]] = [[48, 55, 64], [45, 52, 60], [41, 48, 57], [43, 50, 59]]
        for (i, ch) in chords.enumerated() {
            for (k, pitch) in ch.enumerated() { pc.notes.append(Note(pitch: pitch - (k == 2 ? 12 : 0), start: Double(i) * bar, length: bar, velocity: 70)) }
        }
        let melody: [(Int, Double, Double)] = [
            (72, 0, 1), (74, 1, 0.5), (76, 1.5, 0.5), (79, 2, 1.5), (76, 3.5, 0.5),
            (72, 4, 1), (69, 5, 1), (72, 6, 1), (76, 7, 1),
            (77, 8, 0.75), (76, 8.75, 0.25), (74, 9, 1), (72, 10, 2),
            (71, 12, 1.5), (74, 13.5, 0.5), (72, 14, 1), (67, 15, 1),
        ]
        for (pitch, s, l) in melody { pc.notes.append(Note(pitch: pitch, start: s, length: l, velocity: 96)) }
        piano.clips = [pc]

        // Bass: roots on every beat pair
        var bass = Track(name: "Bass", colorIndex: 1)
        bass.instrument = InstrumentSpec(gmProgram: 33)
        var bc = Clip(name: "Bass", start: 0, length: bar * 4)
        let roots = [36, 33, 29, 31]
        for (i, r) in roots.enumerated() {
            for b in 0..<4 { bc.notes.append(Note(pitch: r + (b == 3 ? 12 : 0), start: Double(i) * bar + Double(b), length: 0.75, velocity: 92)) }
        }
        bass.clips = [bc]

        // Drums: GM kit — kick, snare, closed hi-hat 8ths, open hat, crash
        var drums = Track(name: "Drums", colorIndex: 2)
        drums.instrument = InstrumentSpec(isDrums: true)
        var dc = Clip(name: "Beat", start: 0, length: bar * 4)
        for barIdx in 0..<4 {
            let o = Double(barIdx) * bar
            for b in [0.0, 2.0, 2.5] { dc.notes.append(Note(pitch: 36, start: o + b, length: 0.25, velocity: 112)) }
            for b in [1.0, 3.0] { dc.notes.append(Note(pitch: 38, start: o + b, length: 0.25, velocity: 104)) }
            for k in 0..<8 { dc.notes.append(Note(pitch: k == 7 ? 46 : 42, start: o + Double(k) * 0.5, length: 0.25, velocity: k % 2 == 0 ? 92 : 64)) }
        }
        dc.notes.append(Note(pitch: 49, start: 0, length: 0.5, velocity: 118))
        drums.clips = [dc]

        p.tracks = [piano, bass, drums]
        return p
    }
}
