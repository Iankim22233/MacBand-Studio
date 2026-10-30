import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import AVFoundation

/// Headless checks for the sound library (`MacBandStudio --soundtest`).
@MainActor enum SoundTest {
    static var failures = 0
    static func check(_ ok: Bool, _ msg: String) { print(ok ? "  ok    \(msg)" : "  FAIL  \(msg)"); if !ok { failures += 1 } }

    static func run() {
        _ = NSApplication.shared
        print("== Sound library test ==")
        let entries = SoundLibrary.buildEntries(extraSoundFonts: [])
        func count(_ g: String) -> Int { entries.filter { $0.group == g }.count }
        print("   groups:", SoundGroup.order.map { "\($0)=\(count($0))" }.joined(separator: "  "))
        check(count(SoundGroup.gm) == 128 + GM.drumKits.count, "General MIDI lists 128 sounds + \(GM.drumKits.count) drum kits")
        check(count(SoundGroup.garageBand) > 0, "GarageBand instruments found")
        check(count(SoundGroup.logic) > 0, "Logic Pro instruments found")
        check(entries.filter { $0.isDrums }.count > 100, "many drum kits are listed (\(entries.filter { $0.isDrums }.count))")
        check(Set(entries.map { $0.id }).count == entries.count, "every sound has a unique id")

        // SoundFont presets
        let sf = entries.filter { $0.group == SoundGroup.soundFonts }
        print("   soundfont presets:", sf.count, "in", Set(sf.map { $0.category }).count, "files")
        if let big = Dictionary(grouping: sf, by: { $0.category }).max(by: { $0.value.count < $1.value.count }) {
            print("   largest soundfont: \(big.key) — \(big.value.count) presets, e.g. \(big.value.prefix(4).map { $0.name })")
        }

        // Loading: a few from each group
        func pick(_ g: String, drums: Bool?, _ n: Int) -> [SoundEntry] {
            entries.filter { $0.group == g && (drums == nil || $0.isDrums == drums!) }.enumerated().filter { $0.offset % max(1, 1 + (entries.count / 7)) == 0 }.map { $0.element }.prefix(n).map { $0 }
        }
        let cache = (try? JSONDecoder().decode([String: [String: Double]].self, from: Data())) ?? [:]
        _ = cache
        func named(_ s: String) -> SoundEntry? { entries.first { $0.id.contains(s) } }

        var cases: [SoundEntry] = []
        for s in ["01 Acoustic Pianos/Grand Piano.exs", "Roland TR-808 Unprocessed Kit.exs", "09 Strings/Strings.exs", "Live Rock Kit.exs", "02 Electric Bass/Liverpool.exs", "Pure House Kit.exs"] {
            guard let e = entries.first(where: { $0.id.hasSuffix(s) }) else { check(false, "found \(s)"); continue }
            cases.append(e)
        }
        cases.append(entries.first { $0.id == "gmkit:25" }!)       // GM TR-808 kit
        cases.append(entries.first { $0.id == "gm:48" }!)           // GM strings
        if let s = sf.first(where: { !$0.isDrums }) { cases.append(s) }
        if let s = sf.first(where: { $0.isDrums }) { cases.append(s) }

        let engine = AudioEngine()
        engine.onError = { print("ENGINE ERROR:", $0) }
        var p = Project(); p.tempo = 120
        var tracks: [Track] = []
        for e in cases {
            var t = Track(name: e.name, colorIndex: tracks.count)
            t.instrument = e.spec
            var c = Clip(name: "t", start: 0, length: 4)
            if e.isDrums { for (i, pitch) in [36, 42, 38, 42, 36, 36, 38, 46].enumerated() { c.notes.append(Note(pitch: pitch, start: Double(i) * 0.5, length: 0.25, velocity: 110)) } }
            else { for (i, pitch) in [60, 64, 67, 72].enumerated() { c.notes.append(Note(pitch: pitch, start: Double(i) * 0.5, length: 0.5, velocity: 100)) } }
            t.clips = [c]
            tracks.append(t)
        }
        p.tracks = tracks
        engine.syncTracks(tracks)
        SelfTest.pump(60) { tracks.allSatisfy { engine.strips[$0.id]?.instrument != nil } }
        for t in tracks {
            check(engine.strips[t.id]?.instrument != nil, "loaded: \(t.name)  [\(t.instrument.sampler?.kind.rawValue ?? (t.instrument.isDrums ? "gm kit" : "gm"))]")
        }
        // Each one on its own makes sound when rendered, and different sounds really are different
        var fingerprints: [String: String] = [:]
        for t in tracks {
            var solo = p; solo.tracks = [t]
            let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macband-sound-\(t.id.uuidString.prefix(6)).wav")
            try? FileManager.default.removeItem(at: out)
            do { try engine.bounce(solo, to: out, testSeconds: 4) { _ in } } catch { check(false, "render \(t.name): \(error)"); continue }
            let r = SelfTest.analyze(out)
            try? FileManager.default.removeItem(at: out)
            let own = engine.renderPeaks[t.id] ?? 0
            let n = min(r.samples.count, 44100 * 3)
            var h: Double = 0
            for i in 0..<n { h += Double(abs(r.samples[i])) * Double((i % 97) + 1) }
            fingerprints[t.name] = String(format: "%.3f", h)
            check((r.rms.max() ?? 0) > 0.003 && own > 0.01, String(format: "sounds: %@ (master rms %.3f, track peak %.3f)", t.name as NSString, r.rms.max() ?? 0, own))
        }

        print("   fingerprints:", fingerprints.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " | "))
        check(Set(fingerprints.values).count == fingerprints.count, "every sound renders different audio")

        // Rendering the same sound again must give the same audio (samples fully loaded before the first note)
        for name in ["Grand Piano", "Roland TR-808 Unprocessed Kit", "String Ensemble 1"] {
            guard let lr = tracks.first(where: { $0.name == name }) else { continue }
            var prints: [String] = []
            for _ in 0..<3 {
                var solo = p; solo.tracks = [lr]
                let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macband-repeat.wav")
                try? FileManager.default.removeItem(at: out)
                try? engine.bounce(solo, to: out, testSeconds: 4) { _ in }
                let r = SelfTest.analyze(out); try? FileManager.default.removeItem(at: out)
                var h: Double = 0
                for i in 0..<min(r.samples.count, 44100 * 3) { h += Double(abs(r.samples[i])) * Double((i % 97) + 1) }
                prints.append(String(format: "%.0f", h))
            }
            check(Set(prints).count == 1, "re-rendering \(name) gives identical audio (\(prints.joined(separator: ", ")))")
        }

        // Same thing with one engine per sound (rules out tracks interfering with each other)
        var iso: [String: String] = [:]
        for t in tracks {
            let e2 = AudioEngine()
            e2.syncTracks([t])
            SelfTest.pump(30) { e2.strips[t.id]?.instrument != nil }
            var solo = p; solo.tracks = [t]
            let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macband-iso-\(t.id.uuidString.prefix(6)).wav")
            try? FileManager.default.removeItem(at: out)
            try? e2.bounce(solo, to: out, testSeconds: 4) { _ in }
            let r = SelfTest.analyze(out)
            if let keep = ProcessInfo.processInfo.environment["MB_KEEP_WAVS"] { try? FileManager.default.createDirectory(atPath: keep, withIntermediateDirectories: true); try? FileManager.default.copyItem(at: out, to: URL(fileURLWithPath: keep).appendingPathComponent(t.name.replacingOccurrences(of: " ", with: "_") + ".wav")) }
            try? FileManager.default.removeItem(at: out)
            var h: Double = 0
            for i in 0..<min(r.samples.count, 44100 * 3) { h += Double(abs(r.samples[i])) * Double((i % 97) + 1) }
            iso[t.name] = String(format: "%.3f", h)
        }
        print("   isolated:", iso.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " | "))
        check(Set(iso.values).count == iso.count, "every sound renders different audio (one engine each)")

        // Audition path
        var previewErr: String? = "pending"
        let t0 = Date()
        engine.preview(cases[0].spec) { previewErr = $0 }
        SelfTest.pump(20) { previewErr != "pending" }
        check(previewErr == nil, "audition loads and plays \(cases[0].name) (\(previewErr ?? "ok"), \(String(format: "%.1f", Date().timeIntervalSince(t0)))s)")
        engine.stopPreviewNotes()

        // Spec survives a project save/load
        var proj = Project(); var t = Track(name: "X", colorIndex: 0); t.instrument = cases[1].spec; proj.tracks = [t]
        let data = try! JSONEncoder().encode(proj)
        let back = try! JSONDecoder().decode(Project.self, from: data)
        check(back.tracks[0].instrument == cases[1].spec, "sampler instrument survives save → open")
        check(AudioEngine.instrumentKey(cases[0].spec) != AudioEngine.instrumentKey(cases[1].spec), "different sounds get different engine keys")
        print(failures == 0 ? "ALL SOUND CHECKS PASSED" : "\(failures) SOUND CHECK(S) FAILED")
    }
}

extension SoundTest {
    /// `--soundtest-live`: plays one note in real time and prints the master level over time (a piano or a drum hit must decay).
    static func live() {
        _ = NSApplication.shared
        let entries = SoundLibrary.buildEntries(extraSoundFonts: [])
        let engine = AudioEngine()
        engine.onError = { print("ENGINE ERROR:", $0) }
        let picks: [(String, SoundEntry, Int)] = [
            ("GM piano", entries.first { $0.id == "gm:0" }!, 60),
            ("GM TR-808 kit snare", entries.first { $0.id == "gmkit:25" }!, 38),
            ("EXS Grand Piano", entries.first { $0.id.hasSuffix("01 Acoustic Pianos/Grand Piano.exs") }!, 60),
            ("EXS TR-808 kick", entries.first { $0.id.hasSuffix("Roland TR-808 Unprocessed Kit.exs") }!, 36),
        ]
        for (label, e, pitch) in picks {
            var t = Track(name: label, colorIndex: 0); t.instrument = e.spec
            engine.syncTracks([t])
            SelfTest.pump(30) { engine.strips[t.id]?.instrument != nil }
            SelfTest.pump(0.3)
            engine.noteOn(trackID: t.id, pitch: pitch, velocity: 110)
            var levels: [String] = []
            for _ in 0..<24 { SelfTest.pump(0.06); levels.append(String(format: "%.2f", engine.masterPeak)) }
            engine.noteOff(trackID: t.id, pitch: pitch)
            print("\(label): \(levels.joined(separator: " "))")
            engine.syncTracks([])
            SelfTest.pump(0.5)
        }
    }
}


/// Headless checks for the step sequencer grid (`--steptest`).
@MainActor enum StepTest {
    static func run() {
        print("== Step sequencer test ==")
        var fails = 0
        func check(_ ok: Bool, _ msg: String) { print(ok ? "  ok    \(msg)" : "  FAIL  \(msg)"); if !ok { fails += 1 } }
        var clip = Clip(name: "t", start: 0, length: 8)
        check(StepGrid.stepCount(clip, stepLen: 0.25) == 32, "2 bars of 1/16 steps = 32")
        check(StepGrid.stepCount(clip, stepLen: 0.5) == 16, "2 bars of 1/8 steps = 16")
        StepGrid.set(&clip, pitch: 36, step: 0, stepLen: 0.25, on: true, velocity: 100)
        StepGrid.set(&clip, pitch: 36, step: 8, stepLen: 0.25, on: true, velocity: 127)
        StepGrid.set(&clip, pitch: 42, step: 2, stepLen: 0.25, on: true, velocity: 100)
        check(clip.notes.count == 3, "three hits painted")
        check(StepGrid.velocity(clip, pitch: 36, step: 8, stepLen: 0.25) == 127, "accent keeps velocity 127")
        check(clip.notes.first { $0.pitch == 42 }?.start == 0.5, "step 2 at 1/16 lands on beat 0.5")
        check(StepGrid.velocity(clip, pitch: 38, step: 0, stepLen: 0.25) == nil, "empty cell reads as off")
        StepGrid.set(&clip, pitch: 36, step: 0, stepLen: 0.25, on: true, velocity: 100)
        check(clip.notes.filter { $0.pitch == 36 && $0.start == 0 }.count == 1, "painting a cell twice doesn't stack notes")
        StepGrid.set(&clip, pitch: 36, step: 0, stepLen: 0.25, on: false, velocity: 0)
        check(StepGrid.velocity(clip, pitch: 36, step: 0, stepLen: 0.25) == nil, "erasing a cell clears it")
        // finer grid still finds a coarser hit
        check(StepGrid.velocity(clip, pitch: 36, step: 4, stepLen: 0.5) == 127, "1/8 grid sees the hit at beat 2")
        // rows: standard drums first, then extras
        clip.notes.append(Note(pitch: 60, start: 1, length: 0.25))
        let rows = StepGrid.rows(for: clip, extra: [70])
        check(Array(rows.prefix(DrumMap.stepRows.count)) == DrumMap.stepRows, "standard drum rows come first, in order")
        check(rows.contains(60) && rows.contains(70), "notes already in the clip and added drums get rows")
        print(fails == 0 ? "ALL STEP CHECKS PASSED" : "\(fails) STEP CHECK(S) FAILED")
        exit(fails == 0 ? 0 : 1)
    }
}

extension SoundTest {
    /// `--soundtest-after`: instruments must still sound like themselves after an offline render and after the engine is paused.
    static func afterOffline() -> Int32 {
        _ = NSApplication.shared
        print("== Instruments after offline render ==")
        var fails = 0
        func check(_ ok: Bool, _ m: String) { print(ok ? "  ok    \(m)" : "  FAIL  \(m)"); if !ok { fails += 1 } }
        let engine = AudioEngine()
        engine.onError = { print("ENGINE ERROR:", $0) }
        var t = Track(name: "Piano", colorIndex: 0); t.instrument = InstrumentSpec(gmProgram: 0)
        var c = Clip(name: "c", start: 0, length: 4); c.notes = [Note(pitch: 60, start: 0, length: 1)]; t.clips = [c]
        var p = Project(); p.tracks = [t]
        engine.syncTracks(p.tracks)
        SelfTest.pump(30) { engine.strips[t.id]?.instrument != nil && engine.strips[t.id]?.loading == false }
        SelfTest.pump(0.5)

        /// How much a played piano note has decayed after a second (a real piano dies away; the default sine tone doesn't).
        func decay() -> Double {
            engine.noteOn(trackID: t.id, pitch: 60, velocity: 110)
            var peaks: [Float] = []
            for _ in 0..<26 { SelfTest.pump(0.06); peaks.append(engine.masterPeak) }
            engine.noteOff(trackID: t.id, pitch: 60)
            SelfTest.pump(2)
            let early = peaks[2...5].reduce(0, +) / 4, late = peaks[18...24].reduce(0, +) / 7
            return early > 0 ? Double(late / early) : 1
        }
        let d0 = decay()
        check(d0 < 0.5, String(format: "before anything: the piano note dies away (late/early = %.2f)", d0))
        engine.engine.pause(); engine.startEngine(); SelfTest.pump(0.5)
        let d1 = decay()
        check(d1 < 0.5, String(format: "after pausing and restarting the engine (%.2f)", d1))
        try? engine.bounce(p, to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macband-after.caf"), testSeconds: 2) { _ in }
        SelfTest.pump(0.5)
        let d2 = decay()
        check(d2 < 0.5, String(format: "after an offline render the piano still dies away (%.2f)", d2))
        try? engine.bounce(p, to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macband-after.caf"), testSeconds: 2) { _ in }
        SelfTest.pump(0.5)
        let d3 = decay()
        check(d3 < 0.5, String(format: "and after a second render (%.2f)", d3))
        print(fails == 0 ? "ALL INSTRUMENT CHECKS PASSED" : "\(fails) INSTRUMENT CHECK(S) FAILED")
        return fails == 0 ? 0 : 1
    }
}
