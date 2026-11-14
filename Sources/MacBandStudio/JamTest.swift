#if os(macOS)
import Foundation
import AppKit
import SceneKit

/// `--jamtest`: instrument choice, the spotlight rule, the stage animating from the song, and a rendered picture.
/// `--jamshots <dir>`: writes pictures of the stage (a duet, a full band, a stopped song) for a look.
@MainActor
enum JamTest {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "PASS " : "FAIL ") + what)
        if !ok { failures += 1 }
    }

    /// A project with one track per entry: (name, GM program or drums), each holding a note for the whole of beats 0–8.
    static func project(_ spec: [(String, Int, Bool)]) -> Project {
        var p = Project()
        p.tempo = 120
        for (i, s) in spec.enumerated() {
            var t = Track(name: s.0, colorIndex: i)
            t.instrument = InstrumentSpec(gmProgram: s.1, isDrums: s.2)
            var c = Clip(name: s.0, start: 0, length: 8)
            if s.2 { for b in 0..<16 { c.notes.append(Note(pitch: b % 4 == 2 ? 38 : (b % 2 == 0 ? 36 : 42), start: Double(b) * 0.5, length: 0.25)) } }
            else { c.notes.append(Note(pitch: 60 + i * 2, start: 0, length: 8)) }
            t.clips = [c]
            p.tracks.append(t)
        }
        return p
    }

    /// Runs the stage for `frames` frames with the playhead held at `beat`.
    static func run(_ stage: JamStage, beat: Double, playing: Bool = true, frames: Int = 60) {
        for _ in 0..<frames { stage.update(beat: beat, playing: playing, secondsPerBeat: 0.5, dt: 1.0 / 60) }
    }

    static func visible(_ stage: JamStage) -> [Int] { stage.slots.filter { !($0.spot?.isHidden ?? true) }.map { $0.track } }

    static func run() -> Int32 {
        // which instrument a track is
        func kind(_ prog: Int, drums: Bool = false) -> JamKind {
            var t = Track(name: "x", colorIndex: 0); t.instrument = InstrumentSpec(gmProgram: prog, isDrums: drums); return JamKind.of(t)
        }
        check(kind(0) == .piano && kind(19) == .piano && kind(11) == .piano, "pianos, organs and mallets have keys")
        check(kind(25) == .guitar && kind(33) == .bass && kind(40) == .strings && kind(48) == .strings, "guitar, bass, strings")
        check(kind(56) == .brass && kind(65) == .reed && kind(73) == .pipe && kind(81) == .synth && kind(100) == .synth, "brass, reeds, pipes, synths")
        check(kind(0, drums: true) == .drums, "a drum track is a drum kit")
        var plug = Track(name: "My Trumpet", colorIndex: 0); plug.instrument = InstrumentSpec(plugin: PluginSpec(format: .au, name: "Brass Thing", isInstrument: true))
        check(JamKind.of(plug) == .brass && JamKind.named("Mystery") == nil && JamKind.named("Grand Piano") == .piano && JamKind.named("Bassoon") == .reed && JamKind.named("Slap Bass") == .bass, "plug-ins are told apart by name")

        // the timeline
        let demo = DemoSong.make()
        let tl = JamTimeline(demo)
        check(tl.sounding(0, at: 0.2).contains { $0.pitch == 72 } && tl.sounding(0, at: 0.2).count == 4, "the timeline knows what is held (melody note plus three chord notes)")
        check(tl.sounding(0, at: 30).isEmpty && !tl.started(1, from: 0, to: 1.01).isEmpty, "…and what starts when")

        // the spotlight rule
        let drums = [false, false, true, false]
        check(JamSpot.targets([0, 1], drums: drums) == [0, 1], "two instruments: a spotlight on both")
        check(JamSpot.targets([0, 1, 2], drums: drums) == [0, 1], "…drums don't count")
        check(JamSpot.targets([0, 2], drums: drums).isEmpty, "one instrument and drums: no spotlight")
        check(JamSpot.targets([0, 1, 3], drums: drums).isEmpty && JamSpot.targets([], drums: drums).isEmpty && JamSpot.targets([2], drums: drums).isEmpty, "three, or none: no spotlight")
        var hold = JamSpot()
        hold.update(sounding: [0], now: 1.0)
        check(hold.playing(now: 1.2) == [0] && hold.playing(now: 1.5).isEmpty, "an instrument counts as playing for a moment after its note ends")

        // the stage
        let stage = JamStage()
        stage.sync(demo, force: true)
        check(stage.slots.count == 3 && stage.slots.map { $0.inst.kind } == [.piano, .bass, .drums], "an instrument on stage for each track")
        check(stage.slots.last?.spot == nil && stage.slots.first?.spot != nil, "drums get no spotlight")
        check(visible(stage).isEmpty, "no spotlight before the music")
        run(stage, beat: 0.3)
        check(stage.spotTargets == [0, 1] && visible(stage) == [0, 1], "piano and bass playing (drums too): both in the spotlight")
        check((stage.slots[0].spot?.light?.intensity ?? 0) > 2000 && stage.dim > 0.9, "…and the house lights go down")
        run(stage, beat: 0.3, playing: false, frames: 90)
        check(visible(stage).isEmpty && stage.dim < 0.05, "stopped: the lights come back")

        func spotted(_ spec: [(String, Int, Bool)]) -> [Int] {
            let s = JamStage(); s.sync(project(spec), force: true); run(s, beat: 1); return s.spotTargets
        }
        check(spotted([("Piano", 0, false), ("Bass", 33, false)]) == [0, 1], "two instruments, no drums: spotlight")
        check(spotted([("Piano", 0, false), ("Drums", 0, true)]).isEmpty, "one instrument and the drums: no spotlight")
        check(spotted([("Piano", 0, false), ("Guitar", 25, false), ("Drums", 0, true)]) == [0, 1], "two instruments and the drums: spotlight")
        check(spotted([("Piano", 0, false), ("Guitar", 25, false), ("Bass", 33, false), ("Drums", 0, true)]).isEmpty, "three instruments: no spotlight")
        check(spotted([("Piano", 0, false)]).isEmpty, "a lone instrument: no spotlight")

        // the instruments follow the notes
        let st = JamStage(); st.sync(demo, force: true)
        run(st, beat: 0.3)
        if let piano = st.slots[0].inst as? JamPiano {
            check(piano.pressed(72) > 0.8 && piano.pressed(74) < 0.05, "the piano key for the note being played is down, others are up")
        } else { check(false, "the piano is a piano") }
        if let bass = st.slots[1].inst as? JamStringed {
            let f = bass.fingering([VNote(start: 0, end: 1, pitch: 33, vel: 100, track: 1), VNote(start: 0, end: 1, pitch: 40, vel: 100, track: 1)])
            check(f.count == 2 && Set(f.keys).count == 2, "two bass notes at once go on two strings")
            let open = bass.fingering([VNote(start: 0, end: 1, pitch: 28, vel: 100, track: 1)])
            check(open.count == 1 && open.values.first?.fret == 0, "the open low string needs no finger")
        } else { check(false, "the bass is a stringed instrument") }
        let gt = JamStringed(kind: .guitar, tint: .red, program: 25)
        let g = gt.fingering([VNote(start: 0, end: 1, pitch: 64, vel: 100, track: 0)])
        check(g.count == 1 && g.values.first?.fret == 0, "E above middle C is an open guitar string")
        check(JamDrums.piece(for: 36) == "kick" && JamDrums.piece(for: 38) == "snare" && JamDrums.piece(for: 42) == "hat" && JamDrums.piece(for: 49) == "crash", "drum notes pick the right drum")

        // a big band builds, and a picture of it isn't blank
        let band = bigBand()
        let bs = JamStage(); bs.sync(band, force: true)
        check(bs.slots.count == 10, "ten instruments for ten tracks")
        run(bs, beat: 2.2)
        check(bs.spotTargets.isEmpty, "a whole band: no spotlight")
        if let img = render(st, size: CGSize(width: 640, height: 400)) { check(colourCount(img) > 40, "the duet renders a picture") } else { print("SKIP no graphics for a rendering"); }
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }

    /// Ten instruments, one of every kind, playing something.
    static func bigBand() -> Project {
        var p = Project()
        p.tempo = 120
        let spec: [(String, Int, Bool, Int)] = [("Piano", 0, false, 60), ("Guitar", 25, false, 52), ("Bass", 33, false, 36), ("Violin", 40, false, 67), ("Cello", 42, false, 48),
                                                ("Trumpet", 56, false, 64), ("Sax", 65, false, 57), ("Flute", 73, false, 72), ("Synth", 81, false, 60), ("Drums", 0, true, 0)]
        for (i, s) in spec.enumerated() {
            var t = Track(name: s.0, colorIndex: i)
            t.instrument = InstrumentSpec(gmProgram: s.1, isDrums: s.2)
            var c = Clip(name: s.0, start: 0, length: 16)
            let scale = [0, 2, 4, 5, 7, 9, 11, 12]
            if s.2 { for b in 0..<32 { c.notes.append(Note(pitch: b % 4 == 2 ? 38 : (b % 2 == 0 ? 36 : 42), start: Double(b) * 0.5, length: 0.25)); if b % 8 == 0 { c.notes.append(Note(pitch: 49, start: Double(b) * 0.5, length: 0.25)) } } }
            else {
                for b in 0..<16 {
                    let deg = (b * 3 + i) % scale.count
                    c.notes.append(Note(pitch: s.3 + scale[deg], start: Double(b), length: 0.9, velocity: 90))
                    if i == 0 { c.notes.append(Note(pitch: s.3 - 12 + scale[(deg + 2) % 8], start: Double(b), length: 0.9)); c.notes.append(Note(pitch: s.3 - 5 + scale[(deg + 4) % 8], start: Double(b), length: 0.9)) }
                }
            }
            t.clips = [c]
            p.tracks.append(t)
        }
        return p
    }

    static func render(_ stage: JamStage, size: CGSize) -> NSImage? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let r = SCNRenderer(device: device, options: nil)
        r.scene = stage.scene
        r.pointOfView = stage.cameraNode
        stage.frameCamera(aspect: Double(size.width / size.height))
        return r.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }

    static func colourCount(_ img: NSImage) -> Int {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return 0 }
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 5) { for x in stride(from: 0, to: rep.pixelsWide, by: 5) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            seen.insert(UInt32(c.redComponent * 31) << 10 | UInt32(c.greenComponent * 31) << 5 | UInt32(c.blueComponent * 31))
        } }
        return seen.count
    }

    static func save(_ img: NSImage, _ path: String) {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    static func shots(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let size = CGSize(width: 1280, height: 760)
        func shot(_ name: String, _ project: Project, beat: Double, playing: Bool = true) {
            let s = JamStage(); s.sync(project, force: true)
            run(s, beat: beat, playing: playing, frames: 80)
            if let img = render(s, size: size) { save(img, "\(dir)/\(name).png"); print("wrote \(name).png (spot: \(s.spotTargets))") } else { print("no graphics") }
        }
        shot("duet", DemoSong.make(), beat: 2.1)
        shot("band", bigBand(), beat: 2.2)
        shot("band-idle", bigBand(), beat: 0, playing: false)
        // each instrument on its own, close up (the spotlight stays off: one at a time)
        let band = bigBand()
        for (i, t) in band.tracks.enumerated() {
            var one = band; one.tracks = [t]
            let s = JamStage(); s.sync(one, force: true)
            run(s, beat: 2.2 + Double(i % 3), frames: 60)
            let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
            r.scene = s.scene; r.pointOfView = s.cameraNode
            let big = t.name == "Piano" || t.name == "Drums" || t.name == "Synth"
            s.cameraNode.position = SCNVector3(x: 0, y: big ? 3.4 : 3.0, z: big ? 8.5 : 9.5)
            if t.name == "Piano" { s.cameraNode.position = SCNVector3(x: 0, y: 3.2, z: 5.5) }
            s.cameraNode.look(at: SCNVector3(x: 0, y: big ? 1.0 : 1.6, z: 0))
            save(r.snapshot(atTime: 0, with: CGSize(width: 640, height: 400), antialiasingMode: .multisampling4X), "\(dir)/close-\(t.name).png")
        }
        var trio = bigBand(); trio.tracks = [trio.tracks[0], trio.tracks[5]]
        shot("duet-horn", trio, beat: 3.1)
    }
}
#endif
