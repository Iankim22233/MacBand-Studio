import Foundation
import SwiftUI

/// Live loudness of every track for the glow on its panel: 0 = silent (normal brightness) up to 1 = very loud.
/// `level` follows the track's loudness as measured (the average power since the last update, about 30 times a second,
/// on a decibel scale) with meter ballistics (up almost at once, down over about a fifth of a second so it doesn't flicker)
/// and drives the level bar. `glow` is the same thing damped a little (it rises
/// quickly and falls over a fraction of a second) and eased so soft sounds barely light the panel, which keeps the light
/// from flickering and from getting too bright.
@MainActor
final class TrackLevels: ObservableObject {
    @Published private(set) var glow: [UUID: Double] = [:]      // the panel light: damped and gentler
    @Published private(set) var level: [UUID: Double] = [:]     // the level bar: the volume as measured, undamped
    private var smoothed: [UUID: Double] = [:]
    private var barSmoothed: [UUID: Double] = [:]
    private var timer: Timer?
    private weak var engine: AudioEngine?

    /// The RMS level that maps to 0 and to 1.
    nonisolated static let floorDB = -54.0, ceilingDB = -14.0

    func attach(_ engine: AudioEngine) {
        self.engine = engine
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Maps mean-square power to 0…1 on a decibel scale.
    nonisolated static func brightness(forPower meanSquare: Double) -> Double {
        guard meanSquare > 1e-9 else { return 0 }
        let db = 10 * log10(meanSquare)
        let x = min(1, max(0, (db - floorDB) / (ceilingDB - floorDB)))
        return x
    }

    /// The damped light: quick to rise, slower to fall, with the soft end pushed down.
    nonisolated static func light(from smoothed: Double) -> Double { 0.85 * pow(smoothed, 1.5) }

    private func step() {
        guard let engine else { return }
        var nextGlow: [UUID: Double] = [:], nextLevel: [UUID: Double] = [:]
        var changed = false
        for (id, strip) in engine.strips {
            let power = strip.levelPower, count = strip.levelCount
            strip.levelPower = 0; strip.levelCount = 0       // the audio thread keeps adding between our reads
            let raw = count > 0 ? Self.brightness(forPower: power / Double(count)) : 0
            let prev = smoothed[id] ?? 0
            var v = raw > prev ? prev + (raw - prev) * 0.45 : prev + (raw - prev) * 0.12
            if v < 0.01 { v = 0 }
            smoothed[id] = v
            let g = Self.light(from: v)
            if g > 0 { nextGlow[id] = g }
            let barPrev = barSmoothed[id] ?? 0
            var bar = raw > barPrev ? barPrev + (raw - barPrev) * 0.85 : barPrev + (raw - barPrev) * 0.22
            if bar < 0.01 { bar = 0 }
            barSmoothed[id] = bar
            if bar > 0 { nextLevel[id] = bar }
            if abs(g - (glow[id] ?? 0)) > 0.008 || abs(bar - (level[id] ?? 0)) > 0.008 { changed = true }
        }
        if glow.keys.contains(where: { nextGlow[$0] == nil }) || level.keys.contains(where: { nextLevel[$0] == nil }) { changed = true }
        if changed { glow = nextGlow; level = nextLevel }
    }
}
