import Foundation
import AVFoundation
import AudioToolbox
import SwiftUI

/// One playable sound in the library.
struct SoundEntry: Identifiable, Hashable {
    var id: String
    var name: String
    var group: String           // General MIDI · GarageBand · Logic Pro · SoundFonts
    var category: String        // folder / family inside the group
    var isDrums: Bool
    var spec: InstrumentSpec
}

enum SoundGroup {
    static let gm = "General MIDI", garageBand = "GarageBand", logic = "Logic Pro", soundFonts = "SoundFonts", plugins = "Plugins"
    static let order = [gm, garageBand, logic, soundFonts, plugins]
}

/// Reads the preset list out of a SoundFont so every sound in it can be picked, not just the first.
enum SF2Info {
    struct Preset { var name: String; var bank: Int; var program: Int }

    static func presets(at url: URL) -> [Preset] {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }
        func read(_ n: Int) -> Data? { (try? fh.read(upToCount: n)).flatMap { $0.count == n ? $0 : nil } }
        func u32(_ d: Data) -> UInt64 { UInt64(d[d.startIndex]) | UInt64(d[d.startIndex + 1]) << 8 | UInt64(d[d.startIndex + 2]) << 16 | UInt64(d[d.startIndex + 3]) << 24 }
        guard let head = read(12), String(data: head.prefix(4), encoding: .ascii) == "RIFF",
              String(data: head.suffix(4), encoding: .ascii) == "sfbk" else { return [] }
        var out: [Preset] = []
        let fileEnd = (try? fh.seekToEnd()) ?? 0
        var pos: UInt64 = 12
        while pos + 8 <= fileEnd {
            try? fh.seek(toOffset: pos)
            guard let h = read(8) else { break }
            let id = String(data: h.prefix(4), encoding: .ascii) ?? ""
            let size = u32(h.suffix(4))
            if id == "LIST", let t = read(4), String(data: t, encoding: .ascii) == "pdta" {
                var q = pos + 12
                let end = pos + 8 + size
                while q + 8 <= end {
                    try? fh.seek(toOffset: q)
                    guard let sh = read(8) else { break }
                    let sid = String(data: sh.prefix(4), encoding: .ascii) ?? ""
                    let ssize = u32(sh.suffix(4))
                    if sid == "phdr", let body = read(Int(ssize)) {
                        let n = Int(ssize) / 38
                        for i in 0..<max(0, n - 1) {          // the last record is the terminator
                            let r = body.subdata(in: (body.startIndex + i * 38)..<(body.startIndex + i * 38 + 38))
                            let nameBytes = r.prefix(20).prefix { $0 != 0 }
                            let name = String(decoding: nameBytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                            let program = Int(r[r.startIndex + 20]) | Int(r[r.startIndex + 21]) << 8
                            let bank = Int(r[r.startIndex + 22]) | Int(r[r.startIndex + 23]) << 8
                            out.append(Preset(name: name.isEmpty ? "Preset \(program)" : name, bank: bank, program: program))
                        }
                        return out
                    }
                    q += 8 + ssize + (ssize & 1)
                }
            }
            pos += 8 + size + (size & 1)
        }
        return out
    }
}

/// Everything that can be played through Apple's sampler: the built-in GM bank (128 sounds, 9 drum kits),
/// GarageBand's and Logic Pro's sampled instruments, and SoundFonts.
@MainActor
final class SoundLibrary: ObservableObject {
    static let shared = SoundLibrary()

    @Published private(set) var entries: [SoundEntry] = []
    @Published private(set) var scanning = false
    /// Entry ids whose sample files are missing or unsupported on this Mac.
    @Published private(set) var unavailable: Set<String> = []
    @Published private(set) var validating = false

    nonisolated static let garageBandRoot = "/Library/Application Support/GarageBand/Instrument Library/Sampler/Sampler Instruments"
    nonisolated static let logicRoot = "/Library/Application Support/Logic/Sampler Instruments"
    nonisolated static var soundFontFolders: [String] {
        #if os(macOS)
        return [NSHomeDirectory() + "/Library/Audio/Sounds/Banks", "/Library/Audio/Sounds/Banks"]
        #else
        // iOS: SoundFonts the person drops into the app's folder in the Files app (or adds with Add SoundFont…)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return [docs.appendingPathComponent("Sounds").path, docs.path]
        #endif
    }
    private static let extraKey = "extraSoundFonts"
    var extraSoundFonts: [String] { UserDefaults.standard.stringArray(forKey: Self.extraKey) ?? [] }

    func addSoundFont(_ url: URL) {
        var list = extraSoundFonts
        if !list.contains(url.path) { list.append(url.path); UserDefaults.standard.set(list, forKey: Self.extraKey) }
        rescan()
    }

    // MARK: Scan

    func rescan() {
        guard !scanning else { return }
        scanning = true
        let extras = extraSoundFonts
        Task.detached(priority: .utility) {
            let list = Self.buildEntries(extraSoundFonts: extras)
            await MainActor.run {
                self.entries = list
                self.scanning = false
                self.validate()
            }
        }
    }

    nonisolated static func buildEntries(extraSoundFonts: [String]) -> [SoundEntry] {
        var out: [SoundEntry] = []
        let fm = FileManager.default

        // General MIDI (built into macOS)
        for (name, range) in GM.families {
            for i in range {
                out.append(SoundEntry(id: "gm:\(i)", name: GM.programs[i], group: SoundGroup.gm, category: name, isDrums: false,
                                      spec: InstrumentSpec(gmProgram: i)))
            }
        }
        for (prog, name) in GM.drumKits {
            out.append(SoundEntry(id: "gmkit:\(prog)", name: "\(name) Drum Kit", group: SoundGroup.gm, category: "Drum Kits", isDrums: true,
                                  spec: InstrumentSpec(gmProgram: prog, isDrums: true)))
        }

        // GarageBand / Logic sampler instruments
        func strip(_ s: String) -> String {
            var t = s
            if let r = t.range(of: #"^\d+\s+"#, options: .regularExpression) { t.removeSubrange(r) }
            return t
        }
        func walk(root: String, group: String) {
            guard let en = fm.enumerator(atPath: root) else { return }
            for case let rel as String in en where rel.hasSuffix(".exs") {
                let comps = rel.split(separator: "/").map(String.init)
                if comps.contains(where: { $0.contains("Drum Kit Designer") }) { continue }   // parts of a separate plugin
                let file = comps.last!
                let name = String(file.dropLast(4)).trimmingCharacters(in: .whitespaces)
                var folders = Array(comps.dropLast()).map(strip)
                var drums = false
                var category: String
                if group == SoundGroup.logic {
                    drums = folders.first == "Drums & Percussion"
                    if drums, folders.count >= 2 { folders = Array(folders.dropFirst()) }
                    category = folders.isEmpty ? "Other" : folders.joined(separator: " · ")
                    if folders.first == "Other" { category = "Vision and Verse" }
                } else {
                    let lower = name.lowercased()
                    drums = lower.contains("kit") || lower.contains("drum machine")
                    category = folders.isEmpty ? (drums ? "Drum Kits" : "Instruments") : folders.joined(separator: " · ")
                }
                let src = SamplerSource(kind: .exs, path: root + "/" + rel, name: name)
                var spec = InstrumentSpec(isDrums: drums)
                spec.sampler = src
                out.append(SoundEntry(id: "exs:\(root + "/" + rel)", name: name, group: group, category: category, isDrums: drums, spec: spec))
            }
        }
        walk(root: garageBandRoot, group: SoundGroup.garageBand)
        walk(root: logicRoot, group: SoundGroup.logic)

        // SoundFonts: every preset inside each file
        var files: [String] = []
        for folder in soundFontFolders {
            for f in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where f.lowercased().hasSuffix(".sf2") { files.append(folder + "/" + f) }
        }
        files += extraSoundFonts.filter { fm.fileExists(atPath: $0) && !files.contains($0) }
        for path in files.sorted() {
            let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let presets = SF2Info.presets(at: URL(fileURLWithPath: path))
            for p in presets {
                let drums = p.bank == 128
                var spec = InstrumentSpec(isDrums: drums)
                spec.sampler = SamplerSource(kind: .sf2, path: path, name: presets.count == 1 ? file : "\(p.name) — \(file)", bank: p.bank, program: p.program)
                out.append(SoundEntry(id: "sf2:\(path):\(p.bank):\(p.program)", name: p.name, group: SoundGroup.soundFonts, category: file, isDrums: drums, spec: spec))
            }
        }
        return out
    }

    // MARK: Validation (which sampler instruments can actually load here)

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacBand Studio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sound-validation.json")
    }
    private struct Verdict: Codable { var mtime: Double; var ok: Bool }

    nonisolated private static func mtime(_ path: String) -> Double {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
    }

    /// Loads each `.exs` once in the background (about a minute for the whole library) and remembers the result,
    /// so instruments whose sample files aren't installed can be hidden instead of failing when picked.
    func validate() {
        guard !validating else { return }
        let exs = entries.filter { $0.spec.sampler?.kind == .exs }
        let cacheURL = Self.cacheURL
        var cache: [String: Verdict] = (try? JSONDecoder().decode([String: Verdict].self, from: Data(contentsOf: cacheURL))) ?? [:]
        let pending = exs.filter { e in
            guard let v = cache[e.spec.sampler!.path] else { return true }
            return abs(v.mtime - Self.mtime(e.spec.sampler!.path)) > 0.01
        }
        unavailable = Set(exs.filter { cache[$0.spec.sampler!.path]?.ok == false }.map { $0.id })
        guard !pending.isEmpty else { return }
        validating = true
        let paths = pending.map { ($0.id, $0.spec.sampler!.path) }
        Task.detached(priority: .background) {
            let engine = AVAudioEngine()
            var batch: [(String, Bool)] = []
            for (id, path) in paths {
                autoreleasepool {
                    let s = AVAudioUnitSampler()
                    engine.attach(s)
                    let ok = (try? s.loadInstrument(at: URL(fileURLWithPath: path))) != nil
                    engine.detach(s)
                    batch.append((id, ok))
                    cache[path] = Verdict(mtime: Self.mtime(path), ok: ok)
                }
                if batch.count >= 40 {
                    let b = batch; batch = []
                    await MainActor.run { for (id, ok) in b where !ok { self.unavailable.insert(id) } }
                }
            }
            if let d = try? JSONEncoder().encode(cache) { try? d.write(to: cacheURL, options: .atomic) }
            let b = batch
            await MainActor.run {
                for (id, ok) in b where !ok { self.unavailable.insert(id) }
                self.validating = false
            }
        }
    }

    // MARK: Queries

    func isAvailable(_ e: SoundEntry) -> Bool { !unavailable.contains(e.id) }

    /// Groups and categories with their sound counts, in display order.
    func categories(includeUnavailable: Bool) -> [(group: String, categories: [(name: String, count: Int)])] {
        var result: [(String, [(String, Int)])] = []
        for g in SoundGroup.order {
            let es = entries.filter { $0.group == g && (includeUnavailable || isAvailable($0)) }
            guard !es.isEmpty else { continue }
            var counts: [String: Int] = [:], order: [String] = []
            for e in es { if counts[e.category] == nil { order.append(e.category) }; counts[e.category, default: 0] += 1 }
            let cats = (g == SoundGroup.logic || g == SoundGroup.garageBand || g == SoundGroup.soundFonts)
                ? order.sorted { a, b in a.localizedStandardCompare(b) == .orderedAscending } : order
            result.append((g, cats.map { ($0, counts[$0]!) }))
        }
        return result.map { (group: $0.0, categories: $0.1.map { (name: $0.0, count: $0.1) }) }
    }
}
