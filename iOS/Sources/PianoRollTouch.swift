import SwiftUI
import UIKit

extension PianoRollView {
    /// Touch for the roll: one finger edits like the mouse does (or scrolls, with the Hand tool), two fingers scroll, a pinch zooms.
    func installTouchInput() {
        var h = TouchHandlers()
        h.down = { [weak self] in self?.pointerDown($0) }
        h.dragged = { [weak self] in self?.pointerDragged($0) }
        h.up = { [weak self] in self?.pointerUp($0) }
        h.scroll = { [weak self] dx, dy in self?.scrollBy(dx: dx, dy: dy) }
        h.pinch = { [weak self] f, _ in self?.zoom(by: f) }
        h.modifiers = { [weak self] in self?.session.touchModifiers ?? [] }
        h.oneFingerScrolls = { [weak self] in self?.session.touchPan ?? false }
        touchController = TouchInputController(view: self, handlers: h)
    }
}

extension LaneView {
    func installTouchInput() {
        var h = TouchHandlers()
        h.down = { [weak self] in self?.pointerDown($0) }
        h.dragged = { [weak self] in self?.pointerDragged($0) }
        h.up = { [weak self] in self?.pointerUp($0) }
        h.scroll = { [weak self] dx, dy in self?.scrollBy(dx: dx, dy: dy) }
        h.modifiers = { [weak self] in self?.session.touchModifiers ?? [] }
        touchController = TouchInputController(view: self, handlers: h)
    }
}

// MARK: - Editing the selection from buttons

extension Session {
    var selectedNotesInRoll: [Note] {
        guard let loc = selectedClipLocation else { return [] }
        return project.tracks[loc.track].clips[loc.clip].notes.filter { selectedNoteIDs.contains($0.id) }
    }

    func deleteSelectedNotes() {
        guard let loc = selectedClipLocation, !selectedNoteIDs.isEmpty else { return }
        let ids = selectedNoteIDs
        edit { $0.tracks[loc.track].clips[loc.clip].notes.removeAll { ids.contains($0.id) } }
        selectedNoteIDs = []
    }

    func duplicateSelectedNotes() {
        guard let loc = selectedClipLocation else { return }
        let src = selectedNotesInRoll
        guard !src.isEmpty else { return }
        let g = snap > 0 ? snap : 0.25
        let span = (src.map { $0.end }.max() ?? 0) - (src.map { $0.start }.min() ?? 0)
        let shiftBy = (span / g).rounded(.up) * g
        var copies: [Note] = []
        for var n in src { n.id = UUID(); n.start += shiftBy; copies.append(n) }
        edit { $0.tracks[loc.track].clips[loc.clip].notes.append(contentsOf: copies) }
        selectedNoteIDs = Set(copies.map { $0.id })
    }

    /// Moves the selected notes up or down by whole semitones (or all the notes, when none are selected).
    func transposeNotes(by semitones: Int) {
        guard let loc = selectedClipLocation else { return }
        let sel = selectedNoteIDs
        edit { p in
            for i in p.tracks[loc.track].clips[loc.clip].notes.indices where sel.isEmpty || sel.contains(p.tracks[loc.track].clips[loc.clip].notes[i].id) {
                let n = p.tracks[loc.track].clips[loc.clip].notes[i].pitch
                p.tracks[loc.track].clips[loc.clip].notes[i].pitch = min(127, max(0, n + semitones))
            }
        }
    }
}

// MARK: - Toolbar

/// The roll's toolbar for a touch screen: bigger controls, a Hand tool to scroll with one finger, and buttons in place of keyboard shortcuts.
struct IOSRollToolbar: View {
    @EnvironmentObject var session: Session
    @ObservedObject var state: RollState
    let track: Track
    let clip: Clip

    private let size: CGFloat = 34

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                HStack(spacing: 1) {
                    ForEach(RollTool.allCases) { t in
                        IconButton(symbol: t.icon, active: session.tool == t && !session.touchPan, size: size) { session.tool = t; session.touchPan = false }
                    }
                    IconButton(symbol: "hand.draw", active: session.touchPan, size: size) { session.touchPan.toggle() }
                }
                IconButton(symbol: "checkmark.circle", active: session.touchShift, size: size) { session.touchShift.toggle() }     // multi-select
                IconButton(symbol: "arrow.uturn.backward", size: size) { session.undo() }
                IconButton(symbol: "arrow.uturn.forward", size: size) { session.redo() }
                IconButton(symbol: "plus.square.on.square", size: size) { session.duplicateSelectedNotes() }
                IconButton(symbol: "trash", size: size) { session.deleteSelectedNotes() }
                IconButton(symbol: "chart.bar.xaxis", active: session.showLane, size: size) { session.showLane.toggle() }     // velocity lane
                IconButton(symbol: "arrow.up", size: size) { session.transposeNotes(by: 1) }
                IconButton(symbol: "arrow.down", size: size) { session.transposeNotes(by: -1) }
                Button { session.slideMode.toggle() } label: {
                    HStack(spacing: 4) { Image(systemName: "arrow.up.right").font(Theme.vista(10)); Text("Slide").font(Theme.vista(11)) }
                        .foregroundStyle(.white.opacity(session.slideMode ? 1 : 0.8)).padding(.horizontal, 9).frame(height: size)
                        .background(VistaFace(state: session.slideMode))
                }.buttonStyle(.plain)
                snapMenu
                Button("Quantize") { quantize() }.buttonStyle(VistaButtonStyle(compact: false))
                RollToolsMenu()
                scaleMenu
                Text(clip.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.color(track.colorIndex)).lineLimit(1)
                VistaStepper(value: Binding(get: { clip.length / session.project.beatsPerBar }, set: { v in setBars(v) }), range: 1...256, step: 1) {
                    Text("\(Int((clip.length / session.project.beatsPerBar).rounded())) bar\(clip.length / session.project.beatsPerBar > 1.5 ? "s" : "")")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim).monospacedDigit()
                }.fixedSize()
                HStack(spacing: 6) {
                    Image(systemName: "minus.magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.faint)
                    VistaSlider(value: Binding(get: { Double(state.ppb) }, set: { state.ppb = CGFloat($0) }), in: 24...320).frame(width: 90)
                    Image(systemName: "plus.magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 44).background(Theme.panel)
    }

    private var snapLabel: String {
        if session.snap == session.project.beatsPerBar { return "Bar" }
        return RollToolbar.snaps.first { $0.1 == session.snap }?.0 ?? "Custom"
    }

    private var snapMenu: some View {
        Menu {
            ForEach(RollToolbar.snaps, id: \.0) { s in Button(s.0) { session.snap = s.1 < 0 ? session.project.beatsPerBar : s.1 } }
        } label: {
            HStack(spacing: 4) { Text("Snap").foregroundStyle(.white.opacity(0.75)); Text(snapLabel).foregroundStyle(.white) }
                .font(Theme.vista(11)).padding(.horizontal, 8).frame(height: size).vistaBackground()
        }.buttonStyle(.plain)
    }

    private var scaleMenu: some View {
        Menu {
            Picker("Key", selection: Binding(get: { session.project.keyRoot }, set: { v in session.edit { $0.keyRoot = v } })) {
                ForEach(0..<12, id: \.self) { Text(Pitch.names[$0]).tag($0) }
            }
            Picker("Scale", selection: Binding(get: { session.project.scale }, set: { v in session.edit { $0.scale = v } })) {
                ForEach(ScaleKind.allCases) { Text($0.rawValue).tag($0) }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Scale").foregroundStyle(.white.opacity(0.75))
                Text(session.project.scale == .chromatic ? "Off" : "\(Pitch.names[session.project.keyRoot]) \(session.project.scale.rawValue)").foregroundStyle(.white)
            }.font(Theme.vista(11)).padding(.horizontal, 8).frame(height: size).vistaBackground()
        }.buttonStyle(.plain)
    }

    private func setBars(_ bars: Double) {
        session.edit { p in
            if let t = session.selectedTrackIndex, let c = session.clipIndex(track: t, id: session.selectedClipID) {
                p.tracks[t].clips[c].length = max(1, bars) * p.beatsPerBar
            }
        }
    }

    private func quantize() {
        let g = session.snap > 0 ? session.snap : 0.25
        let sel = session.selectedNoteIDs
        session.edit { p in
            guard let t = session.selectedTrackIndex, let c = session.clipIndex(track: t, id: session.selectedClipID) else { return }
            for i in p.tracks[t].clips[c].notes.indices where sel.isEmpty || sel.contains(p.tracks[t].clips[c].notes[i].id) {
                var n = p.tracks[t].clips[c].notes[i]
                n.start = max(0, (n.start / g).rounded() * g)
                n.length = max(g, (n.length / g).rounded() * g)
                p.tracks[t].clips[c].notes[i] = n
            }
        }
    }
}
