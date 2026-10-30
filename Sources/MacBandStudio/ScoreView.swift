import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import Combine

// MARK: - The editable score (AppKit view)

final class ScoreCanvas: PlatformView {
    let session: Session
    private var bag = Set<AnyCancellable>()
    private(set) var layoutBox: ScoreLayout?
    private var current: (score: NScore, track: Track, clip: Clip)?
    private var built: Fingerprint?
    private let playhead = CALayer()

    struct Fingerprint: Equatable {
        var notes: [Note]; var length: Double; var num: Int; var den: Int; var fifths: Int
        var clef: ScoreClefMode; var drums: Bool; var res: Double; var zoom: CGFloat; var width: CGFloat; var firstBar: Int
    }

    private enum Mode { case none, drag, marquee }
    private var mode: Mode = .none
    private var downPoint: CGPoint = .zero
    private var originals: [UUID: Note] = [:]
    private var grab: ScoreLayout.StaffHit?
    private var pushedUndo = false
    private var lastApplied: (Int, Double) = (0, 0)
    private var marquee: CGRect?
    #if os(iOS)
    var touchController: TouchInputController?
    #endif

    init(session: Session) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        hostLayer.backgroundColor = Theme.ns.well.cgColor
        playhead.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        playhead.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "hidden": NSNull()]
        playhead.isHidden = true
        hostLayer.addSublayer(playhead)
        session.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &bag)
        session.transport.$beat.sink { [weak self] _ in self?.updatePlayhead() }.store(in: &bag)
        #if os(iOS)
        backgroundColor = Theme.ns.well
        contentMode = .redraw
        installTouchInput()
        #endif
    }
    required init?(coder: NSCoder) { fatalError() }

    #if os(macOS)
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    #endif

    /// The height of the window the score scrolls in, and a way to make the page as tall as the score.
    private var viewportHeight: CGFloat {
        #if os(macOS)
        return enclosingScrollView?.contentSize.height ?? 0
        #else
        return (superview as? UIScrollView)?.bounds.height ?? 0
        #endif
    }
    private func setPageHeight(_ h: CGFloat) {
        #if os(macOS)
        setFrameSize(NSSize(width: frame.width, height: h))
        #else
        frame.size = CGSize(width: frame.width, height: h)
        (superview as? UIScrollView)?.contentSize = frame.size
        #endif
    }

    private var space: CGFloat { 9 * session.scoreZoom }
    private var bpb: Double { session.project.beatsPerBar }
    private var minPageWidth: CGFloat {
        #if os(iOS)
        return 280
        #else
        return 420
        #endif
    }

    // MARK: Layout

    #if os(macOS)
    override func layout() { super.layout(); refresh() }
    #else
    override func layoutSubviews() { super.layoutSubviews(); refresh() }
    #endif

    func refresh() {
        guard let cur = session.currentScore() else {
            layoutBox = nil; current = nil; built = nil; needsDisplay = true; updatePlayhead(); return
        }
        current = cur
        let w = max(minPageWidth, bounds.width)
        let fp = Fingerprint(notes: cur.clip.notes, length: cur.clip.length, num: session.project.timeSigNum, den: session.project.timeSigDen,
                             fifths: session.scoreFifths, clef: session.scoreClef, drums: cur.track.instrument.isDrums, res: session.scoreResolution,
                             zoom: session.scoreZoom, width: w, firstBar: Int(cur.clip.start / bpb))
        if fp != built {
            built = fp
            layoutBox = ScoreLayout(score: cur.score, width: w, space: space, firstMeasureNumber: Int(cur.clip.start / bpb) + 1)
            let h = max(layoutBox!.height, viewportHeight)
            if abs(frame.height - h) > 0.5 { setPageHeight(h) }
        }
        needsDisplay = true
        updatePlayhead()
    }

    // MARK: Drawing

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(Theme.ns.well.cgColor); ctx.fill(dirty)
        guard let lay = layoutBox else {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Theme.ns.dim]
            ("Select a pattern to see it as sheet music" as NSString).draw(at: CGPoint(x: 24, y: 24), withAttributes: a)
            return
        }
        var style = ScoreStyle()
        style.selected = session.selectedNoteIDs
        style.accent = Theme.accentNS
        for i in lay.systems.indices {
            let sys = lay.systems[i]
            if sys.y + sys.height + 20 < dirty.minY || sys.y - 40 > dirty.maxY { continue }
            lay.draw(system: i, ctx: ctx, style: style)
        }
        if let m = marquee {
            ctx.setFillColor(Theme.accentNS.withAlphaComponent(0.12).cgColor); ctx.fill(m)
            ctx.setStrokeColor(Theme.accentNS.cgColor); ctx.setLineWidth(1); ctx.stroke(m)
        }
    }

    private func updatePlayhead() {
        guard let lay = layoutBox, let cur = current else { playhead.isHidden = true; return }
        let beat = session.transport.beat - cur.clip.start
        guard beat >= 0, beat <= cur.clip.length + 1e-6, session.transport.isPlaying || session.transport.beat > 0,
              let pos = lay.position(forBeat: beat) else { playhead.isHidden = true; return }
        let sys = lay.systems[pos.system]
        let top = sys.staffTop.first! - 1.5 * lay.s, bottom = sys.staffTop.last! + 5.5 * lay.s
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playhead.frame = CGRect(x: pos.x - 0.75, y: top, width: 1.5, height: bottom - top)
        playhead.isHidden = false
        CATransaction.commit()
        #if os(macOS)
        if session.transport.isPlaying, let sv = enclosingScrollView {
            let vis = sv.contentView.documentVisibleRect
            if playhead.frame.maxY > vis.maxY || playhead.frame.minY < vis.minY {
                sv.contentView.scroll(to: NSPoint(x: 0, y: max(0, sys.y - 2 * lay.s)))
                sv.reflectScrolledClipView(sv.contentView)
            }
        }
        #else
        if session.transport.isPlaying, let sv = superview as? UIScrollView {
            let vis = CGRect(origin: sv.contentOffset, size: sv.bounds.size)
            if playhead.frame.maxY > vis.maxY || playhead.frame.minY < vis.minY {
                sv.setContentOffset(CGPoint(x: 0, y: min(max(0, sv.contentSize.height - sv.bounds.height), max(0, sys.y - 2 * lay.s))), animated: true)
            }
        }
        #endif
    }

    // MARK: Mouse

    private func absBeat(_ h: ScoreLayout.StaffHit) -> Double { Double(h.measure) * bpb + h.beat }
    private func snap(_ b: Double) -> Double { (b / session.scoreResolution).rounded() * session.scoreResolution }

    private func pitch(forStep step: Int) -> Int? {
        guard let cur = current else { return nil }
        return cur.track.instrument.isDrums ? Notation.drumPitch(forStep: step) : Notation.midi(forStep: step, fifths: session.scoreFifths)
    }

    private func audition(_ pitch: Int) {
        guard let t = current?.track else { return }
        session.engine.noteOn(trackID: t.id, pitch: pitch, velocity: 90)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.session.engine.noteOff(trackID: t.id, pitch: pitch) }
    }

    #if os(macOS)
    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); pointerDown(PointerEvent(e, in: self)) }
    override func mouseDragged(with e: NSEvent) { pointerDragged(PointerEvent(e, in: self)) }
    override func mouseUp(with e: NSEvent) { pointerUp(PointerEvent(e, in: self)) }
    override func rightMouseDown(with e: NSEvent) { deleteHead(at: convert(e.locationInWindow, from: nil)) }
    #endif

    func pointerDown(_ e: PointerEvent) {
        guard let lay = layoutBox, let cur = current else { return }
        let p = e.location
        downPoint = p; pushedUndo = false; originals = [:]; mode = .none; lastApplied = (0, 0)

        if let h = lay.head(at: p), let id = h.id {
            if session.scoreTool == .erase {
                session.selectedNoteIDs = [id]; session.scoreDeleteSelected(); return
            }
            if e.modifierFlags.contains(.shift) {
                if session.selectedNoteIDs.contains(id) { session.selectedNoteIDs.remove(id) } else { session.selectedNoteIDs.insert(id) }
            } else if !session.selectedNoteIDs.contains(id) {
                session.selectedNoteIDs = [id]
            }
            for n in cur.clip.notes where session.selectedNoteIDs.contains(n.id) { originals[n.id] = n }
            grab = lay.staffHit(p)
            mode = .drag
            audition(h.midi)
            return
        }
        switch session.scoreTool {
        case .draw:
            guard let hit = lay.staffHit(p), let midi = pitch(forStep: hit.step) else {
                #if os(macOS)
                NSSound.beep()
                #else
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                #endif
                return
            }
            let start = snap(absBeat(hit))
            session.scoreAddNote(pitch: midi, start: min(start, cur.clip.length + session.project.beatsPerBar * 4), length: session.scoreLength)
            audition(midi)
        case .select:
            if !e.modifierFlags.contains(.shift) { session.selectedNoteIDs = [] }
            mode = .marquee; marquee = CGRect(origin: p, size: .zero)
        case .erase:
            break
        }
    }

    func pointerDragged(_ e: PointerEvent) {
        guard let lay = layoutBox else { return }
        let p = e.location
        switch mode {
        case .drag:
            guard let g = grab, let cur = current else { return }
            let stepDelta = Int(((downPoint.y - p.y) / (lay.s / 2)).rounded())
            var beatDelta = 0.0
            if let now = lay.staffHit(CGPoint(x: p.x, y: downPoint.y)) { beatDelta = snap(absBeat(now) - absBeat(g)) }
            if abs(p.x - downPoint.x) < 4 { beatDelta = 0 }          // don't nudge the timing while dragging straight up or down
            if (stepDelta, beatDelta) == lastApplied { return }
            if !pushedUndo { session.pushUndo(); pushedUndo = true }
            if stepDelta != lastApplied.0 { _ = cur }
            lastApplied = (stepDelta, beatDelta)
            session.scoreApplyDrag(originals: originals, stepDelta: stepDelta, beatDelta: beatDelta, fifths: session.scoreFifths, drums: cur.track.instrument.isDrums)
            if let any = originals.values.first, let n = session.selectedTrack?.clips.flatMap({ $0.notes }).first(where: { $0.id == any.id }) { audition(n.pitch) }
        case .marquee:
            let r = CGRect(x: min(downPoint.x, p.x), y: min(downPoint.y, p.y), width: abs(p.x - downPoint.x), height: abs(p.y - downPoint.y))
            marquee = r
            var sel = e.modifierFlags.contains(.shift) ? session.selectedNoteIDs : []
            for h in lay.heads where h.rect.intersects(r) { if let id = h.id { sel.insert(id) } }
            if sel != session.selectedNoteIDs { session.selectedNoteIDs = sel }
            needsDisplay = true
        case .none: break
        }
    }

    func pointerUp(_ e: PointerEvent) {
        mode = .none; marquee = nil; originals = [:]; grab = nil
        needsDisplay = true
    }

    func deleteHead(at p: CGPoint) {
        guard let lay = layoutBox else { return }
        if let h = lay.head(at: p), let id = h.id { session.selectedNoteIDs = [id]; session.scoreDeleteSelected() }
    }

    // MARK: Keyboard

    #if os(macOS)
    private static let lengthKeys: [Character: Double] = ["1": 4, "2": 2, "3": 1, "4": 0.5, "5": 0.25, "6": 0.125]

    override func keyDown(with e: NSEvent) {
        let shift = e.modifierFlags.contains(.shift)
        if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "a" {
            if let c = current?.clip { session.selectedNoteIDs = Set(c.notes.map { $0.id }) }
            return
        }
        switch e.keyCode {
        case 51, 117: session.scoreDeleteSelected()
        case 126: session.scoreTransposeSelected(semitones: shift ? 12 : 1); previewSelected()
        case 125: session.scoreTransposeSelected(semitones: shift ? -12 : -1); previewSelected()
        case 123: session.scoreMoveSelected(by: -(shift ? session.scoreLength : session.scoreResolution))
        case 124: session.scoreMoveSelected(by: shift ? session.scoreLength : session.scoreResolution)
        case 53: session.selectedNoteIDs = []
        default:
            if let ch = e.charactersIgnoringModifiers?.first, let v = Self.lengthKeys[ch], !e.modifierFlags.contains(.command) {
                session.scoreNoteLength = v
                if !session.selectedNoteIDs.isEmpty { session.scoreSetLength(session.scoreLength) }
            } else if e.charactersIgnoringModifiers == "." {
                session.scoreDotted.toggle()
                if !session.selectedNoteIDs.isEmpty { session.scoreSetLength(session.scoreLength) }
            } else {
                super.keyDown(with: e)
            }
        }
    }

    #endif

    private func previewSelected() {
        guard let c = session.selectedTrack?.clips.first(where: { $0.id == session.selectedClipID }),
              let n = c.notes.first(where: { session.selectedNoteIDs.contains($0.id) }) else { return }
        audition(n.pitch)
    }
}

#if os(macOS)
struct ScoreRepresentable: NSViewRepresentable {
    let session: Session
    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true; sv.hasHorizontalScroller = false
        sv.drawsBackground = true; sv.backgroundColor = Theme.ns.well
        sv.autohidesScrollers = true
        let canvas = ScoreCanvas(session: session)
        canvas.autoresizingMask = [.width]
        sv.documentView = canvas
        DispatchQueue.main.async { canvas.setFrameSize(NSSize(width: sv.contentSize.width, height: canvas.frame.height)); canvas.refresh() }
        return sv
    }
    func updateNSView(_ sv: NSScrollView, context: Context) {}
}
#else
struct ScoreRepresentable: UIViewRepresentable {
    let session: Session
    func makeUIView(context: Context) -> UIScrollView {
        let sv = ScoreScrollView()
        sv.backgroundColor = Theme.ns.well
        sv.alwaysBounceVertical = true
        sv.panGestureRecognizer.minimumNumberOfTouches = 2          // one finger edits the score, two scroll it
        let canvas = ScoreCanvas(session: session)
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        sv.canvas = canvas
        sv.addSubview(canvas)
        return sv
    }
    func updateUIView(_ sv: UIScrollView, context: Context) {}
}

/// Keeps the score as wide as the window.
final class ScoreScrollView: UIScrollView {
    var canvas: ScoreCanvas?
    override func layoutSubviews() {
        super.layoutSubviews()
        if let c = canvas, abs(c.frame.width - bounds.width) > 0.5 {
            c.frame.size.width = bounds.width
            contentSize.width = bounds.width
        }
    }
}
#endif

// MARK: - Toolbar and container

struct ScoreContainer: View {
    @EnvironmentObject var session: Session

    var body: some View {
        if session.selectedClipLocation == nil {
            VStack(spacing: 10) {
                Image(systemName: "music.quarternote.3").font(.system(size: 28)).foregroundStyle(Theme.faint)
                Text("Select a pattern to see it as sheet music").font(.system(size: 13)).foregroundStyle(Theme.dim)
                Text("The score shows the notes of the selected pattern. Editing it edits the same notes as the piano roll.")
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                #if os(iOS)
                ScrollView(.horizontal, showsIndicators: false) { ScoreToolbar().padding(.horizontal, 6) }.frame(height: 40).background(Theme.panel)
                #else
                ScoreToolbar()
                #endif
                Divider().overlay(Theme.line)
                ScoreRepresentable(session: session)
            }
        }
    }
}

struct ScoreToolbar: View {
    @EnvironmentObject var session: Session

    private static let values: [(String, Double)] = [("1", 4), ("1/2", 2), ("1/4", 1), ("1/8", 0.5), ("1/16", 0.25), ("1/32", 0.125)]
    private static let grids: [(String, Double)] = [("1/8", 0.5), ("1/16", 0.25), ("1/32", 0.125)]

    var body: some View {
        HStack(spacing: 8) {
            #if os(iOS)
            IconButton(symbol: "arrow.uturn.backward", size: 30) { session.undo() }
            IconButton(symbol: "arrow.uturn.forward", size: 30) { session.redo() }
            IconButton(symbol: "trash", size: 30) { session.scoreDeleteSelected() }
            #endif
            HStack(spacing: 1) {
                ForEach(ScoreTool.allCases) { t in
                    IconButton(symbol: t.icon, active: session.scoreTool == t, help: "\(t.rawValue) tool", size: 26) { session.scoreTool = t }
                }
            }
            HStack(spacing: 1) {
                ForEach(Self.values, id: \.0) { v in
                    Button(v.0) {
                        session.scoreNoteLength = v.1
                        if !session.selectedNoteIDs.isEmpty { session.scoreSetLength(session.scoreLength) }
                    }
                    .buttonStyle(VistaButtonStyle(state: session.scoreNoteLength == v.1))
                    .help("Note length \(v.0) (key \(Self.values.firstIndex { $0.0 == v.0 }! + 1))")
                }
                Button("•") {
                    session.scoreDotted.toggle()
                    if !session.selectedNoteIDs.isEmpty { session.scoreSetLength(session.scoreLength) }
                }
                .buttonStyle(VistaButtonStyle(state: session.scoreDotted)).help("Dotted (.)")
            }
            HStack(spacing: 1) {
                Button("♯") { session.scoreTransposeSelected(semitones: 1) }.buttonStyle(VistaButtonStyle()).help("Raise the selected notes a semitone (↑)")
                Button("♭") { session.scoreTransposeSelected(semitones: -1) }.buttonStyle(VistaButtonStyle()).help("Lower the selected notes a semitone (↓)")
            }
            Menu {
                Picker("Clef", selection: $session.scoreClef) { ForEach(ScoreClefMode.allCases) { Text($0.rawValue).tag($0) } }
            } label: {
                HStack(spacing: 4) { Text("Clef").foregroundStyle(.white.opacity(0.75)); Text(session.scoreClef.rawValue).foregroundStyle(.white) }
                    .font(Theme.vista(11)).padding(.horizontal, 8).frame(height: 24).vistaBackground()
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Menu {
                Button("From project key") { session.scoreKey = nil }
                Divider()
                ForEach(-7...7, id: \.self) { f in Button("\(Notation.keyName(f))  (\(f == 0 ? "no accidentals" : f > 0 ? "\(f) sharp\(f > 1 ? "s" : "")" : "\(-f) flat\(f < -1 ? "s" : "")"))") { session.scoreKey = f } }
            } label: {
                HStack(spacing: 4) { Text("Key").foregroundStyle(.white.opacity(0.75)); Text(Notation.keyName(session.scoreFifths).components(separatedBy: " major").first ?? "C").foregroundStyle(.white) }
                    .font(Theme.vista(11)).padding(.horizontal, 8).frame(height: 24).vistaBackground()
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Menu {
                ForEach(Self.grids, id: \.0) { g in Button(g.0) { session.scoreResolution = g.1 } }
            } label: {
                HStack(spacing: 4) { Text("Grid").foregroundStyle(.white.opacity(0.75)); Text(Self.grids.first { $0.1 == session.scoreResolution }?.0 ?? "1/16").foregroundStyle(.white) }
                    .font(Theme.vista(11)).padding(.horizontal, 8).frame(height: 24).vistaBackground()
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("The shortest rhythm the score shows and snaps to. Notes between grid lines are rounded for display only.")

            Spacer(minLength: 6)

            Menu {
                Button("PDF…") { session.exportScorePDF() }
                Button("MusicXML…") { session.exportScoreMusicXML() }
            } label: {
                HStack(spacing: 4) { Image(systemName: "square.and.arrow.up"); Text("Export Score") }
                    .font(Theme.vista(11)).foregroundStyle(.white).padding(.horizontal, 8).frame(height: 24).vistaBackground()
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            HStack(spacing: 6) {
                Image(systemName: "minus.magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.faint)
                VistaSlider(value: Binding(get: { Double(session.scoreZoom) }, set: { session.scoreZoom = CGFloat($0) }), in: 0.6...2.0).frame(width: 80).controlSize(.mini)
                Image(systemName: "plus.magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 10).frame(height: 38).background(Theme.panel)
    }
}
