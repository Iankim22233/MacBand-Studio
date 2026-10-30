#if os(iOS)
import Foundation
import AVFoundation
import AudioToolbox
import CoreMIDI
import os

// The sound engine on iOS.
//
// Apple's sampler (AVAudioUnitSampler) streams SoundFont samples from disk on a helper thread, and on a phone that crashed
// the app a few times a minute: the audio thread read a sample buffer the streamer had already freed (a segmentation fault
// inside `SamplerNote::Render`, which no app code can catch). So on iOS the SoundFonts are played by this synthesizer
// instead: the file is memory-mapped, nothing is streamed or freed while it plays, and the audio thread only ever touches
// memory this file owns. It follows the SoundFont 2 spec for what General MIDI sounds need: key/velocity zones, loops,
// volume and modulation envelopes, low-pass filter, vibrato and modulation LFOs, tuning, pan, exclusive classes (hi-hats),
// pitch bend, volume, expression, pan and sustain pedal.

// MARK: - SoundFont file

enum SF2Error: LocalizedError {
    case unreadable(String), missingPreset(bank: Int, program: Int)
    var errorDescription: String? {
        switch self {
        case .unreadable(let m): return m
        case .missingPreset(let b, let p): return "The SoundFont has no sound at bank \(b), program \(p)."
        }
    }
}

/// One playable piece of a preset: a sample with the key and velocity range it answers to and everything that shapes it.
struct SF2Region {
    var keyLo: UInt8 = 0, keyHi: UInt8 = 127, velLo: UInt8 = 0, velHi: UInt8 = 127
    var data: UnsafePointer<Int16>? = nil
    var start = 0, end = 0, loopStart = 0, loopEnd = 0       // sample indexes, all inside the mapped file
    var sampleRate: Float = 44100
    var rootKey: Int = 60
    var tuneCents: Float = 0
    var scaleTuning: Float = 100
    var loopMode = 0                                            // 0 none, 1 loop, 3 loop while the key is down
    var attenCb: Float = 0
    var pan: Float = 0                                          // -500 … 500
    var fcCents: Float = 13500, qCb: Float = 0
    var modLfoToPitch: Float = 0, vibLfoToPitch: Float = 0, modEnvToPitch: Float = 0
    var modLfoToFc: Float = 0, modEnvToFc: Float = 0, modLfoToVol: Float = 0
    var delayModLfo: Float = -12000, freqModLfo: Float = 0, delayVibLfo: Float = -12000, freqVibLfo: Float = 0
    var delayMod: Float = -12000, attMod: Float = -12000, holdMod: Float = -12000, decMod: Float = -12000, susMod: Float = 0, relMod: Float = -12000
    var delayVol: Float = -12000, attVol: Float = -12000, holdVol: Float = -12000, decVol: Float = -12000, susVol: Float = 0, relVol: Float = -12000
    var keyToHoldVol: Float = 0, keyToDecVol: Float = 0, keyToHoldMod: Float = 0, keyToDecMod: Float = 0
    var fixedKey = -1, fixedVel = -1
    var exclusive = 0
}

/// A memory-mapped SoundFont. Banks are kept for the life of the app (a few at most), so nothing a playing voice points at is ever unmapped.
final class SF2Bank {
    private struct PresetHeader { var name: String; var program: Int; var bank: Int; var bagIndex: Int }
    private struct Bag { var gen: Int; var mod: Int }
    private struct Gen { var op: Int; var amount: UInt16 }
    private struct InstHeader { var bagIndex: Int }
    private struct SampleHeader { var start: Int, end: Int, loopStart: Int, loopEnd: Int, rate: Int, pitch: Int, correction: Int, type: Int }

    private let base: UnsafeRawPointer
    private let size: Int
    private var samples: UnsafePointer<Int16>
    private var sampleCount = 0
    private var presets: [PresetHeader] = [], pbag: [Bag] = [], pgen: [Gen] = []
    private var insts: [InstHeader] = [], ibag: [Bag] = [], igen: [Gen] = []
    private var shdr: [SampleHeader] = []

    private static var cache: [String: SF2Bank] = [:]
    private static let lock = NSLock()

    static func open(_ url: URL) throws -> SF2Bank {
        lock.lock(); defer { lock.unlock() }
        let key = url.path
        if let b = cache[key] { return b }
        let b = try SF2Bank(url: url)
        cache[key] = b
        return b
    }

    private init(url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { throw SF2Error.unreadable("Couldn't open \(url.lastPathComponent).") }
        defer { Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 64 else { throw SF2Error.unreadable("\(url.lastPathComponent) is empty.") }
        let n = Int(st.st_size)
        guard let m = mmap(nil, n, PROT_READ, MAP_PRIVATE, fd, 0), m != UnsafeMutableRawPointer(bitPattern: -1) else { throw SF2Error.unreadable("Couldn't read \(url.lastPathComponent).") }
        base = UnsafeRawPointer(m); size = n
        samples = UnsafeRawPointer(m).assumingMemoryBound(to: Int16.self)
        try parse(name: url.lastPathComponent)
    }

    private func u16(_ o: Int) -> Int { Int(base.loadUnaligned(fromByteOffset: o, as: UInt16.self)) }
    private func u32(_ o: Int) -> Int { Int(base.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
    private func tag(_ o: Int) -> String { String(decoding: UnsafeRawBufferPointer(start: base + o, count: 4), as: UTF8.self) }
    private func name(_ o: Int) -> String {
        let raw = UnsafeRawBufferPointer(start: base + o, count: 20)
        return String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    private func parse(name file: String) throws {
        guard size > 12, tag(0) == "RIFF", tag(8) == "sfbk" else { throw SF2Error.unreadable("\(file) isn't a SoundFont.") }
        var pos = 12
        var smplAt = -1, smplLen = 0
        var pdta: (Int, Int)? = nil
        while pos + 8 <= size {
            let id = tag(pos), len = u32(pos + 4)
            let body = pos + 8
            guard body + len <= size else { break }
            if id == "LIST" && len >= 4 {
                let kind = tag(body)
                if kind == "sdta" {
                    var q = body + 4
                    while q + 8 <= body + len {
                        let sid = tag(q), sl = u32(q + 4)
                        if sid == "smpl" { smplAt = q + 8; smplLen = min(sl, size - (q + 8)) }
                        q += 8 + sl + (sl & 1)
                    }
                } else if kind == "pdta" { pdta = (body + 4, body + len) }
            }
            pos = body + len + (len & 1)
        }
        guard smplAt >= 0, smplAt % 2 == 0, let (pStart, pEnd) = pdta else { throw SF2Error.unreadable("\(file) has no usable sample data.") }
        samples = (base + smplAt).assumingMemoryBound(to: Int16.self)
        sampleCount = smplLen / 2

        var q = pStart
        while q + 8 <= pEnd {
            let id = tag(q), len = u32(q + 4), b = q + 8
            guard b + len <= size else { break }
            switch id {
            case "phdr":
                for i in 0..<(len / 38) {
                    let o = b + i * 38
                    presets.append(PresetHeader(name: name(o), program: u16(o + 20), bank: u16(o + 22), bagIndex: u16(o + 24)))
                }
            case "pbag": for i in 0..<(len / 4) { pbag.append(Bag(gen: u16(b + i * 4), mod: u16(b + i * 4 + 2))) }
            case "pgen": for i in 0..<(len / 4) { pgen.append(Gen(op: u16(b + i * 4), amount: UInt16(u16(b + i * 4 + 2)))) }
            case "inst": for i in 0..<(len / 22) { insts.append(InstHeader(bagIndex: u16(b + i * 22 + 20))) }
            case "ibag": for i in 0..<(len / 4) { ibag.append(Bag(gen: u16(b + i * 4), mod: u16(b + i * 4 + 2))) }
            case "igen": for i in 0..<(len / 4) { igen.append(Gen(op: u16(b + i * 4), amount: UInt16(u16(b + i * 4 + 2)))) }
            case "shdr":
                for i in 0..<(len / 46) {
                    let o = b + i * 46
                    let corr = Int(Int8(bitPattern: base.load(fromByteOffset: o + 41, as: UInt8.self)))
                    shdr.append(SampleHeader(start: u32(o + 20), end: u32(o + 24), loopStart: u32(o + 28), loopEnd: u32(o + 32), rate: u32(o + 36),
                                             pitch: Int(base.load(fromByteOffset: o + 40, as: UInt8.self)), correction: corr, type: u16(o + 44)))
                }
            default: break
            }
            q = b + len + (len & 1)
        }
        guard presets.count > 1, pbag.count > 1, insts.count > 1, shdr.count > 1 else { throw SF2Error.unreadable("\(file) has no sounds in it.") }
    }

    // MARK: Building a preset

    private static let defaults: [Int: Int] = [
        8: 13500, 21: -12000, 23: -12000, 25: -12000, 26: -12000, 27: -12000, 28: -12000, 30: -12000,
        33: -12000, 34: -12000, 35: -12000, 36: -12000, 38: -12000, 56: 100, 58: -1,
    ]
    private static let instrumentOnly: Set<Int> = [0, 1, 2, 3, 4, 12, 45, 50, 46, 47, 54, 57, 58, 53, 41, 43, 44]

    private func generators(of bag: Int, in bags: [Bag], gens: [Gen], endBag: Int) -> [Int: UInt16] {
        var out: [Int: UInt16] = [:]
        guard bag + 1 < bags.count else { return out }
        let from = bags[bag].gen, to = min(bags[bag + 1].gen, gens.count)
        if from < to { for g in gens[from..<to] { out[g.op] = g.amount } }
        return out
    }

    private func signed(_ v: UInt16) -> Int { Int(Int16(bitPattern: v)) }

    /// Every region of the preset `bank`:`program`, or nil if the file has no such preset.
    func regions(bank: Int, program: Int) -> [SF2Region]? {
        guard let pi = presets.indices.dropLast().first(where: { presets[$0].bank == bank && presets[$0].program == program }) else { return nil }
        var out: [SF2Region] = []
        let pFirst = presets[pi].bagIndex, pLast = min(presets[pi + 1].bagIndex, pbag.count - 1)
        guard pFirst < pLast else { return nil }
        var pGlobal: [Int: UInt16] = [:]
        for zb in pFirst..<pLast {
            let zone = generators(of: zb, in: pbag, gens: pgen, endBag: pLast)
            guard let instAmount = zone[41] else { if zb == pFirst { pGlobal = zone }; continue }
            let pg = pGlobal.merging(zone) { _, new in new }
            let ii = Int(instAmount)
            guard ii + 1 < insts.count else { continue }
            let iFirst = insts[ii].bagIndex, iLast = min(insts[ii + 1].bagIndex, ibag.count - 1)
            guard iFirst < iLast else { continue }
            var iGlobal: [Int: UInt16] = [:]
            for ib in iFirst..<iLast {
                let izone = generators(of: ib, in: ibag, gens: igen, endBag: iLast)
                guard let sid = izone[53] else { if ib == iFirst { iGlobal = izone }; continue }
                let ig = iGlobal.merging(izone) { _, new in new }
                if let r = makeRegion(sample: Int(sid), inst: ig, preset: pg) { out.append(r) }
            }
        }
        return out.isEmpty ? nil : out
    }

    private func makeRegion(sample: Int, inst ig: [Int: UInt16], preset pg: [Int: UInt16]) -> SF2Region? {
        guard sample < shdr.count - 1 else { return nil }
        let sh = shdr[sample]
        if sh.type & 0x8000 != 0 { return nil }                          // ROM samples aren't in the file
        func range(_ op: Int) -> (Int, Int) {
            func one(_ g: [Int: UInt16]) -> (Int, Int) { g[op].map { (Int($0 & 0xFF), Int($0 >> 8)) } ?? (0, 127) }
            let a = one(ig), b = one(pg)
            return (max(a.0, b.0), min(a.1, b.1))
        }
        let keys = range(43), vels = range(44)
        guard keys.0 <= keys.1, vels.0 <= vels.1 else { return nil }
        func val(_ op: Int) -> Float {
            let d = Self.defaults[op] ?? 0
            let i = ig[op].map { signed($0) } ?? d
            let p = Self.instrumentOnly.contains(op) ? 0 : (pg[op].map { signed($0) } ?? 0)
            return Float(i + p)
        }
        var r = SF2Region()
        r.keyLo = UInt8(keys.0); r.keyHi = UInt8(keys.1); r.velLo = UInt8(vels.0); r.velHi = UInt8(vels.1)
        func off(_ fine: Int, _ coarse: Int) -> Int { (ig[fine].map { signed($0) } ?? 0) + 32768 * (ig[coarse].map { signed($0) } ?? 0) }
        let limit = max(0, sampleCount - 1)
        let start = min(max(0, sh.start + off(0, 4)), limit)
        let end = min(max(start, sh.end + off(1, 12)), limit)
        guard end - start >= 2 else { return nil }
        var ls = min(max(start, sh.loopStart + off(2, 45)), end)
        var le = min(max(start, sh.loopEnd + off(3, 50)), end)
        r.data = samples; r.start = start; r.end = end
        var mode = ig[54].map { Int($0 & 3) } ?? 0
        if mode == 2 { mode = 0 }
        if le - ls < 8 { mode = 0; ls = start; le = end }
        r.loopMode = mode; r.loopStart = ls; r.loopEnd = le
        r.sampleRate = Float(max(sh.rate, 1))
        let override = ig[58].map { signed($0) } ?? -1
        r.rootKey = override >= 0 ? override : (sh.pitch == 255 ? 60 : sh.pitch)
        r.tuneCents = val(51) * 100 + val(52) + Float(sh.correction)
        r.scaleTuning = val(56)
        r.attenCb = val(48)
        r.pan = max(-500, min(500, val(17)))
        r.fcCents = val(8); r.qCb = val(9)
        r.modLfoToPitch = val(5); r.vibLfoToPitch = val(6); r.modEnvToPitch = val(7)
        r.modLfoToFc = val(10); r.modEnvToFc = val(11); r.modLfoToVol = val(13)
        r.delayModLfo = val(21); r.freqModLfo = val(22); r.delayVibLfo = val(23); r.freqVibLfo = val(24)
        r.delayMod = val(25); r.attMod = val(26); r.holdMod = val(27); r.decMod = val(28); r.susMod = val(29); r.relMod = val(30)
        r.keyToHoldMod = val(31); r.keyToDecMod = val(32)
        r.delayVol = val(33); r.attVol = val(34); r.holdVol = val(35); r.decVol = val(36); r.susVol = val(37); r.relVol = val(38)
        r.keyToHoldVol = val(39); r.keyToDecVol = val(40)
        r.fixedKey = ig[46].map { signed($0) } ?? -1
        r.fixedVel = ig[47].map { signed($0) } ?? -1
        r.exclusive = ig[57].map { Int($0) } ?? 0
        return r
    }

    /// Reads the sample data the regions use once, so the first note doesn't wait for the disk.
    func prefetch(_ regions: [SF2Region]) {
        var sum: Int16 = 0
        for r in regions {
            guard let d = r.data else { continue }
            var i = r.start
            while i <= r.end { sum = sum &+ d[i]; i += 2048 }
        }
        if sum == 0x7777 { NSLog("") }                                     // keeps the reads from being optimised away
    }
}

// MARK: - Synthesis

private struct SF2Voice {
    var active = false
    var key = 0, vel = 0, channel = 0, exclusive = 0
    var order: UInt64 = 0
    var held = false, pedalHeld = false, loopActive = false
    var r = SF2Region()
    var pos: Double = 0
    var baseCents: Float = 0, velAmp: Float = 1, attenAmp: Float = 1
    var stage = 0, stageT: Float = 0, ea: Float = 0, ed: Float = 0
    var mStage = 0, mT: Float = 0, mv: Float = 0
    var tDelay: Float = 0, tAtt: Float = 0, tHold: Float = 0, decRate: Float = 0, susDb: Float = 0, relRate: Float = 0
    var mDelay: Float = 0, mAtt: Float = 0, mHold: Float = 0, mDec: Float = 0, mSus: Float = 0, mRel: Float = 0
    var lfoModT: Float = 0, lfoModPhase: Float = 0, lfoVibT: Float = 0, lfoVibPhase: Float = 0
    var modFreq: Float = 8, vibFreq: Float = 8, modDelay: Float = 0, vibDelay: Float = 0
    var gl: Float = 0, gr: Float = 0
    var z1: Float = 0, z2: Float = 0
    var filterOn = false
}

/// The note-playing part, kept free of anything that allocates or locks so it can run on the audio thread.
final class SF2SynthCore {
    private static let maxVoices = 40
    private static let block = 32
    /// Brings a song to about the loudness Apple's sampler gave it (it plays SoundFont attenuation back much louder than the spec says).
    private static let masterGain: Float = 2

    private let voices = UnsafeMutablePointer<SF2Voice>.allocate(capacity: SF2SynthCore.maxVoices)
    private var regions: UnsafeMutablePointer<SF2Region>? = nil
    private var regionCount = 0
    private var pending: UnsafeMutablePointer<SF2Region>? = nil
    private var pendingCount = 0
    private var retired: UnsafeMutablePointer<SF2Region>? = nil
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)

    private let chVolume = UnsafeMutablePointer<Float>.allocate(capacity: 16)
    private let chExpression = UnsafeMutablePointer<Float>.allocate(capacity: 16)
    private let chPan = UnsafeMutablePointer<Float>.allocate(capacity: 16)
    private let chBend = UnsafeMutablePointer<Float>.allocate(capacity: 16)      // semitones
    private let chBendRange = UnsafeMutablePointer<Float>.allocate(capacity: 16)
    private let chPedal = UnsafeMutablePointer<Bool>.allocate(capacity: 16)
    private let chRPN = UnsafeMutablePointer<Int>.allocate(capacity: 16)

    private var sampleRate: Float = 44100
    private var counter: UInt64 = 0
    private let mono = UnsafeMutablePointer<Float>.allocate(capacity: SF2SynthCore.block)

    init() {
        lock.initialize(to: os_unfair_lock())
        voices.initialize(repeating: SF2Voice(), count: Self.maxVoices)
        resetControllers()
    }

    deinit {
        voices.deallocate(); lock.deallocate(); mono.deallocate()
        chVolume.deallocate(); chExpression.deallocate(); chPan.deallocate(); chBend.deallocate(); chBendRange.deallocate(); chPedal.deallocate(); chRPN.deallocate()
        regions?.deallocate(); pending?.deallocate(); retired?.deallocate()
    }

    private func resetControllers() {
        for c in 0..<16 { chVolume[c] = 100.0 / 127; chExpression[c] = 1; chPan[c] = 0; chBend[c] = 0; chBendRange[c] = 2; chPedal[c] = false; chRPN[c] = 0x3FFF }
    }

    func prepare(sampleRate sr: Double) { sampleRate = Float(sr) }

    /// Called from a loader thread: hands the audio thread a new set of regions. Playing notes keep their own copies, so they ring out.
    func install(_ list: [SF2Region]) {
        let p = UnsafeMutablePointer<SF2Region>.allocate(capacity: max(1, list.count))
        p.initialize(from: list, count: list.count)
        os_unfair_lock_lock(lock)
        pending?.deallocate()
        retired?.deallocate(); retired = nil
        pending = p; pendingCount = list.count
        os_unfair_lock_unlock(lock)
    }

    // MARK: Rendering

    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, events: UnsafePointer<AURenderEvent>?, sampleTime: Double) {
        if os_unfair_lock_trylock(lock) {
            if let p = pending { retired = regions; regions = p; regionCount = pendingCount; pending = nil }
            os_unfair_lock_unlock(lock)
        }
        for i in 0..<frames { left[i] = 0; right[i] = 0 }
        var ev = events
        var done = 0
        func offset(_ e: UnsafePointer<AURenderEvent>) -> Int {
            let t = e.pointee.head.eventSampleTime
            if UInt64(bitPattern: t) & 0xFFFF_FFFF_0000_0000 == 0xFFFF_FFFF_0000_0000 { return Int(t & 0xFFFF_FFFF) }
            return max(0, Int(t - Int64(sampleTime)))
        }
        while done < frames {
            while let e = ev, offset(e) <= done { handle(e); ev = e.pointee.head.next.map { UnsafePointer($0) } }
            var next = frames
            if let e = ev { next = min(frames, max(done + 1, offset(e))) }
            renderSegment(from: done, to: next, left: left, right: right)
            done = next
        }
        while let e = ev { handle(e); ev = e.pointee.head.next.map { UnsafePointer($0) } }
    }

    private func renderSegment(from: Int, to: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        var i = from
        while i < to {
            let n = min(Self.block, to - i)
            for v in 0..<Self.maxVoices where voices[v].active {
                renderVoice(voices + v, frames: n, left: left + i, right: right + i)
            }
            i += n
        }
    }

    private func renderVoice(_ vp: UnsafeMutablePointer<SF2Voice>, frames n: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let dt = Float(n) / sampleRate
        // volume envelope
        switch vp.pointee.stage {
        case 0:
            vp.pointee.stageT += dt; vp.pointee.ea = 0
            if vp.pointee.stageT >= vp.pointee.tDelay { vp.pointee.stage = 1; vp.pointee.stageT = 0 }
        case 1:
            if vp.pointee.tAtt < 0.0005 { vp.pointee.ea = 1 } else { vp.pointee.ea += dt / vp.pointee.tAtt }
            if vp.pointee.ea >= 1 { vp.pointee.ea = 1; vp.pointee.stage = 2; vp.pointee.stageT = 0 }
        case 2:
            vp.pointee.stageT += dt
            if vp.pointee.stageT >= vp.pointee.tHold { vp.pointee.stage = 3; vp.pointee.ed = 0 }
        case 3:
            vp.pointee.ed += vp.pointee.decRate * dt
            if vp.pointee.ed >= vp.pointee.susDb { vp.pointee.ed = vp.pointee.susDb; vp.pointee.stage = 4 }
        case 4: vp.pointee.ed = vp.pointee.susDb
        default:
            vp.pointee.ed += vp.pointee.relRate * dt
            if vp.pointee.ed >= 100 { vp.pointee.active = false; return }
        }
        let envAmp: Float = vp.pointee.stage <= 2 ? vp.pointee.ea : powf(10, -vp.pointee.ed / 20)
        // modulation envelope
        switch vp.pointee.mStage {
        case 0:
            vp.pointee.mT += dt
            if vp.pointee.mT >= vp.pointee.mDelay { vp.pointee.mStage = 1; vp.pointee.mT = 0 }
        case 1:
            if vp.pointee.mAtt < 0.0005 { vp.pointee.mv = 1 } else { vp.pointee.mv += dt / vp.pointee.mAtt }
            if vp.pointee.mv >= 1 { vp.pointee.mv = 1; vp.pointee.mStage = 2; vp.pointee.mT = 0 }
        case 2:
            vp.pointee.mT += dt
            if vp.pointee.mT >= vp.pointee.mHold { vp.pointee.mStage = 3 }
        case 3:
            vp.pointee.mv -= (1 - vp.pointee.mSus) * dt / max(0.001, vp.pointee.mDec)
            if vp.pointee.mv <= vp.pointee.mSus { vp.pointee.mv = vp.pointee.mSus; vp.pointee.mStage = 4 }
        case 4: break
        default: vp.pointee.mv = max(0, vp.pointee.mv - dt / max(0.001, vp.pointee.mRel))
        }
        // LFOs
        vp.pointee.lfoModT += dt; vp.pointee.lfoVibT += dt
        var modLfo: Float = 0, vibLfo: Float = 0
        if vp.pointee.lfoModT >= vp.pointee.modDelay {
            vp.pointee.lfoModPhase += vp.pointee.modFreq * dt; vp.pointee.lfoModPhase -= floorf(vp.pointee.lfoModPhase)
            modLfo = 4 * abs(vp.pointee.lfoModPhase - 0.5) - 1
        }
        if vp.pointee.lfoVibT >= vp.pointee.vibDelay {
            vp.pointee.lfoVibPhase += vp.pointee.vibFreq * dt; vp.pointee.lfoVibPhase -= floorf(vp.pointee.lfoVibPhase)
            vibLfo = 4 * abs(vp.pointee.lfoVibPhase - 0.5) - 1
        }
        let r = vp.pointee.r
        let ch = vp.pointee.channel
        let mv = vp.pointee.mv
        // pitch
        let cents = vp.pointee.baseCents + chBend[ch] * 100 + vibLfo * r.vibLfoToPitch + modLfo * r.modLfoToPitch + mv * r.modEnvToPitch
        let step = Double(exp2f(cents / 1200) * r.sampleRate / sampleRate)
        // sample fetch
        guard let data = r.data else { vp.pointee.active = false; return }
        var pos = vp.pointee.pos
        let endD = Double(r.end), loopEndD = Double(r.loopEnd), loopLen = Double(r.loopEnd - r.loopStart)
        let loopEndI = r.loopEnd, loopLenI = r.loopEnd - r.loopStart, endI = r.end
        let looping = vp.pointee.loopActive
        var produced = n
        var ended = false
        let inv: Float = 1 / 32768
        for i in 0..<n {
            if looping && pos >= loopEndD { pos -= loopLen }
            else if pos >= endD { produced = i; ended = true; break }
            let idx = Int(pos)
            let frac = Float(pos - Double(idx))
            let s0 = Float(data[idx])
            var j = idx + 1
            if looping && j >= loopEndI { j -= loopLenI } else if j > endI { j = endI }
            mono[i] = (s0 + (Float(data[j]) - s0) * frac) * inv
            pos += step
        }
        vp.pointee.pos = pos
        if produced < n { for i in produced..<n { mono[i] = 0 } }
        // filter
        if vp.pointee.filterOn {
            let fc = r.fcCents + mv * r.modEnvToFc + modLfo * r.modLfoToFc
            let hz = 8.176 * exp2f(fc / 1200)
            if hz < sampleRate * 0.45 {
                let w0 = 2 * Float.pi * max(20, hz) / sampleRate
                let q = 0.7071 * powf(10, max(0, r.qCb) / 200)
                let alpha = sinf(w0) / (2 * q), cw = cosf(w0)
                let a0 = 1 + alpha
                let b0 = (1 - cw) / 2 / a0, b1 = (1 - cw) / a0, a1 = -2 * cw / a0, a2 = (1 - alpha) / a0
                var z1 = vp.pointee.z1, z2 = vp.pointee.z2
                for i in 0..<n {
                    let x = mono[i]
                    let y = b0 * x + z1
                    z1 = b1 * x - a1 * y + z2
                    z2 = b0 * x - a2 * y
                    mono[i] = y
                }
                vp.pointee.z1 = z1; vp.pointee.z2 = z2
            }
        }
        // level and pan
        var amp = Self.masterGain * envAmp * vp.pointee.velAmp * vp.pointee.attenAmp * chVolume[ch] * chVolume[ch] * chExpression[ch] * chExpression[ch]
        if r.modLfoToVol != 0 { amp *= powf(10, r.modLfoToVol * modLfo / 200) }
        let p = max(-0.5, min(0.5, r.pan / 1000 + chPan[ch] * 0.5))
        let angle = (p + 0.5) * Float.pi / 2
        let tl = amp * cosf(angle), tr = amp * sinf(angle)
        var gl = vp.pointee.gl, gr = vp.pointee.gr
        let dl = (tl - gl) / Float(n), dr = (tr - gr) / Float(n)
        for i in 0..<n {
            gl += dl; gr += dr
            let s = mono[i]
            left[i] += s * gl; right[i] += s * gr
        }
        vp.pointee.gl = tl; vp.pointee.gr = tr
        if ended { vp.pointee.active = false }
    }

    // MARK: MIDI

    private func handle(_ e: UnsafePointer<AURenderEvent>) {
        switch e.pointee.head.eventType {
        case .MIDI:
            let d = e.pointee.MIDI.data
            midi(status: d.0, d1: d.1, d2: d.2)
        case .midiEventList:
            handleList(e)
        default: break
        }
    }

    /// Notes from AVAudioEngine arrive as UMP packets. Only reads, through raw pointers: the event memory belongs to the host's
    /// real-time allocator, and writing into it (even a copy written back) corrupts that allocator.
    private func handleList(_ e: UnsafePointer<AURenderEvent>) {
        let raw = UnsafeRawPointer(e)
        guard let listOffset = MemoryLayout<AUMIDIEventList>.offset(of: \AUMIDIEventList.eventList),
              let packetOffset = MemoryLayout<MIDIEventList>.offset(of: \MIDIEventList.packet),
              let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words) else { return }
        let list = raw + listOffset
        let numPackets = Int(list.load(as: MIDIEventList.self).numPackets)
        var packet = list + packetOffset
        for _ in 0..<numPackets {
            let count = Int(packet.load(fromByteOffset: MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.wordCount) ?? 12, as: UInt32.self))
            guard count > 0, count <= 64 else { return }
            let w = packet + wordsOffset
            var i = 0
            while i < count {
                let word = w.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                let type = word >> 28
                if type == 2 {
                    midi(status: UInt8((word >> 16) & 0xFF), d1: UInt8((word >> 8) & 0xFF), d2: UInt8(word & 0xFF)); i += 1
                } else if type == 4, i + 1 < count {
                    let status = UInt8((word >> 16) & 0xF0), channel = UInt8((word >> 16) & 0x0F)
                    let d1 = UInt8((word >> 8) & 0xFF)
                    let v = w.loadUnaligned(fromByteOffset: (i + 1) * 4, as: UInt32.self)
                    switch status {
                    case 0x90, 0x80: midi(status: status | channel, d1: d1, d2: UInt8(min(127, max(status == 0x90 ? 1 : 0, Int(v >> 25)))))
                    case 0xB0: midi(status: status | channel, d1: d1, d2: UInt8(v >> 25))
                    case 0xE0:
                        let bend = Int(v >> 18)
                        midi(status: status | channel, d1: UInt8(bend & 0x7F), d2: UInt8((bend >> 7) & 0x7F))
                    default: break
                    }
                    i += 2
                } else if type == 0 || type == 1 || type == 6 || type == 7 { i += 1 }
                else if type == 3 || type == 5 { i += 2 } else { i += 4 }
            }
            // the next packet starts after this one's words, rounded up to 4 bytes (what MIDIEventPacketNext does)
            let size = wordsOffset + count * 4
            packet = packet + ((size + 3) & ~3)
        }
    }

    func midi(status: UInt8, d1: UInt8, d2: UInt8) {
        let ch = Int(status & 0x0F)
        switch status & 0xF0 {
        case 0x90: if d2 > 0 { noteOn(key: Int(d1), vel: Int(d2), channel: ch) } else { noteOff(key: Int(d1), channel: ch) }
        case 0x80: noteOff(key: Int(d1), channel: ch)
        case 0xB0: controller(Int(d1), Int(d2), channel: ch)
        case 0xE0:
            let v = Int(d1) | Int(d2) << 7
            chBend[ch] = Float(v - 8192) / 8192 * chBendRange[ch]
        default: break
        }
    }

    private func controller(_ cc: Int, _ v: Int, channel ch: Int) {
        switch cc {
        case 7: chVolume[ch] = Float(v) / 127
        case 11: chExpression[ch] = Float(v) / 127
        case 10: chPan[ch] = (Float(v) - 64) / 64
        case 64:
            let down = v >= 64
            chPedal[ch] = down
            if !down { for i in 0..<Self.maxVoices where voices[i].active && voices[i].channel == ch && voices[i].pedalHeld { voices[i].pedalHeld = false; release(voices + i) } }
        case 101: chRPN[ch] = (chRPN[ch] & 0x7F) | (v << 7)
        case 100: chRPN[ch] = (chRPN[ch] & 0x3F80) | v
        case 6: if chRPN[ch] == 0 { chBendRange[ch] = Float(v) }
        case 120: for i in 0..<Self.maxVoices where voices[i].active && voices[i].channel == ch { fastRelease(voices + i) }
        case 123: for i in 0..<Self.maxVoices where voices[i].active && voices[i].channel == ch && voices[i].held { voices[i].held = false; voices[i].pedalHeld = false; release(voices + i) }
        case 121:
            chVolume[ch] = 100.0 / 127; chExpression[ch] = 1; chPan[ch] = 0; chBend[ch] = 0; chPedal[ch] = false
        default: break
        }
    }

    private func noteOn(key: Int, vel: Int, channel ch: Int) {
        guard let regs = regions else { return }
        for ri in 0..<regionCount {
            let r = regs[ri]
            guard key >= Int(r.keyLo), key <= Int(r.keyHi), vel >= Int(r.velLo), vel <= Int(r.velHi) else { continue }
            if r.exclusive != 0 {
                for i in 0..<Self.maxVoices where voices[i].active && voices[i].exclusive == r.exclusive && voices[i].channel == ch { fastRelease(voices + i) }
            }
            start(r, key: key, vel: vel, channel: ch)
        }
    }

    private func freeVoice() -> UnsafeMutablePointer<SF2Voice> {
        var oldest = 0, oldestOrder = UInt64.max, quiet = -1, quietEd: Float = -1
        for i in 0..<Self.maxVoices {
            if !voices[i].active { return voices + i }
            if voices[i].stage == 5, voices[i].ed > quietEd { quiet = i; quietEd = voices[i].ed }
            if voices[i].order < oldestOrder { oldest = i; oldestOrder = voices[i].order }
        }
        return voices + (quiet >= 0 ? quiet : oldest)
    }

    private func seconds(_ tc: Float) -> Float { exp2f(max(-12000, min(8000, tc)) / 1200) }

    private func start(_ r: SF2Region, key: Int, vel: Int, channel ch: Int) {
        let vp = freeVoice()
        var v = SF2Voice()
        counter &+= 1
        v.active = true; v.key = key; v.vel = vel; v.channel = ch; v.exclusive = r.exclusive
        v.order = counter; v.held = true
        v.r = r
        v.pos = Double(r.start)
        v.loopActive = r.loopMode != 0
        let k = r.fixedKey >= 0 ? r.fixedKey : key
        let velocity = r.fixedVel >= 0 ? r.fixedVel : vel
        v.baseCents = Float(k - r.rootKey) * r.scaleTuning + r.tuneCents
        let vv = Float(max(1, velocity)) / 127
        v.velAmp = vv * vv
        v.attenAmp = powf(10, -max(0, min(1440, r.attenCb)) / 200)
        let kk = Float(60 - k)
        v.tDelay = seconds(r.delayVol)
        v.tAtt = seconds(r.attVol)
        v.tHold = seconds(r.holdVol + r.keyToHoldVol * kk)
        let dec = seconds(r.decVol + r.keyToDecVol * kk)
        v.susDb = max(0, min(144, r.susVol / 10))
        v.decRate = 100 / max(0.001, dec)
        v.relRate = 100 / max(0.001, seconds(r.relVol))
        v.mDelay = seconds(r.delayMod); v.mAtt = seconds(r.attMod)
        v.mHold = seconds(r.holdMod + r.keyToHoldMod * kk)
        v.mDec = seconds(r.decMod + r.keyToDecMod * kk)
        v.mSus = max(0, min(1, 1 - r.susMod / 1000))
        v.mRel = seconds(r.relMod)
        v.modFreq = 8.176 * exp2f(r.freqModLfo / 1200); v.vibFreq = 8.176 * exp2f(r.freqVibLfo / 1200)
        v.modDelay = seconds(r.delayModLfo); v.vibDelay = seconds(r.delayVibLfo)
        v.filterOn = r.fcCents < 13400
        vp.pointee = v
    }

    private func noteOff(key: Int, channel ch: Int) {
        for i in 0..<Self.maxVoices where voices[i].active && voices[i].held && voices[i].key == key && voices[i].channel == ch {
            voices[i].held = false
            if chPedal[ch] { voices[i].pedalHeld = true } else { release(voices + i) }
        }
    }

    private func release(_ vp: UnsafeMutablePointer<SF2Voice>) {
        if vp.pointee.stage == 5 { return }
        if vp.pointee.stage <= 2 { vp.pointee.ed = -20 * log10f(max(vp.pointee.ea, 1e-5)) }
        vp.pointee.stage = 5
        vp.pointee.mStage = 5
        if vp.pointee.r.loopMode == 3 { vp.pointee.loopActive = false }
    }

    private func fastRelease(_ vp: UnsafeMutablePointer<SF2Voice>) {
        release(vp)
        vp.pointee.relRate = 100 / 0.03
        vp.pointee.held = false
        vp.pointee.pedalHeld = false
    }
}

// MARK: - Audio Unit

final class SF2AudioUnit: AUAudioUnit {
    let core = SF2SynthCore()
    private var bus: AUAudioUnitBus!
    private var busses: AUAudioUnitBusArray!
    private static let spareFrames = 8192
    private let ownBuffers: [UnsafeMutablePointer<Float>] = (0..<2).map { _ in
        let p = UnsafeMutablePointer<Float>.allocate(capacity: SF2AudioUnit.spareFrames)
        p.initialize(repeating: 0, count: SF2AudioUnit.spareFrames)
        return p
    }

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        bus = try AUAudioUnitBus(format: format)
        busses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [bus])
        maximumFramesToRender = 4096
    }

    deinit { for b in ownBuffers { b.deallocate() } }

    override var outputBusses: AUAudioUnitBusArray { busses }
    override var audioUnitMIDIProtocol: MIDIProtocolID { ._1_0 }
    override var isMusicDeviceOrEffect: Bool { true }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        core.prepare(sampleRate: bus.format.sampleRate)
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let core = self.core
        let spare = ownBuffers
        return { _, timestamp, frameCount, _, outputData, events, _ in
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            var frames = Int(frameCount)
            guard abl.count >= 1 else { return noErr }
            var left = abl[0].mData?.assumingMemoryBound(to: Float.self)
            var right = abl.count > 1 ? abl[1].mData?.assumingMemoryBound(to: Float.self) : nil
            if left == nil, spare.count == 2 { left = spare[0]; abl[0].mData = UnsafeMutableRawPointer(spare[0]) }
            if abl.count > 1, right == nil, spare.count == 2 { right = spare[1]; abl[1].mData = UnsafeMutableRawPointer(spare[1]) }
            if abl[0].mData == UnsafeMutableRawPointer(spare.first) { frames = min(frames, SF2AudioUnit.spareFrames) }
            guard let l = left else { return noErr }
            let r = right ?? l
            core.render(frames: frames, left: l, right: r, events: events, sampleTime: timestamp.pointee.mSampleTime)
            for i in 0..<abl.count { abl[i].mDataByteSize = UInt32(frames * 4) }
            return noErr
        }
    }
}

/// What the engine plays on iOS in place of `AVAudioUnitSampler`: a MIDI instrument that reads General MIDI sounds out of a SoundFont.
final class SF2Instrument: AVAudioUnitMIDIInstrument {
    static let description = AudioComponentDescription(
        componentType: kAudioUnitType_MusicDevice, componentSubType: 0x6D62_7366, componentManufacturer: 0x4D42_6E64,
        componentFlags: 0, componentFlagsMask: 0)
    private static let registered: Void = {
        AUAudioUnit.registerSubclass(SF2AudioUnit.self, as: SF2Instrument.description, name: "MacBand Studio: SoundFont", version: 1)
    }()

    override convenience init() {
        _ = Self.registered
        self.init(audioComponentDescription: Self.description)
    }

    /// Same call the Mac sampler has: `bankMSB` 0x78 asks for a drum kit (SoundFont bank 128), 0x79 for a melodic sound in bank `bankLSB`.
    func loadSoundBankInstrument(at url: URL, program: UInt8, bankMSB: UInt8, bankLSB: UInt8) throws {
        let bank = try SF2Bank.open(url)
        let number = bankMSB == UInt8(kAUSampler_DefaultPercussionBankMSB) ? 128 : Int(bankLSB)
        guard let regions = bank.regions(bank: number, program: Int(program)) else { throw SF2Error.missingPreset(bank: number, program: Int(program)) }
        bank.prefetch(regions)
        guard let unit = auAudioUnit as? SF2AudioUnit else { throw SF2Error.unreadable("The sound engine isn't ready.") }
        unit.core.install(regions)
    }

    /// GarageBand and Logic sampler instruments (.exs) are Mac files.
    func loadInstrument(at url: URL) throws {
        throw SF2Error.unreadable("Sampler instruments (.exs) can't be played on iOS. Use a SoundFont instead.")
    }
}

typealias SamplerUnit = SF2Instrument
#endif
