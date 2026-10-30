import SwiftUI
import UIKit
import AVFoundation
import Combine

@main
struct MacBandApp: App {
    @StateObject private var session: Session
    @Environment(\.scenePhase) private var scenePhase
    private static var observers = Set<AnyCancellable>()

    init() {
        let s = Session()
        s.showInspector = false                          // the inspector opens from its button (a sheet on a phone)
        s.showEditor = false                             // a phone starts on the Tracks page
        s.showLane = UIDevice.current.userInterfaceIdiom != .phone
        _session = StateObject(wrappedValue: s)
        Self.watchPlayback(s)
        if CommandLine.arguments.contains("--selfcheck") { Task { @MainActor in await IOSDiagnostics.run() } }
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView()
                .environmentObject(session)
                .onOpenURL { url in session.openIncoming(url) }
                .onAppear { Self.applyLaunchOptions(session) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.autosaver.saveNowIfNeeded() }
        }
    }

    /// Keeps the screen awake while music plays, and stops it when the phone rings or the headphones come out.
    static func watchPlayback(_ s: Session) {
        s.transport.$isPlaying.receive(on: DispatchQueue.main).sink { playing in UIApplication.shared.isIdleTimerDisabled = playing }.store(in: &observers)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: DispatchQueue.main).sink { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            MainActor.assumeIsolated {
                if type == .began { if s.transport.isPlaying { s.stop() } }
                else { AudioEngine.configureAudioSession(); s.engine.startEngine() }
            }
        }.store(in: &observers)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: DispatchQueue.main).sink { note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt, AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { if s.transport.isPlaying { s.stop() } }
        }.store(in: &observers)
    }

    /// Developer launch arguments for the simulator: `--landscape` turns the picture sideways (the Simulator's own rotate can be fiddly),
    /// `--demo-song` loads the demo song, `--demo-panel steps|mixer|…` and `--demo-play` set things up for a screenshot.
    static func applyLaunchOptions(_ session: Session) {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if args.contains("--landscape") {
            (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        }
        if args.contains("--portrait") {
            (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
        if args.contains("--demo-song") {
            session.load(DemoSong.make(), url: nil)
            if let ti = value("--demo-track").flatMap({ Int($0) }), ti < session.project.tracks.count { session.selectedTrackID = session.project.tracks[ti].id }
            switch value("--demo-panel") {
            case "editor": session.showEditor = true; session.bottomPanel = .editor
            case "steps": session.showEditor = true; session.bottomPanel = .steps
            case "score": session.showEditor = true; session.bottomPanel = .score
            case "visual": session.showEditor = true; session.bottomPanel = .visual
            case "tune": session.showEditor = true; session.bottomPanel = .tune
            case "mixer": session.showEditor = true; session.bottomPanel = .mixer
            case "inspector": session.showInspector = true
            case "projects": session.showProjectBrowser = true
            case "intro": session.showIntro = true
            case "sounds": session.soundTarget = .newTrack
            default: break
            }
            if args.contains("--demo-keys") { session.showKeyboard = true }
            if let m = value("--demo-visual").flatMap({ VisualMode(rawValue: $0) }) { session.visualMode = m }
            if args.contains("--demo-play") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { session.togglePlay() } }
        }
    }
}
