import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import AVFoundation

/// `--visualtest`: the spectrum analyzer finds the right frequencies, the live audio reaches it, and every shape draws.
/// `--visualshots <dir>` writes a PNG of every mode and palette.
@MainActor enum VisualizerTest {
    static var failures = 0
    static func check(_ ok: Bool, _ m: String) { print(ok ? "  ok    \(m)" : "  FAIL  \(m)"); if !ok { failures += 1 } }

    static func sine(_ hz: Double, amp: Float, n: Int = 8192, sr: Double = 44100) -> [Float] {
        (0..<n).map { amp * Float(sin(2 * Double.pi * hz * Double($0) / sr)) }
    }
    static func settle(_ a: SpectrumAnalyzer, _ ring: SampleRing, frames: Int = 40) { for _ in 0..<frames { a.update(from: ring, dt: 1.0 / 60) } }
    static func peakBand(_ a: SpectrumAnalyzer) -> Int { a.bands.enumerated().max { $0.element < $1.element }!.offset }
    static func peakHz(_ a: SpectrumAnalyzer) -> Double { SpectrumAnalyzer.bandFrequency(peakBand(a)) }

    static func render(_ f: SpectrumFrame) -> [UInt8] {
        let w = 480, h = 300
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return [] }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gc
        let ctx = gc.cgContext
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        VisualizerShapes.background(ctx, CGSize(width: w, height: h), level: 0)
        VisualizerShapes.draw(.wave, ctx: ctx, size: CGSize(width: w, height: h), frame: f, palette: .accent, accent: .systemRed)
        NSGraphicsContext.restoreGraphicsState()
        return Array(UnsafeBufferPointer(start: rep.bitmapData!, count: rep.bytesPerRow * h))
    }
    static func picturesDiffer(_ f: SpectrumFrame) -> Bool {
        var g = f; g.scroll = nil
        let a = render(f), b = render(g)
        return !a.isEmpty && zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count) > 0.05
    }

    static func run() -> Int32 {
        _ = NSApplication.shared
        print("== Visualizer test ==")
        // band layout
        check(SpectrumAnalyzer.bandEdge(0) == SpectrumAnalyzer.lowHz && abs(SpectrumAnalyzer.bandEdge(SpectrumAnalyzer.bandCount) - SpectrumAnalyzer.highHz) < 1e-6, "72 bands span 30 Hz to 16 kHz")
        check((0..<SpectrumAnalyzer.bandCount).allSatisfy { SpectrumAnalyzer.bandEdge($0 + 1) > SpectrumAnalyzer.bandEdge($0) }, "band edges rise steadily")

        for hz in [100.0, 440.0, 1000.0, 4000.0, 10000.0] {
            let ring = SampleRing(), a = SpectrumAnalyzer()
            ring.write(sine(hz, amp: 0.5), sampleRate: 44100)
            settle(a, ring)
            let found = peakHz(a)
            check(abs(found / hz - 1) < 0.12, String(format: "a %.0f Hz tone lights the band at %.0f Hz (value %.2f)", hz, found, a.bands[peakBand(a)]))
        }
        do {
            let ring = SampleRing(), a = SpectrumAnalyzer()
            settle(a, ring, frames: 10)
            check(a.bands.allSatisfy { $0 < 0.02 } && a.level < 0.02, "silence shows nothing")
            ring.write(sine(1000, amp: 0.5), sampleRate: 44100); settle(a, ring)
            let loud = a.bands[peakBand(a)]
            ring.write(sine(1000, amp: 0.02), sampleRate: 44100); settle(a, ring)
            let soft = a.bands[peakBand(a)]
            check(loud > soft + 0.25, String(format: "louder is taller (%.2f vs %.2f)", loud, soft))
            check(a.peaks[peakBand(a)] >= a.bands[peakBand(a)], "the peak cap sits at or above the bar")
            // and the bars fall back when the sound stops
            ring.write([Float](repeating: 0, count: 16384), sampleRate: 44100); settle(a, ring, frames: 120)
            check(a.bands.allSatisfy { $0 < 0.02 }, "the bars fall back to zero once the sound stops")
        }
        do {
            let ring = SampleRing(), a = SpectrumAnalyzer()
            let two = zip(sine(200, amp: 0.3), sine(4000, amp: 0.3)).map { $0 + $1 }
            ring.write(two, sampleRate: 44100); settle(a, ring)
            let lowBand = a.bands.indices.min { abs(SpectrumAnalyzer.bandFrequency($0) - 200) < abs(SpectrumAnalyzer.bandFrequency($1) - 200) }!
            let highBand = a.bands.indices.min { abs(SpectrumAnalyzer.bandFrequency($0) - 4000) < abs(SpectrumAnalyzer.bandFrequency($1) - 4000) }!
            let between = a.bands.indices.min { abs(SpectrumAnalyzer.bandFrequency($0) - 900) < abs(SpectrumAnalyzer.bandFrequency($1) - 900) }!
            check(a.bands[lowBand] > a.bands[between] + 0.2 && a.bands[highBand] > a.bands[between] + 0.2, "two tones give two separate peaks")
        }
        do {
            let ring = SampleRing(), a = SpectrumAnalyzer()
            ring.write(sine(60, amp: 0.6), sampleRate: 44100); settle(a, ring)
            let bassTone = a.bass
            ring.write(sine(8000, amp: 0.6), sampleRate: 44100); settle(a, ring)
            check(bassTone > 0.3 && a.bass < bassTone * 0.4, String(format: "the bass level follows low notes (%.2f for 60 Hz, %.2f for 8 kHz)", bassTone, a.bass))
        }

        // live: a played piano note reaches the analyzer through the engine
        let engine = AudioEngine()
        var t = Track(name: "Piano", colorIndex: 0); t.instrument = InstrumentSpec(gmProgram: 0)
        engine.syncTracks([t])
        SelfTest.pump(30) { engine.strips[t.id]?.instrument != nil && engine.strips[t.id]?.loading == false }
        SelfTest.pump(0.4)
        let live = SpectrumAnalyzer()
        engine.noteOn(trackID: t.id, pitch: 60, velocity: 110)
        var best: Float = 0, hzAtBest = 0.0
        for _ in 0..<30 { SelfTest.pump(0.03); live.update(from: engine.sampleRing, dt: 0.03); if live.bands.max() ?? 0 > best { best = live.bands.max()!; hzAtBest = peakHz(live) } }
        engine.noteOff(trackID: t.id, pitch: 60)
        check(best > 0.3, String(format: "a played piano note lights the spectrum (%.2f)", best))
        check(hzAtBest > 150 && hzAtBest < 1800, String(format: "…at a sensible frequency (%.0f Hz for middle C)", hzAtBest))
        SelfTest.pump(3)
        for _ in 0..<60 { live.update(from: engine.sampleRing, dt: 1.0 / 60) }
        check((live.bands.max() ?? 1) < 0.15, "and it goes dark after the note ends")

        // the combined piano roll sees every track
        let cache = NoteCache()
        cache.rebuild(DemoSong.make())
        check(cache.names == ["Piano", "Bass", "Drums"] && Set(cache.notes.map { $0.track }) == [0, 1, 2], "all three tracks' notes are in the one roll")
        check(cache.notes.count == DemoSong.make().tracks.reduce(0) { $0 + $1.clips.reduce(0) { $0 + $1.notes.count } }, "…every note of them")
        check(zip(cache.notes, cache.notes.dropFirst()).allSatisfy { $0.start <= $1.start }, "notes are sorted by time")
        check(Set((0..<cache.colors.count).map { cache.colors[$0].hashValue }).count == 3, "each track has its own colour")

        // the canvas view draws every mode
        let s = Session()
        s.project = DemoSong.make()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        let canvas = VisualizerCanvas(session: s)
        canvas.frame = NSRect(x: 0, y: 0, width: 900, height: 480)
        win.contentView = canvas
        var blank = 0
        for mode in VisualMode.allCases {
            for pal in (mode == .notes ? [VisualPalette.accent] : VisualPalette.allCases) {
                s.visualMode = mode; s.visualPalette = pal
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vz-test.png")
                canvas.snapshot(to: url)
                if let img = NSBitmapImageRep(data: (try? Data(contentsOf: url)) ?? Data()) {
                    var colours = Set<UInt32>()
                    for y in stride(from: 0, to: img.pixelsHigh, by: 17) { for x in stride(from: 0, to: img.pixelsWide, by: 17) {
                        if let c = img.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { colours.insert(UInt32(c.redComponent * 31) << 10 | UInt32(c.greenComponent * 31) << 5 | UInt32(c.blueComponent * 31)) }
                    } }
                    if colours.count < 4 && mode == .notes { blank += 1 }
                } else { blank += 1 }
            }
        }
        s.visualMode = .notes; s.visualPalette = .accent                      // the test must not change the saved preferences
        UserDefaults.standard.removeObject(forKey: "visualMode"); UserDefaults.standard.removeObject(forKey: "visualPalette")
        check(blank == 0, "every mode draws without crashing (and the notes view isn't blank)")
        // the scrolling waveform glides evenly even though audio arrives in blocks
        do {
            let ring = SampleRing(), hist = WaveHistory()
            let sr = 44100.0
            hist.update(from: ring, dt: 1.0 / 60)                       // first call starts from now
            var written = 0.0, frameTime = 0.0, deltas: [Double] = [], lastHead = hist.head
            var phase = 0.0
            for frame in 0..<360 {                                       // six seconds at 60 frames per second
                frameTime += 1.0 / 60
                // the audio engine hands over 1024-sample blocks (every 23 ms), not a steady trickle
                while written + 1024 <= frameTime * sr {
                    let amp: Float = frame < 240 ? 0.5 : 0
                    let block = (0..<1024).map { i -> Float in amp * Float(sin(2 * Double.pi * 220 * (phase + Double(i)) / sr)) }
                    phase += 1024; written += 1024
                    ring.write(block, sampleRate: sr)
                }
                hist.update(from: ring, dt: 1.0 / 60)
                if frame > 60 && frame < 240 { deltas.append(hist.head - lastHead) }
                lastHead = hist.head
            }
            let mean = deltas.reduce(0, +) / Double(deltas.count)
            check(abs(mean - sr / 60) < 0.06 * sr / 60, String(format: "the waveform moves at a steady speed (%.0f samples a frame, expected %.0f)", mean, sr / 60))
            check((deltas.max() ?? 9e9) < mean * 1.4 && (deltas.min() ?? 0) > mean * 0.6, String(format: "…without stutter (slowest %.0f, fastest %.0f of %.0f)", deltas.min() ?? 0, deltas.max() ?? 0, mean))
            let mid = Int(hist.head) - Int(2.5 * sr)                          // from the loud part
            let loud = hist.extent(from: mid, count: 400)
            check(loud.map { $0.1 > 0.45 && $0.0 < -0.45 } == true, String(format: "a stretch of the loud part spans the signal (%.2f … %.2f)", loud?.0 ?? 0, loud?.1 ?? 0))
            let quiet = hist.extent(from: Int(hist.head) - 3000, count: 1000)
            check(quiet.map { abs($0.0) < 0.05 && abs($0.1) < 0.05 } == true, "…and the newest stretch, after the sound stopped, is flat")
            check(hist.extent(from: -5, count: 10) == nil && hist.extent(from: hist.produced - 3, count: 10) == nil, "samples that don't exist aren't made up")
            // zoom goes with speed: close up you see the wave itself, far out only its outline
            hist.update(from: ring, dt: 1.0 / 60)
            func ripple(_ window: Double) -> Double {                         // how much the column heights vary across the picture
                let n = WaveScrollDraw.columnCount(width: 1000)
                let spp = max(1, Int((window * sr / Double(n)).rounded()))
                let cols = (0..<n).compactMap { k in hist.extent(from: Int(0.5 * sr) + k * spp, count: spp) }
                let tops = cols.map { Double($0.1) }
                let m = tops.reduce(0, +) / Double(max(1, tops.count))
                return tops.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(max(1, tops.count))
            }
            check(ripple(0.02) > 20 * ripple(2.0) + 1e-6, String(format: "close up (0.02 s) the wave shows its cycles, far out (2 s) only the outline (%.4f vs %.6f)", ripple(0.02), ripple(2.0)))
            // a very loud or one-sided sound stays inside the picture (it used to poke out of the top)
            do {
                let ring2 = SampleRing(), loudHist = WaveHistory()
                loudHist.update(from: ring2, dt: 1.0 / 60)
                for blockNo in 0..<120 {
                    let block = (0..<1024).map { i -> Float in 0.9 + 3.0 * Float(sin(2 * Double.pi * 55 * Double(blockNo * 1024 + i) / sr)) }    // far above full scale, mostly above zero
                    ring2.write(block, sampleRate: sr); loudHist.update(from: ring2, dt: 1.0 / 43)
                }
                let size = CGSize(width: 900, height: 400)
                let box = WaveScrollDraw.path(size, history: loudHist, window: 0.1).boundingBox
                let cy = size.height * 0.42, amp = size.height * 0.3
                check(box.minY >= cy - amp - 0.5 && box.maxY <= cy + amp + 0.5, String(format: "a sound far above full scale stays inside the picture (%.0f … %.0f of %.0f … %.0f)", box.minY, box.maxY, cy - amp, cy + amp))
                var onlyPositive = [Float](repeating: 0.8, count: 1024)
                for i in 0..<1024 { onlyPositive[i] = 0.8 + 0.1 * Float(i % 7) / 7 }
                let ring3 = SampleRing(), posHist = WaveHistory()
                posHist.update(from: ring3, dt: 1.0 / 60)
                for _ in 0..<60 { ring3.write(onlyPositive, sampleRate: sr); posHist.update(from: ring3, dt: 1.0 / 43) }
                let box2 = WaveScrollDraw.path(size, history: posHist, window: 0.1).boundingBox
                check(box2.minY >= cy - amp - 0.5 && box2.maxY <= cy + amp + 0.5, "a sound that sits above zero (all samples positive) stays inside too")
            }
            // nothing arriving at all (the engine stopped): the picture keeps gliding over silence
            let before = hist.head
            for _ in 0..<60 { hist.update(from: ring, dt: 1.0 / 60) }
            check(hist.head - before > 0.8 * sr, String(format: "with no audio coming in it keeps moving (%.0f samples in a second)", hist.head - before))
            // drawing it works
            let f = SpectrumFrame(bands: [Float](repeating: 0.3, count: 72), peaks: [Float](repeating: 0.3, count: 72), wave: [Float](repeating: 0, count: 1024), level: 0.3, bass: 0.2, time: 0, scroll: hist)
            check(picturesDiffer(f), "the Wave shape draws the scrolling picture")
        }
        // the Wave picture is handed to Core Animation layers that sit where the picture should be
        do {
            let s = Session()
            s.visualMode = .wave
            UserDefaults.standard.removeObject(forKey: "visualMode")
            let host = VisualizerBackdrop(session: s)
            host.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
            let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            win.contentView = host
            win.orderFrontRegardless()                       // the picture only animates in a visible window
            host.layoutSubtreeIfNeeded()
            for _ in 0..<30 { host.canvas.step(1.0 / 60) }
            let st = host.canvas.waveLayerState
            check(st.shown, "the wave layers are shown in Wave mode")
            check(abs(st.frame.width - 900) < 1 && abs(st.frame.height - 500) < 1, "…covering the picture (\(Int(st.frame.width)) x \(Int(st.frame.height)))")
            check(st.pathBox.width > 800 && st.pathBox.minY > 0 && st.pathBox.maxY < 500, "…with a line across the whole width, inside it (\(st.pathBox))")
            s.visualMode = .bars
            host.canvas.step(1.0 / 60)
            check(!host.canvas.waveLayerState.shown, "…and hidden in the other modes")
            win.close()
        }
        // the round shapes follow the notes
        do {
            var p = Project(); p.tempo = 120
            var a = Track(name: "Keys", colorIndex: 0); var c = Clip(name: "c", start: 0, length: 16)
            c.notes = [Note(pitch: 60, start: 0, length: 2, velocity: 100), Note(pitch: 64, start: 4, length: 2, velocity: 100)]
            a.clips = [c]
            var b = Track(name: "Bass", colorIndex: 1); var c2 = Clip(name: "c", start: 0, length: 16)
            c2.notes = [Note(pitch: 40, start: 8, length: 2, velocity: 110)]
            b.clips = [c2]
            p.tracks = [a, b]
            let cache = NoteCache(); cache.rebuild(p)
            check(cache.sounding(at: 1, tail: 0).map { $0.pitch } == [60], "the cache finds the note sounding at beat 1")
            check(cache.sounding(at: 3, tail: 0).isEmpty, "…and nothing in the gap")
            check(cache.sounding(at: 2.2, tail: 0.5).map { $0.pitch } == [60], "…a note just released is still found, so it can fade")
            check(Set(cache.sounding(at: 4.5, tail: 0).map { $0.pitch }) == [64], "…later notes too")
            let f = SpectrumFrame(bands: [Float](repeating: 0, count: 72), peaks: [Float](repeating: 0, count: 72), wave: [], level: 0, bass: 0, time: 0)
            func picture(_ draw: (CGContext, CGSize) -> Void) -> [UInt8] {
                let w = 420, h = 320
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                      let gc = NSGraphicsContext(bitmapImageRep: rep) else { return [] }
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gc
                let ctx = gc.cgContext
                ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
                VisualizerShapes.background(ctx, CGSize(width: w, height: h), level: 0)
                draw(ctx, CGSize(width: w, height: h))
                NSGraphicsContext.restoreGraphicsState()
                return Array(UnsafeBufferPointer(start: rep.bitmapData!, count: rep.bytesPerRow * h))
            }
            func difference(_ x: [UInt8], _ y: [UInt8]) -> Double { zip(x, y).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(max(1, x.count)) }
            let spb = 0.5
            for (name, draw) in [("Circle", { (ctx: CGContext, s: CGSize, beat: Double) in NoteCircles.wheel(ctx, s, cache: cache, beat: beat, secPerBeat: spb, frame: f, accent: .systemRed) }),
                                 ("Rings", { (ctx: CGContext, s: CGSize, beat: Double) in NoteCircles.rings(ctx, s, cache: cache, beat: beat, secPerBeat: spb, frame: f, accent: .systemRed) })] {
                let quiet = picture { draw($0, $1, 3.0) }, quiet2 = picture { draw($0, $1, 3.1) }
                let c4 = picture { draw($0, $1, 1.0) }, e4 = picture { draw($0, $1, 4.5) }, bass = picture { draw($0, $1, 8.5) }
                check(difference(quiet, quiet2) < 0.05, "\(name): with no note playing the picture holds still")
                check(difference(quiet, c4) > 0.15, String(format: "%@: a playing note appears (%.2f)", name, difference(quiet, c4)))
                check(difference(c4, e4) > 0.3, "\(name): a different note is a different picture")
                check(difference(e4, bass) > 0.3, "\(name): another track's note shows up too")
                // the track colour: the piano note is red-ish (track 0 = the accent colour), the bass note is not
                func warmth(_ px: [UInt8]) -> Double { var r = 0.0, b = 0.0; var i = 0; while i + 3 < px.count { r += Double(px[i]); b += Double(px[i + 2]); i += 4 }; return r - b }
                check(warmth(c4) - warmth(quiet) > warmth(bass) - warmth(quiet) + 200, "\(name): each note takes its own track's colour")
            }
        }
        print(failures == 0 ? "ALL VISUALIZER CHECKS PASSED" : "\(failures) VISUALIZER CHECK(S) FAILED")
        return failures == 0 ? 0 : 1
    }

    // MARK: Pictures

    static func writePNG(size: CGSize, to url: URL, _ body: (CGContext) -> Void) {
        let scale: CGFloat = 1
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let cg = gc.cgContext
        cg.translateBy(x: 0, y: size.height); cg.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        body(cg)
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// A believable spectrum: strong lows falling away, with a few peaks.
    static func fakeFrame(time: Double) -> SpectrumFrame {
        var bands = [Float](), peaks = [Float]()
        for i in 0..<SpectrumAnalyzer.bandCount {
            let x = Double(i) / Double(SpectrumAnalyzer.bandCount)
            var v = 0.85 - 0.55 * x
            v += 0.18 * sin(x * 31 + time) + 0.12 * sin(x * 13 - time * 1.7)
            for c in [0.1, 0.32, 0.5] { v += 0.35 * exp(-pow((x - c) / 0.035, 2)) }
            bands.append(Float(min(1, max(0.02, v))))
            peaks.append(Float(min(1, max(0.02, v + 0.1))))
        }
        let wave = (0..<1024).map { i -> Float in
            let x = Double(i) / 1024
            return Float(0.5 * sin(2 * Double.pi * 6 * x) + 0.22 * sin(2 * Double.pi * 17 * x + 1) + 0.1 * sin(2 * Double.pi * 41 * x))
        }
        return SpectrumFrame(bands: bands, peaks: peaks, wave: wave, level: 0.7, bass: 0.65, time: time)
    }

    static func shots(_ dir: String) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let size = CGSize(width: 960, height: 520)
        let accent = Theme.accentNS
        for mode in VisualMode.allCases where mode != .notes {
            for pal in VisualPalette.allCases {
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(mode.rawValue.lowercased())-\(pal.rawValue.lowercased()).png")
                writePNG(size: size, to: url) { ctx in
                    VisualizerShapes.background(ctx, size, level: 0.7)
                    VisualizerShapes.draw(mode, ctx: ctx, size: size, frame: fakeFrame(time: 2.2), palette: pal, accent: accent)
                }
            }
        }
        let cache = NoteCache(); cache.rebuild(DemoSong.make())
        for (name, follow, beat) in [("notes-follow", true, 5.3), ("notes-overview", false, 9.0)] {
            writePNG(size: size, to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")) { ctx in
                VisualizerShapes.background(ctx, size, level: 0.5)
                NotesRoll.draw(ctx, size, cache: cache, beat: beat, playing: true, windowBeats: 16, follow: follow, accent: accent)
            }
        }
        print("wrote pictures to \(dir)")
    }
}
