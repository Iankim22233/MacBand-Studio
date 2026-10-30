import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import AVFoundation

/// `--bandtest`: GarageBand import, using made-up `.band` packages in a temp folder (never the real GarageBand folder).
@MainActor
enum GarageBandTest {
    static var failures = 0
    static func check(_ ok: Bool, _ m: String) { print(ok ? "  ok    \(m)" : "  FAIL  \(m)"); if !ok { failures += 1 } }

    static func writeWav(_ url: URL, seconds: Double, freq: Double) {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        guard let f = try? AVAudioFile(forWriting: url, settings: fmt.settings) else { return }
        let n = AVAudioFrameCount(seconds * 44100)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        buf.frameLength = n
        for c in 0..<2 { for i in 0..<Int(n) { buf.floatChannelData![c][i] = Float(0.4 * sin(2 * .pi * freq * Double(i) / 44100)) } }
        try? f.write(from: buf)
    }

    static func makeBand(_ root: URL, name: String, bpm: Int, key: String, mode: String, stems: [String]) {
        let fm = FileManager.default
        let band = root.appendingPathComponent(name + ".band", isDirectory: true)
        let alt = band.appendingPathComponent("Alternatives/000", isDirectory: true)
        let media = band.appendingPathComponent("Media/Audio Files", isDirectory: true)
        try? fm.createDirectory(at: alt, withIntermediateDirectories: true)
        try? fm.createDirectory(at: media, withIntermediateDirectories: true)
        let meta: [String: Any] = ["BeatsPerMinute": bpm, "SongKey": key, "SongGenderKey": mode, "SongSignatureNumerator": 3, "SongSignatureDenominator": 4, "NumberOfTracks": stems.count]
        (meta as NSDictionary).write(to: alt.appendingPathComponent("MetaData.plist"), atomically: true)
        for (i, s) in stems.enumerated() { writeWav(media.appendingPathComponent("\(name)_\(s).wav"), seconds: 1.0, freq: 220 * Double(i + 1)) }
    }

    static func spin(_ seconds: Double, until: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !until() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }

    static func run() -> Int32 {
        _ = NSApplication.shared
        print("== GarageBand import test ==")
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macband-band-test-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let music = root.appendingPathComponent("Music", isDirectory: true)
        let gb = music.appendingPathComponent("GarageBand", isDirectory: true)
        let mb = music.appendingPathComponent("MacBand", isDirectory: true)
        try? fm.createDirectory(at: gb, withIntermediateDirectories: true)
        let doneKey = "garageBandImportDone"
        let savedDone = UserDefaults.standard.object(forKey: doneKey)
        let savedKey = RecentProjects.storeKey
        RecentProjects.storeKey = "recentProjectsBandTest"
        var storeFiles: [String] = []
        defer {
            try? fm.removeItem(at: root)
            for f in storeFiles { try? fm.removeItem(at: AudioStore.url(f)) }
            ProjectsFolder.override = nil; Session.noticeOverride = nil
            UserDefaults.standard.removeObject(forKey: "recentProjectsBandTest"); RecentProjects.storeKey = savedKey
            if let v = savedDone { UserDefaults.standard.set(v, forKey: doneKey) } else { UserDefaults.standard.removeObject(forKey: doneKey) }
        }

        makeBand(gb, name: "Song", bpm: 140, key: "A", mode: "minor", stems: ["drums", "bass", "vocals"])
        makeBand(gb, name: "Other", bpm: 90, key: "Eb", mode: "major", stems: ["only"])
        let junk = gb.appendingPathComponent("Broken.band", isDirectory: true)
        try? fm.createDirectory(at: junk, withIntermediateDirectories: true)
        try? fm.createDirectory(at: gb.appendingPathComponent("Not a project", isDirectory: true), withIntermediateDirectories: true)

        check(GarageBandImporter.projects(in: gb).map { $0.lastPathComponent } == ["Broken.band", "Other.band", "Song.band"], "only .band packages are found")
        let info = GarageBandImporter.read(gb.appendingPathComponent("Song.band"))
        check(info?.bpm == 140 && info?.num == 3 && info?.den == 4 && info?.keyRoot == 9 && info?.minor == true && info?.audio.count == 3,
              "tempo, meter, key and stems are read (\(String(describing: info?.bpm)) \(String(describing: info?.keyRoot)))")
        check(GarageBandImporter.read(junk) == nil, "a package with nothing in it is refused")
        check(GarageBandImporter.keyRoot("Eb") == 3 && GarageBandImporter.keyRoot("F#") == 6 && GarageBandImporter.keyRoot("H") == nil, "key names map to pitch classes")
        let names = GarageBandImporter.trackNames(["/x/Song_drums.wav", "/x/Song_bass.wav", "/x/Song_a cappella.wav"].map { URL(fileURLWithPath: $0) })
        check(names == ["drums", "bass", "a cappella"], "tracks are named after what differs (\(names))")
        check(GarageBandImporter.trackNames([URL(fileURLWithPath: "/x/Solo.wav")]) == ["Solo"], "a single stem keeps its name")

        // convert
        let r = GarageBandImporter.convert(gb.appendingPathComponent("Song.band"), into: mb)
        let c = r.converted.first
        for f in (try? JSONDecoder().decode(Project.self, from: Data(contentsOf: mb.appendingPathComponent("Song.macband"))))?.tracks.flatMap({ $0.audioClips.map { $0.file } }) ?? [] { storeFiles.append(f) }
        check(c?.tracks == 3 && c?.bpm == 140 && c?.keyText == "A minor", "converted: 3 audio tracks, 140 BPM, A minor (\(String(describing: c?.keyText)))")
        let p = try? JSONDecoder().decode(Project.self, from: Data(contentsOf: mb.appendingPathComponent("Song.macband")))
        check(p?.tempo == 140 && p?.timeSigNum == 3 && p?.keyRoot == 9 && p?.scale == .minor, "the project takes the tempo, meter and key")
        check(p?.tracks.map { $0.name } == ["bass", "drums", "vocals"] && p?.tracks.allSatisfy { $0.kind == .audio && $0.audioClips.count == 1 && $0.audioClips[0].start == 0 && abs($0.audioClips[0].duration - 1) < 0.05 } == true,
              "each stem is an audio track starting at the beginning (\(p?.tracks.map { $0.name } ?? []))")
        check(fm.fileExists(atPath: mb.appendingPathComponent("Song Audio").path) && ((try? fm.contentsOfDirectory(atPath: mb.appendingPathComponent("Song Audio").path))?.count ?? 0) == 3, "the audio is kept beside the project")
        check(GarageBandImporter.convert(gb.appendingPathComponent("Song.band"), into: mb).alreadyThere == ["Song"], "importing again doesn't make a duplicate")
        check(GarageBandImporter.convert(junk, into: mb).failed.count == 1, "a broken package is reported, not a crash")
        check(ProjectScanner.summary(of: mb.appendingPathComponent("Song.macband"))?.audioTracks == 3, "the chooser can read it")
        check(fm.fileExists(atPath: gb.appendingPathComponent("Song.band/Media/Audio Files/Song_drums.wav").path), "the GarageBand project is untouched")
        try? fm.removeItem(at: mb)

        // first start
        ProjectsFolder.override = mb
        UserDefaults.standard.removeObject(forKey: doneKey)
        var shown: (String, String)?
        Session.noticeOverride = { shown = ($0, $1) }
        let s = Session()
        s.autoImportGarageBandProjects()
        check(s.bandImportRunning, "the import runs in the background")
        spin(30) { shown != nil }
        for f in ["Song", "Other"] { if let q = try? JSONDecoder().decode(Project.self, from: Data(contentsOf: mb.appendingPathComponent("\(f).macband"))) { storeFiles += q.tracks.flatMap { $0.audioClips.map { $0.file } } } }
        check(!s.bandImportRunning, "…and finishes")
        check(fm.fileExists(atPath: mb.appendingPathComponent("Song.macband").path) && fm.fileExists(atPath: mb.appendingPathComponent("Other.macband").path), "both projects are in the MacBand folder")
        check(shown?.0 == "Imported your GarageBand projects" && shown?.1.contains("Song") == true && shown?.1.contains("Other") == true && shown?.1.contains("Broken") == true, "the notice names what happened (\(shown?.0 ?? "none"))")
        check(shown?.1.contains("private format") == true && shown?.1.contains("not changed") == true, "…says what can't come across, and that GarageBand's files weren't changed")
        check(s.toast?.contains("Imported 2") == true, "a toast appears too (\(s.toast ?? "none"))")
        check(UserDefaults.standard.bool(forKey: doneKey), "it won't run a second time")
        shown = nil
        let s2 = Session(); s2.autoImportGarageBandProjects()
        spin(1) { s2.bandImportRunning }
        check(!s2.bandImportRunning && shown == nil, "a second start does nothing")

        // no GarageBand folder at all
        UserDefaults.standard.removeObject(forKey: doneKey)
        ProjectsFolder.override = root.appendingPathComponent("elsewhere/MacBand", isDirectory: true)
        let s3 = Session(); s3.autoImportGarageBandProjects()
        check(!s3.bandImportRunning && shown == nil, "no GarageBand folder: nothing happens, quietly")

        print(failures == 0 ? "ALL GARAGEBAND CHECKS PASSED" : "\(failures) GARAGEBAND CHECK(S) FAILED")
        return failures == 0 ? 0 : 1
    }
}
