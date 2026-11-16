import Foundation

/// A tempo heard in a performance: how fast the beat goes, and where a beat falls.
struct TempoEstimate {
    var bpm: Double
    var offset: Double          // seconds: some beat falls here (beats fall every 60/bpm seconds from it)
    var confidence: Double      // 0…1, how well the notes sit on that beat's grid
    var alsoFits: [Double] = [] // other tempos (half or double) that the notes fit just as well: they can't be told apart from the notes alone
    var period: Double { 60 / bpm }
    /// The beat a time falls on, counted so that the grid's beat nearest the start keeps its number.
    func beat(atSeconds t: Double) -> Double { (t - offset) / period + (offset / period).rounded() }
}

/// Finds the tempo of played notes without being thrown off by eighth notes, triplets or sixteenths.
///
/// A beat grid is judged by how well the notes sit on it: a note on a beat counts fully, on an eighth, a triplet or a sixteenth
/// counts less (but still counts), and a note on none of them counts against it. So a bar of quarter notes with eighth-note and triplet
/// fills still reads as the quarter-note tempo, instead of a tempo made from the fastest notes. Music also repeats itself bar after bar
/// at its true tempo, which a wrong tempo (eighths mistaken for triplets, say) breaks, so a tempo whose bars repeat scores higher.
enum TempoDetect {
    static let range: ClosedRange<Double> = 60...160
    static let minimumNotes = 6
    static let minimumSpan = 2.0                  // seconds the notes must cover
    static let repetitionWeight = 0.45            // how much a tempo whose bars repeat counts, next to how well the notes sit on its grid
    static let repetitionTolerance = 0.06         // seconds: how far off a repeated note may be

    /// Where notes can sit inside a beat and how much each place counts.
    private static let places: [(pos: Double, weight: Double)] = [
        (0, 1), (1, 1), (0.5, 0.6), (1.0 / 3, 0.42), (2.0 / 3, 0.42), (0.25, 0.3), (0.75, 0.3),
    ]

    private static func fit(_ phase: Double, tolerance: Double) -> Double {
        var best = 0.0
        for g in places {
            let x = abs(phase - g.pos) / tolerance
            if x < 1 { best = max(best, g.weight * (1 - x * x)) }
        }
        return best
    }

    /// `onsets` are note start times in seconds, `weights` how strongly each was played (a velocity from 0 to 1).
    static func estimate(onsets rawOnsets: [Double], weights rawWeights: [Double]? = nil, beatsPerBar: Double = 4) -> TempoEstimate? {
        // notes struck together (a chord) are one onset
        let order = rawOnsets.indices.sorted { rawOnsets[$0] < rawOnsets[$1] }
        var t: [Double] = [], w: [Double] = []
        for i in order {
            let weight = rawWeights?[i] ?? 1
            if let last = t.last, rawOnsets[i] - last < 0.03 { w[w.count - 1] = max(w[w.count - 1], weight); continue }
            t.append(rawOnsets[i]); w.append(weight)
        }
        guard t.count >= minimumNotes, let first = t.first, let last = t.last, last - first >= minimumSpan else { return nil }
        let wsum = w.reduce(0, +)
        let repTolerance = repetitionTolerance

        /// How much of the playing comes round again one bar later (and, failing that, two bars later).
        func repetition(_ bpm: Double) -> Double {
            var best = 0.0
            for bars in [1.0, 2.0] {
                let lag = beatsPerBar * bars * 60 / bpm
                var hit = 0.0, possible = 0.0
                for i in t.indices where t[i] + lag <= last + repTolerance {
                    possible += w[i]
                    var lo = i + 1, hi = t.count                                  // first note at or after t[i] + lag - repTolerance
                    while lo < hi { let mid = (lo + hi) / 2; if t[mid] < t[i] + lag - repTolerance { lo = mid + 1 } else { hi = mid } }
                    if lo < t.count, t[lo] <= t[i] + lag + repTolerance { hit += w[i] }
                }
                if possible >= 0.3 * wsum { best = max(best, hit / possible) }
            }
            return best
        }
        let repWeight = TempoDetect.repetitionWeight

        func score(_ bpm: Double, _ t0: Double) -> Double {
            let p = 60 / bpm
            let tol = min(0.14, 0.045 / p)
            var total = 0.0
            for i in t.indices {
                var ph = ((t[i] - t0) / p).truncatingRemainder(dividingBy: 1)
                if ph < 0 { ph += 1 }
                let f = fit(ph, tolerance: tol)
                total += w[i] * (f > 0 ? f : -0.25)
            }
            return total / wsum
        }

        // phases to try: some note starts, spread over the take
        let stride = max(1, t.count / 32)
        var anchors = Array(t.prefix(8))
        for i in Swift.stride(from: 0, to: t.count, by: stride) { anchors.append(t[i]) }

        var best: (bpm: Double, t0: Double, score: Double)?
        var bestRaw: [Double: Double] = [:]                    // best score (without the prior) at each tempo tried
        var bpm = range.lowerBound
        while bpm <= range.upperBound {
            let prior = 1 - 0.06 * abs(log2(bpm / 105))           // between equally good tempos (half or double), the more ordinary one
            let rep = repWeight * repetition(bpm)
            var rawBest = -1.0
            for a in anchors {
                let raw = score(bpm, a) + rep
                rawBest = max(rawBest, raw)
                let s = raw * prior
                if best == nil || s > best!.score { best = (bpm, a, s) }
            }
            bestRaw[bpm] = rawBest
            bpm += 0.5
        }
        guard var b = best else { return nil }

        // fine-tune: fit a line through where each well-placed note falls on the grid (time against beat number)
        for _ in 0..<3 {
            let p = 60 / b.bpm, tol = min(0.14, 0.045 / p)
            var xs: [Double] = [], ys: [Double] = []
            for i in t.indices {
                let pos = (t[i] - b.t0) / p
                let base = pos.rounded(.down)
                var snapped: Double?
                var bestD = tol
                for g in places where g.weight >= 0.3 {
                    let d = abs(pos - (base + g.pos))
                    if d < bestD { bestD = d; snapped = base + g.pos }
                }
                if let s = snapped { xs.append(s); ys.append(t[i]) }
            }
            guard xs.count >= 4 else { break }
            let n = Double(xs.count), mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
            var sxx = 0.0, sxy = 0.0
            for i in xs.indices { sxx += (xs[i] - mx) * (xs[i] - mx); sxy += (xs[i] - mx) * (ys[i] - my) }
            guard sxx > 1e-9, sxy > 0 else { break }
            let newP = sxy / sxx
            let newBPM = 60 / newP
            guard range.contains(newBPM) else { break }
            b.bpm = newBPM; b.t0 = my - newP * mx
        }
        let conf = max(0, min(1, score(b.bpm, b.t0)))
        var est = TempoEstimate(bpm: b.bpm, offset: b.t0, confidence: conf)
        // half or double the tempo that fits nearly as well (an evenly played run fits its own tempo and double) is offered as another reading
        let top = bestRaw.values.max() ?? 0
        for f in [0.5, 2.0] {
            let alt = (b.bpm * f * 2).rounded() / 2
            if range.contains(alt), let r = bestRaw[alt], r >= top - 0.25 { est.alsoFits.append(alt) }
        }
        return est
    }
}
