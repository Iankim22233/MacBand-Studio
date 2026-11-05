import Foundation
import AppKit

/// `--graphfuzz [file.macband|file.mid] [rounds]`: plays while the audio graph is changed as fast as a user (or a project load) can:
/// instruments swapped, tracks added and removed, master effects added and removed, seeks. It must not crash.
@MainActor
enum GraphFuzzTest {
    /// `--graphfuzz a.macband b.macband …`: loads the projects one after another, over and over, while playing, with almost no waiting in between
    /// (every load removes the old instruments and rebuilds the new ones while the sequencer is being reloaded).
    static func loadCycles(_ paths: [String], rounds: Int) {
        _ = NSApplication.shared
        let s = Session()
        func pump(_ sec: Double) { let e = Date().addingTimeInterval(sec); while Date() < e { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) } }
        pump(1)
        var rng = SystemRandomNumberGenerator()
        for round in 0..<rounds {
            let path = paths[round % paths.count]
            s.isDirty = false
            if path.hasSuffix(".mid") { s.newProject(); s.importMIDI(url: URL(fileURLWithPath: path), tempo: .useFile) } else { s.openProject(url: URL(fileURLWithPath: path)) }
            if Bool.random(using: &rng) { s.play() }
            pump(Double.random(in: 0.0...1.5, using: &rng))
            if Int.random(in: 0..<3, using: &rng) == 0 { s.seek(to: Double(Int.random(in: 0...30, using: &rng))) }
            if round % 5 == 0 { print("  load \(round): \((path as NSString).lastPathComponent), \(s.project.tracks.count) tracks, playing \(s.engine.isPlaying)") }
        }
        s.stop(); pump(1)
        print("LOAD CYCLES SURVIVED \(rounds) ROUNDS")
    }

    static func run(_ path: String?, rounds: Int) {
        _ = NSApplication.shared
        let s = Session()
        func pump(_ sec: Double) { let e = Date().addingTimeInterval(sec); while Date() < e { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) } }
        pump(1)
        if let path, path.hasSuffix(".mid") { s.importMIDI(url: URL(fileURLWithPath: path), tempo: .useFile) }
        else if let path { s.openProject(url: URL(fileURLWithPath: path)) }
        else { s.project = DemoSong.make(); s.engine.syncTracks(s.project.tracks) }
        pump(3)
        var rng = SystemRandomNumberGenerator()
        s.play()
        for round in 0..<rounds {
            let ids = s.project.tracks.filter { $0.kind == .instrument }.map { $0.id }
            switch Int.random(in: 0..<8, using: &rng) {
            case 0, 1: if let id = ids.randomElement(using: &rng) { s.setInstrument(trackID: id, InstrumentSpec(gmProgram: Int.random(in: 0..<120, using: &rng))) }
            case 2: s.addTrack(instrument: InstrumentSpec(gmProgram: Int.random(in: 0..<120, using: &rng)))
            case 3: if ids.count > 2, let id = ids.randomElement(using: &rng) { s.deleteTrack(id) }
            case 4: s.seek(to: Double(Int.random(in: 0...40, using: &rng)))
            case 5: s.undo()
            case 6: if s.project.tracks.count < 14, let id = ids.randomElement(using: &rng) { s.duplicateTrack(id) }
            default: s.togglePlay()
            }
            pump(Double.random(in: 0.0...0.25, using: &rng))
            if round % 25 == 0 { print("  round \(round): \(s.project.tracks.count) tracks, playing \(s.engine.isPlaying)") }
        }
        s.stop()
        pump(1)
        print("GRAPH FUZZ SURVIVED \(rounds) ROUNDS")
    }
}
