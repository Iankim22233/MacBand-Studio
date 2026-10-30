import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import AVFoundation

/// Brings GarageBand projects (`.band` packages) in as far as their open parts allow: the audio stems in `Media`,
/// and the tempo, time signature and key in `MetaData.plist`. The notes, instruments and mix live in Apple's private
/// `ProjectData` file, which nothing outside GarageBand can read.
enum GarageBandImporter {
    struct Info {
        var name: String
        var bpm: Double
        var num: Int, den: Int
        var keyRoot: Int?
        var minor: Bool
        var audio: [URL]
        var savedFrom: String
    }

    static let audioExtensions: Set<String> = ["wav", "aif", "aiff", "caf", "mp3", "m4a", "flac"]
    private static let keyNames: [String: Int] = ["C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "F": 5, "F#": 6, "Gb": 6,
                                                  "G": 7, "G#": 8, "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11]

    static func keyRoot(_ name: String) -> Int? { keyNames[name.trimmingCharacters(in: .whitespaces)] }

    /// The `.band` packages directly inside a folder.
    static func projects(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { $0.pathExtension.lowercased() == "band" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func read(_ band: URL) -> Info? {
        let fm = FileManager.default
        // the newest "alternative" that has a MetaData.plist
        let alts = ((try? fm.contentsOfDirectory(at: band.appendingPathComponent("Alternatives"), includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("MetaData.plist").path) }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        var bpm = 120.0, num = 4, den = 4, root: Int?, minor = false
        if let alt = alts.first, let d = NSDictionary(contentsOf: alt.appendingPathComponent("MetaData.plist")) as? [String: Any] {
            if let b = (d["BeatsPerMinute"] as? NSNumber)?.doubleValue, b > 20, b < 400 { bpm = b }
            if let n = (d["SongSignatureNumerator"] as? NSNumber)?.intValue, n > 0 { num = n }
            if let m = (d["SongSignatureDenominator"] as? NSNumber)?.intValue, m > 0 { den = m }
            if let k = d["SongKey"] as? String { root = keyRoot(k) }
            minor = (d["SongGenderKey"] as? String)?.lowercased() == "minor"
        } else if !fm.fileExists(atPath: band.appendingPathComponent("Media").path) && alts.isEmpty { return nil }
        var audio: [URL] = []
        if let en = fm.enumerator(at: band.appendingPathComponent("Media/Audio Files"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let u as URL in en where audioExtensions.contains(u.pathExtension.lowercased()) { audio.append(u) }
        }
        audio.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let saved = ((NSDictionary(contentsOf: band.appendingPathComponent("Resources/ProjectInformation.plist")) as? [String: Any])?["LastSavedFrom"] as? String) ?? ""
        return Info(name: band.deletingPathExtension().lastPathComponent, bpm: bpm, num: num, den: den, keyRoot: root, minor: minor, audio: audio, savedFrom: saved)
    }

    /// Short track names: the part of each stem's name that differs ("Song_drums", "Song_bass" → "drums", "bass").
    static func trackNames(_ files: [URL]) -> [String] {
        let names = files.map { $0.deletingPathExtension().lastPathComponent }
        guard names.count > 1, var prefix = names.first else { return names }
        for n in names.dropFirst() { while !n.hasPrefix(prefix) && !prefix.isEmpty { prefix.removeLast() } }
        // cut the shared part back to a word boundary
        if let cut = prefix.lastIndex(where: { "_ -".contains($0) }) { prefix = String(prefix[...cut]) } else { prefix = "" }
        let stripped = names.map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "_- ")) }
        return zip(stripped, names).map { $0.isEmpty ? $1 : $0 }
    }

    /// A MacBand project made of the stems: one audio track each, all starting at the beginning, with the project's tempo, meter and key.
    static func assemble(_ info: Info, stems: [(file: URL, imported: AudioStore.Imported)]) -> Project {
        var p = Project()
        p.name = info.name
        p.tempo = info.bpm
        p.timeSigNum = info.num; p.timeSigDen = info.den
        if let r = info.keyRoot { p.keyRoot = r; p.scale = info.minor ? .minor : .major }
        let names = trackNames(stems.map { $0.file })
        for (i, s) in stems.enumerated() {
            var t = Track(name: names[i], colorIndex: i, kind: .audio)
            let clip = AudioClip(name: names[i], start: 0, file: s.imported.file, sourceName: s.file.lastPathComponent,
                                 duration: s.imported.duration, length: s.imported.duration, peaks: s.imported.peaks)
            t.audioClips = [clip]
            p.tracks.append(t)
        }
        return p
    }

    /// Where the converted project goes: next to the others, without overwriting anything.
    static func destination(for name: String, in folder: URL) -> URL {
        folder.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-") + ".macband")
    }

    /// Puts the audio a project uses next to it (hard links, so it takes no extra space; a copy if linking isn't possible).
    static func shareAudio(of project: Project, with projectURL: URL) {
        let fm = FileManager.default
        let dir = projectURL.deletingLastPathComponent().appendingPathComponent(projectURL.deletingPathExtension().lastPathComponent + " Audio", isDirectory: true)
        let files = Set(project.tracks.flatMap { $0.audioClips.map { $0.file } })
        guard !files.isEmpty else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files {
            let dst = dir.appendingPathComponent(f)
            if fm.fileExists(atPath: dst.path) { continue }
            if (try? fm.linkItem(at: AudioStore.url(f), to: dst)) == nil { try? fm.copyItem(at: AudioStore.url(f), to: dst) }
        }
    }

    struct Converted {
        var name: String
        var url: URL
        var tracks: Int
        var bpm: Double
        var keyText: String
        var skippedAudio: Int
    }
    struct Result {
        var converted: [Converted] = []
        var alreadyThere: [String] = []
        var failed: [(name: String, reason: String)] = []
    }

    /// Converts one `.band` into `<folder>/<name>.macband`. Heavy (reads and converts every stem): call off the main thread.
    nonisolated static func convert(_ band: URL, into folder: URL, progress: (String) -> Void = { _ in }) -> Result {
        var result = Result()
        let name = band.deletingPathExtension().lastPathComponent
        let dest = destination(for: name, in: folder)
        if FileManager.default.fileExists(atPath: dest.path) { result.alreadyThere.append(name); return result }
        guard let info = read(band) else { result.failed.append((name, "it isn't a GarageBand project package")); return result }
        guard !info.audio.isEmpty else { result.failed.append((name, "it has no audio files to bring across (GarageBand keeps notes and instruments in a private format)")); return result }
        var stems: [(file: URL, imported: AudioStore.Imported)] = []
        var skipped = 0
        for (i, f) in info.audio.enumerated() {
            progress("\(name): audio \(i + 1) of \(info.audio.count)")
            do { stems.append((f, try AudioStore.importFile(f))) } catch { skipped += 1 }
        }
        guard !stems.isEmpty else { result.failed.append((name, "its audio files couldn't be read (are they downloaded from iCloud?)")); return result }
        let project = assemble(info, stems: stems)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
            try enc.encode(project).write(to: dest, options: .atomic)
            shareAudio(of: project, with: dest)
        } catch { result.failed.append((name, "couldn't write the project (\(error.localizedDescription))")); return result }
        let keyText = info.keyRoot.map { "\(Pitch.names[$0]) \(info.minor ? "minor" : "major")" } ?? "no key"
        result.converted.append(Converted(name: name, url: dest, tracks: stems.count, bpm: info.bpm, keyText: keyText, skippedAudio: skipped))
        return result
    }

    /// What the notification says.
    static func notice(for result: Result, from source: URL, to folder: URL) -> (title: String, text: String)? {
        guard !result.converted.isEmpty || !result.failed.isEmpty else { return nil }
        func short(_ u: URL) -> String { u.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        var lines: [String] = []
        if !result.converted.isEmpty {
            let n = result.converted.count
            lines.append("MacBand found \(n) GarageBand project\(n == 1 ? "" : "s") in \(short(source)) and made \(n == 1 ? "a copy" : "copies") in \(short(folder)):")
            for c in result.converted {
                lines.append("  • \(c.name): \(c.tracks) audio track\(c.tracks == 1 ? "" : "s"), \(Int(c.bpm.rounded())) BPM, \(c.keyText)\(c.skippedAudio > 0 ? " (\(c.skippedAudio) file\(c.skippedAudio == 1 ? "" : "s") couldn't be read)" : "")")
            }
            lines.append("")
            lines.append("GarageBand keeps its notes and instruments in a private format only GarageBand can read, so what comes across is each project's audio, tempo, time signature and key. Your GarageBand projects were not changed.")
        }
        for f in result.failed { lines.append("• \(f.name) wasn't imported: \(f.reason).") }
        return (result.converted.isEmpty ? "GarageBand projects couldn't be imported" : "Imported your GarageBand projects", lines.joined(separator: "\n"))
    }
}

@MainActor
extension Session {
    nonisolated(unsafe) static var noticeOverride: ((String, String) -> Void)?    // tests

    /// Where GarageBand keeps its projects, beside the MacBand folder.
    var garageBandFolder: URL { ProjectsFolder.url.deletingLastPathComponent().appendingPathComponent("GarageBand", isDirectory: true) }

    /// First start only: every GarageBand project in the GarageBand folder becomes a MacBand project in the MacBand folder.
    func autoImportGarageBandProjects() {
        #if os(iOS)
        return                                              // an iOS app can't see GarageBand's folder; use Import ▸ GarageBand Project instead
        #else
        let key = "garageBandImportDone"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)                  // one attempt, whatever comes of it
        let source = garageBandFolder, dest = ProjectsFolder.url
        let bands = GarageBandImporter.projects(in: source)
        guard !bands.isEmpty else { return }
        bandImportRunning = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> GarageBandImporter.Result in
                var all = GarageBandImporter.Result()
                for b in bands {
                    let r = GarageBandImporter.convert(b, into: dest)
                    all.converted += r.converted; all.alreadyThere += r.alreadyThere; all.failed += r.failed
                }
                return all
            }.value
            self.bandImportRunning = false
            if let n = GarageBandImporter.notice(for: result, from: source, to: dest) {
                self.pendingNotice = (n.title, n.text)
                self.showToast(result.converted.isEmpty ? "GarageBand import: nothing could be imported" : "Imported \(result.converted.count) GarageBand project\(result.converted.count == 1 ? "" : "s") into \(dest.lastPathComponent)")
                if !self.showIntro { self.showPendingNotice() }
            } else if !self.showIntro { self.maybeShowBrowserAtLaunch() }
        }
        #endif
    }

    /// Shows the "imported your GarageBand projects" message (after the introduction, so the two don't fight for the screen).
    func showPendingNotice() {
        guard let n = pendingNotice else { return }
        pendingNotice = nil
        if let hook = Session.noticeOverride { hook(n.title, n.text); maybeShowBrowserAtLaunch(); return }
        presentNotice(title: n.title, text: n.text) { [self] in maybeShowBrowserAtLaunch() }
    }

    /// File ▸ Import ▸ Band Project… or a drop: one GarageBand project, converted and opened.
    func importGarageBandProject(url: URL) {
        busyMessage = "Importing “\(url.deletingPathExtension().lastPathComponent)” from GarageBand…"
        let dest = ProjectsFolder.ensure().url
        Task {
            let result = await Task.detached(priority: .userInitiated) { GarageBandImporter.convert(url, into: dest) }.value
            self.busyMessage = nil
            if let c = result.converted.first {
                RecentProjects.add(c.url)
                self.openProjectConfirmed(c.url)
                self.showToast("Imported “\(c.name)”: \(c.tracks) audio track\(c.tracks == 1 ? "" : "s"), \(Int(c.bpm.rounded())) BPM. GarageBand's notes and instruments can't be read.")
            } else if let name = result.alreadyThere.first {
                let existing = GarageBandImporter.destination(for: name, in: dest)
                self.openProjectConfirmed(existing)
                self.showToast("“\(name)” was already imported: opened it.")
            } else if let f = result.failed.first {
                self.errorMessage = "“\(f.name)” couldn't be imported: \(f.reason)."
            }
        }
    }
}
