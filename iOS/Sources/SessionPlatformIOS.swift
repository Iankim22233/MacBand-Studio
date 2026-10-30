import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The parts of the session that talk to iOS: questions become alerts, file panels become pickers, and "save as" / "export" become
/// the project folder and the share sheet. (The Mac versions are in SessionPlatformMac.swift.)
extension Session {
    // MARK: - Dialogs

    func alert(_ title: String, _ detail: String) {
        prompt = Prompt(title: title, message: detail, choices: [.init(title: "OK")])
    }

    /// iOS never asks "save changes?": the work is saved instead, so nothing is lost when another project is opened.
    func confirmDiscard() -> Bool {
        guard isDirty else { return true }
        if let url = fileURL { write(to: url) }
        else if project.tracks.contains(where: { $0.clips.contains { !$0.notes.isEmpty } || !$0.audioClips.isEmpty }) {
            let url = uniqueProjectURL(named: project.name)
            write(to: url)
            showToast("Saved “\(url.deletingPathExtension().lastPathComponent)”")
        }
        return true
    }

    /// A file name in the projects folder that isn't taken yet.
    func uniqueProjectURL(named name: String) -> URL {
        let folder = ProjectsFolder.ensure().url
        let base = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        var url = folder.appendingPathComponent((base.isEmpty ? "Untitled" : base) + ".macband")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base.isEmpty ? "Untitled" : base) \(n).macband"); n += 1
        }
        return url
    }

    func saveAs() {
        prompt = Prompt(title: "Save Project", message: "Give the project a name. It is kept in the MacBand Studio folder in the Files app.",
                        choices: [.init(title: "Save"), .init(title: "Cancel", role: .cancel)],
                        textFieldPlaceholder: "Name", textFieldInitial: project.name == "Untitled" ? "" : project.name) { [self] text in
            let name = text.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            let url = ProjectsFolder.ensure().url.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-") + ".macband")
            if FileManager.default.fileExists(atPath: url.path) && url != fileURL {
                prompt = Prompt(title: "Replace “\(name)”?", message: "A project with this name is already in the folder.",
                                choices: [.init(title: "Replace", role: .destructive, action: { [self] in project.name = name; write(to: url) }),
                                          .init(title: "Cancel", role: .cancel)])
            } else { project.name = name; write(to: url) }
        }
    }

    /// Asks for files and gives the completion local copies of them (the picked files can be anywhere: iCloud, other apps…).
    func pickFiles(_ types: [UTType], multiple: Bool = false, then: @escaping ([URL]) -> Void) {
        filePicker = FilePickerRequest(types: types, allowsMultiple: multiple, completion: then)
    }

    func openProjectFromPanel() {
        guard confirmDiscard() else { return }
        pickFiles([UTType(filenameExtension: "macband") ?? .json, .json]) { [self] urls in
            guard let u = urls.first else { return }
            let dest = uniqueProjectURL(named: u.deletingPathExtension().lastPathComponent)
            do { try FileManager.default.copyItem(at: u, to: dest); openProject(url: dest) }
            catch { errorMessage = "Couldn't open \(u.lastPathComponent): \(error.localizedDescription)" }
        }
    }

    /// Open the same chooser a drop uses: another project (merged in), or a GarageBand project (its audio, tempo and key).
    func importBandProject() {
        let band = UTType(filenameExtension: "band", conformingTo: .package) ?? UTType(filenameExtension: "band") ?? .data
        pickFiles(["macband", "json"].compactMap { UTType(filenameExtension: $0) } + [band]) { [self] urls in
            for u in urls { importBandProject(url: u) }
        }
    }

    func importMIDI() {
        pickFiles([UTType(filenameExtension: "mid") ?? .midi, UTType(filenameExtension: "midi") ?? .midi]) { [self] urls in
            for u in urls { importMIDI(url: u) }
        }
    }

    func importAudio() {
        pickFiles([.audio], multiple: true) { [self] urls in
            for u in urls { importAudio(url: u) }
        }
    }

    func askToUseFileTempo(_ imp: MIDIFile.Imported, fileName: String, completion: @escaping (Bool) -> Void) {
        prompt = Prompt(title: "Use the tempo from “\(fileName)”?", message: tempoQuestionDetail(imp),
                        choices: [.init(title: "Use File's Tempo", action: { completion(true) }),
                                  .init(title: "Keep Project Tempo", action: { completion(false) })])
    }

    func askRestore(message: String, restore: @escaping () -> Void, discard: @escaping () -> Void) -> Bool {
        // the answer comes later, so the start-up goes on from the buttons
        let r = restore, d = discard
        prompt = Prompt(title: "Restore your unsaved project?", message: message,
                        choices: [.init(title: "Restore", action: { r() }),
                                  .init(title: "Discard", role: .destructive, action: { [self] in d(); continueLaunch() })])
        return true
    }

    func presentNotice(title: String, text: String, then done: @escaping () -> Void) {
        prompt = Prompt(title: title, message: text, choices: [.init(title: "OK", action: done)])
    }

    // MARK: - Export

    /// iOS has no save panel: the file is written and offered to the share sheet (Save to Files, AirDrop, Mail…).
    func deliverExport(fileName: String, type: UTType, failure: String, write: (URL) throws -> Void) {
        let safe = fileName.replacingOccurrences(of: "/", with: "-")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let url = dir.appendingPathComponent(safe)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try write(url)
            shareItem = ShareItem(url: url)
        } catch { errorMessage = "\(failure): \(error.localizedDescription)" }
    }

    func exportMIDI() {
        deliverExport(fileName: project.name + ".mid", type: .midi, failure: "Couldn't export") { url in
            try MIDIFile.build(self.project, forExport: true).write(to: url, options: .atomic)
        }
    }

    func exportAudio() {
        let safe = project.name.replacingOccurrences(of: "/", with: "-")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(safe + ".wav")
        stop()
        busyMessage = "Rendering audio…"
        let proj = project
        // Offline rendering drives the live engine, so run it on the main thread after the overlay appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            do {
                try self.engine.bounce(proj, to: url) { _ in }
                self.busyMessage = nil
                self.sequenceDirty = true; self.flushSequence()
                self.shareItem = ShareItem(url: url)
            } catch {
                self.busyMessage = nil
                self.errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    /// A file opened from the Files app, a share sheet or AirDrop. It is read once into the app's own folder first.
    func openIncoming(_ url: URL) {
        guard let local = IOSPresentations.localCopy(of: url) else { errorMessage = "Couldn't read \(url.lastPathComponent)."; return }
        switch local.pathExtension.lowercased() {
        case "macband", "json":
            guard confirmDiscard() else { return }
            let dest = uniqueProjectURL(named: local.deletingPathExtension().lastPathComponent)
            do { try FileManager.default.copyItem(at: local, to: dest); openProject(url: dest) }
            catch { errorMessage = "Couldn't open \(local.lastPathComponent): \(error.localizedDescription)" }
        case "sf2", "dls":
            let folder = ProjectsFolder.soundsFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent(local.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: local, to: dest)
            SoundLibrary.shared.rescan()
            showToast("Added “\(local.lastPathComponent)” to the sound library")
        default:
            handleDrop([local])
        }
    }

    func installPlugins(_ urls: [URL]) {
        errorMessage = "Plugins can't be installed on iOS."
    }
}
