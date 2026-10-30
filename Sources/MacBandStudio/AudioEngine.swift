import Foundation
import AVFoundation
import AudioToolbox
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CVST3Host)
import CVST3Host
#endif

/// One mixer channel: instrument → inserts → fader/pan mixer → master.
final class TrackStrip {
    let id: UUID
    var instrument: AVAudioUnitMIDIInstrument?
    var effects: [AVAudioUnit] = []
    let mixer = AVAudioMixerNode()
    var instrumentKey = ""
    var insertKeys: [UUID] = []
    var generation = 0
    var loading = false
    var peak: Float = 0
    var levelPeak: Float = 0        // max-hold since the last read
    var levelPower = 0.0, levelCount = 0     // mean power accumulated since the last read (drives the track glow)
    var measuring = false           // Auto Balance: accumulate loudness while rendering
    let weighting = MixWeighting() // filter state for the balance measurement
    var powerSum = 0.0, powerCount = 0
    var slot = -1                   // which master-mixer input this strip feeds
    var player: AVAudioPlayerNode?  // audio tracks
    var spec: InstrumentSpec?       // what the built-in sampler was loaded with
    /// plugin-spec id → live unit (for state capture & editor windows)
    var units: [UUID: AVAudioUnit] = [:]
    init(id: UUID) { self.id = id }
}

enum EngineError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

final class AudioEngine {
    /// The General MIDI sound bank: Apple's own on the Mac, the bundled GeneralUser GS SoundFont on iOS (which has no built-in bank).
    #if os(macOS)
    static let dlsURL = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
    #else
    static let dlsURL = Bundle.main.url(forResource: "GeneralUser_GS", withExtension: "sf2") ?? URL(fileURLWithPath: "/missing/GeneralUser_GS.sf2")
    #endif

    let engine = AVAudioEngine()
    private(set) var sequencer: AVAudioSequencer!
    private(set) var strips: [UUID: TrackStrip] = [:]
    private let click = SamplerUnit()
    private let previewSampler = SamplerUnit()
    private let auxMixer = AVAudioMixerNode()
    /// Keeps big arrangements (dozens of tracks summing) from clipping the output.
    /// One low-shelf band on the whole mix: the master Bass control.
    private let bassEQ = AVAudioUnitEQ(numberOfBands: 1)
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))

    // Every `connect(a, to: mixer)` without an explicit bus lands on input 0 and *replaces* whatever was
    // there, so each track needs its own input. 60 inputs on the master, then overflow submixers.
    private static let directSlots = 60, clickBus = 63, overflowSlots = 60
    private var freeSlots = Array((0..<(AudioEngine.directSlots + 3 * AudioEngine.overflowSlots)).reversed())
    private var overflowMixers: [Int: AVAudioMixerNode] = [:]

    private func connectToMaster(_ s: TrackStrip) {
        guard let slot = freeSlots.popLast() else { onError?("Too many tracks: MacBand supports up to 240."); return }
        s.slot = slot
        if slot < Self.directSlots {
            engine.connect(s.mixer, to: engine.mainMixerNode, fromBus: 0, toBus: slot, format: nil)
        } else {
            let group = (slot - Self.directSlots) / Self.overflowSlots
            let sub: AVAudioMixerNode
            if let m = overflowMixers[group] { sub = m } else {
                sub = AVAudioMixerNode(); engine.attach(sub)
                engine.connect(sub, to: engine.mainMixerNode, fromBus: 0, toBus: Self.directSlots + group, format: nil)
                overflowMixers[group] = sub
            }
            engine.connect(s.mixer, to: sub, fromBus: 0, toBus: (slot - Self.directSlots) % Self.overflowSlots, format: nil)
        }
    }
    private var clickLoaded = false
    var masterPeak: Float = 0
    /// The last moments of the output, for the visualizer.
    let sampleRing = SampleRing()

    /// Level meter plus the feed for the spectrum visualizer.
    private func installMasterTap() {
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            guard let self else { return }
            self.masterPeak = AudioEngine.peak(buf)
            self.sampleRing.write(buf)
        }
    }
    /// Loudest level each track reached during the last offline render (diagnostics).
    var renderPeaks: [UUID: Float] = [:]
    var metronomeOn = false { didSet { click.volume = metronomeOn ? 1 : 0 } }
    var onError: ((String) -> Void)?
    var onGraphChanged: (() -> Void)?
    private(set) var offlineBusy = false
    var measuringMaster = false
    let masterWeighting = MixWeighting()
    var masterPowerSum = 0.0, masterPowerCount = 0

    init() {
        #if os(iOS)
        Self.configureAudioSession()
        #endif
        engine.attach(limiter); engine.attach(bassEQ)
        let shelf = bassEQ.bands[0]
        shelf.filterType = .lowShelf; shelf.frequency = 140; shelf.bandwidth = 1; shelf.gain = 0; shelf.bypass = false
        engine.connect(engine.mainMixerNode, to: bassEQ, format: nil)
        engine.connect(bassEQ, to: limiter, format: nil)
        engine.connect(limiter, to: engine.outputNode, format: nil)
        engine.attach(auxMixer); engine.attach(click); engine.attach(previewSampler)
        click.volume = 0
        engine.connect(click, to: auxMixer, fromBus: 0, toBus: 0, format: nil)
        engine.connect(previewSampler, to: auxMixer, fromBus: 0, toBus: 1, format: nil)
        engine.connect(auxMixer, to: engine.mainMixerNode, fromBus: 0, toBus: Self.clickBus, format: nil)
        sequencer = AVAudioSequencer(audioEngine: engine)
        installMasterTap()
        engine.prepare()
        startEngine()
        loadClick()
    }

    /// Peak and mean-square power of a buffer (averaged over its channels).
    static func peakAndPower(_ buf: AVAudioPCMBuffer) -> (Float, Double) {
        guard let ch = buf.floatChannelData, buf.frameLength > 0 else { return (0, 0) }
        var p: Float = 0, sum = 0.0
        let n = Int(buf.frameLength), chans = Int(buf.format.channelCount)
        for c in 0..<chans { let d = ch[c]; for i in 0..<n { let v = d[i]; p = max(p, abs(v)); sum += Double(v * v) } }
        return (p, sum / Double(n * max(1, chans)))
    }

    static func peak(_ buf: AVAudioPCMBuffer) -> Float {
        guard let ch = buf.floatChannelData else { return 0 }
        var p: Float = 0
        for c in 0..<Int(buf.format.channelCount) {
            let d = ch[c]
            for i in 0..<Int(buf.frameLength) { p = max(p, abs(d[i])) }
        }
        return p
    }

    #if os(iOS)
    /// Playback through the speaker or headphones, in the background too, with a short buffer so notes feel immediate.
    static func configureAudioSession(recording: Bool = false) {
        let session = AVAudioSession.sharedInstance()
        do {
            if recording { try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP]) }
            else { try session.setCategory(.playback, mode: .default, options: []) }
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
        } catch { NSLog("MacBand: audio session setup failed: \(error)") }
    }
    #endif

    func startEngine() {
        guard !engine.isRunning else { return }
        do { try engine.start() } catch { onError?("Audio engine failed to start: \(error.localizedDescription)") }
    }

    private func loadClick() {
        DispatchQueue.global().async { [self] in
            do {
                try click.loadSoundBankInstrument(at: Self.dlsURL, program: 0, bankMSB: UInt8(kAUSampler_DefaultPercussionBankMSB), bankLSB: 0)
                clickLoaded = true
            } catch { NSLog("click load failed: \(error)") }
        }
    }

    // MARK: - Sound preview

    private var previewGeneration = 0
    private var previewLoaded = ""
    private var previewNotes: [Int] = []

    /// Plays a short phrase (a chord run, or a drum groove) on `spec` so sounds can be auditioned before use.
    func preview(_ spec: InstrumentSpec, completion: ((String?) -> Void)? = nil) {
        stopPreviewNotes()
        let gen = previewGeneration
        let key = Self.instrumentKey(spec)
        Self.samplerQueue.async { [self] in
            do {
                if previewLoaded != key { try Self.loadSamplerSync(previewSampler, spec: spec); previewLoaded = key }
            } catch {
                DispatchQueue.main.async { completion?(error.localizedDescription) }
                return
            }
            guard gen == previewGeneration else { return }
            startEngine()
            let phrase: [(Int, Double, Double)]
            if spec.isDrums {
                phrase = [(36, 0, 0.2), (42, 0, 0.2), (42, 0.25, 0.2), (38, 0.5, 0.2), (42, 0.5, 0.2), (42, 0.75, 0.2),
                          (36, 1.0, 0.2), (42, 1.0, 0.2), (36, 1.25, 0.2), (42, 1.25, 0.2), (38, 1.5, 0.2), (42, 1.5, 0.2), (46, 1.75, 0.2), (49, 2.0, 0.6)]
            } else {
                phrase = [(60, 0, 0.5), (64, 0.0, 0.5), (67, 0.0, 0.5), (72, 0.55, 0.45), (67, 1.0, 0.45), (64, 1.45, 0.45), (60, 1.9, 0.9)]
            }
            for (pitch, at, len) in phrase {
                DispatchQueue.global().asyncAfter(deadline: .now() + at) { [self] in
                    guard gen == previewGeneration else { return }
                    previewSampler.startNote(UInt8(pitch), withVelocity: 96, onChannel: 0)
                    DispatchQueue.global().asyncAfter(deadline: .now() + len) { [self] in
                        previewSampler.stopNote(UInt8(pitch), onChannel: 0)
                    }
                }
            }
            DispatchQueue.main.async { completion?(nil) }
        }
    }

    func stopPreviewNotes() {
        previewGeneration += 1
        for p in 0..<128 { previewSampler.stopNote(UInt8(p), onChannel: 0) }
    }

    // MARK: - Strips

    func syncTracks(_ tracks: [Track]) {
        let ids = Set(tracks.map { $0.id })
        for (id, strip) in strips where !ids.contains(id) {
            Task { @MainActor in PluginWindows.shared.discard(Array(strip.units.keys)) }
            remove(strip); strips[id] = nil
        }
        for t in tracks {
            let strip = strips[t.id] ?? makeStrip(t.id)
            let key = Self.trackKey(t)
            let inserts = t.inserts.map { $0.id }
            if strip.instrumentKey != key || strip.insertKeys != inserts { rebuild(strip, track: t) }
        }
    }

    static func trackKey(_ t: Track) -> String { t.kind == .audio ? "audio" : instrumentKey(t.instrument) }

    static func instrumentKey(_ i: InstrumentSpec) -> String {
        if let p = i.plugin { return "plug:\(p.id)" }
        if let s = i.sampler { return "smp:\(s.kind.rawValue):\(s.path):\(s.bank):\(s.program)" }
        return i.isDrums ? "gm:drums" : "gm:\(i.gmProgram)"
    }

    private func makeStrip(_ id: UUID) -> TrackStrip {
        let s = TrackStrip(id: id)
        engine.attach(s.mixer)
        connectToMaster(s)
        s.mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak s] buf, _ in
            guard let s else { return }
            let (pk, ms) = AudioEngine.peakAndPower(buf)
            s.peak = pk
            s.levelPeak = max(s.levelPeak, pk)
            s.levelPower += ms; s.levelCount += 1
            if s.measuring && ms > 1e-6 {                                              // gated: only count while it's sounding
                s.powerSum += s.weighting.meanSquare(buf); s.powerCount += 1
            }
        }
        strips[id] = s
        return s
    }

    private func remove(_ s: TrackStrip) {
        s.mixer.removeTap(onBus: 0)
        if let i = s.instrument { engine.disconnectNodeOutput(i); engine.detach(i) }
        for e in s.effects { engine.disconnectNodeOutput(e); engine.detach(e) }
        engine.disconnectNodeOutput(s.mixer)
        engine.detach(s.mixer)
        if s.slot >= 0 { freeSlots.append(s.slot); freeSlots.sort(by: >) }
    }

    /// Instantiate instrument + inserts for a track off the main thread, then splice them in.
    private func rebuild(_ s: TrackStrip, track: Track) {
        s.generation += 1
        let gen = s.generation
        s.loading = true
        if track.kind == .audio { rebuildAudio(s, track: track, gen: gen); return }
        let instSpec = track.instrument
        let insertSpecs = track.inserts
        Task { @MainActor in
            var newInst: AVAudioUnitMIDIInstrument?
            var newFx: [AVAudioUnit] = []
            var units: [UUID: AVAudioUnit] = [:]
            var samplerSpec: InstrumentSpec?
            do {
                #if os(iOS)
                let hostedPlugin: PluginSpec? = nil          // plugins can't be hosted on iOS: such a track plays its General MIDI sound instead
                let samplerSpecToLoad: InstrumentSpec = instSpec.plugin == nil ? instSpec : InstrumentSpec(gmProgram: instSpec.gmProgram, isDrums: instSpec.isDrums)
                #else
                let hostedPlugin = instSpec.plugin
                let samplerSpecToLoad = instSpec
                #endif
                if let p = hostedPlugin {
                    let u = try await PluginHost.instantiate(p)
                    guard let mi = u as? AVAudioUnitMIDIInstrument else { throw EngineError.message("\(p.name) is not an instrument.") }
                    newInst = mi; units[p.id] = u
                } else {
                    let sampler = SamplerUnit()
                    self.engine.attach(sampler)
                    try await Self.loadSampler(sampler, spec: samplerSpecToLoad)
                    newInst = sampler
                    samplerSpec = samplerSpecToLoad
                }
            } catch {
                self.onError?("Couldn't load instrument: \(error.localizedDescription)")
            }
            #if os(macOS)
            for p in insertSpecs {
                do {
                    let u = try await PluginHost.instantiate(p)
                    newFx.append(u); units[p.id] = u
                } catch { self.onError?("Couldn't load \(p.name): \(error.localizedDescription)") }
            }
            #endif                                          // (effect plugins can't be hosted on iOS: they are skipped)
            guard s.generation == gen, self.strips[s.id] === s else {
                for u in units.values where u.engine != nil { self.engine.detach(u) }
                return
            }
            // Tear down the old chain (and any editor windows that belonged to it)
            PluginWindows.shared.discard(Array(s.units.keys))
            if let i = s.instrument { self.engine.disconnectNodeOutput(i); self.engine.detach(i) }
            for e in s.effects { self.engine.disconnectNodeOutput(e); self.engine.detach(e) }
            self.engine.disconnectNodeInput(s.mixer)

            if let ni = newInst, ni.engine == nil { self.engine.attach(ni) }
            for fx in newFx { self.engine.attach(fx) }
            if let ni = newInst {
                var prev: AVAudioNode = ni
                for fx in newFx { self.engine.connect(prev, to: fx, format: nil); prev = fx }
                self.engine.connect(prev, to: s.mixer, format: nil)
            }
            s.instrument = newInst
            s.spec = samplerSpec
            s.effects = newFx
            s.units = units
            s.instrumentKey = Self.instrumentKey(instSpec)
            s.insertKeys = insertSpecs.map { $0.id }
            for (i, p) in insertSpecs.enumerated() where i < newFx.count { newFx[i].auAudioUnit.shouldBypassEffect = p.bypassed }
            s.loading = false
            self.startEngine()
            self.onGraphChanged?()
        }
    }

    /// Apple's sampler loads from the shared DLS bank aren't safe to run concurrently (a bulk import of
    /// dozens of tracks produced silent or failed instruments), so they go through one serial queue.
    private static let samplerQueue = DispatchQueue(label: "macband.sampler-load", qos: .userInitiated)

    /// Audio tracks: player → inserts → mixer.
    private func rebuildAudio(_ s: TrackStrip, track: Track, gen: Int) {
        let insertSpecs = track.inserts
        Task { @MainActor in
            var newFx: [AVAudioUnit] = []
            var units: [UUID: AVAudioUnit] = [:]
            #if os(macOS)
            for p in insertSpecs {
                do { let u = try await PluginHost.instantiate(p); newFx.append(u); units[p.id] = u }
                catch { self.onError?("Couldn't load \(p.name): \(error.localizedDescription)") }
            }
            #endif
            guard s.generation == gen, self.strips[s.id] === s else { return }
            PluginWindows.shared.discard(Array(s.units.keys))
            if let pl = s.player { pl.stop(); self.engine.disconnectNodeOutput(pl); self.engine.detach(pl) }
            for e in s.effects { self.engine.disconnectNodeOutput(e); self.engine.detach(e) }
            self.engine.disconnectNodeInput(s.mixer)
            let player = AVAudioPlayerNode()
            self.engine.attach(player)
            for fx in newFx { self.engine.attach(fx) }
            var prev: AVAudioNode = player
            var fmt: AVAudioFormat? = AudioStore.format
            for fx in newFx { self.engine.connect(prev, to: fx, format: fmt); prev = fx; fmt = nil }
            self.engine.connect(prev, to: s.mixer, format: fmt)
            s.player = player; s.instrument = nil; s.effects = newFx; s.units = units
            s.instrumentKey = "audio"; s.insertKeys = insertSpecs.map { $0.id }
            for (i, p) in insertSpecs.enumerated() where i < newFx.count { newFx[i].auAudioUnit.shouldBypassEffect = p.bypassed }
            s.loading = false
            self.startEngine()
            self.onGraphChanged?()
        }
    }

    // MARK: - Audio playback

    private var audioFiles: [String: AVAudioFile] = [:]
    private func audioFile(_ name: String) -> AVAudioFile? {
        if let f = audioFiles[name] { return f }
        guard let f = try? AVAudioFile(forReading: AudioStore.url(name)) else { return nil }
        audioFiles[name] = f; return f
    }
    /// Forget cached handles (after a tuned render replaced a file).
    func invalidateAudioCache() { audioFiles.removeAll() }

    func stopAudio() { for s in strips.values { s.player?.stop() } }

    /// Queue every audio clip from `songBeat` on and start the players. Call right after the sequencer starts.
    func startAudio(_ project: Project, songBeat: Double, delay0: Double) {
        for t in project.tracks where t.kind == .audio {
            guard let player = strips[t.id]?.player else { continue }
            player.stop()
            let items = AudioSchedule.items(project, track: t, startBeat: songBeat, delay0: delay0)
            guard !items.isEmpty else { continue }
            for it in items {
                guard let f = audioFile(it.file), it.frames > 0 else { continue }
                let at = AVAudioTime(sampleTime: AVAudioFramePosition((it.delay * AudioStore.rate).rounded()), atRate: AudioStore.rate)
                player.scheduleSegment(f, startingFrame: it.startFrame, frameCount: AVAudioFrameCount(it.frames), at: at, completionHandler: nil)
            }
            player.play()
        }
    }

    private static func playbackDelay(_ project: Project, at beat: Double) -> Double { 0.06 * 60 / max(20, project.bpm(at: beat)) }

    private static func loadSampler(_ s: SamplerUnit, spec: InstrumentSpec) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            samplerQueue.async {
                do { try loadSamplerSync(s, spec: spec); c.resume() } catch { c.resume(throwing: error) }
            }
        }
    }

    /// Loads whatever `spec` names into `s`: a GarageBand/Logic `.exs`, a SoundFont preset, or a built-in GM sound / drum kit.
    static func loadSamplerSync(_ s: SamplerUnit, spec: InstrumentSpec) throws {
        if let src = spec.sampler {
            let url = URL(fileURLWithPath: src.path)
            switch src.kind {
            case .exs:
                try s.loadInstrument(at: url)
            case .sf2, .dls:
                let perc = src.bank == 128
                let msb = UInt8(perc ? kAUSampler_DefaultPercussionBankMSB : kAUSampler_DefaultMelodicBankMSB)
                do { try s.loadSoundBankInstrument(at: url, program: UInt8(clamping: src.program), bankMSB: msb, bankLSB: UInt8(clamping: perc ? 0 : src.bank)) }
                catch where !perc && src.bank != 0 {
                    try s.loadSoundBankInstrument(at: url, program: UInt8(clamping: src.program), bankMSB: msb, bankLSB: 0)
                }
            }
            return
        }
        func load(_ prog: Int) throws {
            try s.loadSoundBankInstrument(
                at: dlsURL, program: UInt8(min(max(prog, 0), 127)),
                bankMSB: UInt8(spec.isDrums ? kAUSampler_DefaultPercussionBankMSB : kAUSampler_DefaultMelodicBankMSB),
                bankLSB: UInt8(kAUSampler_DefaultBankLSB))
        }
        do { try load(spec.gmProgram) }
        catch {
            // MIDI files often name drum kits / patches the built-in sound bank doesn't have
            // (e.g. kit 24+); fall back to the standard kit or piano rather than failing the track.
            try load(0)
        }
    }

    /// Replace an insert's bypass flag live.
    func setBypass(trackID: UUID, specID: UUID, bypass: Bool) {
        strips[trackID]?.units[specID]?.auAudioUnit.shouldBypassEffect = bypass
    }

    func unit(trackID: UUID, specID: UUID) -> AVAudioUnit? { strips[trackID]?.units[specID] }

    /// Snapshot the live state of every plugin so it can be stored in the project.
    func captureState(of specID: UUID) -> Data? {
        for s in strips.values {
            if let u = s.units[specID] { return PluginHost.captureState(u) }
        }
        return nil
    }

    // MARK: - Mix

    func applyMix(_ project: Project, beat: Double?) {
        engine.mainMixerNode.outputVolume = Mixer.gain(project.masterVolume)
        if bassEQ.bands[0].gain != Float(project.masterBass) { bassEQ.bands[0].gain = Float(project.masterBass) }
        let anySolo = project.tracks.contains { $0.solo }
        for t in project.tracks {
            guard let s = strips[t.id] else { continue }
            let audible = !t.mute && (!anySolo || t.solo)
            var gain = audible ? Mixer.gain(t.volume) * Float(pow(10, t.trim / 20)) : 0
            if audible, let b = beat {
                for c in t.clips where b >= c.start && b < c.end {
                    if let v = Automation.value(c.volume, at: b - c.start) { gain *= Float(Automation.gain(v)) }
                }
            }
            s.mixer.outputVolume = gain
            s.mixer.pan = Float(t.pan)
        }
    }

    // MARK: - Sequencer

    var isPlaying: Bool { sequencer.isPlaying }
    /// Song position in beats (the sequence itself is offset by `MIDIFile.playbackLead`).
    var position: Double {
        get { loopSource.loopWrapped(max(0, sequencer.currentPositionInBeats - MIDIFile.playbackLead)) }
        set { sequencer.currentPositionInBeats = max(0, newValue) + MIDIFile.playbackLead }
    }
    /// Project whose loop settings define how raw sequence time maps back onto the song.
    private var loopSource = Project()

    /// Let hosted VST3 plugins see the tempo and song position (arpeggiators, tempo-synced delays…).
    func updateHostTransport(bpm: Double, beat: Double, playing: Bool) {
        for s in strips.values {
            #if canImport(CVST3Host)
            for u in s.units.values { (u.auAudioUnit as? MBVST3AudioUnit)?.setHostTempo(bpm, beat: beat, playing: playing) }
            #endif
        }
    }

    func allNotesOff() {
        for s in strips.values {
            guard let i = s.instrument else { continue }
            for ch: UInt8 in 0..<1 {
                i.sendController(123, withValue: 0, onChannel: ch)
                i.sendController(120, withValue: 0, onChannel: ch)
                i.sendPitchBend(8192, onChannel: ch)
            }
        }
        if clickLoaded { click.sendController(123, withValue: 0, onChannel: 9) }
    }

    /// Re-render the project into the sequencer, keeping position and play state.
    func reloadSequence(_ project: Project, metronome: Bool) {
        whileRenderPaused { reloadSequenceNow(project, metronome: metronome) }
    }

    private func reloadSequenceNow(_ project: Project, metronome: Bool) {
        let wasPlaying = sequencer.isPlaying
        let songPos = position
        sequencer.stop()
        stopAudio()
        allNotesOff()
        loopSource = project
        let data = MIDIFile.build(project.loopUnrolled(), forExport: false, metronome: metronome)
        // The sequencer keeps the tempo events of whatever it loaded before and adds the new ones to them, so a tempo change
        // that was moved or deleted would still sound. Start from an empty tempo track every time.
        let tempoLength = sequencer.tempoTrack.lengthInBeats
        if tempoLength > 0 { sequencer.tempoTrack.clearEvents(in: AVBeatRange(start: 0, length: tempoLength + 1)) }
        do { try sequencer.load(from: data, options: []) } catch {
            onError?("Sequencer load failed: \(error.localizedDescription)"); return
        }
        let tracks = sequencer.tracks
        // The conductor (tempo) track is included in `tracks` ahead of the music tracks.
        let offset = max(0, tracks.count - (project.tracks.count + 1))
        for (i, t) in project.tracks.enumerated() {
            let idx = i + offset
            if idx < tracks.count { tracks[idx].destinationAudioUnit = strips[t.id]?.instrument }
        }
        let clickIdx = project.tracks.count + offset
        if clickIdx < tracks.count { tracks[clickIdx].destinationAudioUnit = click }
        for t in tracks { t.isLoopingEnabled = false }
        sequencer.currentPositionInBeats = songPos + MIDIFile.playbackLead
        sequencer.prepareToPlay()
        if wasPlaying { try? sequencer.start(); startAudio(project, songBeat: songPos, delay0: 0) }
    }

    /// Apple's sequencer talks to the plugins it feeds whenever it starts, stops or is reloaded. For a plugin running
    /// in another process (an AUv3 extension, an Intel-only AU) that call swaps callbacks the audio thread is using
    /// at that moment, which crashed the app in `AUAudioUnit_XPC`'s render block. While such a plugin is present the
    /// audio hardware is paused for the few milliseconds the call takes.
    var hasRemoteUnits: Bool {
        #if os(macOS)
        return strips.values.contains { s in
            (s.instrument.map { !$0.auAudioUnit.isLoadedInProcess } ?? false) || s.effects.contains { !$0.auAudioUnit.isLoadedInProcess }
        }
        #else
        return false                                        // iOS hosts no plugins in other processes
        #endif
    }

    func whileRenderPaused(_ body: () -> Void) {
        guard !offlineBusy, engine.isRunning, hasRemoteUnits else { body(); return }
        engine.pause()
        body()
        startEngine()
    }

    func play() {
        startEngine()
        // Start a hair early so events exactly on the start position aren't skipped.
        sequencer.currentPositionInBeats = max(0, sequencer.currentPositionInBeats - 0.06)
        sequencer.prepareToPlay()
        let startBeat = position
        whileRenderPaused {
            do { try sequencer.start() } catch { onError?("Couldn't start playback: \(error.localizedDescription)") }
        }
        startAudio(loopSource, songBeat: startBeat, delay0: Self.playbackDelay(loopSource, at: startBeat))
    }

    func stop() {
        whileRenderPaused {
            sequencer.stop()
            stopAudio()
            allNotesOff()
        }
    }

    // MARK: - Live notes

    func noteOn(trackID: UUID, pitch: Int, velocity: Int) {
        strips[trackID]?.instrument?.startNote(UInt8(pitch & 127), withVelocity: UInt8(min(127, max(1, velocity))), onChannel: 0)
    }
    func noteOff(trackID: UUID, pitch: Int) {
        strips[trackID]?.instrument?.stopNote(UInt8(pitch & 127), onChannel: 0)
    }

    // MARK: - Bounce

    /// Render the project to a WAV/AIFF/CAF file faster than real time.
    func bounce(_ project: Project, to url: URL, honorLoop: Bool = false, testSeconds: Double? = nil, progress: @escaping (Double) -> Void) throws {
        offlineBusy = true
        defer { offlineBusy = false }
        let wasPlaying = sequencer.isPlaying
        whileRenderPaused { sequencer.stop(); allNotesOff() }
        engine.stop()
        engine.mainMixerNode.removeTap(onBus: 0)

        let sr = 44100.0
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: false)!
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 512)
        // Switching to offline rendering re-initialises the samplers, which drops what they had loaded
        // (every sound turned into the same default tone), so load each one again.
        for st in strips.values {
            if let sam = st.instrument as? SamplerUnit, let sp = st.spec { try? Self.loadSamplerSync(sam, spec: sp) }
        }
        defer {
            engine.disableManualRenderingMode()
            // Leaving offline mode re-initialises the samplers again and they fall back to the default sine tone,
            // so load their sounds once more before playback resumes.
            for st in strips.values {
                if let sam = st.instrument as? SamplerUnit, let sp = st.spec { try? Self.loadSamplerSync(sam, spec: sp) }
            }
            installMasterTap()
            startEngine()
        }
        var p = project
        if !honorLoop { p.loopEnabled = false }
        try engine.start()
        reloadSequence(p, metronome: false)
        sequencer.currentPositionInBeats = (honorLoop ? p.loopStart : 0) + MIDIFile.playbackLead - 0.06
        sequencer.prepareToPlay()
        try sequencer.start()
        startAudio(p, songBeat: 0, delay0: Self.playbackDelay(p, at: 0))

        let seconds = testSeconds ?? (p.seconds(atBeat: p.contentEnd) + 3)
        let totalFrames = AVAudioFramePosition(seconds * sr)
        let out = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: url.pathExtension.lowercased() == "aif" || url.pathExtension.lowercased() == "aiff",
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        var lastReport = 0.0
        renderPeaks = [:]
        while engine.manualRenderingSampleTime < totalFrames {
            applyMix(p, beat: position)
            let n = AVAudioFrameCount(min(Int64(buf.frameCapacity), totalFrames - engine.manualRenderingSampleTime))
            let status = try engine.renderOffline(n, to: buf)
            if measuringMaster, status == .success {
                let (_, ms) = Self.peakAndPower(buf)
                let w = masterWeighting.meanSquare(buf)
                if ms > 1e-6 { masterPowerSum += w; masterPowerCount += 1 }
            }
            for (id, st) in strips { renderPeaks[id] = max(renderPeaks[id] ?? 0, st.peak) }
            switch status {
            case .success: try out.write(from: buf)
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext: continue
            case .error: throw EngineError.message("Offline render failed.")
            @unknown default: break
            }
            let f = Double(engine.manualRenderingSampleTime) / Double(totalFrames)
            if f - lastReport > 0.02 { lastReport = f; progress(f) }
        }
        sequencer.stop()
        allNotesOff()
        engine.stop()
        _ = wasPlaying
    }
}


// MARK: - Loudness measurement (Auto Balance)

extension AudioEngine {
    /// Renders the start of the project with every fader at unity, no trims and no automation, and returns how loud each
    /// instrument track is while it is sounding (mean power in dBFS). Tracks that stay silent are left out.
    func measureLoudness(_ project: Project, seconds: Double, keepTrims: Bool = false) throws -> [UUID: Double] {
        try measureMix(project, seconds: seconds, keepTrims: keepTrims).tracks
    }

    /// Like `measureLoudness`, and also the loudness of the whole mix (mean power in dBFS while it is sounding).
    func measureMix(_ project: Project, seconds: Double, keepTrims: Bool = false) throws -> (tracks: [UUID: Double], master: Double?) {
        var p = project
        for i in p.tracks.indices {
            p.tracks[i].volume = 0.8; p.tracks[i].pan = 0; if !keepTrims { p.tracks[i].trim = 0 }
            p.tracks[i].mute = false; p.tracks[i].solo = false
            for c in p.tracks[i].clips.indices { p.tracks[i].clips[c].volume = [] }
        }
        p.masterVolume = 0.8
        for s in strips.values { s.measuring = true; s.powerSum = 0; s.powerCount = 0; s.weighting.reset() }
        masterWeighting.reset()
        measuringMaster = true; masterPowerSum = 0; masterPowerCount = 0
        defer { for s in strips.values { s.measuring = false }; measuringMaster = false }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macband-measure-\(UUID().uuidString.prefix(6)).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try bounce(p, to: url, testSeconds: seconds) { _ in }
        var out: [UUID: Double] = [:]
        for t in project.tracks where t.kind == .instrument {
            guard let s = strips[t.id], s.powerCount >= 3 else { continue }
            out[t.id] = 10 * log10(s.powerSum / Double(s.powerCount))
        }
        let master: Double? = masterPowerCount >= 3 ? 10 * log10(masterPowerSum / Double(masterPowerCount)) : nil
        return (out, master)
    }
}

/// Turns measured loudness into per-track trims.
enum AutoBalance {
    static let maxCut = -24.0, maxBoost = 24.0
    /// A track is moved at most this far relative to the others. A track that is 25 dB quieter than the rest is meant to
    /// be quiet (ghost notes, a faint hi-hat); lifting it all the way up would just make it dominate.
    static let maxRelativeBoost = 9.0, maxRelativeCut = -12.0
    static let drumOffset = 0.0
    /// Loudness the finished mix should have while it is sounding, as mean power in dBFS (before the master limiter).
    static let mixTarget = -22.0

    /// Step 1: every sounding track is brought toward the median loudness, so tracks sit level with each other
    /// (limited, see `maxRelativeBoost`). `finalTrims` then adds the overall correction.
    static func relativeTrims(loudness: [UUID: Double], drums: Set<UUID>) -> [UUID: Double] {
        guard !loudness.isEmpty else { return [:] }
        let sorted = loudness.values.sorted()
        let median = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        var out: [UUID: Double] = [:]
        for (id, l) in loudness { out[id] = min(maxRelativeBoost, max(maxRelativeCut, median + (drums.contains(id) ? drumOffset : 0) - l)) }
        return out
    }

    /// Step 2: after the relative trims are applied the whole mix was measured; one overall correction moves it to the target.
    static func finalTrims(relative: [UUID: Double], measuredMix: Double, mixTarget: Double = AutoBalance.mixTarget) -> [UUID: Double] {
        let offset = mixTarget - measuredMix
        return relative.mapValues { min(maxBoost, max(maxCut, (($0 + offset) * 2).rounded() / 2)) }
    }

    /// Single-step version when only per-track loudness is known: assumes the tracks add up as independent sounds.
    static func trims(loudness: [UUID: Double], drums: Set<UUID>, mixTarget: Double = AutoBalance.mixTarget) -> [UUID: Double] {
        guard !loudness.isEmpty else { return [:] }
        let target = mixTarget - 10 * log10(Double(loudness.count))
        var out: [UUID: Double] = [:]
        for (id, l) in loudness { out[id] = min(maxBoost, max(maxCut, ((target + (drums.contains(id) ? drumOffset : 0) - l) * 2).rounded() / 2)) }
        return out
    }
}


/// Loudness measure used by Auto Balance. Plain signal power counts a low note's energy the same as a high note's, but a
/// mix built that way ends up bass-heavy (low sounds carry a lot of energy for how loud they seem), and a very bright
/// track (hi-hats, cymbals) can end up dominating just as easily. So the measurement raises everything below about
/// 200 Hz and everything above about 6 kHz by 6 dB: tracks that are mostly bass or mostly hiss measure louder and are
/// lifted less. Two shelf biquads (RBJ cookbook), each with its own state per channel.
final class MixWeighting {
    private struct Shelf {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var z1 = [0.0, 0.0], z2 = [0.0, 0.0]
        init(low: Bool, sampleRate: Double, frequency: Double, gainDB: Double) {
            let A = pow(10, gainDB / 40), w0 = 2 * Double.pi * frequency / sampleRate
            let cosw = cos(w0), alpha = sin(w0) / 2 * sqrt(2.0)
            let sq = 2 * sqrt(A) * alpha
            if low {
                let a0 = (A + 1) + (A - 1) * cosw + sq
                b0 = A * ((A + 1) - (A - 1) * cosw + sq) / a0
                b1 = 2 * A * ((A - 1) - (A + 1) * cosw) / a0
                b2 = A * ((A + 1) - (A - 1) * cosw - sq) / a0
                a1 = -2 * ((A - 1) + (A + 1) * cosw) / a0
                a2 = ((A + 1) + (A - 1) * cosw - sq) / a0
            } else {
                let a0 = (A + 1) - (A - 1) * cosw + sq
                b0 = A * ((A + 1) + (A - 1) * cosw + sq) / a0
                b1 = -2 * A * ((A - 1) + (A + 1) * cosw) / a0
                b2 = A * ((A + 1) + (A - 1) * cosw - sq) / a0
                a1 = 2 * ((A - 1) - (A + 1) * cosw) / a0
                a2 = ((A + 1) - (A - 1) * cosw - sq) / a0
            }
        }
    }
    private var low: Shelf, high: Shelf

    init(sampleRate: Double = 44100, lowHz: Double = 200, highHz: Double = 6000, gainDB: Double = 6) {
        low = Shelf(low: true, sampleRate: sampleRate, frequency: lowHz, gainDB: gainDB)
        high = Shelf(low: false, sampleRate: sampleRate, frequency: highHz, gainDB: gainDB)
    }

    func reset() { low.z1 = [0, 0]; low.z2 = [0, 0]; high.z1 = [0, 0]; high.z2 = [0, 0] }

    /// Mean-square power of the buffer after the weighting (averaged over channels).
    func meanSquare(_ buf: AVAudioPCMBuffer) -> Double {
        guard let ch = buf.floatChannelData, buf.frameLength > 0 else { return 0 }
        let n = Int(buf.frameLength), chans = min(2, Int(buf.format.channelCount))
        var sum = 0.0
        for c in 0..<chans {
            let d = ch[c]
            var l1 = low.z1[c], l2 = low.z2[c], h1 = high.z1[c], h2 = high.z2[c]
            for i in 0..<n {
                let x = Double(d[i])
                let y = low.b0 * x + l1                      // transposed direct form II
                l1 = low.b1 * x - low.a1 * y + l2
                l2 = low.b2 * x - low.a2 * y
                let z = high.b0 * y + h1
                h1 = high.b1 * y - high.a1 * z + h2
                h2 = high.b2 * y - high.a2 * z
                sum += z * z
            }
            low.z1[c] = l1; low.z2[c] = l2; high.z1[c] = h1; high.z2[c] = h2
        }
        return sum / Double(n * max(1, chans))
    }
}
