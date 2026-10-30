import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import SwiftUI

/// `--projecttest`: the MacBand folder, the project chooser's data, recents, the launch flow and the introduction.
/// `--introshots <dir>`: renders every introduction page at a few moments.
@MainActor enum ProjectTest {
    static var failures = 0
    static func check(_ ok: Bool, _ m: String) { print(ok ? "  ok    \(m)" : "  FAIL  \(m)"); if !ok { failures += 1 } }

    static func writeProject(_ p: Project, to url: URL, modified: Date? = nil) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! JSONEncoder().encode(p).write(to: url)
        if let m = modified { try? FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: url.path) }
    }

    static func run() -> Int32 {
        _ = NSApplication.shared
        print("== Projects folder, chooser and introduction test ==")
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macband-projects-test-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let savedIntro = UserDefaults.standard.object(forKey: Intro.seenKey), savedLaunch = UserDefaults.standard.object(forKey: "showBrowserAtLaunch")
        let savedKey = RecentProjects.storeKey
        RecentProjects.storeKey = "recentProjectsTest"
        defer {
            try? fm.removeItem(at: root)
            ProjectsFolder.override = nil
            UserDefaults.standard.removeObject(forKey: "recentProjectsTest")
            RecentProjects.storeKey = savedKey
            if let v = savedIntro { UserDefaults.standard.set(v, forKey: Intro.seenKey) } else { UserDefaults.standard.removeObject(forKey: Intro.seenKey) }
            if let v = savedLaunch { UserDefaults.standard.set(v, forKey: "showBrowserAtLaunch") } else { UserDefaults.standard.removeObject(forKey: "showBrowserAtLaunch") }
        }

        // where the folder goes
        let home1 = root.appendingPathComponent("home1", isDirectory: true)
        try? fm.createDirectory(at: home1.appendingPathComponent("Music/GarageBand"), withIntermediateDirectories: true)
        check(ProjectsFolder.locate(home: home1, bandFiles: { [] }).path == home1.appendingPathComponent("Music/MacBand").path, "next to ~/Music/GarageBand: the folder is ~/Music/MacBand")
        let home2 = root.appendingPathComponent("home2", isDirectory: true)
        let bands = ["/Users/x/Documents/Beats/a.band", "/Users/x/Documents/Beats/b.band", "/Users/x/Desktop/c.band", "/Users/x/Library/Mobile Documents/d.band"].map { URL(fileURLWithPath: $0) }
        check(ProjectsFolder.locate(home: home2, bandFiles: { bands }).path == "/Users/x/Documents/Beats/MacBand", "no GarageBand folder: it goes beside where most .band projects are (iCloud/Library ones ignored)")
        check(ProjectsFolder.locate(home: home2, bandFiles: { [] }).path == home2.appendingPathComponent("Music/MacBand").path, "no .band files at all: ~/Music/MacBand")

        // creating it
        let folder = root.appendingPathComponent("lib/MacBand", isDirectory: true)
        ProjectsFolder.override = folder
        let first = ProjectsFolder.ensure()
        check(first.created && fm.fileExists(atPath: folder.path), "the folder is created")
        check(!ProjectsFolder.ensure().created, "…and left alone when it already exists")

        // projects to choose from
        func project(_ name: String, tracks: Int, notes: Int, tempo: Double) -> Project {
            var p = Project(); p.name = name; p.tempo = tempo
            for t in 0..<tracks {
                var tr = Track(name: "T\(t)", colorIndex: t)
                var c = Clip(name: "c", start: 0, length: 16)
                for i in 0..<notes { c.notes.append(Note(pitch: 48 + (i * 3 + t * 7) % 30, start: Double(i) * 0.25, length: 0.25)) }
                tr.clips = [c]; p.tracks.append(tr)
            }
            return p
        }
        let now = Date()
        writeProject(project("Newest", tracks: 3, notes: 20, tempo: 128), to: folder.appendingPathComponent("Newest.macband"), modified: now)
        writeProject(project("Older", tracks: 1, notes: 5, tempo: 90), to: folder.appendingPathComponent("Older.macband"), modified: now.addingTimeInterval(-86400))
        writeProject(project("Nested", tracks: 2, notes: 3, tempo: 100), to: folder.appendingPathComponent("Album/Nested.macband"), modified: now.addingTimeInterval(-3600))
        writeProject(project("Hidden", tracks: 1, notes: 1, tempo: 100), to: folder.appendingPathComponent("Song Audio/Hidden.macband"))
        try? "not a project".write(to: folder.appendingPathComponent("Broken.macband"), atomically: true, encoding: .utf8)
        let files = ProjectScanner.projectFiles(in: folder).map { $0.lastPathComponent }.sorted()
        check(files == ["Broken.macband", "Nested.macband", "Newest.macband", "Older.macband"], "the folder and one level of subfolders are searched, audio folders skipped (\(files))")
        let info = ProjectScanner.summary(of: folder.appendingPathComponent("Newest.macband"))
        check(info?.tracks == 3 && info?.notes == 60 && info?.tempo == 128 && info?.bars == 4, "a project's summary: \(info?.details ?? "nil")")
        check(ProjectScanner.summary(of: folder.appendingPathComponent("Broken.macband")) == nil, "a damaged file is skipped, not a crash")
        let capped = ProjectScanner.summary(of: folder.appendingPathComponent("Newest.macband"), previewLimit: 10)
        check(capped?.preview.count == 10 && capped?.notes == 60, "the preview keeps a sample (10 of 60) while the count stays true")
        check(info?.name == "Newest", "the project is named after its file")

        let lib = ProjectLibrary()
        lib.refresh(includeOther: false)
        SelfTest.pump(10) { !lib.scanning }
        check(lib.inFolder.map { $0.name } == ["Newest", "Nested", "Older"], "the chooser lists them newest first (\(lib.inFolder.map { $0.name }))")

        // recents
        for i in 0..<15 { RecentProjects.add(folder.appendingPathComponent("Newest.macband")); _ = i }
        RecentProjects.add(folder.appendingPathComponent("Older.macband"))
        check(RecentProjects.urls.map { $0.lastPathComponent } == ["Older.macband", "Newest.macband"], "recents are newest first without duplicates")
        RecentProjects.remove(folder.appendingPathComponent("Older.macband"))
        check(RecentProjects.urls.map { $0.lastPathComponent } == ["Newest.macband"], "…and can be removed")
        check(ProjectScanner.isUserProject(URL(fileURLWithPath: "/Users/x/Downloads/Song.macband"), excluding: folder), "a project in Downloads counts as one to offer")
        check(!ProjectScanner.isUserProject(URL(fileURLWithPath: "/Users/x/Library/Application Support/MacBand Studio/Backups/Song/2026.macband"), excluding: folder), "backups are not offered as projects")
        check(!ProjectScanner.isUserProject(URL(fileURLWithPath: "/Users/x/Library/Application Support/MacBand Studio/Autosave/Untitled recovery.macband"), excluding: folder), "the recovery copy isn't either")

        // opening and saving go through the session
        let s = Session()
        s.openProjectConfirmed(folder.appendingPathComponent("Older.macband"))
        check(s.project.tempo == 90 && s.fileURL?.lastPathComponent == "Older.macband", "choosing a project opens it")
        check(RecentProjects.urls.first?.lastPathComponent == "Older.macband", "…and puts it first in the recents")
        s.write(to: folder.appendingPathComponent("Saved Now.macband"))
        check(RecentProjects.urls.first?.lastPathComponent == "Saved Now.macband", "a project you save is recent too")

        // launch flow decisions
        UserDefaults.standard.set(true, forKey: "showBrowserAtLaunch")
        let l = Session(); l.showProjectBrowser = false
        l.maybeShowBrowserAtLaunch()
        check(l.showProjectBrowser, "with projects around, the chooser appears at launch")
        let emptyFolder = root.appendingPathComponent("empty/MacBand", isDirectory: true)
        ProjectsFolder.override = emptyFolder; try? fm.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: "recentProjectsTest")
        let l2 = Session(); l2.showProjectBrowser = false; l2.maybeShowBrowserAtLaunch()
        check(!l2.showProjectBrowser, "with nothing to choose from, it doesn't")
        ProjectsFolder.override = folder
        UserDefaults.standard.set(false, forKey: "showBrowserAtLaunch")
        let l3 = Session(); l3.showProjectBrowser = false; l3.maybeShowBrowserAtLaunch()
        check(!l3.showProjectBrowser, "turned off in the window, it stays away")
        UserDefaults.standard.set(true, forKey: "showBrowserAtLaunch")
        let l4 = Session(); l4.write(to: root.appendingPathComponent("x.macband")); l4.edit { $0.name = "changed" }; l4.showProjectBrowser = false; l4.maybeShowBrowserAtLaunch()
        check(!l4.showProjectBrowser, "…and not over a project you're already working on")

        // welcome project and intro
        let welcomeFolder = root.appendingPathComponent("fresh/MacBand", isDirectory: true)
        try? fm.createDirectory(at: welcomeFolder, withIntermediateDirectories: true)
        s.writeWelcomeProject(in: welcomeFolder)
        let welcome = ProjectScanner.summary(of: welcomeFolder.appendingPathComponent("Welcome to MacBand.macband"))
        check(welcome?.tracks == 3 && (welcome?.notes ?? 0) > 50, "a welcome song is put in a new folder (\(welcome?.details ?? "nil"))")
        check(Intro.pages.count == 7 && Intro.pages.allSatisfy { !$0.title.isEmpty && !$0.text.isEmpty }, "the introduction has seven pages")
        check(Intro.pages.last!.points.first!.contains("MacBand"), "…the last one names the folder (\(Intro.pages.last!.points.first!))")
        UserDefaults.standard.removeObject(forKey: Intro.seenKey)
        check(!Intro.seen, "a fresh install hasn't seen it")
        s.startIntro(); check(s.showIntro, "it can be started whenever you like")
        s.finishIntro(); check(!s.showIntro && Intro.seen, "finishing it (or skipping) is remembered")

        // every page really animates and isn't blank
        for page in 0..<Intro.pages.count {
            var hashes: [Int] = []
            var blank = false
            for t in [1.0, 2.7, 4.4] {
                let r = ImageRenderer(content: IntroArt(page: page, t: t).frame(width: 720, height: 280).background(Color.black))
                r.scale = 1
                guard let cg = r.cgImage, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { blank = true; continue }
                hashes.append(data.hashValue)
                let rep = NSBitmapImageRep(cgImage: cg)
                var colours = Set<UInt32>()
                for y in stride(from: 0, to: rep.pixelsHigh, by: 9) { for x in stride(from: 0, to: rep.pixelsWide, by: 9) {
                    if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { colours.insert(UInt32(c.redComponent * 15) << 8 | UInt32(c.greenComponent * 15) << 4 | UInt32(c.blueComponent * 15)) }
                } }
                if colours.count < 8 { blank = true }
            }
            check(!blank && Set(hashes).count == 3, "page \(page + 1) (\(Intro.pages[page].title)) draws something different at different moments")
        }
        print(failures == 0 ? "ALL PROJECT CHECKS PASSED" : "\(failures) PROJECT CHECK(S) FAILED")
        return failures == 0 ? 0 : 1
    }

    static func introShots(_ dir: String) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for page in 0..<Intro.pages.count {
            for (k, t) in [2.3, 5.1].enumerated() {
                let r = ImageRenderer(content: IntroArt(page: page, t: t).frame(width: 760, height: 280).background(Color(white: 0.06)))
                r.scale = 1
                if let cg = r.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("page\(page + 1)-\(k + 1).png"))
                }
            }
        }
        print("wrote intro pictures to \(dir)")
    }
}
