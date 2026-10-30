import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import UniformTypeIdentifiers
import Combine

@MainActor
final class Transport: ObservableObject {
    @Published var beat: Double = 0
    @Published var isPlaying = false
    @Published var isRecording = false
}

enum BottomPanel: String, CaseIterable, Identifiable {
    case editor = "Editor", steps = "Step Sequencer", score = "Score", visual = "Visualizer", tune = "Vocal Tune", mixer = "Mixer"
    var id: String { rawValue }
}

enum RollTool: String, CaseIterable, Identifiable {
    case draw = "Draw", select = "Select", erase = "Erase"
    var id: String { rawValue }
    var icon: String {
        switch self { case .draw: return "pencil"; case .select: return "cursorarrow"; case .erase: return "eraser" }
    }
}

enum AutoLane: String, CaseIterable, Identifiable {
    case velocity = "Velocity", volume = "Volume"
    var id: String { rawValue }
}

extension UTType {
    static let macBandProject = UTType(exportedAs: "com.macband.project", conformingTo: .json)
}

@MainActor
final class Session: ObservableObject {
    // Document
    @Published var project: Project
    @Published var fileURL: URL?
    @Published var isDirty = false

    // Selection / UI state
    @Published var selectedTrackID: UUID?
    @Published var selectedClipID: UUID?
    @Published var selectedNoteIDs: Set<UUID> = []
    @Published var selectedAudioClipID: UUID?
    @Published var selectedTuneNoteIDs: Set<UUID> = []
    @Published var tuneSplitTool = false
    @Published var tuneWorking: Set<UUID> = []          // audio clips being analyzed or re-rendered
    var recorder: AudioRecorder?
    var recordStartBeat = 0.0
    var tuneRenderGeneration: [UUID: Int] = [:]
    var tuneRenderWork: [UUID: DispatchWorkItem] = [:]
    @Published var bottomPanel: BottomPanel = .editor
    @Published var showEditor = true
    @Published var showInspector = true
    @Published var showPluginManager = false
    @Published var showProjectBrowser = false
    @Published var showIntro = false
    var introStartPage = 0
    var bandImportRunning = false
    var pendingNotice: (title: String, text: String)?
    /// Non-nil while the Sound Library window is open (and says where the picked sound goes).
    @Published var soundTarget: SoundTarget?
    @Published var metronome = false { didSet { engine.metronomeOn = metronome } }
    @Published var musicalTyping = false
    @Published var typingOctave = 4
    @Published var errorMessage: String?
    @Published var busyMessage: String?
    @Published var toast: String?
    @Published var lastMIDIDevice = ""
    // Shown by the iOS root view (the Mac uses its own panels and alerts)
    @Published var prompt: Prompt?
    @Published var filePicker: FilePickerRequest?
    @Published var shareItem: ShareItem?
    // iOS: the toolbar toggles that stand in for the Shift and Option keys while editing with touch
    @Published var touchShift = false
    @Published var touchOption = false
    @Published var showKeyboard = false                // iOS: the on-screen piano above the page tabs
    @Published var touchPan = false                    // iOS Hand tool: one finger scrolls the piano roll instead of editing
    var touchModifiers: PointerModifiers { var m: PointerModifiers = []; if touchShift { m.insert(.shift) }; if touchOption { m.insert(.option) }; return m }

    // Piano roll settings
    @Published var tool: RollTool = .select
    @Published var commandHeld = false                 // ⌘ is down over the piano roll: it draws while it is held
    /// The tool the piano roll acts with right now: holding ⌘ turns Select into Draw until it is let go.
    var activeTool: RollTool { commandHeld && tool == .select ? .draw : tool }
    @Published var slideMode = false
    @Published var snap: Double = 0.25
    @Published var lane: AutoLane = .velocity
    @Published var showLane = true                     // the velocity / volume lane under the piano roll (hidden by default on a phone)
    @Published var lastNoteLength: Double = 0.5
    @Published var lastVelocity = 100

    // Visualizer settings
    /// Seconds of sound across the Wave picture (0.02 … 3): the smaller, the faster it moves and the closer the zoom.
    @Published var waveWindow: Double = { let v = UserDefaults.standard.double(forKey: "waveWindowSeconds"); return v >= 0.02 && v <= 3 ? v : 0.1 }() { didSet { UserDefaults.standard.set(waveWindow, forKey: "waveWindowSeconds") } }
    /// The Speed slider's position 0…1 (right = faster) on a log scale.
    var waveSpeed: Double {
        get { (log(3.0) - log(waveWindow)) / (log(3.0) - log(0.02)) }
        set { waveWindow = exp(log(3.0) - min(1, max(0, newValue)) * (log(3.0) - log(0.02))) }
    }
    @Published var visualMode: VisualMode = VisualMode(rawValue: UserDefaults.standard.string(forKey: "visualMode") ?? "") ?? .notes { didSet { UserDefaults.standard.set(visualMode.rawValue, forKey: "visualMode") } }
    @Published var visualPalette: VisualPalette = VisualPalette(rawValue: UserDefaults.standard.string(forKey: "visualPalette") ?? "") ?? .accent { didSet { UserDefaults.standard.set(visualPalette.rawValue, forKey: "visualPalette") } }
    @Published var visualWindowBeats: Double = 16
    @Published var visualFollow = true

    // Score editor settings
    @Published var scoreTool: ScoreTool = .draw
    @Published var scoreNoteLength: Double = 1          // beats: 4 whole … 0.125 thirty-second
    @Published var scoreDotted = false
    @Published var scoreClef: ScoreClefMode = .auto
    @Published var scoreKey: Int? = nil                 // key signature override (sharps, negative = flats); nil = from the project key
    @Published var scoreResolution: Double = 0.25       // finest rhythm shown, in beats
    @Published var scoreZoom: CGFloat = 1.0

    let transport = Transport()
    let autosaver = Autosaver()
    @Published var lastAutoSave: Date?
    let levels = TrackLevels()
    let engine = AudioEngine()
    let library = PluginLibrary.shared

    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private var timer: Timer?
    var sequenceDirty = true
    private var reloadWork: DispatchWorkItem?
    #if os(macOS)
    var keyMonitor: Any?
    #endif
    var heldKeys: [UInt16: Int] = [:]
    private var tapTimes: [Date] = []
    private var recording: [Int: (beat: Double, vel: Int)] = [:]
    private var recordClipID: UUID?
    var noteClipboard: [Note] = []
    let midiInput = MIDIInput()

    init() {
        var p = Project()
        var t = Track(name: "Piano", colorIndex: 0)
        t.clips = [Clip(name: "Pattern 1", start: 0, length: p.beatsPerBar * 4)]
        p.tracks = [t]
        project = p
        selectedTrackID = t.id
        selectedClipID = t.clips.first?.id
        engine.onError = { [weak self] m in Task { @MainActor in self?.errorMessage = m } }
        engine.onGraphChanged = { [weak self] in Task { @MainActor in self?.graphChanged() } }
        engine.syncTracks(project.tracks)
        applyMix()
        levels.attach(engine)
        library.rescan()
        SoundLibrary.shared.rescan()
        startTimer()
        autosaver.start(self)
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) { launchFlow() }          // not in the developer test modes
        #if os(macOS)
        installKeyMonitor()
        PluginWindows.shared.installFullscreenSupport()
        EventLog.installIfRequested()
        #endif
        midiInput.onNoteOn = { [weak self] p, v in Task { @MainActor in self?.liveNoteOn(p, v) } }
        midiInput.onNoteOff = { [weak self] p in Task { @MainActor in self?.liveNoteOff(p) } }
        midiInput.onDevices = { [weak self] names in Task { @MainActor in self?.lastMIDIDevice = names.joined(separator: ", ") } }
        midiInput.start()
        #if os(macOS)
        if let i = CommandLine.arguments.firstIndex(of: "--demo-tune"), i + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.importAudio(url: url)
                for _ in 0..<120 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if let id = self.selectedAudioClipID, let loc = self.findAudioClip(id), self.project.tracks[loc.track].audioClips[loc.clip].tune?.analyzed == true, !self.tuneWorking.contains(id) {
                        if CommandLine.arguments.contains("--demo-tune-on") { self.setTuneEnabled(id, true); try? await Task.sleep(nanoseconds: 3_000_000_000) }
                        if CommandLine.arguments.contains("--demo-chord") { self.applyChord(id, noteIDs: Set(self.project.tracks[loc.track].audioClips[loc.clip].tune!.notes.prefix(2).map { $0.id }), intervals: self.chordIntervals("Major")) }
                        self.bottomPanel = .tune
                        if CommandLine.arguments.contains("--demo-drag") { try? await Task.sleep(nanoseconds: 1_500_000_000); await self.demoDragNote(id) }
                        print("DEMO_WINDOW \(NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })?.windowNumber ?? 0)"); fflush(stdout)
                        return
                    }
                }
            }
        }
        runDemoSongIfRequested()
        if let i = CommandLine.arguments.firstIndex(of: "--fullscreen-test"), i + 1 < CommandLine.arguments.count {
            runFullscreenTest(CommandLine.arguments[i + 1])
        }
        if let i = CommandLine.arguments.firstIndex(of: "--demo-plugin"), i + 1 < CommandLine.arguments.count {
            runDemoPlugin(CommandLine.arguments[i + 1])
        }
        #endif
    }

    // MARK: - Derived

    var selectedTrackIndex: Int? { project.tracks.firstIndex { $0.id == selectedTrackID } }
    var selectedTrack: Track? { selectedTrackIndex.map { project.tracks[$0] } }
    func clipIndex(track ti: Int, id: UUID?) -> Int? { project.tracks[ti].clips.firstIndex { $0.id == id } }
    var selectedClipLocation: (track: Int, clip: Int)? {
        guard let ti = selectedTrackIndex, let ci = clipIndex(track: ti, id: selectedClipID) else { return nil }
        return (ti, ci)
    }

    // MARK: - Editing & undo

    func pushUndo() {
        undoStack.append(project)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Mutate the project. Call `pushUndo()` first for user-visible steps.
    func modify(_ body: (inout Project) -> Void) {
        body(&project)
        isDirty = true
        engine.syncTracks(project.tracks)
        applyMix()
        sequenceDidChange()
    }

    func edit(_ body: (inout Project) -> Void) { pushUndo(); modify(body) }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(project)
        let old = project
        project = prev; afterRestore(from: old)
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        let old = project
        project = next; afterRestore(from: old)
    }
    private func afterRestore(from old: Project) {
        isDirty = true
        if !project.tracks.contains(where: { $0.id == selectedTrackID }) { selectedTrackID = project.tracks.first?.id }
        if selectedClipLocation == nil { selectedClipID = nil }
        selectedNoteIDs = selectedNoteIDs.filter { id in project.tracks.contains { $0.clips.contains { $0.notes.contains { $0.id == id } } } }
        engine.syncTracks(project.tracks)
        applyMix()
        sequenceDidChange()
        // tuned audio must follow the restored notes
        let before = Dictionary(uniqueKeysWithValues: old.tracks.flatMap { $0.audioClips }.map { ($0.id, $0.tune) })
        for c in project.tracks.flatMap({ $0.audioClips }) {
            guard let t = c.tune else { continue }
            let was = before[c.id] ?? nil
            if was?.notes != t.notes || was?.amount != t.amount || was?.defaultGlide != t.defaultGlide || was?.enabled != t.enabled {
                if t.enabled { scheduleRetune(c.id, immediately: true) } else { audioContentChanged() }
            }
        }
    }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func applyMix() { engine.applyMix(project, beat: engine.isPlaying ? engine.position : nil) }

    private func graphChanged() { sequenceDirty = true; flushSequence() }

    private func sequenceDidChange() {
        sequenceDirty = true
        guard engine.isPlaying else { return }
        reloadWork?.cancel()
        let w = DispatchWorkItem { [weak self] in Task { @MainActor in self?.flushSequence() } }
        reloadWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    func flushSequence() {
        guard sequenceDirty else { return }
        sequenceDirty = false
        engine.reloadSequence(project, metronome: true)
    }

    // MARK: - Tracks

    func addTrack(instrument: InstrumentSpec = InstrumentSpec(), name: String? = nil) {
        pushUndo()
        let n = name ?? instrument.displayName
        var t = Track(name: n, colorIndex: project.tracks.count)
        t.instrument = instrument
        if instrument.plugin != nil { t.bendRange = 2 }
        let start = (transport.beat / project.beatsPerBar).rounded(.down) * project.beatsPerBar
        t.clips = [Clip(name: "Pattern 1", start: start, length: project.beatsPerBar * 2)]
        modify { $0.tracks.append(t) }
        selectedTrackID = t.id
        selectedClipID = t.clips.first?.id
        selectedNoteIDs = []
        showEditor = true
    }

    func deleteTrack(_ id: UUID) {
        pushUndo()
        modify { $0.tracks.removeAll { $0.id == id } }
        if selectedTrackID == id { selectedTrackID = project.tracks.first?.id; selectedClipID = nil }
    }

    func duplicateTrack(_ id: UUID) {
        guard var t = project.tracks.first(where: { $0.id == id }) else { return }
        pushUndo()
        t.id = UUID(); t.name += " Copy"
        t.clips = t.clips.map { var c = $0; c.id = UUID(); c.notes = c.notes.map { var n = $0; n.id = UUID(); return n }; return c }
        if var p = t.instrument.plugin { p.id = UUID(); p.state = engine.captureState(of: p.id) ?? p.state; t.instrument.plugin = p }
        t.inserts = t.inserts.map { var p = $0; p.id = UUID(); return p }
        modify { $0.tracks.append(t) }
        selectedTrackID = t.id
    }

    func setInstrument(trackID: UUID, _ inst: InstrumentSpec) {
        pushUndo()
        modify {
            guard let i = $0.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            let oldDefault = $0.tracks[i].instrument.displayName
            $0.tracks[i].instrument = inst
            $0.tracks[i].bendRange = inst.plugin == nil ? 12 : 2
            if $0.tracks[i].name == oldDefault || $0.tracks[i].name.hasPrefix("Track ") { $0.tracks[i].name = inst.displayName }
        }
    }

    func addInsert(trackID: UUID, _ spec: PluginSpec) {
        var s = spec; s.id = UUID()
        edit { if let i = $0.tracks.firstIndex(where: { $0.id == trackID }) { $0.tracks[i].inserts.append(s) } }
    }
    func removeInsert(trackID: UUID, specID: UUID) {
        edit { if let i = $0.tracks.firstIndex(where: { $0.id == trackID }) { $0.tracks[i].inserts.removeAll { $0.id == specID } } }
    }
    func toggleBypass(trackID: UUID, specID: UUID) {
        guard let ti = project.tracks.firstIndex(where: { $0.id == trackID }),
              let si = project.tracks[ti].inserts.firstIndex(where: { $0.id == specID }) else { return }
        pushUndo()
        project.tracks[ti].inserts[si].bypassed.toggle()
        engine.setBypass(trackID: trackID, specID: specID, bypass: project.tracks[ti].inserts[si].bypassed)
        isDirty = true
    }
    func openEditor(trackID: UUID, spec: PluginSpec) {
        guard let u = engine.unit(trackID: trackID, specID: spec.id) else { errorMessage = "\(spec.name) is still loading."; return }
        PluginWindows.shared.open(unit: u, title: spec.name, key: spec.id)
    }

    // MARK: - Clips

    @discardableResult
    func addClip(trackID: UUID, start: Double, length: Double? = nil) -> UUID? {
        guard let ti = project.tracks.firstIndex(where: { $0.id == trackID }) else { return nil }
        pushUndo()
        let c = Clip(name: "Pattern \(project.tracks[ti].clips.count + 1)", start: start, length: length ?? project.beatsPerBar * 2)
        modify { $0.tracks[ti].clips.append(c) }
        selectedTrackID = trackID; selectedClipID = c.id; selectedNoteIDs = []
        return c.id
    }

    func deleteClip(trackID: UUID, clipID: UUID) {
        edit { p in
            if let ti = p.tracks.firstIndex(where: { $0.id == trackID }) { p.tracks[ti].clips.removeAll { $0.id == clipID } }
        }
        if selectedClipID == clipID { selectedClipID = nil; selectedNoteIDs = [] }
    }

    func duplicateClip(trackID: UUID, clipID: UUID) {
        guard let ti = project.tracks.firstIndex(where: { $0.id == trackID }),
              var c = project.tracks[ti].clips.first(where: { $0.id == clipID }) else { return }
        c.id = UUID(); c.start = c.end
        c.notes = c.notes.map { var n = $0; n.id = UUID(); return n }
        c.volume = c.volume.map { var a = $0; a.id = UUID(); return a }
        edit { $0.tracks[ti].clips.append(c) }
        selectedClipID = c.id
    }

    func findClip(_ id: UUID) -> (track: Int, clip: Int)? {
        for (ti, t) in project.tracks.enumerated() { if let ci = t.clips.firstIndex(where: { $0.id == id }) { return (ti, ci) } }
        return nil
    }

    /// Option-drag: leave a copy behind and keep dragging the original's identity on a fresh clip.
    func duplicateClipInPlace(trackID: UUID, clipID: UUID) {
        guard let ti = project.tracks.firstIndex(where: { $0.id == trackID }),
              let ci = project.tracks[ti].clips.firstIndex(where: { $0.id == clipID }) else { return }
        pushUndo()
        var copy = project.tracks[ti].clips[ci]
        copy.id = UUID()
        copy.notes = copy.notes.map { var n = $0; n.id = UUID(); return n }
        copy.volume = copy.volume.map { var a = $0; a.id = UUID(); return a }
        modify { $0.tracks[ti].clips.append(copy) }
        selectedClipID = copy.id
    }

    func moveClip(id: UUID, toTrackIndex tj: Int, start: Double) {
        guard let loc = findClip(id), tj >= 0, tj < project.tracks.count else { return }
        modify { p in
            var c = p.tracks[loc.track].clips.remove(at: loc.clip)
            c.start = start
            p.tracks[tj].clips.append(c)
        }
        selectedTrackID = project.tracks[tj].id
    }

    func splitClip(trackID: UUID, clipID: UUID, at beat: Double) {
        guard let ti = project.tracks.firstIndex(where: { $0.id == trackID }),
              let ci = project.tracks[ti].clips.firstIndex(where: { $0.id == clipID }) else { return }
        let c = project.tracks[ti].clips[ci]
        let rel = beat - c.start
        guard rel > 0.01, rel < c.length - 0.01 else { return }
        var left = c, right = c
        right.id = UUID(); right.name = c.name + " B"
        right.start = beat; right.length = c.length - rel
        left.length = rel
        left.notes = c.notes.filter { $0.start < rel }.map { var n = $0; n.length = min(n.length, rel - n.start); return n }
        right.notes = c.notes.filter { $0.end > rel }.map { var n = $0; n.id = UUID(); let s = max(n.start, rel); n.length = n.end - s; n.start = s - rel; return n }
        left.volume = c.volume.filter { $0.beat <= rel }
        right.volume = c.volume.filter { $0.beat >= rel }.map { var a = $0; a.id = UUID(); a.beat -= rel; return a }
        edit { $0.tracks[ti].clips[ci] = left; $0.tracks[ti].clips.insert(right, at: ci + 1) }
    }

    // MARK: - Transport

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        if engine.offlineBusy { return }
        if engine.isPlaying {
            let b = engine.position
            transport.beat = b
            engine.applyMix(project, beat: b)
            engine.updateHostTransport(bpm: project.bpm(at: b), beat: b, playing: true)
        }
        if transport.isPlaying != engine.isPlaying { transport.isPlaying = engine.isPlaying }
    }

    func togglePlay() {
        if engine.isPlaying { stop() } else { play() }
    }

    func play(from beat: Double? = nil) {
        if let b = beat { engine.position = b; transport.beat = b }
        flushSequence()
        engine.position = transport.beat
        engine.play()
        transport.isPlaying = true
    }

    func stop() {
        if recorder != nil { finishAudioRecording(); return }
        if transport.isRecording { finishRecording() }
        engine.stop()
        transport.isPlaying = false
        transport.beat = engine.position
        applyMix()
    }

    func rewind() {
        let wasPlaying = engine.isPlaying
        if wasPlaying { engine.stop() }
        engine.position = project.loopEnabled ? project.loopStart : 0
        transport.beat = engine.position
        if wasPlaying { engine.play() }
    }

    func seek(to beat: Double) {
        let b = max(0, beat)
        engine.position = b
        transport.beat = b
    }

    func toggleRecord() {
        if recorder != nil { finishAudioRecording(); return }
        if transport.isRecording { finishRecording(); transport.isRecording = false; return }
        if selectedTrack?.kind == .audio { startAudioRecording(); return }
        guard selectedTrack != nil else { return }
        transport.isRecording = true
        if !engine.isPlaying { play() }
    }

    func toggleLoop() {
        edit { p in
            p.loopEnabled.toggle()
            // First time on: loop the selected pattern, or the first four bars.
            if p.loopEnabled && p.loopEnd <= p.loopStart {
                if let loc = selectedClipLocation {
                    let c = p.tracks[loc.track].clips[loc.clip]
                    p.loopStart = c.start; p.loopEnd = c.end
                } else { p.loopStart = 0; p.loopEnd = p.beatsPerBar * 4 }
            }
        }
    }

    func setTempo(_ bpm: Double) {
        let v = min(300, max(20, bpm))
        edit { $0.tempo = v }
    }

    func tapTempo() {
        let now = Date()
        tapTimes = tapTimes.filter { now.timeIntervalSince($0) < 2.5 }
        tapTimes.append(now)
        guard tapTimes.count >= 3 else { return }
        let intervals = zip(tapTimes.dropFirst(), tapTimes).map { $0.timeIntervalSince($1) }
        let avg = intervals.reduce(0, +) / Double(intervals.count)
        if avg > 0 { setTempo((60 / avg).rounded()) }
    }

    // MARK: - Live playing & recording

    func liveNoteOn(_ pitch: Int, _ vel: Int) {
        guard let t = selectedTrack else { return }
        engine.noteOn(trackID: t.id, pitch: pitch, velocity: vel)
        if transport.isRecording && engine.isPlaying { recording[pitch] = (engine.position, vel) }
    }

    func liveNoteOff(_ pitch: Int) {
        guard let t = selectedTrack else { return }
        engine.noteOff(trackID: t.id, pitch: pitch)
        guard let on = recording.removeValue(forKey: pitch), transport.isRecording else { return }
        let endBeat = max(engine.position, on.beat + 0.0625)
        addRecordedNote(trackID: t.id, pitch: pitch, start: on.beat, end: endBeat, vel: on.vel)
    }

    private func addRecordedNote(trackID: UUID, pitch: Int, start: Double, end: Double, vel: Int) {
        guard let ti = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let bar = project.beatsPerBar
        var ci = project.tracks[ti].clips.firstIndex { start >= $0.start - 1e-6 && start < $0.end }
        if ci == nil {
            let s = (start / bar).rounded(.down) * bar
            let c = Clip(name: "Recording", start: s, length: bar)
            modify { $0.tracks[ti].clips.append(c) }
            ci = project.tracks[ti].clips.count - 1
        }
        guard let idx = ci else { return }
        modify { p in
            let cs = p.tracks[ti].clips[idx].start
            let n = Note(pitch: pitch, start: start - cs, length: max(0.0625, end - start), velocity: vel)
            p.tracks[ti].clips[idx].notes.append(n)
            p.tracks[ti].clips[idx].fitLengthToNotes(minBeats: bar, quantum: bar)
        }
        selectedClipID = project.tracks[ti].clips[idx].id
    }

    private func finishRecording() {
        guard let t = selectedTrack else { return }
        let now = engine.position
        for (pitch, on) in recording { addRecordedNote(trackID: t.id, pitch: pitch, start: on.beat, end: now, vel: on.vel) }
        recording.removeAll()
        transport.isRecording = false
    }


    // MARK: - Files

    /// Brief confirmation shown over the window (imports, installs…).
    func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in if self?.toast == text { self?.toast = nil } }
    }


    func captureStates() {
        for ti in project.tracks.indices {
            if var p = project.tracks[ti].instrument.plugin, let d = engine.captureState(of: p.id) {
                p.state = d; project.tracks[ti].instrument.plugin = p
            }
            for si in project.tracks[ti].inserts.indices {
                if let d = engine.captureState(of: project.tracks[ti].inserts[si].id) { project.tracks[ti].inserts[si].state = d }
            }
        }
    }

    func encodeProject() throws -> Data {
        captureStates()
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return try enc.encode(project)
    }

    func newProject() {
        guard confirmDiscard() else { return }
        stop(); PluginWindows.shared.closeAll()
        var p = Project()
        var t = Track(name: "Piano", colorIndex: 0)
        t.clips = [Clip(name: "Pattern 1", start: 0, length: p.beatsPerBar * 4)]
        p.tracks = [t]
        clearRecoveryFile()
        load(p, url: nil)
        lastAutoSave = nil
    }


    func load(_ p: Project, url: URL?) {
        project = p; fileURL = url; isDirty = false
        if let url { RecentProjects.add(url) }
        undoStack.removeAll(); redoStack.removeAll()
        selectedTrackID = p.tracks.first?.id
        selectedClipID = p.tracks.first?.clips.first?.id
        selectedNoteIDs = []
        transport.beat = 0; engine.position = 0
        engine.syncTracks(p.tracks)
        applyMix()
        sequenceDirty = true; flushSequence()
        restoreAudioAssets(for: p.tracks, near: url)
    }

    func save() {
        if let url = fileURL { write(to: url) } else { saveAs() }
    }


    func write(to url: URL) {
        do { try encodeProject().write(to: url, options: .atomic); fileURL = url; isDirty = false; saveAudioAssets(for: url); lastAutoSave = nil; clearRecoveryFile(); RecentProjects.add(url) }
        catch { errorMessage = "Couldn't save: \(error.localizedDescription)" }
    }

    /// File ▸ Open: the project chooser first (with a way through to the file dialog).
    func openProject() { showProjectBrowser = true }

    /// Opens a chosen project after asking about unsaved changes.
    func openProjectConfirmed(_ url: URL) {
        guard confirmDiscard() else { return }
        openProject(url: url)
    }


    func openProject(url: URL) {
        do {
            let p = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
            stop(); PluginWindows.shared.closeAll()
            load(p, url: url)
        } catch { errorMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)" }
    }


    func importBandProject(url: URL) {
        if url.pathExtension.lowercased() == "band" { importGarageBandProject(url: url); return }
        do {
            let other = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
            pushUndo()
            let wasEmpty = project.tracks.allSatisfy { $0.clips.allSatisfy { $0.notes.isEmpty } }
            let tracks = other.tracks.map { t -> Track in
                var t = t; t.id = UUID()
                t.colorIndex = project.tracks.count + t.colorIndex
                if var p = t.instrument.plugin { p.id = UUID(); t.instrument.plugin = p }
                t.inserts = t.inserts.map { var p = $0; p.id = UUID(); return p }
                return t
            }
            guard !tracks.isEmpty else { errorMessage = "“\(url.lastPathComponent)” doesn't contain any tracks."; return }
            restoreAudioAssets(for: tracks, near: url)
            modify {
                if wasEmpty {
                    $0.tempo = other.tempo; $0.tempoPoints = other.tempoPoints; $0.timeSigNum = other.timeSigNum; $0.timeSigDen = other.timeSigDen
                    $0.tracks.removeAll { $0.clips.allSatisfy { $0.notes.isEmpty } && $0.instrument.plugin == nil }   // drop the empty starter track
                }
                $0.tracks.append(contentsOf: tracks)
            }
            selectedTrackID = tracks.first?.id
            selectedClipID = tracks.first?.clips.first?.id
            seek(to: 0)
            showToast("Imported \(tracks.count) track\(tracks.count == 1 ? "" : "s") from “\(url.deletingPathExtension().lastPathComponent)”")
        } catch { errorMessage = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)" }
    }


    /// What to do with a MIDI file's tempo changes and time signature when the project already has music in it.
    enum TempoChoice { case ask, useFile, keepProject }

    func importMIDI(url: URL, tempo choice: TempoChoice = .ask) {
        do {
            let imp = try MIDIFile.parse(Data(contentsOf: url))
            guard !imp.tracks.isEmpty else { errorMessage = "That MIDI file doesn't contain any notes."; return }
            let name = url.deletingPathExtension().lastPathComponent
            let wasEmpty = project.tracks.allSatisfy { $0.clips.allSatisfy { $0.notes.isEmpty } }
            // An empty project simply takes the file's tempo map. Otherwise the file's timing is only used if asked for,
            // so importing a second file doesn't silently rewrite the first one's tempo.
            let differs = !imp.tempoPoints.isEmpty || abs(imp.tempo - project.tempo) > 0.01
                || imp.timeSigNum != project.timeSigNum || imp.timeSigDen != project.timeSigDen
            if wasEmpty || !differs { finishMIDIImport(imp, name: name, wasEmpty: wasEmpty, differs: differs, useFileTiming: wasEmpty); return }
            switch choice {
            case .useFile: finishMIDIImport(imp, name: name, wasEmpty: wasEmpty, differs: differs, useFileTiming: true)
            case .keepProject: finishMIDIImport(imp, name: name, wasEmpty: wasEmpty, differs: differs, useFileTiming: false)
            case .ask:
                // the Mac asks right here; iOS shows its own question and finishes when it is answered
                askToUseFileTempo(imp, fileName: name) { [self] use in
                    finishMIDIImport(imp, name: name, wasEmpty: wasEmpty, differs: differs, useFileTiming: use)
                }
            }
        } catch { errorMessage = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)" }
    }

    /// The wording of the "use this file's tempo?" question (the same on every platform).
    func tempoQuestionDetail(_ imp: MIDIFile.Imported) -> String {
        var detail = "The file starts at \(String(format: "%g", imp.tempo)) BPM"
        if !imp.tempoPoints.isEmpty { detail += " and has \(imp.tempoPoints.count) tempo change\(imp.tempoPoints.count == 1 ? "" : "s")" }
        detail += " in \(imp.timeSigNum)/\(imp.timeSigDen). This project is at \(String(format: "%g", project.tempo)) BPM"
        detail += project.tempoPoints.isEmpty ? "." : " with its own tempo changes."
        detail += "\n\nUsing the file's tempo replaces this project's tempo map; the notes already here keep their positions in bars and beats."
        return detail
    }

    func finishMIDIImport(_ imp: MIDIFile.Imported, name: String, wasEmpty: Bool, differs: Bool, useFileTiming: Bool) {
        pushUndo()
        var bar = project.beatsPerBar
        if useFileTiming { bar = Double(imp.timeSigNum) * 4.0 / Double(imp.timeSigDen) }
        let tracks = MIDIFile.makeTracks(imp, beatsPerBar: bar, firstColor: project.tracks.count)
        modify {
            if wasEmpty {
                $0.tracks.removeAll { $0.clips.allSatisfy { $0.notes.isEmpty } }
                $0.name = name
            }
            if useFileTiming {
                $0.tempo = imp.tempo; $0.tempoPoints = imp.tempoPoints
                $0.timeSigNum = imp.timeSigNum; $0.timeSigDen = imp.timeSigDen
            }
            $0.tracks.append(contentsOf: tracks)
        }
        selectedTrackID = tracks.first?.id
        selectedClipID = tracks.first?.clips.first?.id
        seek(to: 0)
        var msg = "Imported \(tracks.count) track\(tracks.count == 1 ? "" : "s") from “\(name)”"
        if useFileTiming && !imp.tempoPoints.isEmpty { msg += " with \(imp.tempoPoints.count) tempo change\(imp.tempoPoints.count == 1 ? "" : "s")" }
        else if !useFileTiming && differs { msg += " (kept the project's tempo)" }
        if imp.sustainedNotes > 0 { msg += " · sustain pedal held \(imp.sustainedNotes) notes" }
        showToast(msg)
        if autoBalanceOnImport { balanceAfterLoading() }
    }

    func handleDrop(_ urls: [URL]) {
        for u in urls {
            switch u.pathExtension.lowercased() {
            case "mid", "midi": importMIDI(url: u)
            case "band": importGarageBandProject(url: u)
            case "macband": if project.tracks.isEmpty || !isDirty { openProject(url: u) } else { importBandProject(url: u) }
            case "wav", "wave", "aif", "aiff", "mp3", "m4a", "caf", "flac", "aac", "ogg", "mp4": importAudio(url: u)
            case "component", "vst3", "vst": installPlugins([u])
            default: break
            }
        }
    }

}
