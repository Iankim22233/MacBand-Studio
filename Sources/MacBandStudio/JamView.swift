#if os(macOS)
import SwiftUI
import AppKit
import SceneKit
import Combine

/// The 3D stage on screen: a SceneKit view driven by the song's playhead. Drag to orbit, scroll to zoom, double-click to reset the camera.
final class JamView: SCNView {
    let session: Session
    let stage = JamStage()
    private var timer: Timer?
    private var last = Date()
    private var dirty = true
    private var framedSize = CGSize.zero
    private var bag = Set<AnyCancellable>()

    init(session: Session) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 960, height: 600), options: nil)
        scene = stage.scene
        pointOfView = stage.cameraNode
        backgroundColor = .black
        antialiasingMode = .multisampling4X
        preferredFramesPerSecond = 60
        allowsCameraControl = true
        autoenablesDefaultLighting = false
        session.objectWillChange.sink { [weak self] _ in self?.dirty = true }.store(in: &bag)
        stage.sync(session.project)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        last = Date()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    override func layout() {
        super.layout()
        guard bounds.height > 10, bounds.size != framedSize else { return }
        framedSize = bounds.size
        stage.frameCamera(aspect: Double(bounds.width / bounds.height))
    }

    private func tick() {
        let visible = (window?.occlusionState.contains(.visible) ?? false) || CommandLine.arguments.contains("--demo-song")     // pictures for the docs run even when the window is behind others
        if rendersContinuously != visible { rendersContinuously = visible }
        guard visible else { return }
        let now = Date()
        let dt = min(0.1, now.timeIntervalSince(last))
        last = now
        step(dt)
    }

    /// Moves the stage on by `dt` seconds (also used by the tests).
    func step(_ dt: Double) {
        if dirty { dirty = false; if stage.sync(session.project) { framedSize = .zero; needsLayout = true } }
        let beat = session.transport.beat
        stage.update(beat: beat, playing: session.transport.isPlaying, secondsPerBeat: 60 / max(20, session.project.bpm(at: beat)), dt: dt)
    }
}

/// The 3D stage in a window of its own (⌥⌘J): it can go full screen.
@MainActor
final class JamWindow: NSObject, NSWindowDelegate {
    static let shared = JamWindow()
    private(set) var window: NSWindow?
    private(set) var view: JamView?

    func show(_ session: Session) {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let v = JamView(session: session)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "3D Stage"
        w.identifier = NSUserInterfaceItemIdentifier("jam")
        w.contentView = v
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.minSize = NSSize(width: 520, height: 340)
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.delegate = self
        w.center()
        window = w; view = v
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { sender.orderOut(nil) }       // keep it around so reopening is instant
        return false
    }
}
#endif
