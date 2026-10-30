import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

#if os(macOS)
/// The "MacBand" projects folder, kept next to GarageBand's own (`~/Music/GarageBand` → `~/Music/MacBand`).
enum ProjectsFolder {
    nonisolated(unsafe) static var override: URL?           // tests
    static let folderName = "MacBand"
    static let defaultsKey = "projectsFolder"

    /// Where the folder belongs: beside GarageBand's folder if there is one; otherwise beside the `.band` projects
    /// Spotlight finds (the folder most of them are in); otherwise in Music.
    static func locate(home: URL = FileManager.default.homeDirectoryForCurrentUser, bandFiles: () -> [URL] = spotlightBandFiles) -> URL {
        let fm = FileManager.default
        let garageBand = home.appendingPathComponent("Music/GarageBand", isDirectory: true)
        if fm.fileExists(atPath: garageBand.path) { return garageBand.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true) }
        let parents = bandFiles().filter { !$0.path.contains("/Library/") && !$0.path.contains("/.Trash/") }.map { $0.deletingLastPathComponent().path }
        var counts: [String: Int] = [:]
        for p in parents { counts[p, default: 0] += 1 }
        if let best = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key {
            return URL(fileURLWithPath: best, isDirectory: true).appendingPathComponent(folderName, isDirectory: true)
        }
        return home.appendingPathComponent("Music/\(folderName)", isDirectory: true)
    }

    nonisolated static func spotlightBandFiles() -> [URL] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-onlyin", NSHomeDirectory(), "kMDItemFSName == '*.band'c"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    /// The folder in use: the one chosen before, else where it belongs.
    static var url: URL {
        if let o = override { return o }
        if let saved = UserDefaults.standard.string(forKey: defaultsKey) { return URL(fileURLWithPath: saved, isDirectory: true) }
        return locate()
    }

    /// Creates the folder if it isn't there (and remembers where it is). Returns the folder in use and whether it was just made.
    @discardableResult
    static func ensure() -> (url: URL, created: Bool) {
        let target = url
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { remember(target); return (target, false) }
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            remember(target)
            return (target, true)
        } catch {
            // e.g. no permission there: fall back to Documents
            let fallback = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(folderName, isDirectory: true)
            try? fm.createDirectory(at: fallback, withIntermediateDirectories: true)
            remember(fallback)
            return (fallback, true)
        }
    }

    static func choose(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        remember(folder)
    }

    private static func remember(_ u: URL) { if override == nil { UserDefaults.standard.set(u.path, forKey: defaultsKey) } }
}

#else
/// The projects folder on iOS is the app's own Documents folder, which the Files app shows as "MacBand Studio".
enum ProjectsFolder {
    nonisolated(unsafe) static var override: URL?           // tests
    static let folderName = "MacBand"
    static let defaultsKey = "projectsFolder"
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var url: URL { override ?? documents }
    /// Where SoundFonts the person adds (through the Files app or an import) are kept.
    static var soundsFolder: URL { documents.appendingPathComponent("Sounds", isDirectory: true) }

    /// `created` is true the first time the app runs, so the welcome song gets written once.
    @discardableResult
    static func ensure() -> (url: URL, created: Bool) {
        let target = url
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: soundsFolder, withIntermediateDirectories: true)
        if override != nil { return (target, false) }
        let key = "iosFolderPrepared"
        let first = !UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        return (target, first)
    }
    static func choose(_ folder: URL) {}
}
#endif

/// Projects opened or saved lately, newest first.
enum RecentProjects {
    nonisolated(unsafe) static var storeKey = "recentProjects"
    static let limit = 12

    static var urls: [URL] {
        (UserDefaults.standard.stringArray(forKey: storeKey) ?? []).map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func add(_ url: URL) {
        var paths = (UserDefaults.standard.stringArray(forKey: storeKey) ?? []).filter { $0 != url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(limit)), forKey: storeKey)
    }
    static func remove(_ url: URL) {
        UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: storeKey) ?? []).filter { $0 != url.path }, forKey: storeKey)
    }
}

struct PreviewNote: Hashable { var track: Int; var start: Float; var end: Float; var pitch: Int16 }

/// What the project chooser shows about a project file, read without loading the whole project.
struct ProjectInfo: Identifiable, Hashable {
    var url: URL
    var name: String
    var modified: Date
    var tracks: Int
    var audioTracks: Int
    var notes: Int
    var tempo: Double
    var bars: Int
    var colors: [Int]                 // colour index of each track
    var preview: [PreviewNote]
    var endBeat: Float
    var id: String { url.path }
    var details: String {
        var parts = ["\(tracks) track\(tracks == 1 ? "" : "s")"]
        if notes > 0 { parts.append("\(notes) notes") }
        parts.append("\(Int(tempo.rounded())) BPM")
        if bars > 0 { parts.append("\(bars) bar\(bars == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

enum ProjectScanner {
    private struct Lite: Decodable {
        var name: String?, tempo: Double?, timeSigNum: Int?, timeSigDen: Int?
        var tracks: [LTrack]?
        struct LTrack: Decodable { var colorIndex: Int?; var kind: String?; var clips: [LClip]?; var audioClips: [LAudio]? }
        struct LClip: Decodable { var start: Double?; var length: Double?; var notes: [LNote]? }
        struct LNote: Decodable { var pitch: Int; var start: Double; var length: Double }
        struct LAudio: Decodable { var start: Double?; var length: Double? }
    }

    static func summary(of url: URL, previewLimit: Int = 700) -> ProjectInfo? {
        guard let data = try? Data(contentsOf: url), let lite = try? JSONDecoder().decode(Lite.self, from: data) else { return nil }
        let modified = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date) ?? .distantPast
        let bpb = Double(lite.timeSigNum ?? 4) * 4 / Double(max(1, lite.timeSigDen ?? 4))
        var notes: [PreviewNote] = []
        var noteCount = 0, endBeat = 0.0, audio = 0
        for (ti, t) in (lite.tracks ?? []).enumerated() {
            if t.kind == "audio" { audio += 1 }
            for c in t.clips ?? [] {
                endBeat = max(endBeat, (c.start ?? 0) + (c.length ?? 0))
                for n in c.notes ?? [] {
                    noteCount += 1
                    notes.append(PreviewNote(track: ti, start: Float((c.start ?? 0) + n.start), end: Float((c.start ?? 0) + n.start + n.length), pitch: Int16(clamping: n.pitch)))
                }
            }
            for a in t.audioClips ?? [] { endBeat = max(endBeat, (a.start ?? 0) + (a.length ?? 0) * (lite.tempo ?? 120) / 60) }
        }
        if notes.count > previewLimit { let k = Double(notes.count) / Double(previewLimit); notes = (0..<previewLimit).map { notes[Int(Double($0) * k)] } }
        return ProjectInfo(url: url, name: url.deletingPathExtension().lastPathComponent,
                           modified: modified, tracks: lite.tracks?.count ?? 0, audioTracks: audio, notes: noteCount, tempo: lite.tempo ?? 120,
                           bars: endBeat > 0 ? Int(ceil(endBeat / bpb)) : 0, colors: (lite.tracks ?? []).map { $0.colorIndex ?? 0 },
                           preview: notes, endBeat: Float(max(endBeat, bpb * 2)))
    }

    /// `.macband` files in a folder and one level of folders inside it.
    static func projectFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for u in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            if u.pathExtension.lowercased() == "macband" { out.append(u) }
            else if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true, !u.lastPathComponent.hasSuffix("Audio") {
                for v in (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [] where v.pathExtension.lowercased() == "macband" { out.append(v) }
            }
        }
        return out
    }

    /// Projects elsewhere on this Mac (Downloads, the Desktop…), found with Spotlight; backups and auto-save copies are skipped.
    nonisolated static func otherProjectFiles(excluding folder: URL) -> [URL] {
        #if os(iOS)
        return []                                           // an iOS app only sees its own folder
        #else
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-onlyin", NSHomeDirectory(), "kMDItemFSName == '*.macband'c"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            .filter { isUserProject($0, excluding: folder) }
        #endif
    }

    nonisolated static func isUserProject(_ u: URL, excluding folder: URL) -> Bool {
        let path = u.path
        if path.hasPrefix(folder.path + "/") { return false }
        for skip in ["/Library/", "/.Trash/", "/Backups/", "/Autosave/", "/node_modules/", "/.build/"] where path.contains(skip) { return false }
        return !u.lastPathComponent.hasPrefix("Untitled recovery")
    }
}

/// The three lists the chooser shows. Loading happens off the main thread.
@MainActor
final class ProjectLibrary: ObservableObject {
    @Published private(set) var inFolder: [ProjectInfo] = []
    @Published private(set) var recent: [ProjectInfo] = []
    @Published private(set) var other: [ProjectInfo] = []
    @Published private(set) var scanning = false
    @Published private(set) var folder: URL = ProjectsFolder.url
    private var generation = 0

    var isEmpty: Bool { inFolder.isEmpty && recent.isEmpty && other.isEmpty }

    func refresh(includeOther: Bool = true) {
        generation += 1
        let gen = generation
        let folder = ProjectsFolder.url
        self.folder = folder
        let recents = RecentProjects.urls
        scanning = true
        Task.detached(priority: .userInitiated) {
            let inFolderFiles = ProjectScanner.projectFiles(in: folder)
            let inFolder = inFolderFiles.compactMap { ProjectScanner.summary(of: $0) }.sorted { $0.modified > $1.modified }
            let folderPaths = Set(inFolder.map { $0.id })
            let recent = recents.filter { !folderPaths.contains($0.path) }.compactMap { ProjectScanner.summary(of: $0) }
            await MainActor.run { if gen == self.generation { self.inFolder = inFolder; self.recent = recent } }
            guard includeOther else { await MainActor.run { if gen == self.generation { self.scanning = false } }; return }
            let shown = folderPaths.union(recent.map { $0.id })
            let others = ProjectScanner.otherProjectFiles(excluding: folder).filter { !shown.contains($0.path) }
                .compactMap { ProjectScanner.summary(of: $0) }.sorted { $0.modified > $1.modified }.prefix(40)
            await MainActor.run { if gen == self.generation { self.other = Array(others); self.scanning = false } }
        }
    }
}
