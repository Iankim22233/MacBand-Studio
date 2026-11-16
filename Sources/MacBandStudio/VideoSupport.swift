#if os(macOS)
import Foundation
import AVFoundation
import AppKit
import SwiftUI
import Combine

/// Video clips: a video file lives on an audio track as a clip. Its own sound plays like any audio clip, its picture is
/// shown in the Video window (⌥⌘M) following the playhead, and the arrangement shows a strip of frames on the clip.

// MARK: - Importing

enum VideoStore {
    static let extensions: Set<String> = ["mov", "mp4", "m4v"]

    struct Imported { var video: String; var audio: AudioStore.Imported; var size: CGSize }

    static func hasPicture(_ url: URL) async -> Bool {
        let tracks = (try? await AVURLAsset(url: url).loadTracks(withMediaType: .video)) ?? []
        return !tracks.isEmpty
    }

    /// Copies the video into MacBand's folder and brings its sound in as the clip's audio (silence if it has none).
    static func importFile(_ src: URL) async throws -> Imported {
        let asset = AVURLAsset(url: src)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AudioStore.StoreError.unreadable("“\(src.lastPathComponent)” doesn't contain a picture.")
        }
        let seconds = try await asset.load(.duration).seconds
        guard seconds.isFinite, seconds > 0 else { throw AudioStore.StoreError.unreadable("Couldn't read the length of “\(src.lastPathComponent)”.") }
        let natural = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let size = natural.applying(transform)
        let ext = src.pathExtension.lowercased()
        let name = UUID().uuidString + "." + (extensions.contains(ext) ? ext : "mov")
        try FileManager.default.copyItem(at: src, to: AudioStore.url(name))

        let hasSound = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        let audio: AudioStore.Imported
        if !hasSound {
            audio = try AudioStore.silence(seconds: seconds)
        } else if let direct = try? AudioStore.importFile(src) {
            audio = direct
        } else {
            // some containers can't be read as audio directly: pull the sound out first
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw AudioStore.StoreError.unreadable("Couldn't read the sound of “\(src.lastPathComponent)”.")
            }
            ex.outputURL = tmp; ex.outputFileType = .m4a
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in ex.exportAsynchronously { c.resume() } }
            audio = try AudioStore.importFile(tmp)
        }
        return Imported(video: name, audio: audio, size: CGSize(width: abs(size.width), height: abs(size.height)))
    }
}

extension AudioStore {
    /// A silent stereo file of `seconds` (for videos without sound), with flat peaks.
    static func silence(seconds: Double) throws -> Imported {
        let name = UUID().uuidString + ".caf"
        let out = try AVAudioFile(forWriting: url(name), settings: fileSettings(channels: 2), commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: AVAudioFrameCount = 44100
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw StoreError.unreadable("Out of memory.") }
        buf.frameLength = chunk
        for c in 0..<2 { memset(buf.floatChannelData![c], 0, Int(chunk) * 4) }
        var left = Int((seconds * rate).rounded())
        let total = left
        while left > 0 {
            buf.frameLength = AVAudioFrameCount(min(Int(chunk), left))
            try out.write(from: buf)
            left -= Int(buf.frameLength)
        }
        return Imported(file: name, duration: Double(total) / rate, peaks: Data(count: Int(seconds * 100) + 1), sampleRate: rate, channels: 2)
    }
}

// MARK: - Which picture, when

struct VideoCue { var clip: AudioClip; var time: Double }

enum VideoPlan {
    /// The video clip showing at `beat` (the one on the lowest track wins where clips overlap) and the moment of the file to show.
    static func cue(_ p: Project, beat: Double) -> VideoCue? {
        let now = p.seconds(atBeat: beat)
        var found: VideoCue?
        for t in p.tracks {
            for c in t.audioClips where c.video != nil {
                let rel = now - p.seconds(atBeat: c.start)
                guard rel >= -1e-9, rel < c.length else { continue }
                let time = c.offset + max(0, rel)
                if time < c.duration + c.offset { found = VideoCue(clip: c, time: time) }
            }
        }
        return found
    }
}

// MARK: - Frames for the arrangement

@MainActor
final class VideoThumbs {
    static let shared = VideoThumbs()
    nonisolated static let count = 24
    var onReady: (() -> Void)?
    private var cache: [String: [CGImage?]] = [:]
    private var pending = Set<String>()

    /// The frames of a video, evenly spaced across its whole length (nil entries are frames that couldn't be read). Starts making them if needed.
    func frames(_ file: String) -> [CGImage?]? {
        if let f = cache[file] { return f }
        guard !pending.contains(file), FileManager.default.fileExists(atPath: AudioStore.url(file).path) else { return nil }
        pending.insert(file)
        Task { [weak self] in
            let made = await Self.generate(AudioStore.url(file))
            guard let self else { return }
            self.pending.remove(file)
            self.cache[file] = made
            self.onReady?()
        }
        return nil
    }

    nonisolated static func generate(_ url: URL) async -> [CGImage?] {
        let asset = AVURLAsset(url: url)
        guard let dur = try? await asset.load(.duration).seconds, dur > 0 else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 240, height: 135)
        gen.requestedTimeToleranceBefore = CMTime(seconds: dur / Double(count), preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = gen.requestedTimeToleranceBefore
        var out = [CGImage?](repeating: nil, count: count)
        let times = (0..<count).map { CMTime(seconds: (Double($0) + 0.5) / Double(count) * dur, preferredTimescale: 600) }
        var i = 0
        for await r in gen.images(for: times) {
            if case .success(_, let img, _) = r { out[i] = img }
            i += 1
        }
        // a frame that failed takes its neighbour's picture
        for k in 1..<count where out[k] == nil { out[k] = out[k - 1] }
        for k in stride(from: count - 2, through: 0, by: -1) where out[k] == nil { out[k] = out[k + 1] }
        return out
    }
}

// MARK: - The Video window

/// The picture of the video clip under the playhead, kept in step with the transport: it plays with the song, and scrubs when the playhead moves.
final class VideoView: NSView {
    let session: Session
    private let layerHost = AVPlayerLayer()
    private let message = NSTextField(labelWithString: "No video at the playhead")
    private var players: [String: AVPlayer] = [:]
    private var outputs: [String: AVPlayerItemVideoOutput] = [:]
    private var shown: String?
    private var seeking = false
    private var timer: Timer?
    private(set) var lastCue: VideoCue?

    init(session: Session) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 450))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layerHost.videoGravity = .resizeAspect
        layerHost.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(layerHost)
        message.textColor = NSColor(white: 1, alpha: 0.55)
        message.font = .systemFont(ofSize: 14)
        message.alignment = .center
        addSubview(message)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layerHost.frame = bounds
        message.frame = NSRect(x: 0, y: bounds.midY - 12, width: bounds.width, height: 24)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.step() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func player(for file: String) -> AVPlayer {
        if let p = players[file] { return p }
        let item = AVPlayerItem(url: AudioStore.url(file))
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(out)
        let p = AVPlayer(playerItem: item)
        p.isMuted = true                    // the sound comes from the audio engine
        p.actionAtItemEnd = .pause
        players[file] = p; outputs[file] = out
        return p
    }

    /// Follows the transport once: pick the clip, then play, pause or jump the picture so it matches the playhead.
    func step() {
        let beat = session.transport.beat
        let playing = session.transport.isPlaying
        guard let cue = VideoPlan.cue(session.project, beat: beat), let file = cue.clip.video,
              FileManager.default.fileExists(atPath: AudioStore.url(file).path) else {
            lastCue = nil
            for p in players.values where p.rate != 0 { p.pause() }
            layerHost.isHidden = true
            message.isHidden = false
            message.stringValue = session.project.tracks.contains { $0.audioClips.contains { $0.video != nil } } ? "No video at the playhead" : "Drop a video onto the window, or use File ▸ Import ▸ Video File…"
            shown = nil
            return
        }
        lastCue = cue
        let p = player(for: file)
        if shown != file {
            for (f, other) in players where f != file && other.rate != 0 { other.pause() }
            layerHost.player = p
            shown = file
            seeking = false
        }
        layerHost.isHidden = false
        message.isHidden = true
        let target = CMTime(seconds: cue.time, preferredTimescale: 600)
        let at = p.currentTime().seconds
        if playing {
            if p.rate == 0 {
                guard !seeking else { return }
                seek(p, to: target) { p.play() }
            } else if abs(at - cue.time) > 0.25, !seeking {
                seek(p, to: target) { p.play() }
            }
        } else {
            if p.rate != 0 { p.pause() }
            if abs(at - cue.time) > 0.02, !seeking { seek(p, to: target) {} }
        }
    }

    private func seek(_ p: AVPlayer, to t: CMTime, then: @escaping () -> Void) {
        seeking = true
        p.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async { self?.seeking = false; then() }
        }
    }

    /// The colour of the picture's centre right now (for the tests), nil until a frame has arrived.
    func centerColor() -> (r: Int, g: Int, b: Int)? {
        guard let file = shown, let out = outputs[file], let p = players[file] else { return nil }
        var display = CMTime.zero
        guard let buf = out.copyPixelBuffer(forItemTime: p.currentTime(), itemTimeForDisplay: &display) ?? lastBuffer else { return nil }
        lastBuffer = buf
        CVPixelBufferLockBaseAddress(buf, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf), rowBytes = CVPixelBufferGetBytesPerRow(buf)
        let px = base.advanced(by: (h / 2) * rowBytes + (w / 2) * 4).assumingMemoryBound(to: UInt8.self)
        return (Int(px[2]), Int(px[1]), Int(px[0]))
    }
    private var lastBuffer: CVPixelBuffer?
}

@MainActor
final class VideoWindow: NSObject, NSWindowDelegate {
    static let shared = VideoWindow()
    private(set) var window: NSWindow?
    private(set) var view: VideoView?

    func show(_ session: Session) {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let v = VideoView(session: session)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 450), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Video"
        w.identifier = NSUserInterfaceItemIdentifier("video")
        w.contentView = v
        w.contentAspectRatio = NSSize(width: 16, height: 9)
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.minSize = NSSize(width: 320, height: 180)
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.delegate = self
        w.center()
        window = w; view = v
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { sender.orderOut(nil) }
        return false
    }
}

// MARK: - Session

extension Session {
    func importVideo() {
        let panel = NSOpenPanel()
        panel.title = "Import Video"
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie]
        if panel.runModal() == .OK { for u in panel.urls { importMedia(url: u) } }
    }

    /// A file dropped or picked: video if it has a picture, otherwise plain audio.
    func importMedia(url: URL) {
        Task {
            if VideoStore.extensions.contains(url.pathExtension.lowercased()), await VideoStore.hasPicture(url) { importVideo(url: url) }
            else { importAudio(url: url) }
        }
    }

    /// Adds a video clip at the playhead (on the selected audio track, or a new one).
    func importVideo(url: URL) {
        busyMessage = "Importing “\(url.lastPathComponent)”…"
        Task {
            let result: Result<VideoStore.Imported, Error>
            do { result = .success(try await VideoStore.importFile(url)) } catch { result = .failure(error) }
            self.busyMessage = nil
            switch result {
            case .failure(let e): self.errorMessage = e.localizedDescription
            case .success(let imp):
                self.pushUndo()
                var trackID = self.selectedTrack?.kind == .audio ? self.selectedTrackID : nil
                let name = url.deletingPathExtension().lastPathComponent
                if trackID == nil {
                    let t = Track(name: name, colorIndex: self.project.tracks.count, kind: .audio)
                    self.modify { $0.tracks.append(t) }
                    trackID = t.id
                }
                var clip = AudioClip(name: name, start: (self.transport.beat * 4).rounded() / 4, file: imp.audio.file, sourceName: url.lastPathComponent,
                                     duration: imp.audio.duration, length: imp.audio.duration, peaks: imp.audio.peaks)
                clip.video = imp.video
                self.modify { p in if let ti = p.tracks.firstIndex(where: { $0.id == trackID }) { p.tracks[ti].audioClips.append(clip) } }
                self.selectedTrackID = trackID
                self.selectedAudioClipID = clip.id
                self.selectedClipID = nil
                VideoThumbs.shared.onReady = { [weak self] in self?.objectWillChange.send() }
                VideoWindow.shared.show(self)
                self.showToast("Imported “\(url.lastPathComponent)”")
            }
        }
    }
}
#endif
