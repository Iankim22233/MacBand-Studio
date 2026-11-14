import Foundation

/// What a track looks like on the 3D stage: the kind of instrument that plays it.
enum JamKind: String, CaseIterable {
    case drums, piano, guitar, bass, strings, brass, reed, pipe, synth

    /// The instrument for a track: its General MIDI program, or (for plug-ins and GarageBand sounds, which have no program) its name.
    static func of(_ t: Track) -> JamKind {
        let spec = t.instrument
        if spec.isDrums || spec.sampler?.bank == 128 { return .drums }
        if spec.plugin != nil || spec.sampler?.kind == .exs {
            let hint = [t.name, spec.plugin?.name ?? "", spec.sampler?.name ?? ""].joined(separator: " ")
            return named(hint) ?? .synth
        }
        return gm(spec.sampler?.program ?? spec.gmProgram)
    }

    /// The General MIDI families, in program order.
    static func gm(_ program: Int) -> JamKind {
        switch program {
        case 0...23: return .piano                 // pianos, mallets, organs: all have keys
        case 24...31: return .guitar
        case 32...39: return .bass
        case 40...55: return .strings              // strings, harp, timpani, ensembles and choirs
        case 56...63: return .brass
        case 64...71: return .reed
        case 72...79: return .pipe
        case 104...107: return .guitar             // sitar, banjo, shamisen, koto
        case 110: return .strings                  // fiddle
        default: return .synth
        }
    }

    static func named(_ text: String) -> JamKind? {
        let s = text.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { s.contains($0) } }
        if has(["drum", "kit", "percussion", "beat"]) { return .drums }
        if has(["sax", "clarinet", "oboe", "bassoon", "reed"]) { return .reed }
        if has(["bass"]) { return .bass }
        if has(["guitar", "gtr", "banjo", "ukulele", "sitar", "lute", "mandolin"]) { return .guitar }
        if has(["piano", "keys", "organ", "rhodes", "clav", "harpsichord", "marimba", "vibraphone", "xylophone", "celesta", "bell"]) { return .piano }
        if has(["violin", "viola", "cello", "string", "fiddle", "harp"]) { return .strings }
        if has(["trumpet", "trombone", "horn", "tuba", "brass"]) { return .brass }
        if has(["flute", "pipe", "piccolo", "recorder", "whistle"]) { return .pipe }
        return nil
    }
}

/// Every track's notes on their own, sorted by start, so the stage can ask "what is sounding on this track right now".
struct JamTimeline {
    private(set) var tracks: [[VNote]] = []
    private var longest: [Double] = []

    init() {}
    init(_ project: Project) {
        for (ti, t) in project.tracks.enumerated() {
            var list: [VNote] = []
            for c in t.clips { for n in c.notes { list.append(VNote(start: c.start + n.start, end: c.start + n.end, pitch: n.pitch, vel: n.velocity, track: ti)) } }
            list.sort { $0.start < $1.start }
            tracks.append(list)
            longest.append(list.map { $0.end - $0.start }.max() ?? 0)
        }
    }

    /// Index of the first note starting after `beat` (notes are sorted by start).
    private func firstStarting(after beat: Double, in list: [VNote]) -> Int {
        var lo = 0, hi = list.count
        while lo < hi { let mid = (lo + hi) / 2; if list[mid].start <= beat { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    /// Notes held down at `beat`.
    func sounding(_ ti: Int, at beat: Double) -> [VNote] {
        guard tracks.indices.contains(ti) else { return [] }
        let list = tracks[ti]
        var i = firstStarting(after: beat, in: list) - 1
        var out: [VNote] = []
        while i >= 0, list[i].start >= beat - longest[ti] {
            if list[i].end > beat { out.append(list[i]) }
            i -= 1
        }
        return out
    }

    /// Notes that start in `from`...`to`.
    func started(_ ti: Int, from: Double, to: Double) -> [VNote] {
        guard tracks.indices.contains(ti), to >= from else { return [] }
        let list = tracks[ti]
        var i = firstStarting(after: from - 1e-9, in: list)
        var out: [VNote] = []
        while i < list.count, list[i].start <= to { out.append(list[i]); i += 1 }
        return out
    }

    func hasNotes(_ ti: Int) -> Bool { tracks.indices.contains(ti) && !tracks[ti].isEmpty }
    func pitchRange(_ ti: Int) -> ClosedRange<Int> {
        guard tracks.indices.contains(ti), let lo = tracks[ti].map({ $0.pitch }).min(), let hi = tracks[ti].map({ $0.pitch }).max() else { return 48...72 }
        return lo...hi
    }
}

/// The spotlight rule: when exactly two instruments are playing (drums not counted), a spotlight picks them out.
/// An instrument counts as playing for a moment after each note ends, so the light doesn't flicker between notes.
struct JamSpot {
    static let hold = 0.3
    private var last: [Int: Double] = [:]

    mutating func update(sounding: [Int], now: Double) {
        for t in sounding { last[t] = now }
    }
    mutating func reset() { last = [:] }

    func playing(now: Double) -> [Int] {
        last.filter { now - $0.value <= Self.hold }.map { $0.key }.sorted()
    }

    /// The tracks to light: the two non-drum instruments, or none unless there are exactly two.
    static func targets(_ playing: [Int], drums: [Bool]) -> [Int] {
        let melodic = playing.filter { $0 < drums.count && !drums[$0] }
        return melodic.count == 2 ? melodic : []
    }
}
