import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Pure grid logic for the step sequencer (kept apart from the view so it can be tested headlessly).
enum StepGrid {
    /// Rows to show for a drum clip: the standard drums first, then any other drums the clip already uses, then extras the user added.
    static func rows(for clip: Clip, extra: Set<Int>) -> [Int] {
        var all = Set(DrumMap.stepRows)
        for n in clip.notes { all.insert(n.pitch) }
        all.formUnion(extra)
        let order = Dictionary(uniqueKeysWithValues: DrumMap.stepRows.enumerated().map { ($1, $0) })
        return all.sorted { a, b in
            switch (order[a], order[b]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a > b
            }
        }
    }

    static func stepCount(_ clip: Clip, stepLen: Double) -> Int { max(1, Int((clip.length / stepLen).rounded())) }

    /// Notes at `pitch` that start inside step `step`.
    static func hits(_ clip: Clip, pitch: Int, step: Int, stepLen: Double) -> [Note] {
        let a = Double(step) * stepLen - 1e-6, b = a + stepLen + 2e-6
        return clip.notes.filter { $0.pitch == pitch && $0.start >= a && $0.start < b - 1e-6 }
    }

    static func velocity(_ clip: Clip, pitch: Int, step: Int, stepLen: Double) -> Int? {
        hits(clip, pitch: pitch, step: step, stepLen: stepLen).map { $0.velocity }.max()
    }

    /// Turns one cell on (with `velocity`) or off.
    static func set(_ clip: inout Clip, pitch: Int, step: Int, stepLen: Double, on: Bool, velocity: Int) {
        let a = Double(step) * stepLen - 1e-6, b = a + stepLen
        clip.notes.removeAll { $0.pitch == pitch && $0.start >= a && $0.start < b - 1e-6 }
        if on {
            clip.notes.append(Note(pitch: pitch, start: Double(step) * stepLen, length: min(stepLen, 0.25), velocity: velocity))
        }
    }
}

struct StepSequencerContainer: View {
    @EnvironmentObject var session: Session
    var body: some View {
        if let loc = session.selectedClipLocation, session.project.tracks[loc.track].instrument.isDrums {
            StepSequencerView(trackID: session.project.tracks[loc.track].id, clipID: session.project.tracks[loc.track].clips[loc.clip].id)
        } else if let t = session.selectedTrack, t.instrument.isDrums {
            VStack(spacing: 10) {
                Image(systemName: "circle.grid.3x3.fill").font(.system(size: 26)).foregroundStyle(Theme.faint)
                Text("Select a drum pattern, or make one").font(.system(size: 13)).foregroundStyle(Theme.dim)
                Button("New Pattern on “\(t.name)”") {
                    let bpb = session.project.beatsPerBar
                    _ = session.addClip(trackID: t.id, start: (session.transport.beat / bpb).rounded(.down) * bpb)
                }.buttonStyle(VistaButtonStyle(compact: false))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "circle.grid.3x3.fill").font(.system(size: 26)).foregroundStyle(Theme.faint)
                Text("The step sequencer is for drum tracks").font(.system(size: 13)).foregroundStyle(Theme.dim)
                Text("Pick a drum track, or add one with a drum kit from the Sound Library.").font(.system(size: 11)).foregroundStyle(Theme.faint)
                Button("Add a Drum Track") { session.addTrack(instrument: InstrumentSpec(isDrums: true)); session.bottomPanel = .steps }
                    .buttonStyle(VistaButtonStyle(compact: false))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct StepSequencerView: View {
    @EnvironmentObject var session: Session
    let trackID: UUID
    let clipID: UUID

    @State private var stepLen = 0.25
    @State private var extraRows = Set<Int>()
    @State private var paintOn = true
    @State private var lastCell: (Int, Int)?
    @State private var dragging = false
    #if os(iOS)
    @State private var accentMode = false                   // there is no Option key on a touch screen: a toggle instead
    private var accentHeld: Bool { accentMode }
    #else
    private var accentHeld: Bool { NSEvent.modifierFlags.contains(.option) }
    #endif

    private let labelW: CGFloat = 132, cellW: CGFloat = 28, cellH: CGFloat = 22, headH: CGFloat = 22

    private var clip: Clip? {
        session.project.tracks.first { $0.id == trackID }?.clips.first { $0.id == clipID }
    }
    private static let lengths: [(String, Double)] = [("1/4", 1), ("1/8", 0.5), ("1/16", 0.25), ("1/32", 0.125)]

    var body: some View {
        if let clip {
            let rows = StepGrid.rows(for: clip, extra: extraRows)
            let steps = StepGrid.stepCount(clip, stepLen: stepLen)
            VStack(spacing: 0) {
                toolbar(clip, rows: rows)
                Divider().overlay(Theme.line)
                HStack(alignment: .top, spacing: 0) {
                    labels(rows: rows, clip: clip)
                    ScrollView(.horizontal) {
                        grid(clip: clip, rows: rows, steps: steps)
                            .frame(width: CGFloat(steps) * cellW, height: headH + CGFloat(rows.count) * cellH)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }

    // MARK: Toolbar

    private func toolbar(_ clip: Clip, rows: [Int]) -> some View {
        HStack(spacing: 10) {
            Text(clip.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.dim)
            Menu {
                ForEach(Self.lengths, id: \.0) { l in Button(l.0) { stepLen = l.1 } }
            } label: {
                HStack(spacing: 4) { Text("Steps").foregroundStyle(.white.opacity(0.75)); Text(Self.lengths.first { $0.1 == stepLen }?.0 ?? "1/16").foregroundStyle(.white) }
                    .font(Theme.vista(11)).padding(.horizontal, 8).frame(height: 24).vistaBackground()
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Menu {
                let have = Set(rows)
                ForEach(DrumMap.names.keys.sorted().filter { !have.contains($0) }, id: \.self) { p in
                    Button(DrumMap.label(p)) { extraRows.insert(p) }
                }
            } label: {
                HStack(spacing: 4) { Image(systemName: "plus"); Text("Add Drum") }
                    .font(Theme.vista(11)).foregroundStyle(.white).padding(.horizontal, 8).frame(height: 24).vistaBackground()
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            #if os(iOS)
            Toggle("Accent", isOn: $accentMode).toggleStyle(VistaCheckboxStyle()).font(Theme.vista(11)).foregroundStyle(Theme.dim)
            #endif
            Button("Clear") { session.edit { p in mutate(&p) { $0.notes = [] } } }.buttonStyle(VistaButtonStyle())
            Menu {
                Button("Four on the Floor") { fill(.fourOnFloor) }
                Button("Basic Rock") { fill(.rock) }
                Button("Hip Hop") { fill(.hipHop) }
                Button("Eighth-Note Hats") { fill(.hats) }
            } label: {
                Text("Pattern…").font(Theme.vista(11)).foregroundStyle(.white).padding(.horizontal, 8).frame(height: 24).vistaBackground()
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Spacer()
            Text("Click or drag to paint · ⌥-click for an accent · click a name to hear it")
                .font(.system(size: 10)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 10).frame(height: 38).background(Theme.panel)
    }

    // MARK: Labels & grid

    private func tint(_ p: Int) -> Color {
        switch DrumMap.family(p) {
        case .kick: return Color(red: 0.85, green: 0.32, blue: 0.30)
        case .snare: return Color(red: 0.95, green: 0.62, blue: 0.20)
        case .hat: return Color(red: 0.95, green: 0.85, blue: 0.30)
        case .tom: return Color(red: 0.35, green: 0.68, blue: 0.90)
        case .cymbal: return Color(red: 0.60, green: 0.85, blue: 0.55)
        case .percussion: return Color(red: 0.72, green: 0.55, blue: 0.92)
        }
    }

    private func labels(rows: [Int], clip: Clip) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: headH)
            ForEach(rows, id: \.self) { p in
                Button { audition(p) } label: {
                    HStack(spacing: 6) {
                        Text(DrumMap.label(p)).font(Theme.vista(11)).foregroundStyle(.white).lineLimit(1).padding(.leading, 8)
                        Spacer(minLength: 0)
                    }
                    .frame(height: cellH - 1).background(VistaFace(state: false, base: NSColor(tint(p)), border: 0.75))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.bottom, 1)
            }
        }
        .frame(width: labelW)
        .background(Theme.panel)
    }

    private func grid(clip: Clip, rows: [Int], steps: Int) -> some View {
        let perBeat = max(1, Int((1 / stepLen).rounded()))
        let perBar = max(1, Int((session.project.beatsPerBar / stepLen).rounded()))
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                for s in 0..<steps {
                    let x = CGFloat(s) * cellW
                    let bar = s % perBar == 0
                    let beat = s % perBeat == 0
                    if (s / perBeat) % 2 == 1 { ctx.fill(Path(CGRect(x: x, y: headH, width: cellW, height: size.height - headH)), with: .color(.white.opacity(0.025))) }
                    ctx.fill(Path(CGRect(x: x, y: bar ? 0 : headH, width: 1, height: size.height - (bar ? 0 : headH))), with: .color(.white.opacity(bar ? 0.28 : (beat ? 0.12 : 0.05))))
                    if beat {
                        let label = bar ? "\(s / perBar + 1)" : "\(s / perBeat % max(1, Int(session.project.beatsPerBar)) + 1)"
                        ctx.draw(Text(label).font(.system(size: 9, weight: bar ? .bold : .regular)).foregroundColor(bar ? .white.opacity(0.8) : .white.opacity(0.35)), at: CGPoint(x: x + 5, y: headH / 2), anchor: .leading)
                    }
                }
                for (ri, p) in rows.enumerated() {
                    let y = headH + CGFloat(ri) * cellH
                    ctx.fill(Path(CGRect(x: 0, y: y + cellH - 1, width: size.width, height: 1)), with: .color(.white.opacity(0.06)))
                    for s in 0..<steps {
                        guard let v = StepGrid.velocity(clip, pitch: p, step: s, stepLen: stepLen) else { continue }
                        let r = CGRect(x: CGFloat(s) * cellW + 2, y: y + 2, width: cellW - 3, height: cellH - 4)
                        let a = 0.45 + 0.55 * Double(v) / 127
                        ctx.fill(Path(r), with: .color(tint(p).opacity(a)))
                        ctx.stroke(Path(r), with: .color(.white.opacity(v >= 118 ? 0.9 : 0.35)), lineWidth: v >= 118 ? 1.5 : 1)
                    }
                }
            }
            PlayheadOverlay(clipStart: clip.start, cellW: cellW, stepLen: stepLen, height: headH + CGFloat(rows.count) * cellH)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                let col = Int(v.location.x / cellW), row = Int((v.location.y - headH) / cellH)
                guard col >= 0, col < steps, row >= 0, row < rows.count else { return }
                if !dragging {
                    dragging = true; lastCell = nil
                    session.pushUndo()
                    let cur = StepGrid.velocity(clip, pitch: rows[row], step: col, stepLen: stepLen)
                    let accent = accentHeld
                    paintOn = accent ? (cur ?? 0) < 118 : cur == nil
                }
                if let l = lastCell, l == (col, row) { return }
                lastCell = (col, row)
                let accent = accentHeld
                let p = rows[row]
                session.modify { proj in
                    mutate(&proj) { StepGrid.set(&$0, pitch: p, step: col, stepLen: stepLen, on: paintOn, velocity: accent ? 127 : 100) }
                }
                if paintOn { audition(p) }
            }
            .onEnded { _ in dragging = false; lastCell = nil })
    }

    // MARK: Helpers

    private func mutate(_ p: inout Project, _ body: (inout Clip) -> Void) {
        guard let ti = p.tracks.firstIndex(where: { $0.id == trackID }), let ci = p.tracks[ti].clips.firstIndex(where: { $0.id == clipID }) else { return }
        body(&p.tracks[ti].clips[ci])
    }

    private func audition(_ pitch: Int) {
        session.engine.noteOn(trackID: trackID, pitch: pitch, velocity: 100)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { session.engine.noteOff(trackID: trackID, pitch: pitch) }
    }

    enum Preset { case fourOnFloor, rock, hipHop, hats }
    private func fill(_ preset: Preset) {
        guard let clip else { return }
        let beats = clip.length
        var notes: [Note] = []
        func add(_ p: Int, _ at: Double, _ v: Int = 100) { if at < beats - 1e-6 { notes.append(Note(pitch: p, start: at, length: 0.25, velocity: v)) } }
        var b = 0.0
        while b < beats - 1e-6 {
            switch preset {
            case .fourOnFloor:
                for k in 0..<4 { add(36, b + Double(k)); add(42, b + Double(k) + 0.5, 80) }
                add(39, b + 1); add(39, b + 3)
            case .rock:
                add(36, b); add(36, b + 2); add(38, b + 1); add(38, b + 3, 108)
                for k in 0..<8 { add(42, b + Double(k) * 0.5, k % 2 == 0 ? 96 : 70) }
            case .hipHop:
                add(36, b); add(36, b + 1.75); add(36, b + 2.5); add(38, b + 1); add(38, b + 3)
                for k in 0..<8 { add(42, b + Double(k) * 0.5, k % 2 == 0 ? 92 : 62) }
                add(46, b + 3.5, 80)
            case .hats:
                for k in 0..<8 { add(42, b + Double(k) * 0.5, k % 2 == 0 ? 96 : 68) }
            }
            b += 4
        }
        session.edit { p in mutate(&p) { $0.notes.append(contentsOf: notes) } }
    }
}

/// Moving playhead line over the grid (its own view so the grid isn't redrawn 60 times a second).
private struct PlayheadOverlay: View {
    @EnvironmentObject var session: Session
    let clipStart: Double, cellW: CGFloat, stepLen: Double, height: CGFloat
    var body: some View { Inner(transport: session.transport, clipStart: clipStart, cellW: cellW, stepLen: stepLen, height: height) }
    struct Inner: View {
        @ObservedObject var transport: Transport
        let clipStart: Double, cellW: CGFloat, stepLen: Double, height: CGFloat
        var body: some View {
            let x = CGFloat((transport.beat - clipStart) / stepLen) * cellW
            Rectangle().fill(Color.white.opacity(0.9)).frame(width: 1.5, height: height)
                .offset(x: x).opacity(x >= 0 ? 1 : 0).allowsHitTesting(false)
        }
    }
}
