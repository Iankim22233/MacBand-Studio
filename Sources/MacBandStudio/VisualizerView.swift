import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import Combine

/// The drawing surface for the visualizer: either every track's notes in one piano roll, or one of the spectrum shapes.
final class VisualizerCanvas: PlatformView {
    let session: Session
    private let analyzer = SpectrumAnalyzer()
    private let cache = NoteCache()
    private let waveHistory = WaveHistory()
    private var cacheDirty = true
    private var timer: Timer?
    private var lastTick = Date()
    private var time = 0.0
    private var bag = Set<AnyCancellable>()
    /// True when the backdrop is a layer behind this view (the app); false draws it here (tests, snapshots).
    var hostsBackdrop = false
    private var lastDrawnMode: VisualMode?
    var onLevel: ((Float) -> Void)?
    // the scrolling waveform is drawn by Core Animation, not by CPU drawing: it is far lighter
    private let waveGlow = CAShapeLayer(), waveLine = CAShapeLayer(), waveEdge = CAShapeLayer()

    init(session: Session) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        hostLayer.masksToBounds = true                                  // nothing of the picture may draw outside its panel
        #if os(iOS)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        #endif
        for l in [waveGlow, waveLine, waveEdge] {
            l.fillColor = nil; l.lineJoin = .round; l.lineCap = .round; l.isHidden = true
            l.actions = ["path": NSNull(), "strokeColor": NSNull(), "hidden": NSNull(), "bounds": NSNull(), "position": NSNull()]
            hostLayer.addSublayer(l)
        }
        waveGlow.lineWidth = 6; waveLine.lineWidth = 1.6; waveEdge.lineWidth = 1.5
        session.objectWillChange.sink { [weak self] _ in self?.cacheDirty = true }.store(in: &bag)
    }
    required init?(coder: NSCoder) { fatalError() }

    #if os(macOS)
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    #endif

    #if os(macOS)
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); windowChanged() }
    #else
    override func didMoveToWindow() { super.didMoveToWindow(); windowChanged() }
    #endif

    private func windowChanged() {
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        lastTick = Date()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        #if os(macOS)
        guard let w = window, w.occlusionState.contains(.visible) || CommandLine.arguments.contains("--demo-song") else { return }     // pictures for the docs run even when the window is behind others
        #else
        guard window != nil, UIApplication.shared.applicationState == .active else { return }
        #endif
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        step(dt)
    }

    /// Moves everything on by `dt` seconds and redraws.
    func step(_ dt: Double) {
        time += dt
        analyzer.update(from: session.engine.sampleRing, dt: dt)
        if session.visualMode == .wave { waveHistory.update(from: session.engine.sampleRing, dt: dt) }
        updateWaveLayers()
        onLevel?(analyzer.level)
        // In Wave mode the line is a layer, so only the spectrum curve underneath is drawn: redraw just the lower half.
        if hostsBackdrop && session.visualMode == .wave && lastDrawnMode == .wave {
            setNeedsDisplay(NSRect(x: 0, y: bounds.height * 0.5, width: bounds.width, height: bounds.height * 0.5))
        } else {
            needsDisplay = true
        }
        lastDrawnMode = session.visualMode
    }

    /// What the wave layers are doing (for tests): shown, where, and how big the path is.
    var waveLayerState: (shown: Bool, frame: CGRect, pathBox: CGRect, flipped: Bool) {
        (!waveLine.isHidden, waveLine.frame, waveLine.path?.boundingBox ?? .zero, hostLayer.isGeometryFlipped)
    }

    private func updateWaveLayers() {
        let on = session.visualMode == .wave
        for l in [waveGlow, waveLine, waveEdge] where l.isHidden == on { l.isHidden = !on }
        guard on, bounds.width > 20 else { return }
        let path = WaveScrollDraw.path(bounds.size, history: waveHistory, window: session.waveWindow)
        let p = session.visualPalette, accent = Theme.accentNS
        for l in [waveGlow, waveLine] { l.frame = bounds; l.path = path }
        waveGlow.strokeColor = p.color(0.6, accent: accent, alpha: 0.22).cgColor
        waveLine.strokeColor = p.color(0.62 + 0.38 * Double(analyzer.level), accent: accent, alpha: 1).cgColor
        let cy = bounds.height * 0.42, amp = bounds.height * 0.3
        let edge = CGMutablePath()                                  // where new sound enters
        edge.move(to: CGPoint(x: bounds.width - 1, y: cy - amp)); edge.addLine(to: CGPoint(x: bounds.width - 1, y: cy + amp))
        waveEdge.frame = bounds; waveEdge.path = edge
        waveEdge.strokeColor = p.color(0.9, accent: accent, alpha: 0.5).cgColor
    }

    #if os(macOS)
    /// Writes a still frame of the current view to a PNG (developer aid).
    func snapshot(to url: URL) {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let w = window, w.identifier?.rawValue == "visualizer" { w.toggleFullScreen(nil) }
    }
    #endif

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if cacheDirty { cache.rebuild(session.project); cacheDirty = false }
        if !hostsBackdrop { VisualizerShapes.background(ctx, bounds.size, level: analyzer.level) }
        let accent = Theme.accentNS
        if session.visualMode == .notes {
            NotesRoll.draw(ctx, bounds.size, cache: cache, beat: session.transport.beat, playing: session.transport.isPlaying,
                           windowBeats: session.visualWindowBeats, follow: session.visualFollow, accent: accent)
        } else {
            let f = SpectrumFrame(bands: analyzer.bands, peaks: analyzer.peaks, wave: analyzer.wave, level: analyzer.level, bass: analyzer.bass, time: time, scroll: waveHistory, scrollWindow: session.waveWindow, waveformOnLayers: hostsBackdrop)
            let beat = session.transport.beat
            let spb = 60 / max(20, session.project.bpm(at: beat))
            // the round shapes follow the notes; a project with no notes (audio only) falls back to the live spectrum
            if session.visualMode == .circle, !cache.notes.isEmpty {
                NoteCircles.wheel(ctx, bounds.size, cache: cache, beat: beat, secPerBeat: spb, frame: f, accent: accent)
            } else if session.visualMode == .rings, !cache.notes.isEmpty {
                NoteCircles.rings(ctx, bounds.size, cache: cache, beat: beat, secPerBeat: spb, frame: f, accent: accent)
            } else {
                VisualizerShapes.draw(session.visualMode, ctx: ctx, size: bounds.size, frame: f, palette: session.visualPalette, accent: accent)
            }
        }
    }
}

/// The canvas on top of a backdrop made of two Core Animation gradient layers (a dark fade and a glow that follows the loudness).
/// The graphics card draws those, so they cost nothing per frame; before, the whole backdrop was redrawn by the CPU every frame.
final class VisualizerBackdrop: PlatformView {
    let canvas: VisualizerCanvas
    private let fade = CAGradientLayer(), glow = CAGradientLayer()

    init(session: Session) {
        canvas = VisualizerCanvas(session: session)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        hostLayer.masksToBounds = true
        fade.colors = [NSColor(red: 0.04, green: 0.045, blue: 0.075, alpha: 1).cgColor, NSColor(red: 0.01, green: 0.012, blue: 0.022, alpha: 1).cgColor]
        #if os(macOS)
        fade.startPoint = CGPoint(x: 0.5, y: 1); fade.endPoint = CGPoint(x: 0.5, y: 0)          // top to bottom (the Mac's layers have y pointing up)
        #else
        fade.startPoint = CGPoint(x: 0.5, y: 0); fade.endPoint = CGPoint(x: 0.5, y: 1)
        #endif
        glow.type = .radial
        glow.colors = [NSColor(white: 1, alpha: 0.15).cgColor, NSColor(white: 1, alpha: 0).cgColor]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5); glow.endPoint = CGPoint(x: 1.1, y: 1.1)
        glow.opacity = 0.33
        for l in [fade, glow] { l.actions = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]; hostLayer.addSublayer(l) }
        canvas.hostsBackdrop = true
        canvas.onLevel = { [weak self] level in self?.glow.opacity = (0.05 + 0.1 * level) / 0.15 }
        addSubview(canvas)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func arrange() {
        fade.frame = bounds; glow.frame = bounds
        canvas.frame = bounds
    }
    #if os(macOS)
    override func layout() { super.layout(); arrange() }
    #else
    override func layoutSubviews() { super.layoutSubviews(); arrange() }
    #endif
}

#if os(macOS)
struct VisualizerRepresentable: NSViewRepresentable {
    let session: Session
    func makeNSView(context: Context) -> VisualizerBackdrop { VisualizerBackdrop(session: session) }
    func updateNSView(_ v: VisualizerBackdrop, context: Context) { v.canvas.needsDisplay = true }
}
#else
struct VisualizerRepresentable: UIViewRepresentable {
    let session: Session
    func makeUIView(context: Context) -> VisualizerBackdrop { VisualizerBackdrop(session: session) }
    func updateUIView(_ v: VisualizerBackdrop, context: Context) { v.canvas.needsDisplay = true }
}
#endif

struct VisualizerContainer: View {
    @EnvironmentObject var session: Session
    var inWindow = false

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            ScrollView(.horizontal, showsIndicators: false) { toolbar }.frame(height: 42).background(Theme.panel)
            #else
            toolbar
            #endif
            Divider().overlay(Theme.line)
            VisualizerRepresentable(session: session)
        }
        .background(Color.black)
    }

    private var paletteMenu: some View {
        Menu {
                    Picker("Colors", selection: $session.visualPalette) { ForEach(VisualPalette.allCases) { Text($0.rawValue).tag($0) } }
                } label: {
                    HStack(spacing: 4) { Text("Colors").foregroundStyle(.white.opacity(0.75)); Text(session.visualPalette.rawValue).foregroundStyle(.white) }
                        .font(Theme.vista(11)).padding(.horizontal, 8).frame(height: 24).vistaBackground()
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            ForEach(VisualMode.allCases) { m in
                Button { session.visualMode = m } label: { Label(m.rawValue, systemImage: m.icon).labelStyle(.titleAndIcon) }
                    .buttonStyle(VistaButtonStyle(state: session.visualMode == m))
                    .help(m == .notes ? "Every track's notes in one piano roll, in the track colours" : (m == .circle ? "A pitch wheel: every sounding note is a circle in its track's colour" : (m == .rings ? "One ring per track: notes light up on their track's ring" : "\(m.rawValue): a live spectrum of the audio")))
            }
            Spacer(minLength: 8)
            if session.visualMode == .notes {
                Toggle("Follow", isOn: $session.visualFollow).toggleStyle(VistaCheckboxStyle()).font(Theme.vista(11)).foregroundStyle(Theme.dim)
                    .help("Scroll the notes past a fixed playhead, or show the whole song")
                if session.visualFollow {
                    Text("Window").font(.system(size: 10)).foregroundStyle(Theme.faint)
                    VistaSlider(value: $session.visualWindowBeats, in: 4...64).frame(width: 90)
                }
            } else if session.visualMode == .wave {
                Text("Speed").font(.system(size: 10)).foregroundStyle(Theme.faint)
                // right = faster and closer: fewer seconds of sound fit across the picture
                VistaSlider(value: Binding(get: { session.waveSpeed }, set: { session.waveSpeed = $0 }), in: 0...1).frame(width: 90)
                    .help(String(format: "%.2f seconds of sound across the picture: the faster it moves, the closer the zoom", session.waveWindow))
                paletteMenu
            } else if (session.visualMode == .circle || session.visualMode == .rings) && session.project.tracks.contains(where: { $0.clips.contains { !$0.notes.isEmpty } }) {
                Text("Each track in its own colour").font(.system(size: 10)).foregroundStyle(Theme.faint)
            } else {
                paletteMenu
            }
            #if os(macOS)
            if inWindow {
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
            } else {
                Button { VisualizerWindow.shared.show(session) } label: { Label("Pop Out", systemImage: "rectangle.on.rectangle") }
                    .help("Open the visualizer in its own window (⌥⌘V), which can go full screen")
            }
            #endif
        }
        .padding(.horizontal, 10).frame(height: 38).background(Theme.panel)
    }
}

#if os(macOS)
/// The visualizer in a window of its own: resizable, full screen with a double-click on the picture.
@MainActor
final class VisualizerWindow: NSObject, NSWindowDelegate {
    static let shared = VisualizerWindow()
    private var window: NSWindow?

    func show(_ session: Session) {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let root = VisualizerContainer(inWindow: true).environmentObject(session).buttonStyle(VistaButtonStyle()).preferredColorScheme(.dark)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 640), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Visualizer"
        w.identifier = NSUserInterfaceItemIdentifier("visualizer")
        w.contentView = NSHostingView(rootView: root)
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.minSize = NSSize(width: 520, height: 320)
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.delegate = self
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { sender.orderOut(nil) }       // keep it around so reopening is instant
        return false
    }
}
#endif
