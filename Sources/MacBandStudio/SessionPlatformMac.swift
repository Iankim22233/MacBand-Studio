#if os(macOS)
import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The parts of the session that talk to macOS: file panels, alerts, the keyboard, plugin windows and the developer test modes.
/// (iOS has its own versions in SessionPlatformIOS.swift.)
extension Session {
    /// Developer aid: drag the first wide note of the selected clip through the real window's event path.
    func demoDragNote(_ clipID: UUID) async {
        func find(_ v: NSView) -> TuneCanvas? { if let c = v as? TuneCanvas { return c }; for s in v.subviews { if let r = find(s) { return r } }; return nil }
        guard let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }), let canvas = win.contentView.flatMap(find) else { print("DRAG no canvas"); return }
        guard let loc = findAudioClip(clipID), let notes = project.tracks[loc.track].audioClips[loc.clip].tune?.notes, let n = notes.max(by: { $0.length < $1.length }) else { print("DRAG no notes"); return }
        let st = canvas.debugState
        let top = TuneState.rulerH + TuneState.waveH
        let px = TuneState.keysW + (CGFloat((n.start + n.end) / 2) - st.scrollX) * st.pps
        let py = top + (st.topPitch - CGFloat(n.pitch)) * st.rowH + st.rowH / 2
        func ev(_ t: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: t, location: canvas.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NSApp.activate(ignoringOtherApps: true); win.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let winPt = canvas.convert(CGPoint(x: px, y: py), to: nil)
        let hitView = win.contentView?.superview?.hitTest(winPt)
        var chain: [String] = []; var hv = hitView; while let v = hv { chain.append(String(describing: type(of: v)).prefix(40).description); hv = v.superview }
        print("DRAG hit chain: \(chain.joined(separator: " ← "))")
        print("DRAG hit view at that point: \(hitView.map { String(describing: type(of: $0)) } ?? "nil") | canvas frame \(canvas.frame) in window \(canvas.convert(canvas.bounds, to: nil)) | window key \(win.isKeyWindow)")
        func dump(_ v: NSView, _ depth: Int) {
            let r = v.convert(v.bounds, to: nil)
            if v is TimelineView || v is TuneCanvas || v is PianoRollView || String(describing: type(of: v)).contains("Hosting") { print("DRAG   \(String(repeating: " ", count: depth))\(type(of: v)) window-rect \(NSStringFromRect(r)) hidden=\(v.isHidden)") }
            for sv in v.subviews { dump(sv, depth + 1) }
        }
        dump(win.contentView!, 0)
        print("DRAG before: note pitch \(n.pitch) word '\(n.word)' len \(String(format: "%.2f", n.length)) s at (\(Int(px)),\(Int(py)))")
        win.sendEvent(ev(.leftMouseDown, CGPoint(x: px, y: py)))
        for i in 1...8 { win.sendEvent(ev(.leftMouseDragged, CGPoint(x: px, y: py - CGFloat(i) * st.rowH / 4))) }
        win.sendEvent(ev(.leftMouseUp, CGPoint(x: px, y: py - 2 * st.rowH)))
        let after = project.tracks[loc.track].audioClips[loc.clip].tune?.notes.first { $0.id == n.id }
        print("DRAG after: note pitch \(after?.pitch ?? -1) edited \(after?.edited ?? false)")
        fflush(stdout)
    }

    /// Developer aid: `--fullscreen-test au:name` checks plugin windows behave while MacBand is fullscreen.
    func runFullscreenTest(_ arg: String) {
        let vst3 = arg.hasPrefix("vst3:")
        let name = (vst3 ? String(arg.dropFirst(5)) : arg.hasPrefix("au:") ? String(arg.dropFirst(3)) : arg).lowercased()
        Task { @MainActor in
            func out(_ s: String) { print(s); fflush(stdout) }
            func wait(_ seconds: Double, until: () -> Bool = { false }) async {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end && !until() { try? await Task.sleep(nanoseconds: 100_000_000) }
            }
            await wait(20) { NSApp.windows.contains { $0.identifier?.rawValue == "main" } && !library.plugins.isEmpty && !library.scanning }
            guard let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) else { out("no main window"); exit(2) }
            main.toggleFullScreen(nil)
            await wait(4)
            out("main window fullscreen: \(main.styleMask.contains(.fullScreen))")
            guard let lp = library.instruments.first(where: { $0.spec.name.lowercased().contains(name) && (!vst3 || $0.spec.format == .vst3) && (vst3 || $0.spec.format == .au) }) else { out("plugin not found"); exit(2) }
            var spec = lp.spec; spec.id = UUID()
            addTrack(instrument: InstrumentSpec(plugin: spec))
            let tid = selectedTrackID!
            await wait(30) { engine.unit(trackID: tid, specID: spec.id) != nil }
            out("plugin instance ready: \(engine.unit(trackID: tid, specID: spec.id) != nil) error=\(errorMessage ?? "none")")
            openEditor(trackID: tid, spec: spec)
            await wait(25) { PluginWindows.shared.window(for: spec.id) != nil }
            await wait(1)
            guard let w1 = PluginWindows.shared.window(for: spec.id) else { out("FAIL: editor window never appeared"); exit(1) }
            out("1st open: visible=\(w1.isVisible) onActiveSpace=\(w1.isOnActiveSpace) auxiliary=\(w1.collectionBehavior.contains(.fullScreenAuxiliary)) level=\(w1.level.rawValue) size=\(w1.frame.size) key=\(w1.isKeyWindow)")
            if let v = w1.contentView {
                let p = NSPoint(x: v.bounds.midX, y: v.bounds.midY)
                out("   hit-test at centre → \(type(of: v.hitTest(p) ?? v)) (subviews: \(v.subviews.count))")
            }
            w1.performClose(nil)
            await wait(1)
            out("after close: visible=\(w1.isVisible) (hidden, not destroyed)")
            openEditor(trackID: tid, spec: spec)
            await wait(1)
            let w2 = PluginWindows.shared.window(for: spec.id)
            out("2nd open: same window=\(w2 === w1) visible=\(w2?.isVisible ?? false) onActiveSpace=\(w2?.isOnActiveSpace ?? false)")
            // a window the plugin might open itself (nag screen, file dialog…)
            let dlg = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
            dlg.title = "plugin dialog"
            dlg.makeKeyAndOrderFront(nil)
            await wait(1)
            out("plugin-style dialog: visible=\(dlg.isVisible) onActiveSpace=\(dlg.isOnActiveSpace) auxiliary=\(dlg.collectionBehavior.contains(.fullScreenAuxiliary))")
            exit(0)
        }
    }

    /// Developer aid: `MacBand --demo-plugin vst3:sylenth` adds that instrument and opens its window.
    func runDemoPlugin(_ arg: String) {
        let vst3 = arg.hasPrefix("vst3:")
        var name = (vst3 ? String(arg.dropFirst(5)) : arg).lowercased()
        var maker: UInt32? = nil
        if let at = arg.firstIndex(of: "@") { maker = PluginHost.fourCC(String(arg[arg.index(after: at)...])); name = String(name[..<(name.firstIndex(of: "@") ?? name.endIndex)]) }
        Task { @MainActor in
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !library.scanning, !library.plugins.isEmpty else { continue }
                guard let lp = library.instruments.first(where: { $0.spec.name.lowercased().contains(name) && (!vst3 || $0.spec.format == .vst3) && (maker == nil || $0.spec.auManufacturer == maker!) }) else { return }
                var spec = lp.spec; spec.id = UUID()
                addTrack(instrument: InstrumentSpec(plugin: spec))
                for _ in 0..<60 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if engine.unit(trackID: selectedTrackID ?? UUID(), specID: spec.id) != nil {
                        let tid = selectedTrackID!
                        openEditor(trackID: tid, spec: spec)
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if let w = PluginWindows.shared.window(for: spec.id) { print("PLUGIN_WINDOW \(w.windowNumber) level=\(w.level.rawValue) frame=\(NSStringFromRect(w.frame)) key=\(w.isKeyWindow)"); fflush(stdout) }
                        if let i = CommandLine.arguments.firstIndex(of: "--demo-snapshot"), i + 1 < CommandLine.arguments.count {
                            let path = CommandLine.arguments[i + 1]
                            engine.noteOn(trackID: tid, pitch: 62, velocity: 100)
                            for n in 1...3 {
                                try? await Task.sleep(nanoseconds: 260_000_000)
                                PluginWindows.shared.snapshot(key: spec.id, to: path.replacingOccurrences(of: ".png", with: "\(n).png"))
                            }
                            exit(0)
                        }
                        if CommandLine.arguments.contains("--demo-notes") {
                            while true {   // developer aid: a note every 1.6 s so the editor animation can be seen
                                engine.noteOn(trackID: tid, pitch: 62, velocity: 100)
                                try? await Task.sleep(nanoseconds: 900_000_000)
                                engine.noteOff(trackID: tid, pitch: 62)
                                try? await Task.sleep(nanoseconds: 700_000_000)
                            }
                        }
                        return
                    }
                }
                return
            }
        }
    }

    // MARK: - Keyboard

    static let typingMap: [UInt16: Int] = [
        0: 0, 13: 1, 1: 2, 14: 3, 2: 4, 3: 5, 17: 6, 5: 7, 16: 8, 4: 9, 32: 10, 38: 11,
        40: 12, 31: 13, 37: 14, 35: 15, 41: 16, 39: 17,
    ]

    func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            if let r = NSApp.keyWindow?.firstResponder, r is NSTextView { return event }
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false { return event }
            guard ["main", "visualizer"].contains(NSApp.keyWindow?.identifier?.rawValue ?? "") else { return event }
            if event.type == .keyDown {
                if event.keyCode == 49 && !event.isARepeat { self.togglePlay(); return nil }   // space
                if !self.musicalTyping, !event.isARepeat {
                    switch event.charactersIgnoringModifiers {
                    case "r": self.toggleRecord(); return nil
                    case "l": self.toggleLoop(); return nil
                    case "c": self.metronome.toggle(); return nil
                    case "t" where self.selectedAudioClipID != nil && self.bottomPanel == .tune: self.toggleTuneForSelection(); return nil
                    case "\r", "\u{3}": self.rewind(); return nil
                    default: break
                    }
                }
                if self.musicalTyping {
                    if event.charactersIgnoringModifiers == "z" { self.typingOctave = max(0, self.typingOctave - 1); return nil }
                    if event.charactersIgnoringModifiers == "x" { self.typingOctave = min(8, self.typingOctave + 1); return nil }
                    if let off = Self.typingMap[event.keyCode] {
                        if !event.isARepeat {
                            let pitch = (self.typingOctave + 1) * 12 + off
                            self.heldKeys[event.keyCode] = pitch
                            self.liveNoteOn(pitch, 100)
                        }
                        return nil
                    }
                }
            } else if let pitch = self.heldKeys.removeValue(forKey: event.keyCode) {
                self.liveNoteOff(pitch); return nil
            }
            return event
        }
    }

    // MARK: - Files and dialogs

    /// Hands a finished file to the person: the Mac asks where to save it (iOS opens the share sheet instead).
    func deliverExport(fileName: String, type: UTType, failure: String, write: (URL) throws -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = fileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try write(url); toast = "Exported \(url.lastPathComponent)" } catch { errorMessage = "\(failure): \(error.localizedDescription)" }
    }

    func importAudio() {
        let panel = NSOpenPanel()
        panel.title = "Import Audio"
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK { for u in panel.urls { importAudio(url: u) } }
    }


    /// Offers the project that was open when the app last closed. Returns true if it was restored.
    func askRestore(message: String, restore: @escaping () -> Void, discard: @escaping () -> Void) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Restore your unsaved project?"
        alert.informativeText = message
        alert.addButton(withTitle: "Restore"); alert.addButton(withTitle: "Discard")
        if alert.runModal() == .alertFirstButtonReturn { restore(); return true }
        discard()
        return false
    }

    /// A message that stays until dismissed, with a way to open the MacBand folder.
    func presentNotice(title: String, text: String, then done: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show in Finder")
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(ProjectsFolder.ensure().url) }
        done()
    }

    func alert(_ title: String, _ detail: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = detail; a.runModal()
    }

    func confirmDiscard() -> Bool {
        guard isDirty else { return true }
        let a = NSAlert()
        a.messageText = "Save changes to “\(project.name)”?"
        a.informativeText = "Your changes will be lost if you don't save them."
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Don't Save"); a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: save(); return !isDirty
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "macband") ?? .json]
        panel.nameFieldStringValue = project.name + ".macband"
        panel.directoryURL = fileURL?.deletingLastPathComponent() ?? ProjectsFolder.ensure().url
        panel.title = "Save Band Project"
        if panel.runModal() == .OK, let url = panel.url {
            project.name = url.deletingPathExtension().lastPathComponent
            write(to: url)
        }
    }

    func openProjectFromPanel() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = ProjectsFolder.url
        panel.allowedContentTypes = [UTType(filenameExtension: "macband") ?? .json]
        panel.title = "Open Band Project"
        if panel.runModal() == .OK, let url = panel.url { openProject(url: url) }
    }

    /// Import a band project by merging its tracks into the current project.
    func importBandProject() {
        let panel = NSOpenPanel()
        // .macband is ours; .json and GarageBand's .band are allowed so picking them gives a clear answer instead of a greyed-out file
        panel.allowedContentTypes = ["macband", "json", "band"].compactMap { UTType(filenameExtension: $0) }
        panel.title = "Import Band Project"
        if panel.runModal() == .OK, let url = panel.url { importBandProject(url: url) }
    }

    func importMIDI() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mid") ?? .midi, UTType(filenameExtension: "midi") ?? .midi]
        panel.title = "Import MIDI File"
        if panel.runModal() == .OK, let url = panel.url { importMIDI(url: url) }
    }

    func askToUseFileTempo(_ imp: MIDIFile.Imported, fileName: String, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Use the tempo from “\(fileName)”?"
        alert.informativeText = tempoQuestionDetail(imp)
        alert.addButton(withTitle: "Use File's Tempo")
        alert.addButton(withTitle: "Keep Project Tempo")
        completion(alert.runModal() == .alertFirstButtonReturn)
    }

    func exportMIDI() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mid") ?? .midi]
        panel.nameFieldStringValue = project.name + ".mid"
        panel.title = "Export MIDI File"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try MIDIFile.build(project, forExport: true).write(to: url, options: .atomic) }
        catch { errorMessage = "Couldn't export: \(error.localizedDescription)" }
    }

    func exportAudio() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = project.name + ".wav"
        panel.title = "Export Audio (WAV)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        stop()
        busyMessage = "Rendering audio…"
        let proj = project
        // Offline rendering drives the live engine, so run it on the main thread after the overlay appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            do {
                try self.engine.bounce(proj, to: url) { _ in }
                self.busyMessage = nil
                self.sequenceDirty = true; self.flushSequence()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self.busyMessage = nil
                self.errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func installPlugins(_ urls: [URL]) {
        let results = library.install(urls) { name in
            let a = NSAlert(); a.messageText = "Replace “\(name)”?"
            a.informativeText = "A plugin with this name is already installed. The old copy will be moved to the Trash."
            a.addButton(withTitle: "Replace"); a.addButton(withTitle: "Skip")
            return a.runModal() == .alertFirstButtonReturn
        }
        var failures: [String] = []
        for r in results { if case .failed(let m) = r { failures.append(m) } }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        // AU registration can lag behind the copy by a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.library.rescan() }
    }
}
#endif
