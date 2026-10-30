import Foundation
import AVFoundation

/// `--selfcheck` (pass it as a launch argument in the simulator): loads the demo song through the bundled SoundFont, renders it and
/// checks there is real sound in it. Prints the result and exits.
@MainActor
enum IOSDiagnostics {
    static func run() async {
        func out(_ s: String) { print(s); fflush(stdout) }
        out("== iOS self check ==")
        let sf2 = AudioEngine.dlsURL
        out("SoundFont: \(sf2.lastPathComponent) exists=\(FileManager.default.fileExists(atPath: sf2.path)) size=\((try? FileManager.default.attributesOfItem(atPath: sf2.path)[.size] as? Int) ?? 0)")
        let engine = AudioEngine()
        engine.onError = { out("ENGINE ERROR: \($0)") }
        let p = DemoSong.make()
        engine.syncTracks(p.tracks)
        let started = Date()
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if p.tracks.allSatisfy({ engine.strips[$0.id]?.instrument != nil && engine.strips[$0.id]?.loading == false }) { break }
        }
        out(String(format: "waited %.1f s for the instruments", Date().timeIntervalSince(started)))
        let loaded = p.tracks.filter { engine.strips[$0.id]?.instrument != nil }.count
        out("instruments loaded: \(loaded) of \(p.tracks.count)")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("selfcheck.wav")
        try? FileManager.default.removeItem(at: url)
        do { try engine.bounce(p, to: url, testSeconds: 4) { _ in } } catch { out("RENDER FAILED: \(error)"); exit(1) }
        guard let f = try? AVAudioFile(forReading: url), let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { out("cannot read the render"); exit(1) }
        try? f.read(into: buf)
        let ch = buf.floatChannelData![0], n = Int(buf.frameLength)
        var peak: Float = 0, sum = 0.0
        for i in 0..<n { peak = max(peak, abs(ch[i])); sum += Double(ch[i] * ch[i]) }
        let rms = sqrt(sum / Double(max(1, n)))
        out(String(format: "rendered %.1f s: peak %.3f, rms %.4f", Double(n) / f.processingFormat.sampleRate, peak, rms))
        var failures = 0
        func check(_ ok: Bool, _ m: String) { out((ok ? "  ok    " : "  FAIL  ") + m); if !ok { failures += 1 } }
        check(loaded == p.tracks.count, "all instruments load from the bundled SoundFont (\(loaded) of \(p.tracks.count))")
        check(rms > 0.005, String(format: "the rendered song has sound (rms %.3f)", rms))
        for prog in [0, 24, 40, 56, 73, 127] {
            let sam = SamplerUnit()
            do { try AudioEngine.loadSamplerSync(sam, spec: InstrumentSpec(gmProgram: prog)); check(true, "General MIDI sound \(prog) loads") }
            catch { check(false, "General MIDI sound \(prog) loads: \(error)") }
        }
        for kit in [0, 8, 16, 24, 25, 32, 40, 48, 56] {
            let sam = SamplerUnit()
            do { try AudioEngine.loadSamplerSync(sam, spec: InstrumentSpec(gmProgram: kit, isDrums: true)); check(true, "drum kit \(kit) loads") }
            catch { check(false, "drum kit \(kit) loads: \(error)") }
        }

        // the built-in SoundFont synthesizer: pitch, drums, release, and notes sent in the middle of a render
        do {
            let eng = AVAudioEngine()
            let inst = SamplerUnit()
            eng.attach(inst)
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            eng.connect(inst, to: eng.mainMixerNode, format: fmt)
            try eng.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 512)
            try eng.start()
            func render(_ seconds: Double) -> [Float] {
                var out: [Float] = []
                let buf = AVAudioPCMBuffer(pcmFormat: eng.manualRenderingFormat, frameCapacity: 512)!
                var left = Int(seconds * 44100)
                while left > 0 {
                    let n = AVAudioFrameCount(min(512, left))
                    if (try? eng.renderOffline(n, to: buf)) != nil, let ch = buf.floatChannelData?[0] { out.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(buf.frameLength))) }
                    left -= Int(n)
                }
                return out
            }
            func frequency(_ x: [Float]) -> Double {                       // the strongest repeat between 100 and 1000 Hz
                let a = Array(x[(x.count / 3)..<(x.count / 3 + 4096)])
                var best = 0.0, bestLag = 1
                for lag in 44...441 {
                    var c = 0.0
                    for i in 0..<(a.count - lag) { c += Double(a[i] * a[i + lag]) }
                    if c > best { best = c; bestLag = lag }
                }
                return 44100 / Double(bestLag)
            }
            try inst.loadSoundBankInstrument(at: AudioEngine.dlsURL, program: 0, bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: 0)
            inst.startNote(69, withVelocity: 100, onChannel: 0)
            let a4 = render(0.8)
            let hz = frequency(a4)
            let level = sqrt(a4.reduce(0) { $0 + Double($1 * $1) } / Double(a4.count))
            check(abs(hz - 440) < 8 && level > 0.01, String(format: "the SoundFont synth plays A4 at the right pitch (%.1f Hz, level %.3f)", hz, level))
            inst.stopNote(69, onChannel: 0)
            _ = render(2.5)
            let tail = render(0.3)
            check((tail.map { abs($0) }.max() ?? 1) < 0.002, "…and a released note dies away")
            try inst.loadSoundBankInstrument(at: AudioEngine.dlsURL, program: 0, bankMSB: UInt8(kAUSampler_DefaultPercussionBankMSB), bankLSB: 0)
            inst.startNote(38, withVelocity: 100, onChannel: 0)
            let snare = render(0.3)
            check((snare.map { abs($0) }.max() ?? 0) > 0.02, "…and a drum kit plays a snare")
            // loading another sound while notes are sounding must not disturb the audio thread
            for prog in [4, 25, 40, 56, 73, 0] {
                inst.startNote(60, withVelocity: 90, onChannel: 0); inst.startNote(64, withVelocity: 90, onChannel: 0)
                _ = render(0.05)
                try inst.loadSoundBankInstrument(at: AudioEngine.dlsURL, program: UInt8(prog), bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: 0)
                _ = render(0.1)
            }
            check(true, "…and sounds can be swapped while it plays")
            eng.stop()
        } catch { check(false, "the SoundFont synth runs: \(error)") }

        // the situation that crashed Apple's sampler: a live engine playing while other sounds load on another thread
        do {
            let eng = AVAudioEngine()
            let units = (0..<4).map { _ in SamplerUnit() }
            for u in units { eng.attach(u); eng.connect(u, to: eng.mainMixerNode, format: nil) }
            try eng.start()
            let loader = DispatchQueue(label: "selfcheck.loader")
            let done = DispatchSemaphore(value: 0)
            var loadFailures = 0
            let t0 = Date()
            let stressLoads = ProcessInfo.processInfo.environment["STRESS_LOADS"] != "0"
            let stressNotes = ProcessInfo.processInfo.environment["STRESS_NOTES"] != "0"
            for u in units { try? u.loadSoundBankInstrument(at: AudioEngine.dlsURL, program: 0, bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: 0) }
            loader.async {
                var round = 0
                while Date().timeIntervalSince(t0) < 5 {
                    defer { round += 1 }
                    if !stressLoads { Thread.sleep(forTimeInterval: 0.01); continue }
                    let u = units[round % units.count]
                    let kit = round % 5 == 4
                    do {
                        try u.loadSoundBankInstrument(at: AudioEngine.dlsURL, program: UInt8(kit ? 0 : (round * 7) % 128),
                                                      bankMSB: UInt8(kit ? kAUSampler_DefaultPercussionBankMSB : kAUSampler_DefaultMelodicBankMSB), bankLSB: 0)
                    } catch { loadFailures += 1 }
                }
                done.signal()
            }
            var notes = 0
            while done.wait(timeout: .now() + 0.01) == .timedOut && Date().timeIntervalSince(t0) < 60 {
                for (i, u) in units.enumerated() where stressNotes {
                    let key = UInt8(36 + (notes * 5 + i * 7) % 60)
                    u.startNote(key, withVelocity: 90, onChannel: 0)
                    if notes % 3 == 0 { u.stopNote(UInt8(36 + ((notes - 3) * 5 + i * 7) % 60), onChannel: 0) }
                }
                notes += 1
            }
            for u in units { u.sendController(123, withValue: 0, onChannel: 0) }
            Thread.sleep(forTimeInterval: 0.3)
            eng.stop()
            check(loadFailures == 0, "sounds load on another thread while notes play (\(notes) note groups over 5 s, no crash)")
        } catch { check(false, "the live-engine stress run: \(error)") }

        // MIDI round trip
        let midi = MIDIFile.build(p, forExport: true)
        let back = try? MIDIFile.parse(midi)
        let notesIn = p.tracks.reduce(0) { $0 + $1.clips.reduce(0) { $0 + $1.notes.count } }
        check((back?.tracks.count ?? 0) == p.tracks.count && abs((back?.tempo ?? 0) - p.tempo) < 0.5, "a MIDI file exports and imports again (\(back?.tracks.count ?? 0) tracks, \(Int(back?.tempo ?? 0)) BPM)")
        check((back?.tracks.reduce(0) { $0 + $1.notes.count } ?? 0) == notesIn, "…with every one of the \(notesIn) notes")

        // saving and opening
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("selfcheck-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        ProjectsFolder.override = work
        defer { ProjectsFolder.override = nil; try? FileManager.default.removeItem(at: work) }
        let s = Session()
        s.project = DemoSong.make(); s.project.name = "Round Trip"
        let saved = work.appendingPathComponent("Round Trip.macband")
        s.write(to: saved)
        check(FileManager.default.fileExists(atPath: saved.path) && !s.isDirty, "a project saves to a file")
        let s2 = Session()
        s2.openProject(url: saved)
        check(s2.project.tracks.count == 3 && s2.project.tempo == 104 && s2.fileURL == saved, "…and opens again")
        check(ProjectScanner.summary(of: saved)?.notes == notesIn, "the project chooser can read it")
        s2.pushUndo(); s2.modify { $0.tempo = 150 }
        check(s2.project.tempo == 150, "an edit changes the project"); s2.undo()
        check(s2.project.tempo == 104, "…and undo puts it back")

        // sheet music
        s2.selectedTrackID = s2.project.tracks[0].id
        s2.selectedClipID = s2.project.tracks[0].clips[0].id
        if let cur = s2.currentScore() {
            let pdf = ScorePDF.data(score: cur.score, title: "Test", subtitle: "iOS", firstMeasure: 1)
            check(pdf.count > 2000 && pdf.prefix(4) == Data("%PDF".utf8), "sheet music exports as a PDF (\(pdf.count) bytes)")
            let lay = ScoreLayout(score: cur.score, width: 600, space: 9, firstMeasureNumber: 1)
            check(lay.systems.count > 0 && lay.heads.count > 0, "the notation lays out (\(lay.systems.count) systems, \(lay.heads.count) note heads)")
        } else { check(false, "the selected pattern has a score") }

        // GarageBand import
        let gb = work.appendingPathComponent("GarageBand", isDirectory: true)
        let band = gb.appendingPathComponent("Song.band", isDirectory: true)
        let alt = band.appendingPathComponent("Alternatives/000", isDirectory: true), media = band.appendingPathComponent("Media/Audio Files", isDirectory: true)
        try? FileManager.default.createDirectory(at: alt, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        (["BeatsPerMinute": 140, "SongKey": "A", "SongGenderKey": "minor", "SongSignatureNumerator": 3, "SongSignatureDenominator": 4] as NSDictionary).write(to: alt.appendingPathComponent("MetaData.plist"), atomically: true)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        if let wf = try? AVAudioFile(forWriting: media.appendingPathComponent("Song_bass.wav"), settings: fmt.settings), let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44100) {
            b.frameLength = 44100
            for c in 0..<2 { for i in 0..<44100 { b.floatChannelData![c][i] = 0.3 * sin(Float(i) * 0.05) } }
            try? wf.write(from: b)
        }
        let converted = GarageBandImporter.convert(band, into: work)
        check(converted.converted.first?.tracks == 1 && converted.converted.first?.keyText == "A minor", "a GarageBand project's audio, tempo and key import (\(converted.converted.first?.keyText ?? "nothing"))")
        if let c = converted.converted.first, let proj = try? JSONDecoder().decode(Project.self, from: Data(contentsOf: c.url)) {
            for f in proj.tracks.flatMap({ $0.audioClips.map { $0.file } }) { try? FileManager.default.removeItem(at: AudioStore.url(f)) }
        }

        // the scrolling waveform
        let ring = SampleRing(), hist = WaveHistory()
        hist.update(from: ring, dt: 1.0 / 60)
        for blockNo in 0..<40 {
            ring.write((0..<1024).map { 0.5 * sin(Float(blockNo * 1024 + $0) * 0.1) }, sampleRate: 44100)
            hist.update(from: ring, dt: 1.0 / 43)
        }
        let cols = WaveScrollDraw.columns(hist, window: 0.1, count: 200).cols.compactMap { $0 }
        check(cols.count > 150 && (cols.map { $0.1 }.max() ?? 0) > 0.4, "the waveform history fills in as sound arrives")

        // Vocal Tune: a sung-like tone (A3, 220 Hz) is imported, analysed, and found as one note near MIDI 57
        let tone = work.appendingPathComponent("tone.wav")
        let vf = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        if let wf = try? AVAudioFile(forWriting: tone, settings: vf.settings), let b = AVAudioPCMBuffer(pcmFormat: vf, frameCapacity: 44100 * 3) {
            b.frameLength = 44100 * 3
            for i in 0..<Int(b.frameLength) {
                let t = Double(i) / 44100
                b.floatChannelData![0][i] = Float(0.4 * sin(2 * Double.pi * 220 * t) + 0.15 * sin(2 * Double.pi * 440 * t) + 0.08 * sin(2 * Double.pi * 660 * t))
            }
            try? wf.write(from: b)
        }
        let s3 = Session()
        s3.addAudioTrack()
        s3.importAudio(url: tone, analyze: true)
        var analysed = false
        for _ in 0..<240 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let c = s3.project.tracks.flatMap({ $0.audioClips }).first, c.tune?.analyzed == true { analysed = true; break }       // (the word recognition goes on afterwards and may ask for permission)
        }
        let tuneClip = s3.project.tracks.flatMap { $0.audioClips }.first
        let found = tuneClip?.tune?.notes ?? []
        check(analysed && !found.isEmpty, "Vocal Tune finds notes in an imported tone (\(found.count) found)")
        check(found.contains { abs($0.pitch - 57) <= 1 }, "…at the right pitch (A3 = 57, found \(found.map { $0.pitch }))")
        for f in s3.project.tracks.flatMap({ $0.audioClips.map { $0.file } }) { try? FileManager.default.removeItem(at: AudioStore.url(f)) }

        out(failures == 0 ? "SELF CHECK PASSED" : "SELF CHECK FAILED (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }
}
