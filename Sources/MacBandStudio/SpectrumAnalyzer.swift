import Foundation
import AVFoundation
import Accelerate

/// The most recent seconds of the mixed output as mono samples. The audio thread writes, the main thread reads;
/// a half-written block only costs a frame of slightly wrong visuals, so no lock is used.
final class SampleRing: @unchecked Sendable {
    static let size = 16384
    private let ptr = UnsafeMutablePointer<Float>.allocate(capacity: SampleRing.size)
    private var writeIndex = 0
    private(set) var totalWritten = 0                  // samples written since the start (for readers that want only what is new)
    private(set) var sampleRate: Double = 44100
    init() { ptr.initialize(repeating: 0, count: Self.size) }
    deinit { ptr.deallocate() }

    func write(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData else { return }
        let n = Int(buf.frameLength), chans = max(1, Int(buf.format.channelCount))
        sampleRate = buf.format.sampleRate
        var w = writeIndex
        for i in 0..<n {
            var v: Float = 0
            for c in 0..<chans { v += ch[c][i] }
            ptr[w] = v / Float(chans)
            w = (w + 1) & (Self.size - 1)
        }
        writeIndex = w
        totalWritten &+= n
    }

    /// Writes plain samples (tests).
    func write(_ samples: [Float], sampleRate sr: Double) {
        sampleRate = sr
        var w = writeIndex
        for v in samples { ptr[w] = v; w = (w + 1) & (Self.size - 1) }
        writeIndex = w
        totalWritten &+= samples.count
    }

    /// Fills `out` with the samples written since `last` (the value an earlier call returned; -1 for the first call, which starts empty)
    /// and returns the new total. If more than the ring holds arrived, only the newest are kept.
    func newSamples(since last: Int, into out: inout [Float]) -> Int {
        let total = totalWritten, w = writeIndex
        let n = last < 0 ? 0 : min(max(0, total - last), Self.size - 2048)
        if out.count != n { out = [Float](repeating: 0, count: n) }
        var r = (w - n) & (Self.size - 1)
        for i in 0..<n { out[i] = ptr[r]; r = (r + 1) & (Self.size - 1) }
        return total
    }

    /// Copies the latest `count` samples (oldest first).
    func latest(_ count: Int, into out: inout [Float]) {
        let n = min(count, Self.size)
        if out.count != n { out = [Float](repeating: 0, count: n) }
        var r = (writeIndex - n) & (Self.size - 1)
        for i in 0..<n { out[i] = ptr[r]; r = (r + 1) & (Self.size - 1) }
    }
}

/// Turns the output into 72 smoothed, log-spaced frequency bands (0…1) plus a waveform, an overall level and a bass level.
final class SpectrumAnalyzer {
    static let bandCount = 72
    static let lowHz = 30.0, highHz = 16000.0
    static let floorDB = -72.0, ceilingDB = -8.0
    let fftSize = 4096

    private(set) var bands = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private(set) var peaks = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private(set) var wave = [Float](repeating: 0, count: 1024)
    private(set) var level: Float = 0           // overall loudness 0…1
    private(set) var bass: Float = 0            // energy in the lowest bands 0…1

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var samples = [Float]()
    private var reference: Float = 1            // FFT magnitude of a full-scale sine, so 0 dB means full scale

    init() {
        log2n = vDSP_Length(log2(Double(fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        // calibrate: a full-scale 1 kHz sine defines 0 dB
        let sr = 44100.0
        let sine = (0..<fftSize).map { Float(sin(2 * Double.pi * 1000 * Double($0) / sr)) }
        reference = max(1e-6, magnitudes(of: sine).max() ?? 1)
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    /// Centre frequency of a band.
    static func bandFrequency(_ i: Int) -> Double { lowHz * pow(highHz / lowHz, (Double(i) + 0.5) / Double(bandCount)) }
    static func bandEdge(_ i: Int) -> Double { lowHz * pow(highHz / lowHz, Double(i) / Double(bandCount)) }

    private func magnitudes(of x: [Float]) -> [Float] {
        var frame = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(x, 1, window, 1, &frame, 1, vDSP_Length(fftSize))
        var re = [Float](repeating: 0, count: fftSize / 2), im = [Float](repeating: 0, count: fftSize / 2)
        var power = [Float](repeating: 0, count: fftSize / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2)) }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(fftSize / 2))
            }
        }
        return power.map { $0.squareRoot() }
    }

    /// One analysis step from the latest samples. `dt` is the time since the last step (smoothing is per 1/60 s).
    func update(from ring: SampleRing, dt: Double) {
        ring.latest(fftSize, into: &samples)
        let sr = ring.sampleRate
        let mags = magnitudes(of: samples)
        let binHz = sr / Double(fftSize)
        let n = Self.bandCount
        let k = Float(min(3, max(0.3, dt * 60)))              // frames elapsed, for frame-rate independent smoothing

        var target = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let lo = Self.bandEdge(i), hi = Self.bandEdge(i + 1)
            var b0 = Int((lo / binHz).rounded(.down)), b1 = Int((hi / binHz).rounded(.up))
            b0 = max(1, b0); b1 = min(fftSize / 2 - 1, max(b0, b1))
            var m: Float = 0
            for b in b0...b1 { m = max(m, mags[b]) }
            let db = 20 * log10(max(m / reference, 1e-7))
            // lift the highs a little (music falls about 3 dB per octave), so the right side of the display isn't empty
            let tilt = 2.5 * log2(max(0.2, Self.bandFrequency(i) / 500))
            let v = (Double(db) + tilt - Self.floorDB) / (Self.ceilingDB - Self.floorDB)
            target[i] = Float(min(1, max(0, v)))
        }
        for i in 0..<n {
            let rise = 1 - pow(1 - 0.65, k), fall = 1 - pow(1 - 0.14, k)
            bands[i] += (target[i] - bands[i]) * (target[i] > bands[i] ? rise : fall)
            if bands[i] < 0.002 { bands[i] = 0 }
            peaks[i] = max(bands[i], peaks[i] - 0.012 * k)
        }
        ring.latest(wave.count, into: &wave)
        var rms: Float = 0
        vDSP_rmsqv(wave, 1, &rms, vDSP_Length(wave.count))
        let rmsDB = rms > 1e-6 ? 20 * log10(rms) : -90
        let lv = Float(min(1, max(0, (rmsDB + 50) / 40)))
        level += (lv - level) * (lv > level ? 0.5 : 0.12)
        let bassNow = bands[0..<10].reduce(0, +) / 10
        bass += (bassNow - bass) * (bassNow > bass ? 0.6 : 0.15)
    }

    func reset() {
        for i in 0..<Self.bandCount { bands[i] = 0; peaks[i] = 0 }
        level = 0; bass = 0
    }
}
