import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import SwiftUI

/// A small multi-track song used by the dev flags (`--demo-song`) and the headless tests.
extension Session {
    /// `--demo-song [--demo-panel editor|score|steps|mixer] [--demo-track N] [--demo-shot out.png]`
    func runDemoSongIfRequested() {
        let args = CommandLine.arguments
        guard args.contains("--demo-song") else { return }
        func value(_ f: String) -> String? { args.firstIndex(of: f).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            self.project = DemoSong.make()
            self.engine.syncTracks(self.project.tracks, master: self.project.masterInserts)
            self.applyMix()
            let ti = Int(value("--demo-track") ?? "0") ?? 0
            self.selectedTrackID = self.project.tracks[ti].id
            self.selectedClipID = self.project.tracks[ti].clips.first?.id
            if args.contains("--demo-mute-solo") { self.project.tracks[1].mute = true; self.project.tracks[2].solo = true }      // for pictures of the M and S buttons
            self.demoPanel(value("--demo-panel"))
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if args.contains("--demo-play") {                      // capture while the music plays (track glow)
                self.togglePlay()
                try? await Task.sleep(nanoseconds: UInt64((Double(value("--demo-after") ?? "1.3") ?? 1.3) * 1e9))
            }
            let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })?.windowNumber ?? 0
            print("DEMO_WINDOW \(win)"); fflush(stdout)
            if let out = value("--demo-shot") {
                func grab(_ w: NSWindow?, to path: String) {
                    guard let w else { return }
                    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    p.arguments = ["-x", "-o", "-l", "\(w.windowNumber)", path]
                    try? p.run(); p.waitUntilExit()
                    if FileManager.default.fileExists(atPath: path) { return }
                    // The screen isn't available (display asleep, locked…): render the view hierarchy instead.
                    guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })
                grab(main, to: out)
                grab(main?.attachedSheet, to: out.replacingOccurrences(of: ".png", with: "-sheet.png"))
                exit(0)
            }
        }
    }

    private func demoPanel(_ name: String?) {
        switch name {
        case "mixer": bottomPanel = .mixer
        case "tune": bottomPanel = .tune
        case "steps": bottomPanel = .steps
        case "score": bottomPanel = .score
        case "visual":
            bottomPanel = .visual
            if let i = CommandLine.arguments.firstIndex(of: "--demo-visual-mode"), i + 1 < CommandLine.arguments.count,
               let m = VisualMode(rawValue: CommandLine.arguments[i + 1]) {
                visualMode = m
                UserDefaults.standard.removeObject(forKey: "visualMode")      // a picture run must not change the saved choice
            }
        case "browser": showProjectBrowser = true
        case "master":                                      // the Master track selected, with two example effects
            bottomPanel = .mixer
            project.masterInserts = [MasterTest.delay(), PluginSpec(format: .au, name: "AUMultibandCompressor", vendor: "Apple", isInstrument: false)]
            selectMaster()
        case "intro":
            introStartPage = Int(CommandLine.arguments.firstIndex(of: "--demo-intro-page").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil } ?? "0") ?? 0
            showIntro = true
        case "sounds": soundTarget = .newTrack
        default: bottomPanel = .editor
        }
    }
}
