#if os(macOS)
import Foundation
import AppKit
import AVFoundation

/// `--videotest`: makes real movie files, imports them as clips, and checks the sound, the frames, the timing and the picture in the Video window.
@MainActor
enum VideoTest {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { failures += 1 } }

    /// A silent movie of flat colour blocks, one per entry, each `each` seconds long.
    static func makeMovie(at url: URL, colors: [(r: UInt8, g: UInt8, b: UInt8)], each: Double, size: CGSize = CGSize(width: 320, height: 180)) async throws {
        try? FileManager.default.removeItem(at: url)
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                           kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
        w.add(input)
        w.startWriting(); w.startSession(atSourceTime: .zero)
        let fps = 10
        var frame = 0
        for (ci, c) in colors.enumerated() {
            for _ in 0..<Int(each * Double(fps)) {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                var pb: CVPixelBuffer?
                CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &pb)
                guard let buf = pb else { continue }
                CVPixelBufferLockBaseAddress(buf, [])
                let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
                let rb = CVPixelBufferGetBytesPerRow(buf)
                for y in 0..<Int(size.height) { for x in 0..<Int(size.width) { let o = y * rb + x * 4; base[o] = c.b; base[o + 1] = c.g; base[o + 2] = c.r; base[o + 3] = 255 } }
                CVPixelBufferUnlockBaseAddress(buf, [])
                adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
                frame += 1
            }
            _ = ci
        }
        input.markAsFinished()
        await w.finishWriting()
        if w.status != .completed { throw w.error ?? NSError(domain: "videotest", code: 1) }
    }

    /// The same picture with a 440 Hz tone as its sound.
    static func addTone(to silent: URL, seconds: Double, at out: URL) async throws {
        let tone = FileManager.default.temporaryDirectory.appendingPathComponent("videotest-tone.caf")
        try? FileManager.default.removeItem(at: tone)
        let f = try AVAudioFile(forWriting: tone, settings: AudioStore.fileSettings(channels: 2), commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = Int(seconds * 44100)
        let buf = AVAudioPCMBuffer(pcmFormat: AudioStore.format, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for c in 0..<2 { for i in 0..<n { buf.floatChannelData![c][i] = 0.5 * sinf(2 * .pi * 440 * Float(i) / 44100) } }
        try f.write(from: buf)
        let comp = AVMutableComposition()
        let v = AVURLAsset(url: silent), a = AVURLAsset(url: tone)
        let dur = CMTime(seconds: seconds, preferredTimescale: 600)
        if let vt = try await v.loadTracks(withMediaType: .video).first, let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try ct.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: vt, at: .zero)
        }
        if let at = try await a.loadTracks(withMediaType: .audio).first, let ct = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try ct.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: at, at: .zero)
        }
        try? FileManager.default.removeItem(at: out)
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { throw NSError(domain: "videotest", code: 2) }
        ex.outputURL = out; ex.outputFileType = .mov
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in ex.exportAsynchronously { c.resume() } }
        if ex.status != .completed { throw ex.error ?? NSError(domain: "videotest", code: 3) }
    }

    static func pump(_ seconds: Double, until: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// Runs an async step to its end while the main loop keeps turning (the importers hop to the main actor).
    static func wait<T>(_ work: @escaping () async throws -> T) -> Result<T, Error> {
        var out: Result<T, Error>?
        Task { do { out = .success(try await work()) } catch { out = .failure(error) } }
        pump(60) { out != nil }
        return out ?? .failure(NSError(domain: "videotest", code: 9))
    }

    static func near(_ c: (r: Int, g: Int, b: Int)?, _ want: (Int, Int, Int)) -> Bool {
        guard let c else { return false }
        return abs(c.r - want.0) < 40 && abs(c.g - want.1) < 40 && abs(c.b - want.2) < 40
    }

    /// `--videomake out.mov`: an 8-second movie of colour blocks with a tone, for pictures.
    static func make(_ path: String) -> Int32 {
        _ = NSApplication.shared
        let silent = FileManager.default.temporaryDirectory.appendingPathComponent("videomake-silent.mov")
        let cols: [(r: UInt8, g: UInt8, b: UInt8)] = [(230, 60, 60), (240, 160, 40), (240, 220, 60), (70, 190, 90), (60, 160, 220), (110, 90, 220), (200, 80, 190), (60, 60, 70)]
        guard case .success = wait({ try await makeMovie(at: silent, colors: cols, each: 1, size: CGSize(width: 640, height: 360)) }),
              case .success = wait({ try await addTone(to: silent, seconds: 8, at: URL(fileURLWithPath: path)) }) else { print("couldn't make the movie"); return 1 }
        print("made", path)
        return 0
    }

    static func run() -> Int32 {
        _ = NSApplication.shared
        print("== Video clips test ==")
        let tmp = FileManager.default.temporaryDirectory
        let silent = tmp.appendingPathComponent("videotest-silent.mov"), loud = tmp.appendingPathComponent("videotest-loud.mov")
        let red = (r: UInt8(255), g: UInt8(0), b: UInt8(0)), green = (r: UInt8(0), g: UInt8(255), b: UInt8(0)), blue = (r: UInt8(0), g: UInt8(0), b: UInt8(255)), yellow = (r: UInt8(255), g: UInt8(255), b: UInt8(0))
        let made = wait { try await makeMovie(at: silent, colors: [red, green, blue, yellow], each: 1) }
        guard case .success = made else { print("FAIL making a test movie:", made); return 1 }
        _ = wait { try await addTone(to: silent, seconds: 4, at: loud) }

        // importing
        guard case .success(let imp) = wait({ try await VideoStore.importFile(silent) }) else { print("FAIL import"); return 1 }
        check(FileManager.default.fileExists(atPath: AudioStore.url(imp.video).path), "the video is copied into the MacBand folder")
        check(abs(imp.audio.duration - 4) < 0.15, "a video without sound still gets a silent clip as long as the picture (\(String(format: "%.2f", imp.audio.duration)) s)")
        check(abs(imp.size.width - 320) < 1 && abs(imp.size.height - 180) < 1, "the picture size is read")
        check(imp.audio.peaks.allSatisfy { $0 == 0 }, "the silent clip has flat peaks")
        guard case .success(let impLoud) = wait({ try await VideoStore.importFile(loud) }) else { print("FAIL import with sound"); return 1 }
        check((impLoud.audio.peaks.max() ?? 0) > 100 && abs(impLoud.audio.duration - 4) < 0.2, "a video with sound brings its sound in as the clip's audio")
        check(wait({ await VideoStore.hasPicture(silent) }).value == true && wait({ await VideoStore.hasPicture(AudioStore.url(impLoud.audio.file)) }).value == false, "a file with a picture is told apart from plain audio")

        // frames for the arrangement
        var frames: [CGImage?] = []
        if case .success(let f) = wait({ await VideoThumbs.generate(AudioStore.url(imp.video)) }) { frames = f }
        func colorOf(_ i: CGImage?) -> (r: Int, g: Int, b: Int)? {
            guard let i else { return nil }
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(i, in: CGRect(x: -i.width / 2, y: -i.height / 2, width: i.width, height: i.height))
            return (Int(px[0]), Int(px[1]), Int(px[2]))
        }
        check(frames.count == VideoThumbs.count && frames.allSatisfy { $0 != nil }, "\(VideoThumbs.count) frames are made across the video")
        check(near(colorOf(frames.first ?? nil), (255, 0, 0)) && near(colorOf(frames.last ?? nil), (255, 255, 0)), "the first frame is the start of the picture and the last is its end")

        // which picture at which moment: 120 bpm = 2 beats a second; the clip starts at beat 4 (2 s) and skips its first 0.5 s
        var p = Project(); p.tempo = 120
        var t = Track(name: "V", colorIndex: 0, kind: .audio)
        var clip = AudioClip(name: "clip", start: 4, file: imp.audio.file, duration: 4, length: 3)
        clip.offset = 0.5; clip.video = imp.video
        t.audioClips = [clip]
        p.tracks = [t]
        check(VideoPlan.cue(p, beat: 3.9) == nil, "before the clip starts there is no picture")
        check(abs((VideoPlan.cue(p, beat: 4)?.time ?? -1) - 0.5) < 1e-6, "at the clip's start the picture is at the trimmed-off point (0.5 s)")
        check(abs((VideoPlan.cue(p, beat: 5)?.time ?? -1) - 1.0) < 1e-6, "half a second in (1 beat) the picture is at 1.0 s")
        check(VideoPlan.cue(p, beat: 9.9) != nil && VideoPlan.cue(p, beat: 10) == nil, "the picture stops when the clip ends (3 s long)")
        var plain = t; plain.audioClips[0].video = nil
        var p2 = p; p2.tracks = [plain]
        check(VideoPlan.cue(p2, beat: 5) == nil, "an ordinary audio clip shows no picture")
        // tempo changes move the clip in seconds, and the picture follows
        var p3 = p; p3.tempo = 60
        check(abs((VideoPlan.cue(p3, beat: 5)?.time ?? -1) - 1.5) < 1e-6, "at 60 bpm a beat is a second, so one beat in the picture is at 1.5 s")

        // saving
        let enc = try! JSONEncoder().encode(p)
        let back = try! JSONDecoder().decode(Project.self, from: enc)
        check(back.tracks[0].audioClips[0].video == imp.video && back.tracks[0].audioClips[0].hasVideo, "the video is kept when the project is saved and opened")
        var legacy = (try! JSONSerialization.jsonObject(with: enc)) as! [String: Any]
        var tracks = legacy["tracks"] as! [[String: Any]]
        var clips = tracks[0]["audioClips"] as! [[String: Any]]
        clips[0].removeValue(forKey: "video"); tracks[0]["audioClips"] = clips; legacy["tracks"] = tracks
        let old = try? JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(old?.tracks[0].audioClips[0].video == nil, "projects saved before video clips existed still open")

        // the Video window follows the playhead
        let s = Session()
        s.project = p
        let view = VideoView(session: s)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = view
        win.orderFrontRegardless()
        func show(beat: Double, want: (Int, Int, Int), _ what: String) {
            s.transport.beat = beat
            var ok = false
            let end = Date().addingTimeInterval(8)
            while Date() < end && !ok { view.step(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)); ok = near(view.centerColor(), want) }
            check(ok, what)
        }
        show(beat: 5, want: (0, 255, 0), "at 1.0 s the window shows the green part")                  // 1.0 s → green (1–2 s)
        show(beat: 8, want: (0, 0, 255), "moving the playhead to 2.5 s jumps the picture to blue")      // 0.5 + 2 s = 2.5 s → blue (2–3 s)
        show(beat: 4.2, want: (255, 0, 0), "moving it back shows red again")                           // 0.5 + 0.1 = 0.6 s → red
        s.transport.beat = 20; view.step()
        check(view.lastCue == nil, "past the end of the clip the window shows no picture")
        // playing: the picture runs by itself and keeps up with the transport
        s.transport.beat = 4.2; s.transport.isPlaying = true
        var sawBlue = false
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 2.8 {
            s.transport.beat = 4.2 + Date().timeIntervalSince(t0) * 2        // the transport runs at 2 beats a second
            view.step(); RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            if near(view.centerColor(), (0, 0, 255)) { sawBlue = true }
        }
        check(sawBlue, "while playing the picture runs on to the blue part (it started at red, 0.6 s)")
        s.transport.isPlaying = false; view.step()

        print(failures == 0 ? "ALL VIDEO CHECKS PASSED" : "\(failures) VIDEO CHECK(S) FAILED")
        return failures == 0 ? 0 : 1
    }
}

private extension Result {
    var value: Success? { if case .success(let v) = self { return v }; return nil }
}
#endif
